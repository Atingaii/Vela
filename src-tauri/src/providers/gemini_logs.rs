//! Gemini CLI/OpenCode/Hermes keep different token semantics. Match the owner's accounting.
use super::{AccountSummary, Failure};
use crate::usage::{Fidelity, LimitWindow, UsageSnapshot};
use chrono::{DateTime, Datelike, Local, TimeZone};
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
    fn add(
        &mut self,
        at: i64,
        tokens: u64,
        calls: u64,
        month: i64,
        end: i64,
        today: i64,
        tomorrow: i64,
    ) {
        if at < month || at >= end || tokens == 0 {
            return;
        }
        self.month = self.month.saturating_add(tokens);
        self.calls = self.calls.saturating_add(calls);
        if at >= today && at < tomorrow {
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
    if !path.exists() {
        return None;
    }
    let flags =
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let db = rusqlite::Connection::open_with_flags(path, flags)
        .ok()
        .or_else(|| {
            // A closed WAL database may have no -shm sidecar. Only then can an
            // immutable read safely fall back without missing a live owner's WAL.
            let mut wal = path.as_os_str().to_os_string();
            wal.push("-wal");
            if Path::new(&wal).exists() {
                return None;
            }
            let uri = tauri::Url::from_file_path(path).ok()?;
            rusqlite::Connection::open_with_flags(
                format!("{uri}?immutable=1"),
                flags | rusqlite::OpenFlags::SQLITE_OPEN_URI,
            )
            .ok()
        })?;
    db.busy_timeout(std::time::Duration::from_millis(100))
        .ok()?;
    Some(db)
}
pub(super) fn read(home: &Path, budget: Option<u64>) -> Result<UsageSnapshot, Failure> {
    read_at(home, budget, Local::now())
}

fn read_at(
    home: &Path,
    budget: Option<u64>,
    now: DateTime<Local>,
) -> Result<UsageSnapshot, Failure> {
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
    let tomorrow = Local
        .from_local_datetime(
            &now.date_naive()
                .succ_opt()
                .ok_or(Failure::Invalid)?
                .and_hms_opt(0, 0, 0)
                .ok_or(Failure::Invalid)?,
        )
        .earliest()
        .ok_or(Failure::Invalid)?;
    let (month, today, end, tomorrow) = (
        month.timestamp_millis(),
        today.timestamp_millis(),
        next.timestamp_millis(),
        tomorrow.timestamp_millis(),
    );
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
                    total.add(at, tokens, 1, month, end, today, tomorrow);
                }
            }
        }
        sources.push(("cli", "Gemini CLI", total));
    }
    if let Some(db) = db(&home.join(".local/share/opencode/opencode.db")) {
        let mut total = Totals::default();
        if let Ok(mut statement) = db.prepare("SELECT time_created, data FROM message WHERE time_created >= ?1 AND json_extract(data,'$.role')='assistant' AND json_extract(data,'$.providerID')='google' LIMIT 100001") {
        if let Ok(mut rows) = statement.query([month]) {
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
            total.add(at, tokens, 1, month, end, today, tomorrow);
        }
        }
        }
        sources.push(("opencode", "OpenCode", total));
    }
    if let Some(db) = db(&home.join(".hermes/state.db")) {
        let mut total = Totals::default();
        if let Ok(mut statement) = db.prepare("SELECT last_seen, coalesce(input_tokens,0)+coalesce(cache_read_tokens,0)+coalesce(cache_write_tokens,0)+coalesce(output_tokens,0), api_call_count FROM session_model_usage WHERE billing_provider='gemini' AND last_seen >= ?1 LIMIT 100001") {
        if let Ok(mut rows) = statement.query([month / 1000]) {
        let mut count = 0;
        while let Some(row) = rows.next().map_err(|_| Failure::Invalid)? {
            count += 1;
            if count > 100000 {
                return Err(Failure::Invalid);
            }
            let at = row.get::<_, f64>(0).map_err(|_| Failure::Invalid)?;
            let tokens = row.get::<_, i64>(1).unwrap_or(0).max(0) as u64;
            let calls = row.get::<_, i64>(2).unwrap_or(0).max(0) as u64;
            total.add(
                (at * 1000.) as i64,
                tokens,
                calls,
                month,
                end,
                today,
                tomorrow,
            );
        }
        }
        }
        sources.push(("hermes", "Hermes", total));
    }
    if sources.is_empty() {
        return Err(Failure::Unsupported(
            "No Gemini CLI, OpenCode or Hermes sessions found",
        ));
    }
    let total = sources
        .iter()
        .fold(0u64, |n, (_, _, s)| n.saturating_add(s.month));
    let day = sources
        .iter()
        .fold(0u64, |n, (_, _, s)| n.saturating_add(s.today));
    let budget = budget.filter(|n| *n > 0);
    let compact = |n: u64| {
        if n < 10_000 {
            n.to_string()
        } else if n < 1_000_000 {
            format!("{}k", n / 1_000)
        } else {
            format!("{:.1}M", n as f64 / 1_000_000.)
        }
    };
    let mut windows = vec![LimitWindow {
        remaining: None,
        used_count: None,
        id: "month".into(),
        label: budget
            .map(|n| format!("Tokens this month · budget {}", compact(n)))
            .unwrap_or_else(|| "Tokens this month · billed per token, no limit".into()),
        used: budget.map(|b| total as f64 / b as f64).unwrap_or(0.),
        count: Some(total.min(i64::MAX as u64) as i64),
        has_fraction: Some(budget.is_some()),
        resets_at: Some(end as u64),
        duration: Some((end - month) as f64 / 1000.),
        derived: true,
        group: None,
        ..Default::default()
    }];
    let count_window = |id: &str, label: String, count: u64, reset| LimitWindow {
        id: id.into(),
        label,
        count: Some(count.min(i64::MAX as u64) as i64),
        has_fraction: Some(false),
        resets_at: reset,
        derived: true,
        ..Default::default()
    };
    windows.push(count_window(
        "today",
        "Tokens today".into(),
        day,
        Some(tomorrow as u64),
    ));
    for (id, name, t) in sources {
        windows.push(count_window(
            id,
            format!("{name} · this month"),
            t.month,
            None,
        ));
    }
    Ok(UsageSnapshot {
        windows,
        fidelity: if budget.is_some() {
            Fidelity::Manual
        } else {
            Fidelity::Derived
        },
        ..Default::default()
    })
}

pub(super) fn account(home: &Path, snap: &UsageSnapshot) -> Option<AccountSummary> {
    let tools: Vec<&str> = snap
        .windows
        .iter()
        .filter_map(|w| match w.id.as_str() {
            "cli" => Some("Gemini CLI"),
            "opencode" => Some("OpenCode"),
            "hermes" => Some("Hermes"),
            _ => None,
        })
        .collect();
    if tools.is_empty() {
        return None;
    }
    // Only the CLI's non-secret selectedType is read. Keys and auth files stay untouched.
    let auth_type = std::fs::read(home.join(".gemini/settings.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|v| {
            v["security"]["auth"]["selectedType"]
                .as_str()
                .map(str::to_owned)
        });
    let google_account = auth_type.as_deref() == Some("oauth-personal");
    Some(AccountSummary {
        label: Some(
            if google_account {
                "Google account"
            } else {
                "API key"
            }
            .into(),
        ),
        plan: (!google_account).then(|| "metered".into()),
        source: tools.join(", "),
        manage_url: None,
    })
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

    #[test]
    fn source_rows_month_day_and_budget_match_swift_snapshot() {
        let home = tempfile::tempdir().unwrap();
        let now = Local
            .with_ymd_and_hms(2026, 9, 15, 12, 0, 0)
            .earliest()
            .unwrap();
        let chats = home.path().join(".gemini/tmp/project/chats");
        std::fs::create_dir_all(&chats).unwrap();
        std::fs::write(chats.join("one.jsonl"),
            b"{\"id\":\"a\",\"type\":\"gemini\",\"timestamp\":\"2026-09-15T01:00:00Z\",\"tokens\":{\"total\":1200}}\n{\"id\":\"b\",\"type\":\"gemini\",\"timestamp\":\"2026-09-03T01:00:00Z\",\"tokens\":{\"total\":300}}\n{\"id\":\"c\",\"type\":\"gemini\",\"timestamp\":\"2026-08-28T01:00:00Z\",\"tokens\":{\"total\":500}}")
            .unwrap();
        let snap = read_at(home.path(), None, now).unwrap();
        assert_eq!(
            snap.windows
                .iter()
                .map(|w| w.id.as_str())
                .collect::<Vec<_>>(),
            ["month", "today", "cli"]
        );
        assert_eq!(snap.windows[0].count, Some(1500));
        assert_eq!(snap.windows[1].count, Some(1200));
        assert_eq!(snap.windows[2].count, Some(1500));
        assert_eq!(snap.windows[0].has_fraction, Some(false));
        assert_eq!(snap.fidelity, Fidelity::Derived);
        assert_eq!(snap.windows[0].duration, Some(30. * 86400.));
        let budgeted = read_at(home.path(), Some(2_000_000), now).unwrap();
        assert_eq!(budgeted.windows[0].count, Some(1500));
        assert_eq!(budgeted.windows[0].used, 1500. / 2_000_000.);
        assert_eq!(budgeted.windows[0].has_fraction, Some(true));
        assert!(budgeted.windows[0].label.contains("2.0M"));
        assert_eq!(budgeted.fidelity, Fidelity::Manual);
        assert_eq!(account(home.path(), &snap).unwrap().source, "Gemini CLI");
    }

    #[test]
    fn absent_logs_are_nothing_metered_and_account_names_cli_auth_mode() {
        let home = tempfile::tempdir().unwrap();
        let now = Local
            .with_ymd_and_hms(2026, 9, 15, 12, 0, 0)
            .earliest()
            .unwrap();
        assert!(matches!(
            read_at(home.path(), None, now),
            Err(Failure::Unsupported(_))
        ));
        std::fs::create_dir_all(home.path().join(".gemini/tmp")).unwrap();
        std::fs::write(
            home.path().join(".gemini/settings.json"),
            br#"{"security":{"auth":{"selectedType":"oauth-personal"}}}"#,
        )
        .unwrap();
        let snap = read_at(home.path(), None, now).unwrap();
        let account = account(home.path(), &snap).unwrap();
        assert_eq!(account.label.as_deref(), Some("Google account"));
        assert!(account.plan.is_none());
        assert_eq!(account.source, "Gemini CLI");
    }

    #[test]
    fn opencode_and_hermes_rows_count_different_token_components() {
        let home = tempfile::tempdir().unwrap();
        let now = Local
            .with_ymd_and_hms(2026, 9, 15, 12, 0, 0)
            .earliest()
            .unwrap();
        let opencode = home.path().join(".local/share/opencode/opencode.db");
        std::fs::create_dir_all(opencode.parent().unwrap()).unwrap();
        let connection = rusqlite::Connection::open(&opencode).unwrap();
        connection
            .execute_batch("CREATE TABLE message(time_created INTEGER, data TEXT);")
            .unwrap();
        connection.execute("INSERT INTO message VALUES (?1, ?2)",
            rusqlite::params![now.timestamp_millis(),
                r#"{"role":"assistant","providerID":"google","tokens":{"input":2834,"output":51,"reasoning":17,"cache":{"read":93106,"write":0}}}"#]).unwrap();
        connection
            .execute(
                "INSERT INTO message VALUES (?1, ?2)",
                rusqlite::params![
                    now.timestamp_millis(),
                    r#"{"role":"assistant","providerID":"google-vertex","tokens":{"total":900000}}"#
                ],
            )
            .unwrap();
        drop(connection);
        let hermes = home.path().join(".hermes/state.db");
        std::fs::create_dir_all(hermes.parent().unwrap()).unwrap();
        let connection = rusqlite::Connection::open(&hermes).unwrap();
        connection.execute_batch("CREATE TABLE session_model_usage(last_seen REAL, input_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER, output_tokens INTEGER, reasoning_tokens INTEGER, api_call_count INTEGER, billing_provider TEXT);").unwrap();
        connection
            .execute(
                "INSERT INTO session_model_usage VALUES (?1,100,50,5,20,7,3,'gemini')",
                [now.timestamp() as f64],
            )
            .unwrap();
        drop(connection);
        let snap = read_at(home.path(), None, now).unwrap();
        assert_eq!(
            snap.windows
                .iter()
                .map(|w| w.id.as_str())
                .collect::<Vec<_>>(),
            ["month", "today", "opencode", "hermes"]
        );
        assert_eq!(snap.windows[0].count, Some(96_183));
        assert_eq!(snap.windows[2].count, Some(96_008));
        assert_eq!(snap.windows[3].count, Some(175));
        assert_eq!(
            account(home.path(), &snap).unwrap().source,
            "OpenCode, Hermes"
        );
    }
}
