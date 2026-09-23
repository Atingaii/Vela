//! The envelopes shared by Antigravity's language server and Cloud Code.
//! This follows AntigravityQuotaParser.swift at the pinned reference revision.

use crate::usage::LimitWindow;
use serde_json::Value;

fn normalized(value: &str) -> String {
    value.trim().to_lowercase().replace('_', "-")
}

fn field<'a>(bucket: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter()
        .find_map(|key| bucket.get(*key)?.as_str().filter(|s| !s.trim().is_empty()))
}

fn id(bucket: &Value, group: Option<&str>) -> String {
    field(bucket, &["bucketId", "modelId", "name"])
        .or(group.filter(|name| !name.trim().is_empty()))
        .unwrap_or("quota")
        .trim()
        .into()
}

fn cadence_value(raw: &str) -> String {
    normalized(raw).trim_end_matches(" limit").to_string()
}

fn cadence(bucket: &Value) -> u8 {
    let values: Vec<_> = ["window", "bucketId", "displayName"]
        .into_iter()
        .filter_map(|key| bucket.get(key).and_then(Value::as_str))
        .map(cadence_value)
        .collect();
    if values
        .iter()
        .any(|value| value == "weekly" || value.ends_with("-weekly") || value.ends_with(" weekly"))
    {
        return 1;
    }
    if values.iter().any(|value| {
        matches!(
            value.as_str(),
            "session" | "5h" | "5-hour" | "five hour" | "five-hour" | "hourly"
        ) || ["-session", "-5h", "-5-hour", "-five-hour", "-hourly"]
            .iter()
            .any(|suffix| value.ends_with(suffix))
    }) {
        return 0;
    }
    2
}

fn duration(bucket: &Value) -> Option<f64> {
    match cadence(bucket) {
        0 => Some(5. * 3600.),
        1 => Some(7. * 86400.),
        _ => None,
    }
}

fn reset(bucket: &Value) -> Option<u64> {
    bucket
        .get("resetTime")
        .and_then(Value::as_str)
        .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok())
        .map(|date| date.timestamp_millis().max(0) as u64)
}

fn remaining(bucket: &Value) -> Option<f64> {
    bucket
        .get("remainingFraction")
        .and_then(Value::as_f64)
        .or_else(|| {
            let remaining = bucket.get("remaining")?;
            remaining
                .get("remainingFraction")
                .and_then(Value::as_f64)
                .or_else(|| {
                    (remaining.get("case").and_then(Value::as_str) == Some("remainingFraction"))
                        .then(|| remaining.get("value").and_then(Value::as_f64))
                        .flatten()
                })
        })
        .filter(|fraction| (0.0..=1.0).contains(fraction))
}

fn label(bucket: &Value, fallback: &str) -> String {
    let name = bucket
        .get("displayName")
        .and_then(Value::as_str)
        .unwrap_or(fallback);
    let name = name.strip_suffix(" Remaining").unwrap_or(name);
    if name == "Five Hour Limit" {
        "5-hour Limit".into()
    } else {
        name.into()
    }
}

fn group_rank(name: &str) -> u8 {
    let value = normalized(name);
    if value.contains("gemini") {
        0
    } else if value.contains("claude") || value.contains("gpt") {
        1
    } else {
        2
    }
}

fn measured(bucket: &Value) -> Option<f64> {
    let limit = bucket.get("limit")?.as_f64()?;
    let used = bucket.get("used")?.as_f64()?;
    (limit > 0. && used >= 0. && used <= limit * 1.5).then_some(used / limit)
}

fn window(bucket: &Value, group: Option<&str>) -> Option<LimitWindow> {
    if bucket.get("disabled").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    let raw_id = id(bucket, group);
    let fraction = remaining(bucket)
        .map(|left| 1. - left)
        .or_else(|| measured(bucket))?;
    Some(LimitWindow {
        id: raw_id.clone(),
        group: group.filter(|value| !value.is_empty()).map(str::to_owned),
        label: label(bucket, if group.is_some() { "Usage" } else { &raw_id }),
        used: fraction,
        has_fraction: Some(true),
        resets_at: reset(bucket),
        duration: duration(bucket),
        ..Default::default()
    })
}

fn grouped(groups: &[Value]) -> Vec<LimitWindow> {
    let mut groups: Vec<_> = groups.iter().enumerate().collect();
    groups.sort_by_key(|(index, group)| {
        (
            group_rank(
                group
                    .get("displayName")
                    .and_then(Value::as_str)
                    .unwrap_or(""),
            ),
            *index,
        )
    });
    let mut out = Vec::new();
    for (_, group) in groups {
        let group_name = group.get("displayName").and_then(Value::as_str);
        let Some(buckets) = group.get("buckets").and_then(Value::as_array) else {
            continue;
        };
        let mut buckets: Vec<_> = buckets.iter().enumerate().collect();
        buckets.sort_by_key(|(index, bucket)| (cadence(bucket), *index));
        out.extend(
            buckets
                .into_iter()
                .filter_map(|(_, bucket)| window(bucket, group_name)),
        );
    }
    out
}

#[derive(Clone)]
struct Candidate {
    remaining: f64,
    reset: Option<u64>,
}

fn aggregate(
    candidates: &[Candidate],
    id: &str,
    group: &str,
    label: &str,
    weekly: bool,
) -> Option<LimitWindow> {
    let best = candidates
        .iter()
        .min_by(|a, b| a.remaining.total_cmp(&b.remaining))?;
    Some(LimitWindow {
        id: id.into(),
        group: Some(group.into()),
        label: label.into(),
        used: 1. - best.remaining,
        has_fraction: Some(true),
        resets_at: best.reset,
        duration: Some(if weekly { 7. * 86400. } else { 5. * 3600. }),
        ..Default::default()
    })
}

fn models(buckets: &[Value], now: u64) -> Vec<LimitWindow> {
    let mut gemini_hourly = Vec::new();
    let mut gemini_weekly = Vec::new();
    let mut third_hourly = Vec::new();
    let mut third_weekly = Vec::new();
    for bucket in buckets {
        let Some(left) = remaining(bucket) else {
            continue;
        };
        let model = normalized(&id(bucket, None));
        if model.is_empty() || model.starts_with("chat-") {
            continue;
        }
        let reset = reset(bucket);
        let weekly =
            cadence(bucket) == 1 || reset.is_some_and(|at| at > now.saturating_add(86_400_000));
        let candidate = Candidate {
            remaining: left,
            reset,
        };
        if model.contains("gemini") {
            if weekly {
                gemini_weekly.push(candidate)
            } else {
                gemini_hourly.push(candidate)
            }
        } else if model.contains("claude") || model.contains("gpt") || model.contains("openai") {
            if weekly {
                third_weekly.push(candidate)
            } else {
                third_hourly.push(candidate)
            }
        }
    }
    [
        aggregate(
            &gemini_hourly,
            "gemini-hourly",
            "Gemini Models",
            "5-hour Limit",
            false,
        ),
        aggregate(
            &gemini_weekly,
            "gemini-weekly",
            "Gemini Models",
            "Weekly Limit",
            true,
        ),
        aggregate(
            &third_hourly,
            "3p-hourly",
            "Claude and GPT models",
            "5-hour Limit",
            false,
        ),
        aggregate(
            &third_weekly,
            "3p-weekly",
            "Claude and GPT models",
            "Weekly Limit",
            true,
        ),
    ]
    .into_iter()
    .flatten()
    .collect()
}

pub(super) fn parse(value: &Value, now: u64) -> Vec<LimitWindow> {
    let groups = value
        .pointer("/response/groups")
        .or_else(|| value.pointer("/summary/groups"))
        .or_else(|| value.get("groups"))
        .or_else(|| value.get("quotaGroups"))
        .and_then(Value::as_array);
    if let Some(groups) = groups.filter(|groups| !groups.is_empty()) {
        return grouped(groups);
    }
    let Some(buckets) = value.get("buckets").and_then(Value::as_array) else {
        return Vec::new();
    };
    if buckets.iter().any(|bucket| bucket.get("limit").is_some()) {
        buckets
            .iter()
            .filter_map(|bucket| {
                let raw_id = id(bucket, None);
                let fraction = measured(bucket)?;
                Some(LimitWindow {
                    id: raw_id.clone(),
                    label: label(bucket, &raw_id),
                    used: fraction,
                    has_fraction: Some(true),
                    resets_at: reset(bucket),
                    duration: duration(bucket),
                    ..Default::default()
                })
            })
            .collect()
    } else {
        models(buckets, now)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grouped_and_direct_model_buckets_share_window_semantics() {
        let grouped = serde_json::json!({"groups":[{"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-weekly","remaining":{"case":"remainingFraction","value":0.55}}]},{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","remainingFraction":0.86}]}]});
        let windows = parse(&grouped, 0);
        assert_eq!(
            windows
                .iter()
                .map(|window| window.id.as_str())
                .collect::<Vec<_>>(),
            ["gemini-5h", "3p-weekly"]
        );
        assert!((windows[0].used - 0.14).abs() < 0.0001);
        assert_eq!(windows[1].duration, Some(7. * 86400.));

        let direct = serde_json::json!({"buckets":[{"modelId":"claude-sonnet","remainingFraction":0.75,"resetTime":"2026-09-09T10:39:57Z"},{"modelId":"gemini-flash","remainingFraction":0.9,"resetTime":"2026-09-09T10:39:57Z"},{"modelId":"gemini-bad","remainingFraction":1.5}]});
        let now = chrono::DateTime::parse_from_rfc3339("2026-09-09T10:00:00Z")
            .unwrap()
            .timestamp_millis() as u64;
        let windows = parse(&direct, now);
        assert_eq!(
            windows
                .iter()
                .map(|window| window.id.as_str())
                .collect::<Vec<_>>(),
            ["gemini-hourly", "3p-hourly"]
        );
        assert!((windows[0].used - 0.1).abs() < 0.0001);
        assert!((windows[1].used - 0.25).abs() < 0.0001);
    }
}
