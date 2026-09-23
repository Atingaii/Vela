//! Read-only activity for the three clients sharing a Gemini API key.
//! Swift GeminiAPIActivityMonitor fixes the order: Gemini CLI, OpenCode, Hermes.
use crate::activity::Activity;
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

const STALE_MS: u64 = 45_000;

pub fn read(now_ms: u64) -> Vec<Activity> {
    if crate::smoke::root().is_some() {
        return Vec::new();
    }
    let Some(home) = dirs::home_dir() else {
        return Vec::new();
    };
    read_at(
        &home.join(".gemini/tmp"),
        &home.join(".local/share/opencode/opencode.db"),
        &home.join(".hermes/state.db"),
        now_ms,
    )
}

fn read_at(gemini: &Path, opencode: &Path, hermes: &Path, now_ms: u64) -> Vec<Activity> {
    let mut out = gemini_cli(gemini, now_ms);
    out.extend(open_code(opencode, now_ms));
    out.extend(hermes_sessions(hermes, now_ms));
    out
}

fn modified_ms(path: &Path) -> Option<u64> {
    fs::metadata(path)
        .ok()?
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|value| value.as_millis() as u64)
}

fn recent(at: u64, now: u64) -> bool {
    now.saturating_sub(at) <= STALE_MS
}

fn basename(path: &str) -> String {
    Path::new(path)
        .file_name()
        .map(|part| part.to_string_lossy().into_owned())
        .filter(|part| !part.is_empty())
        .unwrap_or_default()
}

fn gemini_cli(root: &Path, now_ms: u64) -> Vec<Activity> {
    let Ok(projects) = fs::read_dir(root) else {
        return Vec::new();
    };
    let mut newest: Option<(PathBuf, PathBuf, u64)> = None;
    for project in projects.flatten().take(1024) {
        let project_path = project.path();
        let Ok(files) = fs::read_dir(project_path.join("chats")) else {
            continue;
        };
        for file in files.flatten().take(4096) {
            let path = file.path();
            if path.extension().and_then(|ext| ext.to_str()) != Some("jsonl") {
                continue;
            }
            let Some(at) = modified_ms(&path) else {
                continue;
            };
            if newest.as_ref().is_none_or(|(_, _, old)| at > *old) {
                newest = Some((path, project_path.clone(), at));
            }
        }
    }
    let Some((session, project, at)) = newest else {
        return Vec::new();
    };
    if !recent(at, now_ms) {
        return Vec::new();
    }
    let marker = project.join(".project_root");
    let project_name = fs::read_to_string(marker)
        .ok()
        .filter(|value| value.len() <= 4096)
        .map(|value| basename(value.trim()))
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| basename(&project.to_string_lossy()));
    vec![Activity {
        id: format!(
            "gemini-api.{}",
            session.file_stem().unwrap_or_default().to_string_lossy()
        ),
        provider: "gemini-api".into(),
        state: "busy".into(),
        name: "Gemini CLI".into(),
        detail: format!("Working in {project_name}"),
        waiting_for: None,
        since: at,
        queued: 0,
    }]
}

fn open_readonly(path: &Path) -> Option<Connection> {
    if !path.is_file() {
        return None;
    }
    let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;
    let _ = db.busy_timeout(std::time::Duration::from_millis(50));
    Some(db)
}

fn unfinished_google(data: &str) -> bool {
    let Ok(message) = serde_json::from_str::<Value>(data) else {
        return false;
    };
    message.get("role").and_then(Value::as_str) == Some("assistant")
        && message.get("providerID").and_then(Value::as_str) == Some("google")
        && message
            .pointer("/time/completed")
            .is_none_or(Value::is_null)
}

fn open_code(path: &Path, now_ms: u64) -> Vec<Activity> {
    let Some(db) = open_readonly(path) else {
        return Vec::new();
    };
    let cutoff = now_ms.saturating_sub(STALE_MS) as i64;
    let Ok(mut query) = db.prepare(
        "SELECT r.id, r.title, r.directory, m.time_created, m.time_updated, m.data \
         FROM session s JOIN session r ON r.id = COALESCE(s.parent_id, s.id) \
         JOIN message m ON m.id = (SELECT id FROM message WHERE session_id = s.id \
         ORDER BY time_created DESC LIMIT 1) WHERE s.time_updated >= ?1 \
         ORDER BY m.time_updated DESC LIMIT 256",
    ) else {
        return Vec::new();
    };
    let Ok(rows) = query.query_map([cutoff], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, Option<String>>(1)?.unwrap_or_default(),
            row.get::<_, Option<String>>(2)?.unwrap_or_default(),
            row.get::<_, i64>(3)?,
            row.get::<_, i64>(4)?,
            row.get::<_, String>(5)?,
        ))
    }) else {
        return Vec::new();
    };
    let mut seen = std::collections::HashSet::new();
    rows.flatten()
        .filter_map(|(root, title, directory, created, updated, data)| {
            if root.is_empty()
                || updated < cutoff
                || !unfinished_google(&data)
                || !seen.insert(root.clone())
            {
                return None;
            }
            let project = if directory.is_empty() {
                title
            } else {
                basename(&directory)
            };
            Some(Activity {
                id: format!("gemini-api.opencode.{root}"),
                provider: "gemini-api".into(),
                state: "busy".into(),
                name: "OpenCode".into(),
                detail: format!("Working in {project}"),
                waiting_for: None,
                since: created.max(0) as u64,
                queued: 0,
            })
        })
        .collect()
}

fn hermes_sessions(path: &Path, now_ms: u64) -> Vec<Activity> {
    let Some(db) = open_readonly(path) else {
        return Vec::new();
    };
    let mut tables = std::collections::HashSet::new();
    if let Ok(mut query) = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('sessions','session_turn_leases')") {
        if let Ok(rows) = query.query_map([], |row| row.get::<_, String>(0)) {
            tables.extend(rows.flatten());
        }
    }
    if !tables.contains("sessions") {
        return Vec::new();
    }
    let now_sec = (now_ms / 1000) as i64;
    let cutoff = now_sec - 45;
    let lease = if tables.contains("session_turn_leases") {
        " OR EXISTS (SELECT 1 FROM session_turn_leases l WHERE l.conversation_id=s.id AND l.expires_at>?2)"
    } else {
        ""
    };
    let sql = format!(
        "SELECT s.id,s.title,s.cwd,s.started_at,s.last_activity_at FROM sessions s \
        WHERE s.billing_provider='gemini' AND s.ended_at IS NULL \
        AND (s.last_activity_at>=?1{lease}) ORDER BY s.last_activity_at DESC LIMIT 256"
    );
    let Ok(mut query) = db.prepare(&sql) else {
        return Vec::new();
    };
    let map = |row: &rusqlite::Row<'_>| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, Option<String>>(1)?.unwrap_or_default(),
            row.get::<_, Option<String>>(2)?.unwrap_or_default(),
            row.get::<_, Option<f64>>(3)?,
        ))
    };
    let rows = if lease.is_empty() {
        query.query_map([cutoff], map)
    } else {
        query.query_map([cutoff, now_sec], map)
    };
    let Ok(rows) = rows else { return Vec::new() };
    rows.flatten()
        .map(|(id, title, cwd, started)| {
            let cwd = cwd.trim();
            let title = title.trim();
            let detail = if !cwd.is_empty() {
                format!("Working in {}", basename(cwd))
            } else if !title.is_empty() {
                title.to_owned()
            } else {
                "Working".into()
            };
            Activity {
                id: format!("gemini-api.hermes.{id}"),
                provider: "gemini-api".into(),
                state: "busy".into(),
                name: "Hermes".into(),
                detail,
                waiting_for: None,
                since: started
                    .map(|value| (value * 1000.0).max(0.0) as u64)
                    .unwrap_or(now_ms),
                queued: 0,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn google_assistant_requires_unfinished_latest_turn() {
        assert!(unfinished_google(
            r#"{"role":"assistant","providerID":"google","time":{}}"#
        ));
        assert!(unfinished_google(
            r#"{"role":"assistant","providerID":"google","time":{"completed":null}}"#
        ));
        assert!(!unfinished_google(
            r#"{"role":"assistant","providerID":"google","time":{"completed":1789000}}"#
        ));
        assert!(!unfinished_google(
            r#"{"role":"assistant","providerID":"other"}"#
        ));
    }
    #[test]
    fn gemini_cli_uses_only_newest_chat_and_project_marker() {
        let temp = tempfile::tempdir().unwrap();
        let project = temp.path().join("hash");
        fs::create_dir_all(project.join("chats")).unwrap();
        fs::write(project.join(".project_root"), "/Users/me/my-project\n").unwrap();
        fs::write(project.join("chats/current.jsonl"), "{}").unwrap();
        let at = modified_ms(&project.join("chats/current.jsonl")).unwrap();
        let rows = gemini_cli(temp.path(), at);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, "gemini-api.current");
        assert_eq!(rows[0].detail, "Working in my-project");
        assert!(gemini_cli(temp.path(), at + STALE_MS + 1).is_empty());
    }
}
