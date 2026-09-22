//! Pure ports of the Swift usage decoders; missing quota never means 0% used.
use super::Failure;
use crate::usage::LimitWindow;
use serde_json::Value;

pub(super) fn number(v: &Value) -> Option<f64> {
    v.as_f64()
        .or_else(|| v.as_str()?.trim().parse().ok())
        .filter(|n| n.is_finite())
}
pub(super) fn date(v: &Value) -> Option<u64> {
    if let Some(s) = v.as_str() {
        if let Ok(d) = chrono::DateTime::parse_from_rfc3339(s) {
            return u64::try_from(d.timestamp_millis()).ok();
        }
    }
    number(v).filter(|n| *n > 0.).map(|n| {
        if n > 1e12 {
            n as u64
        } else {
            (n * 1000.) as u64
        }
    })
}
fn meter(id: &str, label: &str, used: f64, reset: Option<u64>) -> LimitWindow {
    LimitWindow {
        id: id.into(),
        label: label.into(),
        used: used.max(0.),
        resets_at: reset,
        count: None,
        derived: false,
        group: None,
    }
}
fn count(id: &str, label: &str, n: f64) -> LimitWindow {
    let mut w = meter(id, label, 0., None);
    w.count = Some(n.max(0.).min(i64::MAX as f64) as i64);
    w
}
fn nonempty(w: Vec<LimitWindow>) -> Result<Vec<LimitWindow>, Failure> {
    if w.is_empty() {
        Err(Failure::Invalid)
    } else {
        Ok(w)
    }
}
pub(super) fn opencode(v: &Value) -> Result<Vec<LimitWindow>, Failure> {
    nonempty(
        [
            ("rolling", "5-hour limit"),
            ("weekly", "Weekly limit"),
            ("monthly", "Monthly limit"),
        ]
        .iter()
        .filter_map(|(id, label)| {
            let x = &v["usage"][*id];
            Some(meter(
                id,
                label,
                number(&x["percent"])? / 100.,
                date(&x["resetsAt"]),
            ))
        })
        .collect(),
    )
}
pub(super) fn kimi(v: &Value) -> Result<Vec<LimitWindow>, Failure> {
    fn window(x: &Value, id: &str) -> Option<LimitWindow> {
        let used =
            number(&x["used"]).or_else(|| Some(number(&x["limit"])? - number(&x["remaining"])?))?;
        let label = if id == "weekly" {
            "Weekly limit"
        } else {
            "5-hour limit"
        };
        let mut w = if let Some(limit) = number(&x["limit"]).filter(|n| *n > 0.) {
            meter(id, label, used / limit, date(&x["resetTime"]))
        } else {
            count(id, label, used)
        };
        w.resets_at = date(&x["resetTime"]);
        Some(w)
    }
    let mut out = Vec::new();
    if let Some(w) = window(&v["usage"], "weekly") {
        out.push(w);
    }
    for x in v["limits"].as_array().into_iter().flatten() {
        let d = number(&x["window"]["duration"]);
        let unit = x["window"]["timeUnit"]
            .as_str()
            .unwrap_or("")
            .to_lowercase();
        let id = match (d, unit.as_str()) {
            (Some(300.), "minute" | "minutes") | (Some(5.), "hour" | "hours") => "rolling",
            (Some(1.), "week" | "weeks") => "weekly",
            _ => continue,
        };
        if let Some(w) = window(&x["detail"], id) {
            out.retain(|w| w.id != id);
            out.push(w);
        }
    }
    nonempty(out)
}
pub(super) fn copilot(v: &Value) -> Result<Vec<LimitWindow>, Failure> {
    let quotas = v["quota_snapshots"].as_object().ok_or(Failure::Invalid)?;
    let mut keys: Vec<_> = quotas.keys().collect();
    keys.sort_by_key(|k| {
        (
            match k.as_str() {
                "premium_interactions" => 0,
                "chat" => 1,
                "completions" => 2,
                _ => 3,
            },
            k.as_str(),
        )
    });
    nonempty(
        keys.into_iter()
            .filter_map(|id| {
                let x = &quotas[id];
                if x["unlimited"] == true {
                    return None;
                }
                let cap = number(&x["entitlement"]);
                if cap == Some(0.) {
                    return None;
                }
                let reset = [
                    &x["reset_date"],
                    &x["reset_at"],
                    &x["resets_at"],
                    &v["quota_reset_date"],
                ]
                .into_iter()
                .find_map(date);
                let mut w = if let Some(cap) = cap.filter(|n| *n > 0.) {
                    let used = number(&x["used"])
                        .unwrap_or_else(|| (cap - number(&x["remaining"]).unwrap_or(cap)).max(0.));
                    meter(id, id, used / cap, reset)
                } else {
                    let n = number(&x["remaining"]).or_else(|| number(&x["used"]))?;
                    count(id, &format!("{id} · count"), n)
                };
                w.resets_at = reset;
                Some(w)
            })
            .collect(),
    )
}
pub(super) fn devin(v: &Value) -> Result<Vec<LimitWindow>, Failure> {
    let p = &v["userStatus"]["planStatus"];
    let mut out = Vec::new();
    for (id, label, hide) in [
        ("daily", "Daily quota", "hideDailyQuota"),
        ("weekly", "Weekly quota", "hideWeeklyQuota"),
    ] {
        if p[hide] == true {
            continue;
        }
        let reset = date(&p[format!("{id}QuotaResetAtUnix")]);
        let remain =
            number(&p[format!("{id}QuotaRemainingPercent")]).filter(|n| (0.0..=100.0).contains(n));
        if remain.is_some() || reset.is_some() {
            out.push(meter(id, label, 1. - remain.unwrap_or(0.) / 100., reset));
        }
    }
    if let Some(n) = number(&p["overageBalanceMicros"]).filter(|n| *n >= 0.) {
        out.push(count(
            "overage",
            &format!("Extra usage balance · ${:.2}", n / 1e6),
            (n / 10000.).round(),
        ));
    }
    nonempty(out)
}
pub(super) fn commandcode(
    summary: &Value,
    credits: &Value,
    sub: &Value,
) -> Result<Vec<LimitWindow>, Failure> {
    let used = number(&summary["totalCost"]).unwrap_or(0.);
    let remaining = number(&credits["credits"]["monthlyCredits"]).unwrap_or(0.);
    let cap = used + remaining;
    if cap <= 0. {
        return Err(Failure::Invalid);
    }
    let sub = sub.get("data").unwrap_or(sub);
    let mut out = vec![meter(
        "monthly",
        "Monthly limit",
        used / cap,
        date(&sub["currentPeriodEnd"]),
    )];
    for (id, label) in [("fiveHour", "5-hour limit"), ("weekly", "Weekly limit")] {
        let x = &credits["windowLimits"][id];
        if let Some(cap) = number(&x["cap"]).filter(|n| *n > 0.) {
            out.push(meter(
                id,
                label,
                number(&x["used"]).unwrap_or(0.) / cap,
                date(&x["resetAt"]),
            ));
        }
    }
    Ok(out)
}
pub(super) fn minimax(v: &Value, now: u64) -> Result<Vec<LimitWindow>, Failure> {
    for x in [v, &v["data"]] {
        if let Some(code) = number(&x["base_resp"]["status_code"]) {
            if code != 0. && code != 200. {
                return Err(if [1004., 401.].contains(&code) {
                    Failure::Auth
                } else if code == 429. {
                    Failure::Throttle(60)
                } else {
                    Failure::Invalid
                });
            }
        }
    }
    let body = if v["data"].is_object() { &v["data"] } else { v };
    let lanes = body["model_remains"].as_array().ok_or(Failure::Invalid)?;
    let lane = lanes
        .iter()
        .filter(|x| {
            let n = x["model_name"].as_str().unwrap_or("").trim().to_lowercase();
            n.is_empty()
                || n == "general"
                || n == "text generation"
                || n == "text-generation"
                || n.contains("minimax-m")
                || n.starts_with("m2.")
        })
        .min_by_key(|x| {
            if x["model_name"]
                .as_str()
                .unwrap_or("")
                .eq_ignore_ascii_case("general")
            {
                0
            } else {
                1
            }
        })
        .ok_or(Failure::Invalid)?;
    let mut out = Vec::new();
    for (id, prefix, end, remain, label) in [
        (
            "session",
            "current_interval",
            "end_time",
            "remains_time",
            "5-hour limit",
        ),
        (
            "weekly",
            "current_weekly",
            "weekly_end_time",
            "weekly_remains_time",
            "Weekly limit",
        ),
    ] {
        let pct = number(&lane[format!("{prefix}_remaining_percent")]);
        let status = number(&lane[format!("{prefix}_status")]);
        let total = number(&lane[format!("{prefix}_total_count")]);
        let left = number(&lane[format!("{prefix}_usage_count")]);
        let unlimited = id == "weekly" && status == Some(3.) && pct.is_some_and(|p| p >= 100.);
        if !unlimited
            && status == Some(3.)
            && total.unwrap_or(0.) == 0.
            && left.unwrap_or(0.) == 0.
            && pct.is_some_and(|p| p >= 100.)
        {
            continue;
        }
        let used = if unlimited {
            Some(0.)
        } else {
            pct.map(|p| (1. - p / 100.).max(0.))
                .or_else(|| Some((total.filter(|t| *t > 0.)? - left?) / total?))
        };
        if let Some(used) = used {
            let reset = if unlimited {
                None
            } else {
                date(&lane[end]).filter(|t| *t > now).or_else(|| {
                    number(&lane[remain])
                        .filter(|n| *n > 0.)
                        .map(|n| now.saturating_add(n as u64))
                })
            };
            out.push(meter(id, label, used, reset));
        }
    }
    nonempty(out)
}
pub(super) fn ollama(v: &Value) -> Result<Vec<LimitWindow>, Failure> {
    let mut out = Vec::new();
    for id in ["monthly", "weekly", "session"] {
        let x = &v["limits"][id];
        if let Some(n) = number(&x["usage"]).filter(|n| *n > 0.) {
            out.push(meter(id, id, n, None));
        }
        for m in x["models"].as_array().into_iter().flatten() {
            if let (Some(name), Some(n)) = (
                m["name"].as_str(),
                number(&m["request_count"]).filter(|n| *n > 0.),
            ) {
                out.push(count(&format!("{id}.{name}"), name, n));
            }
        }
    }
    nonempty(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn quota_direction_and_missing_values() {
        assert_eq!(
            opencode(&json!({"usage":{"rolling":{"percent":25}}})).unwrap()[0].used,
            0.25
        );
        assert!(opencode(&json!({"usage":{}})).is_err());
        let d=devin(&json!({"userStatus":{"planStatus":{"dailyQuotaResetAtUnix":"1757600000","weeklyQuotaRemainingPercent":"75"}}})).unwrap();
        assert_eq!(d[0].used, 1.);
        assert_eq!(d[1].used, 0.25);
        assert!(devin(&json!({"userStatus":{"planStatus":{}}})).is_err());
    }
    #[test]
    fn minimax_remaining_counts_and_millisecond_duration() {
        let w=minimax(&json!({"model_remains":[{"model_name":"video","current_interval_total_count":100,"current_interval_usage_count":1},{"model_name":"general","current_interval_total_count":"100","current_interval_usage_count":"75","remains_time":30000}]}),1000).unwrap();
        assert_eq!(w[0].used, 0.25);
        assert_eq!(w[0].resets_at, Some(31000));
        assert!(minimax(
            &json!({"base_resp":{"status_code":1004},"data":{"base_resp":{"status_code":0}}}),
            0
        )
        .is_err());
    }
    #[test]
    fn copilot_unlimited_is_not_a_full_ring() {
        let w=copilot(&json!({"quota_snapshots":{"chat":{"unlimited":true},"premium_interactions":{"entitlement":300,"remaining":225}}})).unwrap();
        assert_eq!(w.len(), 1);
        assert_eq!(w[0].used, 0.25);
        assert!(copilot(&json!({"quota_snapshots":{"chat":{"entitlement":0}}})).is_err());
    }
    #[test]
    fn commandcode_cap_includes_remaining_credit() {
        let w=commandcode(&json!({"totalCost":5}),&json!({"credits":{"monthlyCredits":15},"windowLimits":{"weekly":{"cap":10,"used":3,"resetAt":0}}}),&json!({"data":{}})).unwrap();
        assert_eq!(w[0].used, 0.25);
        assert_eq!(w[1].resets_at, None);
    }
    #[test]
    fn kimi_only_recognizes_real_windows_and_never_divides_by_zero() {
        let w=kimi(&json!({"usage":{"used":"15","limit":"0"},"limits":[{"window":{"duration":5,"timeUnit":"HOUR"},"detail":{"used":25,"limit":100}}]})).unwrap();
        assert_eq!(w[0].count, Some(15));
        assert_eq!(w[1].used, 0.25);
    }
    #[test]
    fn ollama_counts_have_no_invented_reset_or_denominator() {
        let w=ollama(&json!({"limits":{"monthly":{"usage":0.2,"models":[{"name":"qwen","request_count":4}]}},"activity":{"period":"2026-09"}})).unwrap();
        assert_eq!(w[0].used, 0.2);
        assert_eq!(w[1].count, Some(4));
        assert!(w.iter().all(|w| w.resets_at.is_none()));
        assert_eq!(number(&json!(true)), None);
        assert_eq!(date(&json!(0)), None);
    }
}
