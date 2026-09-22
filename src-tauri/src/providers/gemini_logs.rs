//! Gemini CLI/OpenCode/Hermes keep different token semantics. Match the owner's accounting.
use super::Failure;
use crate::usage::LimitWindow;
use chrono::{Datelike, Local, TimeZone};
use serde_json::Value;
use std::{
    collections::HashMap,
    io::{BufRead, BufReader},
    path::Path,
};
#[derive(Default)]
struct Totals {
    month: u64,
    today: u64,
    calls: u64,
}
impl Totals {
    fn add(&mut self, at: i64, tokens: u64, calls: u64, month: i64, today: i64, now: i64) {
        if at < month || at > now || tokens == 0 {
            return;
        }
        self.month = self.month.saturating_add(tokens);
        self.calls = self.calls.saturating_add(calls);
        if at >= today {
            self.today = self.today.saturating_add(tokens);
        }
    }
}
fn cli_entries(reader: impl BufRead) -> HashMap<String, (i64, u64)> {
    let mut rows = HashMap::new();
    for line in reader.lines().map_while(Result::ok) {
        let Ok(v) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if v["type"] != "gemini" || !v["tokens"].is_object() {
            continue;
        }
        let Some(id) = v["id"].as_str() else { continue };
        let Some(at) = v["timestamp"]
            .as_str()
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        else {
            continue;
        };
        // Rewind affects visible history, never the bill; final duplicate id wins.
        rows.insert(
            id.into(),
            (
                at.timestamp_millis(),
                v["tokens"]["total"].as_u64().unwrap_or(0),
            ),
        );
    }
    rows
}
fn db(path: &Path) -> Option<rusqlite::Connection> {
    let db = rusqlite::Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()?;
    db.busy_timeout(std::time::Duration::from_millis(100))
        .ok()?;
    Some(db)
}
pub(super) fn read(home: &Path, budget: Option<u64>) -> Result<Vec<LimitWindow>, Failure> {
    let now = Local::now();
    let month = Local
        .with_ymd_and_hms(now.year(), now.month(), 1, 0, 0, 0)
        .earliest()
        .ok_or(Failure::Invalid)?;
    let today = now
        .date_naive()
        .and_hms_opt(0, 0, 0)
        .and_then(|d| Local.from_local_datetime(&d).earliest())
        .ok_or(Failure::Invalid)?;
    let next = if now.month() == 12 {
        Local.with_ymd_and_hms(now.year() + 1, 1, 1, 0, 0, 0)
    } else {
        Local.with_ymd_and_hms(now.year(), now.month() + 1, 1, 0, 0, 0)
    }
    .earliest()
    .ok_or(Failure::Invalid)?;
    let (month, today, end) = (
        month.timestamp_millis(),
        today.timestamp_millis(),
        next.timestamp_millis() as u64,
    );
    let now = now.timestamp_millis();
    let mut sources = Vec::new();
    let root = home.join(".gemini/tmp");
    let mut bytes = 0u64;
    let mut files = 0;
    if let Ok(projects) = std::fs::read_dir(&root) {
        let mut total = Totals::default();
        for project in projects.flatten().take(1000) {
            if project.file_type().map(|t| !t.is_dir()).unwrap_or(true) {
                continue;
            }
            let Ok(chats) = std::fs::read_dir(project.path().join("chats")) else {
                continue;
            };
            for file in chats.flatten() {
                if file.path().extension().and_then(|s| s.to_str()) != Some("jsonl")
                    || file.file_type().map(|t| !t.is_file()).unwrap_or(true)
                {
                    continue;
                }
                let Ok(meta) = file.metadata() else { continue };
                if meta
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .is_some_and(|t| t.as_millis() < (month as u128))
                {
                    continue;
                }
                files += 1;
                bytes = bytes.saturating_add(meta.len());
                if files > 1000 || bytes > 32 * 1024 * 1024 {
                    return Err(Failure::Invalid);
                }
                let Ok(file) = std::fs::File::open(file.path()) else {
                    continue;
                };
                for (at, tokens) in cli_entries(BufReader::new(file)).into_values() {
                    total.add(at, tokens, 1, month, today, now);
                }
            }
        }
        sources.push(("Gemini CLI", total));
    }
    if let Some(db) = db(&home.join(".local/share/opencode/opencode.db")) {
        let mut statement=db.prepare("SELECT time_created, data FROM message WHERE time_created >= ?1 AND json_extract(data,'$.role')='assistant' AND json_extract(data,'$.providerID')='google' LIMIT 100001").map_err(|_|Failure::Invalid)?;
        let mut rows = statement.query([month]).map_err(|_| Failure::Invalid)?;
        let mut total = Totals::default();
        let mut count = 0;
        while let Some(row) = rows.next().map_err(|_| Failure::Invalid)? {
            count += 1;
            if count > 100000 {
                return Err(Failure::Invalid);
            }
            let at = row.get::<_, i64>(0).map_err(|_| Failure::Invalid)?;
            let text = row.get::<_, String>(1).map_err(|_| Failure::Invalid)?;
            let Ok(v) = serde_json::from_str::<Value>(&text) else {
                continue;
            };
            let t = &v["tokens"];
            let tokens = t["total"].as_u64().filter(|n| *n > 0).unwrap_or_else(|| {
                [
                    &t["input"],
                    &t["output"],
                    &t["reasoning"],
                    &t["cache"]["read"],
                    &t["cache"]["write"],
                ]
                .iter()
                .fold(0u64, |a, n| a.saturating_add(n.as_u64().unwrap_or(0)))
            });
            total.add(at, tokens, 1, month, today, now);
        }
        sources.push(("OpenCode", total));
    }
    if let Some(db) = db(&home.join(".hermes/state.db")) {
        let mut statement=db.prepare("SELECT last_seen, coalesce(input_tokens,0)+coalesce(cache_read_tokens,0)+coalesce(cache_write_tokens,0)+coalesce(output_tokens,0), api_call_count FROM session_model_usage WHERE billing_provider='gemini' AND last_seen >= ?1 LIMIT 100001").map_err(|_|Failure::Invalid)?;
        let mut rows = statement
            .query([month / 1000])
            .map_err(|_| Failure::Invalid)?;
        let mut total = Totals::default();
        let mut count = 0;
        while let Some(row) = rows.next().map_err(|_| Failure::Invalid)? {
            count += 1;
            if count > 100000 {
                return Err(Failure::Invalid);
            }
            let at = row.get::<_, f64>(0).map_err(|_| Failure::Invalid)?;
            let tokens = row.get::<_, i64>(1).unwrap_or(0).max(0) as u64;
            let calls = row.get::<_, i64>(2).unwrap_or(0).max(0) as u64;
            total.add((at * 1000.) as i64, tokens, calls, month, today, now);
        }
        sources.push(("Hermes · session totals by last call", total));
    }
    if sources.is_empty() {
        return Err(Failure::Absent);
    }
    let total = sources
        .iter()
        .fold(0u64, |n, (_, s)| n.saturating_add(s.month));
    let budget = budget.filter(|n| *n > 0);
    let mut windows = vec![LimitWindow {
        id: "month".into(),
        label: "Tokens this month · local records".into(),
        used: budget.map(|b| total as f64 / b as f64).unwrap_or(0.),
        count: if budget.is_some() {
            None
        } else {
            Some(total.min(i64::MAX as u64) as i64)
        },
        resets_at: Some(end),
        derived: true,
        group: None,
    }];
    for (source, t) in sources {
        for (id, label, n) in [
            ("month", "This month", t.month),
            ("today", "Today", t.today),
            ("calls", "Calls this month", t.calls),
        ] {
            windows.push(LimitWindow {
                id: format!("{source}/{id}"),
                label: label.into(),
                used: 0.,
                count: Some(n.min(i64::MAX as u64) as i64),
                resets_at: None,
                derived: true,
                group: Some(source.into()),
            });
        }
    }
    Ok(windows)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rewinds_do_not_unbill_and_duplicates_do_not_double_count() {
        let text=b"{\"id\":\"a\",\"type\":\"gemini\",\"timestamp\":\"2026-09-01T00:00:00Z\"}\n{\"id\":\"a\",\"type\":\"gemini\",\"timestamp\":\"2026-09-01T00:00:00Z\",\"tokens\":{\"total\":12,\"cached\":10}}\n{\"$rewindTo\":\"a\"}\n{\"id\":\"a\",\"type\":\"gemini\",\"timestamp\":\"2026-09-01T00:00:00Z\",\"tokens\":{\"total\":14}}";
        let entries = cli_entries(&text[..]);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries["a"].1, 14);
    }
}
