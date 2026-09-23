//! Pure ports of the Swift usage decoders; missing quota never means 0% used.
use super::Failure;
use crate::usage::LimitWindow;
use chrono::{Datelike, Timelike};
use serde_json::Value;

/// Keep account metadata with the reading through cache and Phone Link serialization.
pub(super) fn reading(id: &str, v: &Value) -> Result<crate::usage::UsageSnapshot, Failure> {
    let windows = match id {
        "opencode" => opencode(v),
        "kimi" => kimi(v),
        "copilot" => copilot(v),
        "devin" => devin(v),
        "minimax" => minimax(v, crate::now_ms()),
        "ollama-cloud" => ollama(v),
        _ => Err(Failure::Invalid),
    }?;
    let text = |v: &Value| {
        v.as_str()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
    };
    let plan = match id {
        "opencode" => Some("Go".into()),
        "kimi" => text(&v["user"]["membership"]["level"]).map(|s| {
            s.strip_prefix("LEVEL_")
                .unwrap_or(&s)
                .split('_')
                .map(|part| {
                    let mut chars = part.chars();
                    chars
                        .next()
                        .map(|c| c.to_uppercase().to_string() + &chars.as_str().to_lowercase())
                        .unwrap_or_default()
                })
                .collect::<Vec<_>>()
                .join(" ")
        }),
        "copilot" => text(&v["copilot_plan"]).or_else(|| text(&v["plan"])),
        "minimax" => {
            let payload = v.get("data").filter(|d| d.is_object()).unwrap_or(v);
            ["current_subscribe_title", "plan_name", "combo_title"]
                .iter()
                .find_map(|key| text(&payload[*key]))
        }
        _ => None,
    };
    Ok(crate::usage::UsageSnapshot {
        windows,
        plan,
        ..Default::default()
    })
}

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
        remaining: None,
        used_count: None,
        id: id.into(),
        label: label.into(),
        used: used.max(0.),
        has_fraction: Some(true),
        resets_at: reset,
        count: None,
        derived: false,
        group: None,
        duration: None,
        ..Default::default()
    }
}
// OpenCode uses the preceding Gregorian month; Copilot only declares a monthly
// cadence at midnight UTC on the first. Never substitute a 30-day estimate.
fn monthly_duration(reset: Option<u64>, first_only: bool) -> Option<f64> {
    let end = chrono::DateTime::from_timestamp_millis(reset?.try_into().ok()?)?;
    if first_only && (end.day() != 1 || end.hour() != 0 || end.minute() != 0 || end.second() != 0) {
        return None;
    }
    let start = end.checked_sub_months(chrono::Months::new(1))?;
    Some((end - start).num_milliseconds() as f64 / 1000.)
}
fn timed(mut window: LimitWindow, duration: Option<f64>) -> LimitWindow {
    window.duration = duration;
    window
}
fn count(id: &str, label: &str, n: f64) -> LimitWindow {
    let mut w = meter(id, label, 0., None);
    w.count = Some(n.max(0.).min(i64::MAX as f64) as i64);
    w.has_fraction = Some(false);
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
            let reset = date(&x["resetsAt"]);
            Some(timed(
                meter(id, label, number(&x["percent"])? / 100., reset),
                match *id {
                    "rolling" => Some(5. * 3600.),
                    "weekly" => Some(7. * 86400.),
                    _ => monthly_duration(reset, false),
                },
            ))
        })
        .collect(),
    )
}
pub(super) fn kimi(v: &Value) -> Result<Vec<LimitWindow>, Failure> {
    fn window(x: &Value, id: &str) -> Option<LimitWindow> {
        let used = number(&x["used"])?;
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
        w.duration = Some(if id == "weekly" {
            7. * 86400.
        } else {
            5. * 3600.
        });
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
            (Some(300.), "time_unit_minute" | "minute" | "minutes")
            | (Some(5.), "time_unit_hour" | "hour" | "hours") => "rolling",
            (Some(1.), "time_unit_week" | "week" | "weeks") => "weekly",
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
    let windows = keys
        .into_iter()
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
            let label = copilot_label(id);
            let mut w = if let Some(cap) = cap.filter(|n| *n > 0.) {
                let used = number(&x["used"])
                    .unwrap_or_else(|| (cap - number(&x["remaining"]).unwrap_or(cap)).max(0.));
                meter(id, &label, used / cap, reset)
            } else {
                let used = number(&x["used"]);
                let remaining = number(&x["remaining"]);
                if let Some(n) = used.filter(|n| *n >= 0.) {
                    count(id, &label, n.round())
                } else if used.is_none() {
                    let n = remaining.filter(|n| *n >= 0.)?.round();
                    let mut w = count(id, &label, n);
                    w.remaining = Some(n.min(i64::MAX as f64) as i64);
                    w
                } else {
                    return None;
                }
            };
            w.resets_at = reset;
            if w.count.is_none() {
                w.duration = monthly_duration(reset, true);
            }
            Some(w)
        })
        .collect::<Vec<_>>();
    (!windows.is_empty())
        .then_some(windows)
        .ok_or(Failure::Unsupported(
            "GitHub Copilot reported no metered quotas",
        ))
}

fn copilot_label(id: &str) -> String {
    match id {
        "premium_interactions" => "Premium requests".into(),
        "chat" => "Chat requests".into(),
        "completions" => "Completions".into(),
        _ => id
            .replace('_', " ")
            .split_whitespace()
            .map(|part| {
                let mut chars = part.chars();
                chars
                    .next()
                    .map(|first| first.to_uppercase().to_string() + &chars.as_str().to_lowercase())
                    .unwrap_or_default()
            })
            .collect::<Vec<_>>()
            .join(" "),
    }
}
pub(super) fn devin(v: &Value) -> Result<Vec<LimitWindow>, Failure> {
    if !v["userStatus"]["planStatus"].is_object() {
        return Err(Failure::Invalid);
    }
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
            let mut window = meter(id, label, 1. - remain.unwrap_or(0.) / 100., reset);
            window.group = Some("Usage".into());
            out.push(window);
        }
    }
    if let Some(n) = number(&p["overageBalanceMicros"]).filter(|n| *n >= 0.) {
        let cents = (n / 10_000.).round();
        if cents < 9_223_372_036_854_775_808.0 {
            let mut window = count("overage", "Extra usage balance", cents);
            window.group = Some("Extra usage".into());
            window.used_text = Some(format!("${:.2}", cents / 100.));
            out.push(window);
        }
    }
    nonempty(out)
}
pub(super) fn commandcode(
    summary: &Value,
    credits: &Value,
    sub: &Value,
) -> Result<Vec<LimitWindow>, Failure> {
    if !summary.is_object() || !credits.is_object() {
        return Err(Failure::Invalid);
    }
    let used = number(&summary["totalCost"]).unwrap_or(0.);
    let remaining = number(&credits["credits"]["monthlyCredits"]).unwrap_or(0.);
    let cap = used + remaining;
    if cap <= 0. {
        return Err(Failure::Unsupported(
            "Command Code has nothing metered on this account yet",
        ));
    }
    let sub = sub.get("data").unwrap_or(sub);
    let mut out = vec![meter(
        "monthly",
        "Monthly limit",
        used / cap,
        date(&sub["currentPeriodEnd"]),
    )];
    for (id, label) in [("fiveHour", "5h limit"), ("weekly", "Weekly limit")] {
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
            let start = date(
                &lane[if id == "weekly" {
                    "weekly_start_time"
                } else {
                    "start_time"
                }],
            );
            let duration = date(&lane[end])
                .zip(start)
                .and_then(|(end, start)| end.checked_sub(start))
                .filter(|ms| *ms > 0)
                .map(|ms| ms as f64 / 1000.)
                .unwrap_or(if id == "weekly" {
                    7. * 86400.
                } else {
                    5. * 3600.
                });
            let mut w = timed(meter(id, label, used, reset), Some(duration));
            if !unlimited {
                if pct.is_some() {
                    let boost_key = if id == "weekly" {
                        "weekly_boost_permill"
                    } else {
                        "interval_boost_permill"
                    };
                    let boost = number(&lane[boost_key])
                        .or_else(|| number(&lane[format!("{boost_key}e")]))
                        .filter(|n| *n > 0.);
                    if let Some(boost) = boost {
                        let cap = (boost / 10.).round().max(1.);
                        let spent = (used * cap).round();
                        w.used_count = Some(spent as i64);
                        w.remaining = Some((cap - spent).max(0.) as i64);
                    }
                } else {
                    w.remaining = left.map(|n| n as i64);
                    w.used_count = total
                        .zip(left)
                        .map(|(total, left)| (total - left).max(0.) as i64);
                }
            }
            out.push(w);
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
    fn kimi_wire_units_preserve_the_five_hour_window_and_plan() {
        let v = json!({"user":{"membership":{"level":"LEVEL_ADVANCED"}},"usage":{"used":"2","limit":"100"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"used":"8","limit":"100"}},{"window":{"duration":24,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"used":"99","limit":"100"}}]});
        let r = reading("kimi", &v).unwrap();
        assert_eq!(r.plan.as_deref(), Some("Advanced"));
        assert_eq!(r.windows.len(), 2);
        assert_eq!(r.windows[1].id, "rolling");
        assert_eq!(r.windows[1].used, 0.08);
        assert_eq!(r.windows[1].duration, Some(18000.));
        assert!(kimi(&json!({"usage":{"remaining":90,"limit":100}})).is_err());
    }
    #[test]
    fn copilot_unknown_denominator_keeps_remaining_and_used_distinct() {
        let r = reading("copilot", &json!({"copilot_plan":"individual","quota_snapshots":{"premium_interactions":{"remaining":72},"chat":{"used":8,"remaining":50},"completions":{"used":-2}}})).unwrap();
        assert_eq!(r.plan.as_deref(), Some("individual"));
        assert_eq!(r.windows.len(), 2);
        assert_eq!(r.windows[0].remaining, Some(72));
        assert_eq!(r.windows[1].count, Some(8));
        assert_eq!(r.windows[1].remaining, None);
    }
    #[test]
    fn minimax_plan_and_boost_counts_survive_without_changing_fraction() {
        let r = reading("minimax", &json!({"data":{"plan_name":"Starter","model_remains":[{"model_name":"general","current_interval_remaining_percent":75,"interval_boost_permill":2000}]}})).unwrap();
        assert_eq!(r.plan.as_deref(), Some("Starter"));
        assert_eq!(r.windows[0].used, 0.25);
        assert_eq!(r.windows[0].count, None);
        assert_eq!(r.windows[0].used_count, Some(50));
        assert_eq!(r.windows[0].remaining, Some(150));
    }
    #[test]
    fn reported_cycles_match_swift_including_calendar_months() {
        let leap = date(&json!("2024-03-01T00:00:00Z"));
        assert_eq!(monthly_duration(leap, true), Some(29. * 86400.));
        assert_eq!(
            monthly_duration(date(&json!("2024-03-31T12:00:00Z")), false),
            Some(31. * 86400.)
        );
        assert_eq!(
            monthly_duration(date(&json!("2024-03-01T12:00:00Z")), true),
            None
        );
        let open=opencode(&json!({"usage":{"rolling":{"percent":20},"weekly":{"percent":30},"monthly":{"percent":40,"resetsAt":"2024-03-01T00:00:00Z"}}})).unwrap();
        assert_eq!(
            open.iter().map(|w| w.duration).collect::<Vec<_>>(),
            vec![Some(18000.), Some(604800.), Some(2505600.)]
        );
        let mm=minimax(&json!({"model_remains":[{"model_name":"general","current_interval_remaining_percent":70,"start_time":1800000000000u64,"end_time":1800014400000u64}]}),1800000000000).unwrap();
        assert_eq!(mm[0].duration, Some(14400.));
    }
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
        assert_eq!(w[0].label, "Premium requests");
        assert!(copilot(&json!({"quota_snapshots":{"chat":{"entitlement":0}}})).is_err());
    }
    #[test]
    fn copilot_labels_and_devin_groups_and_balance_match_swift() {
        let copilot = copilot(&json!({"quota_snapshots":{
            "chat":{"remaining":30}, "completions":{"used":5},
            "future_meter":{"used":4}
        }}))
        .unwrap();
        assert_eq!(
            copilot.iter().map(|w| w.label.as_str()).collect::<Vec<_>>(),
            ["Chat requests", "Completions", "Future Meter"]
        );
        let d = devin(&json!({"userStatus":{"planStatus":{
            "dailyQuotaRemainingPercent":99, "weeklyQuotaRemainingPercent":50,
            "dailyQuotaResetAtUnix":"1789113600", "overageBalanceMicros":"14277951"
        }}}))
        .unwrap();
        assert_eq!(
            d.iter().map(|w| w.id.as_str()).collect::<Vec<_>>(),
            ["daily", "weekly", "overage"]
        );
        assert_eq!(d[0].group.as_deref(), Some("Usage"));
        assert_eq!(d[2].group.as_deref(), Some("Extra usage"));
        assert_eq!(d[2].label, "Extra usage balance");
        assert_eq!(d[2].count, Some(1428));
        assert_eq!(d[2].used_text.as_deref(), Some("$14.28"));
        let only_balance =
            devin(&json!({"userStatus":{"planStatus":{"overageBalanceMicros":"0"}}})).unwrap();
        assert_eq!(only_balance.len(), 1);
        assert_eq!(only_balance[0].used_text.as_deref(), Some("$0.00"));
    }
    #[test]
    fn commandcode_cap_includes_remaining_credit() {
        let w=commandcode(&json!({"totalCost":5}),&json!({"credits":{"monthlyCredits":15},"windowLimits":{"weekly":{"cap":10,"used":3,"resetAt":0}}}),&json!({"data":{}})).unwrap();
        assert_eq!(w[0].used, 0.25);
        assert_eq!(w[1].resets_at, None);
        assert_eq!(w[0].label, "Monthly limit");
        let five = commandcode(&json!({"totalCost":1}),
            &json!({"credits":{"monthlyCredits":9},"windowLimits":{"fiveHour":{"cap":10,"used":2}}}),
            &json!({})).unwrap();
        assert_eq!(five[1].label, "5h limit");
        assert!(matches!(
            commandcode(&json!({}), &json!({"credits":{}}), &json!({})),
            Err(Failure::Unsupported(_))
        ));
        assert!(matches!(
            commandcode(&json!(null), &json!({}), &json!({})),
            Err(Failure::Invalid)
        ));
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
