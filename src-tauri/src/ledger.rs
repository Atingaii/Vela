//! On-demand, bounded local usage ledger. No prompts, credentials, or network pricing requests.
use chrono::{Datelike, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{BTreeMap, HashMap},
    fs,
    io::{BufRead, BufReader, Read},
    path::{Path, PathBuf},
};
const MAX_BYTES: u64 = 32 * 1024 * 1024;
const MAX_FILES: usize = 300;
#[derive(Clone, Default, Deserialize, Serialize)]
pub struct Rate {
    pub model: String,
    pub input: f64,
    pub output: f64,
    pub cache_read: f64,
    pub cache_write: f64,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(default)]
pub struct Billing {
    pub currency: String,
    pub cycle_day: u32,
    pub subscription: f64,
    pub rates: Vec<Rate>,
}
impl Default for Billing {
    fn default() -> Self {
        Self {
            currency: "USD".into(),
            cycle_day: 1,
            subscription: 0.0,
            rates: vec![],
        }
    }
}
#[derive(Clone, Default, Serialize)]
pub struct Record {
    pub day: String,
    pub cli: String,
    pub model: String,
    pub project: String,
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
}
#[derive(Serialize)]
pub struct Report {
    rows: Vec<Record>,
    billing: Billing,
    cycle_start: String,
    cycle_end: String,
    known_cost: f64,
    unknown_records: usize,
    forecast: Option<f64>,
    partial: bool,
    files: usize,
    skipped: usize,
}
fn billing_path() -> PathBuf {
    crate::workbench::root().join("billing.json")
}
#[tauri::command]
pub fn get_billing() -> Result<Billing, String> {
    let billing = match fs::read(billing_path()) {
        Ok(b) => serde_json::from_slice(&b).map_err(|e| format!("计费配置损坏: {e}"))?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Billing::default(),
        Err(e) => return Err(e.to_string()),
    };
    validate(&billing)?;
    Ok(billing)
}
#[tauri::command]
pub fn save_billing(billing: Billing) -> Result<(), String> {
    validate(&billing)?;
    crate::workbench::atomic(
        &billing_path(),
        &serde_json::to_vec_pretty(&billing).map_err(|e| e.to_string())?,
    )
}
fn validate(b: &Billing) -> Result<(), String> {
    if b.currency.len() != 3
        || !b.currency.bytes().all(|c| c.is_ascii_uppercase())
        || !(1..=31).contains(&b.cycle_day)
        || !b.subscription.is_finite()
        || b.subscription < 0.0
        || b.subscription > 1e12
        || b.rates.len() > 100
    {
        return Err("账期、币种或订阅金额无效".into());
    }
    let mut seen = std::collections::HashSet::new();
    for r in &b.rates {
        if r.model.is_empty()
            || !seen.insert(&r.model)
            || [r.input, r.output, r.cache_read, r.cache_write]
                .iter()
                .any(|n| !n.is_finite() || *n < 0.0 || *n > 1e9)
        {
            return Err("模型名称需唯一，单价须为非负数".into());
        }
    }
    Ok(())
}
fn month_day(year: i32, month: u32, day: u32) -> NaiveDate {
    (1..=day.min(31))
        .rev()
        .find_map(|d| NaiveDate::from_ymd_opt(year, month, d))
        .unwrap()
}
pub fn cycle(today: NaiveDate, day: u32) -> (NaiveDate, NaiveDate) {
    let mut start = month_day(today.year(), today.month(), day);
    if start > today {
        let prev = start.with_day(1).unwrap().pred_opt().unwrap();
        start = month_day(prev.year(), prev.month(), day);
    }
    let (y, m) = if start.month() == 12 {
        (start.year() + 1, 1)
    } else {
        (start.year(), start.month() + 1)
    };
    (start, month_day(y, m, day))
}
fn n(v: &Value, key: &str) -> u64 {
    v[key].as_u64().unwrap_or(0).min(1_000_000_000_000)
}
fn str_at(v: &Value, key: &str) -> String {
    v[key].as_str().unwrap_or("").to_owned()
}
// Merge repeated streaming messages by maxima, not sum. IDs are scoped to a session.
fn parse_lines(
    reader: impl Read,
    cli: &str,
    source: &str,
    rows: &mut HashMap<String, Record>,
    skipped: &mut usize,
) {
    let mut project = String::new();
    let mut model = "unknown".to_owned();
    let mut session = source.to_owned();
    let mut previous = [0u64; 4];
    for (index, line) in BufReader::new(reader).split(b'\n').enumerate() {
        let Ok(line) = line else {
            *skipped += 1;
            continue;
        };
        if line.is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_slice::<Value>(&line) else {
            *skipped += 1;
            continue;
        };
        if let Some(cwd) = v["cwd"].as_str().or(v["payload"]["cwd"].as_str()) {
            project = cwd.to_owned();
        }
        if v["type"] == "session_meta" {
            session = v["payload"]["id"].as_str().unwrap_or(source).to_owned();
        }
        if v["type"] == "turn_context" {
            model = v["payload"]["model"]
                .as_str()
                .unwrap_or("unknown")
                .to_owned();
        }
        let timestamp = v["timestamp"].as_str().unwrap_or("");
        let Ok(date) = chrono::DateTime::parse_from_rfc3339(timestamp)
            .map(|d| d.with_timezone(&Utc).date_naive())
        else {
            continue;
        };
        let mut row = Record {
            day: date.to_string(),
            cli: cli.into(),
            model: model.clone(),
            project: project.clone(),
            ..Default::default()
        };
        let key;
        if cli == "claude" {
            if v["type"] != "assistant" || !v["message"]["usage"].is_object() {
                continue;
            }
            let msg = &v["message"];
            let u = &msg["usage"];
            row.model = msg["model"].as_str().unwrap_or("unknown").into();
            row.input = n(u, "input_tokens");
            row.output = n(u, "output_tokens");
            row.cache_read = n(u, "cache_read_input_tokens");
            row.cache_write = n(u, "cache_creation_input_tokens");
            let sid = v["sessionId"].as_str().unwrap_or(source);
            let id = str_at(msg, "id");
            key = if id.is_empty() {
                format!("claude:{source}:{index}")
            } else {
                format!("claude:{sid}:{id}")
            };
            if let Some(old) = rows.get(&key) {
                row.input = row.input.max(old.input);
                row.output = row.output.max(old.output);
                row.cache_read = row.cache_read.max(old.cache_read);
                row.cache_write = row.cache_write.max(old.cache_write);
            }
        } else {
            if v["type"] != "event_msg" || v["payload"]["type"] != "token_count" {
                continue;
            }
            let u = &v["payload"]["info"]["total_token_usage"];
            if !u.is_object() {
                *skipped += 1;
                continue;
            }
            let totals = [
                n(u, "input_tokens"),
                n(u, "output_tokens"),
                n(u, "cached_input_tokens"),
                0,
            ];
            // A reset starts a new accumulation epoch. Repeated cumulative samples add nothing.
            let reset = totals[0] < previous[0] || totals[1] < previous[1];
            let delta: Vec<u64> = totals
                .iter()
                .enumerate()
                .map(|(i, t)| t.saturating_sub(if reset { 0 } else { previous[i] }))
                .collect();
            previous = totals;
            row.cache_read = delta[2].min(delta[0]);
            row.input = delta[0].saturating_sub(row.cache_read);
            row.output = delta[1];
            if row.input + row.output + row.cache_read == 0 {
                continue;
            }
            key = format!(
                "codex:{session}:{timestamp}:{}:{}:{}",
                totals[0], totals[1], totals[2]
            );
        }
        rows.insert(key, row);
    }
}
fn collect(
    root: &Path,
    out: &mut Vec<(PathBuf, String)>,
    cli: &str,
    partial: &mut bool,
    visited: &mut usize,
    depth: usize,
) {
    if depth > 10 || *visited >= 4000 {
        *partial = true;
        return;
    }
    let Ok(dir) = fs::read_dir(root) else { return };
    for e in dir {
        *visited += 1;
        if *visited > 4000 || out.len() >= MAX_FILES {
            *partial = true;
            break;
        }
        let Ok(e) = e else {
            *partial = true;
            continue;
        };
        let Ok(t) = e.file_type() else {
            *partial = true;
            continue;
        };
        if t.is_symlink() {
            continue;
        }
        if t.is_dir() {
            collect(&e.path(), out, cli, partial, visited, depth + 1);
        } else if t.is_file() && e.path().extension().is_some_and(|s| s == "jsonl") {
            out.push((e.path(), cli.into()));
        }
    }
}
fn scan(home: &Path, billing: Billing, today: NaiveDate) -> Result<Report, String> {
    let mut files = vec![];
    let mut partial = false;
    let mut visited = 0;
    collect(
        &home.join(".claude/projects"),
        &mut files,
        "claude",
        &mut partial,
        &mut visited,
        0,
    );
    collect(
        &home.join(".codex/sessions"),
        &mut files,
        "codex",
        &mut partial,
        &mut visited,
        0,
    );
    files.sort_by_key(|(p, _)| std::cmp::Reverse(fs::metadata(p).and_then(|m| m.modified()).ok()));
    let mut raw = HashMap::new();
    let mut bytes = 0;
    let mut skipped = 0;
    let mut read = 0;
    for (p, cli) in files {
        let Ok(m) = fs::symlink_metadata(&p) else {
            skipped += 1;
            continue;
        };
        if m.file_type().is_symlink() || !m.is_file() || bytes + m.len() > MAX_BYTES {
            partial = true;
            skipped += 1;
            continue;
        }
        let Ok(f) = fs::File::open(&p) else {
            skipped += 1;
            continue;
        };
        bytes += m.len();
        read += 1;
        parse_lines(
            f.take(m.len()),
            &cli,
            &p.to_string_lossy(),
            &mut raw,
            &mut skipped,
        );
    }
    let (start, end) = cycle(today, billing.cycle_day);
    let mut grouped: BTreeMap<(String, String, String, String), Record> = BTreeMap::new();
    let mut cost = 0.0;
    let mut unknown = 0;
    for row in raw.into_values() {
        if row.day < start.to_string() || row.day > today.to_string() {
            continue;
        }
        if let Some(r) = billing.rates.iter().find(|r| r.model == row.model) {
            cost += (row.input as f64 * r.input
                + row.output as f64 * r.output
                + row.cache_read as f64 * r.cache_read
                + row.cache_write as f64 * r.cache_write)
                / 1_000_000.0;
        } else {
            unknown += 1;
        }
        let key = (
            row.day.clone(),
            row.cli.clone(),
            row.model.clone(),
            row.project.clone(),
        );
        let e = grouped.entry(key).or_insert_with(|| Record {
            input: 0,
            output: 0,
            cache_read: 0,
            cache_write: 0,
            ..row.clone()
        });
        e.input += row.input;
        e.output += row.output;
        e.cache_read += row.cache_read;
        e.cache_write += row.cache_write;
    }
    partial |= skipped > 0;
    let elapsed = (today - start).num_days(); // completed days only would omit today's cost: include today, label pace estimate.
    let forecast = if unknown == 0 && !partial && !grouped.is_empty() {
        Some(cost * (end - start).num_days() as f64 / (elapsed + 1) as f64)
    } else {
        None
    };
    Ok(Report {
        rows: grouped.into_values().collect(),
        billing,
        cycle_start: start.to_string(),
        cycle_end: end.to_string(),
        known_cost: cost,
        unknown_records: unknown,
        forecast,
        partial,
        files: read,
        skipped,
    })
}
#[tauri::command]
pub async fn read_ledger() -> Result<Report, String> {
    tauri::async_runtime::spawn_blocking(|| {
        let billing = get_billing()?;
        scan(
            &dirs::home_dir().ok_or("无法定位用户目录")?,
            billing,
            Utc::now().date_naive(),
        )
    })
    .await
    .map_err(|e| e.to_string())?
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cycles_clamp_month_ends_and_leap_year() {
        let d = NaiveDate::from_ymd_opt(2024, 2, 29).unwrap();
        let (a, b) = cycle(d, 31);
        assert_eq!(a.to_string(), "2024-02-29");
        assert_eq!(b.to_string(), "2024-03-31");
        let (a, _) = cycle(d.pred_opt().unwrap(), 31);
        assert_eq!(a.to_string(), "2024-01-31");
    }
    #[test]
    fn cumulative_codex_counts_and_cached_input_not_double_counted() {
        let mut rows = HashMap::new();
        let mut skipped = 0;
        let lines=[(100,20,40),(100,20,40),(150,30,50)].into_iter().map(|(i,o,c)|serde_json::json!({"type":"event_msg","timestamp":"2026-09-10T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":i,"output_tokens":o,"cached_input_tokens":c}}}}).to_string()).collect::<Vec<_>>().join("\n");
        parse_lines(lines.as_bytes(), "codex", "a", &mut rows, &mut skipped);
        assert_eq!(rows.values().map(|r| r.input).sum::<u64>(), 100);
        assert_eq!(rows.values().map(|r| r.cache_read).sum::<u64>(), 50);
        assert_eq!(rows.values().map(|r| r.output).sum::<u64>(), 30);
    }
    #[test]
    fn claude_streams_are_deduplicated() {
        let line=serde_json::json!({"type":"assistant","sessionId":"s","timestamp":"2026-09-01T00:00:00Z","message":{"id":"m","model":"test","usage":{"input_tokens":10,"output_tokens":2}}}).to_string();
        let mut rows = HashMap::new();
        let mut skip = 0;
        parse_lines(
            format!("{line}\n{line}\nbad").as_bytes(),
            "claude",
            "a",
            &mut rows,
            &mut skip,
        );
        assert_eq!(rows.len(), 1);
        assert_eq!(rows.values().next().unwrap().input, 10);
        assert_eq!(skip, 1);
    }
    #[test]
    fn costs_forecast_and_missing_prices_are_distinct() {
        let t = tempfile::tempdir().unwrap();
        let dir = t.path().join(".claude/projects/test");
        fs::create_dir_all(&dir).unwrap();
        let line = serde_json::json!({"type":"assistant","sessionId":"s","timestamp":"2026-09-10T12:00:00Z","message":{"id":"m","model":"test","usage":{"input_tokens":1_000_000,"output_tokens":500_000,"cache_read_input_tokens":100_000}}});
        fs::write(dir.join("a.jsonl"), line.to_string()).unwrap();
        let today = NaiveDate::from_ymd_opt(2026, 9, 10).unwrap();
        let unknown = scan(t.path(), Billing::default(), today).unwrap();
        assert_eq!(unknown.unknown_records, 1);
        assert!(unknown.forecast.is_none());
        let b = Billing {
            rates: vec![Rate {
                model: "test".into(),
                input: 2.0,
                output: 4.0,
                cache_read: 0.5,
                cache_write: 1.0,
            }],
            subscription: 20.0,
            ..Billing::default()
        };
        let r = scan(t.path(), b, today).unwrap();
        assert!((r.known_cost - 4.05).abs() < 1e-9);
        assert!((r.forecast.unwrap() - 12.15).abs() < 1e-9);
        assert_eq!(r.billing.subscription, 20.0);
    }
    #[test]
    fn no_data_has_no_forecast() {
        let t = tempfile::tempdir().unwrap();
        let r = scan(t.path(), Billing::default(), Utc::now().date_naive()).unwrap();
        assert!(r.forecast.is_none());
    }
}
