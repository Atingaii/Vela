//! DeepSeek's signed-in account detail, ported from UsageDetail.swift and DeepSeekUsage.swift.
//! Raw API responses are parsed in memory and are never persisted or logged.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ProviderUsageDetail {
    /// Epoch milliseconds, matching the rest of the Tauri usage wire format.
    pub start: u64,
    pub end: u64,
    pub time_zone_seconds: i32,
    pub currency: String,
    pub groups: Vec<UsageDetailGroup>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct UsageDetailGroup {
    pub api_key_id: String,
    pub api_key_label: String,
    pub model: String,
    pub days: Vec<UsageDetailDay>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct UsageDetailDay {
    pub date: u64,
    pub cache_hit_tokens: i64,
    pub cache_miss_tokens: i64,
    pub output_tokens: i64,
    pub requests: i64,
    pub cost: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DeepSeekSummary {
    pub currency: String,
    pub spent: f64,
    pub balance: f64,
    pub available_tokens: Option<i64>,
}

impl DeepSeekSummary {
    pub fn used_fraction(&self) -> f64 {
        let funded = self.spent + self.balance;
        if funded > 0.0 {
            (self.spent / funded).clamp(0.0, 1.0)
        } else {
            0.0
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct DeepSeekReading {
    pub summary: DeepSeekSummary,
    pub detail: Option<ProviderUsageDetail>,
}

fn json(text: &str) -> Result<Value, &'static str> {
    serde_json::from_str(text).map_err(|_| "unreadable DeepSeek response")
}

fn scalar(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .or_else(|| value.as_str()?.trim().parse().ok())
        .filter(|n| n.is_finite())
}

fn integer(value: &Value) -> i64 {
    scalar(value).unwrap_or(0.0) as i64
}

fn text(value: &Value) -> Option<&str> {
    value.as_str().map(str::trim).filter(|s| !s.is_empty())
}

fn api_key(series: &Value) -> (String, String) {
    let key = &series["api_key"];
    let name = text(&key["name"]);
    let tracking = text(&key["tracking_id"]);
    match (name, tracking) {
        (Some(label), Some(id)) => (id.into(), label.into()),
        (Some(label), None) => (label.into(), label.into()),
        (None, Some(id)) => (id.into(), "Unnamed API key".into()),
        (None, None) => ("unknown".into(), "Unnamed API key".into()),
    }
}

fn series_key(series: &Value) -> Result<(String, String, String), &'static str> {
    let (id, label) = api_key(series);
    let model = series["model"].as_str().ok_or("missing DeepSeek model")?;
    Ok((id, label, model.into()))
}

/// The envelope contains three JSON strings from the site's own API requests.
pub fn parse_deepseek(body: &str) -> Result<DeepSeekReading, &'static str> {
    let envelope = json(body)?;
    let summary_text = envelope["summary"]
        .as_str()
        .ok_or("missing DeepSeek summary")?;
    let amount_text = envelope["amount"]
        .as_str()
        .ok_or("missing DeepSeek amount")?;
    let cost_text = envelope["cost"].as_str().ok_or("missing DeepSeek cost")?;
    let summary = json(summary_text)?;
    let amount = json(amount_text)?;
    let cost = json(cost_text)?;
    let wallet = summary["data"]["biz_data"]["normal_wallets"]
        .as_array()
        .and_then(|rows| rows.first())
        .ok_or("DeepSeek wallet missing")?;
    let currency = wallet["currency"]
        .as_str()
        .ok_or("DeepSeek wallet currency missing")?;
    let balance = scalar(&wallet["balance"]).ok_or("DeepSeek wallet balance invalid")?;
    let spent = summary["data"]["biz_data"]["total_costs"]
        .as_array()
        .and_then(|rows| rows.iter().find(|row| row["currency"] == currency))
        .and_then(|row| scalar(&row["amount"]))
        .unwrap_or(0.0);
    if balance < 0.0 || spent < 0.0 {
        return Err("DeepSeek money invalid");
    }
    let available_tokens = text(&summary["data"]["biz_data"]["total_available_token_estimation"])
        .and_then(|value| value.parse().ok());
    let summary = DeepSeekSummary {
        currency: currency.into(),
        spent,
        balance,
        available_tokens,
    };

    let amount_data = &amount["data"]["biz_data"];
    let cost_data = &cost["data"]["biz_data"];
    if amount_data.is_null() && cost_data.is_null() {
        return Ok(DeepSeekReading {
            summary,
            detail: None,
        });
    }
    let start = envelope["start"]
        .as_u64()
        .ok_or("DeepSeek detail start invalid")?;
    let end = envelope["end"]
        .as_u64()
        .ok_or("DeepSeek detail end invalid")?;
    let time_zone_seconds = envelope["time_zone_seconds"]
        .as_i64()
        .and_then(|n| i32::try_from(n).ok())
        .ok_or("DeepSeek detail timezone invalid")?;
    if end <= start {
        return Err("DeepSeek detail range invalid");
    }
    let mut groups: BTreeMap<(String, String), UsageDetailGroup> = BTreeMap::new();
    let mut days: BTreeMap<(String, String, u64), UsageDetailDay> = BTreeMap::new();
    for series in amount_data["series"].as_array().into_iter().flatten() {
        let (id, label, model) = series_key(series)?;
        groups
            .entry((id.clone(), model.clone()))
            .or_insert_with(|| UsageDetailGroup {
                api_key_id: id.clone(),
                api_key_label: label,
                model: model.clone(),
                days: Vec::new(),
            });
        for bucket in series["buckets"].as_array().into_iter().flatten() {
            let Some(time) = bucket["time"].as_u64() else {
                continue;
            };
            if time < start || time >= end {
                continue;
            }
            let day = days
                .entry((id.clone(), model.clone(), time))
                .or_insert_with(|| UsageDetailDay {
                    date: time * 1000,
                    ..Default::default()
                });
            let usage = &bucket["usage"];
            day.cache_hit_tokens += integer(&usage["PROMPT_CACHE_HIT_TOKEN"]);
            day.cache_miss_tokens += integer(&usage["PROMPT_CACHE_MISS_TOKEN"]);
            day.output_tokens += integer(&usage["RESPONSE_TOKEN"]);
            day.requests += integer(&usage["REQUEST"]);
        }
    }
    let currency_data = cost_data["data"].as_array().and_then(|rows| rows.first());
    if let Some(rows) = currency_data.and_then(|v| v["series"].as_array()) {
        for series in rows {
            let (id, label, model) = series_key(series)?;
            groups
                .entry((id.clone(), model.clone()))
                .or_insert_with(|| UsageDetailGroup {
                    api_key_id: id.clone(),
                    api_key_label: label,
                    model: model.clone(),
                    days: Vec::new(),
                });
            for bucket in series["buckets"].as_array().into_iter().flatten() {
                let Some(time) = bucket["time"].as_u64() else {
                    continue;
                };
                if time < start || time >= end {
                    continue;
                }
                let day = days
                    .entry((id.clone(), model.clone(), time))
                    .or_insert_with(|| UsageDetailDay {
                        date: time * 1000,
                        ..Default::default()
                    });
                day.cost += scalar(&bucket["cost"]).unwrap_or(0.0);
            }
        }
    }
    for ((id, model, _), day) in days {
        if let Some(group) = groups.get_mut(&(id, model)) {
            group.days.push(day);
        }
    }
    let mut groups: Vec<_> = groups.into_values().collect();
    groups.sort_by(|a, b| {
        a.api_key_label
            .cmp(&b.api_key_label)
            .then(a.model.cmp(&b.model))
    });
    let currency = currency_data
        .and_then(|data| data["currency"].as_str())
        .unwrap_or("CNY");
    Ok(DeepSeekReading {
        summary,
        detail: Some(ProviderUsageDetail {
            start: start * 1000,
            end: end * 1000,
            time_zone_seconds,
            currency: currency.into(),
            groups,
        }),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summary_and_series_match_swift_fixture() {
        let summary = r#"{"data":{"biz_data":{"normal_wallets":[{"currency":"CNY","balance":"10.87"}],"total_costs":[{"currency":"CNY","amount":"9.20"}],"total_available_token_estimation":"3300000"}}}"#;
        let amount = r#"{"data":{"biz_data":{"series":[{"api_key":{"name":"main","tracking_id":"key-1"},"model":"deepseek-chat","buckets":[{"time":1800000000,"usage":{"PROMPT_CACHE_HIT_TOKEN":"100","PROMPT_CACHE_MISS_TOKEN":50,"RESPONSE_TOKEN":25,"REQUEST":2}}]}]}}}"#;
        let cost = r#"{"data":{"biz_data":{"data":[{"currency":"CNY","series":[{"api_key":{"name":"main","tracking_id":"key-1"},"model":"deepseek-chat","buckets":[{"time":1800000000,"cost":"0.12"}]}]}]}}}"#;
        let payload=serde_json::json!({"summary":summary,"amount":amount,"cost":cost,"start":1800000000,"end":1800086400,"time_zone_seconds":28800}).to_string();
        let reading = parse_deepseek(&payload).unwrap();
        assert!((reading.summary.used_fraction() - 9.20 / 20.07).abs() < 0.0001);
        assert_eq!(reading.summary.available_tokens, Some(3_300_000));
        let detail = reading.detail.unwrap();
        assert_eq!(detail.groups.len(), 1);
        assert_eq!(detail.groups[0].api_key_label, "main");
        assert_eq!(
            detail.groups[0].days[0].cache_hit_tokens
                + detail.groups[0].days[0].cache_miss_tokens
                + detail.groups[0].days[0].output_tokens,
            175
        );
        assert_eq!(detail.groups[0].days[0].requests, 2);
        assert_eq!(detail.groups[0].days[0].cost, 0.12);
    }
}
