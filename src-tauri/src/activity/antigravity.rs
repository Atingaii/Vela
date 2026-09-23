//! Fixed Swift AntigravityActivityMonitor: transcript states and permission waits.
use super::{mtime_ms, open_ro, Activity};
use serde_json::Value;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

const TAIL_BYTES: u64 = 64 * 1024;
const BUSY_MS: u64 = 60_000; // Swift staleAfter (45 s) + 15 s grace.
const SUCCESS_MS: u64 = 9_000;

#[derive(Debug, PartialEq)]
enum State {
    Busy,
    Waiting(&'static str),
    Idle,
}

fn parse(text: &str) -> State {
    let mut turn_over = false;
    for line in text.lines().rev() {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let Some(kind) = v.get("type").and_then(Value::as_str) else {
            continue;
        };
        match kind {
            "USER_INPUT" => return if turn_over { State::Idle } else { State::Busy },
            "PLANNER_RESPONSE" => {
                if let Some(calls) = v
                    .get("tool_calls")
                    .and_then(Value::as_array)
                    .filter(|a| !a.is_empty())
                {
                    for call in calls {
                        let Some(name) = call.get("name").and_then(Value::as_str) else {
                            continue;
                        };
                        if name.contains("ask_question") {
                            return State::Waiting("Question");
                        }
                        if [
                            "multi_replace_file_content",
                            "write_to_file",
                            "replace_file_content",
                        ]
                        .iter()
                        .any(|needle| name.contains(needle))
                            && call
                                .pointer("/arguments/ArtifactMetadata/RequestFeedback")
                                .and_then(Value::as_bool)
                                == Some(true)
                        {
                            return State::Waiting("Approval");
                        }
                    }
                    if !turn_over {
                        return State::Busy;
                    }
                } else {
                    turn_over = true;
                }
            }
            "EPHEMERAL_MESSAGE" | "CONVERSATION_HISTORY" | "KNOWLEDGE_ARTIFACTS" | "CHECKPOINT" => {
            }
            _ if !turn_over => return State::Busy,
            _ => {}
        }
    }
    State::Idle
}

fn tail(path: &Path) -> Option<String> {
    let mut file = std::fs::File::open(path).ok()?;
    let end = file.seek(SeekFrom::End(0)).ok()?;
    file.seek(SeekFrom::Start(end.saturating_sub(TAIL_BYTES)))
        .ok()?;
    let mut bytes = Vec::new();
    file.take(TAIL_BYTES).read_to_end(&mut bytes).ok()?;
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

fn session(root: &Path, id: &str, path: &Path, modified: u64, now: u64) -> Option<Activity> {
    let mut state = tail(path).map(|s| parse(&s)).unwrap_or(State::Idle);
    if state == State::Busy {
        // A missing/busy/unsupported DB leaves the transcript state intact. Never create it.
        if let Some(db) = open_ro(&root.join("conversations").join(format!("{id}.db"))) {
            let status = db.query_row(
                "SELECT status FROM steps ORDER BY idx DESC LIMIT 1",
                [],
                |row| row.get::<_, i64>(0),
            );
            if matches!(status, Ok(2)) {
                state = State::Waiting("Permission");
            }
        }
    }
    let age = now.saturating_sub(modified);
    let (state, detail, waiting_for) = match state {
        State::Busy if age <= BUSY_MS => ("busy", "Working", None),
        State::Idle if age <= SUCCESS_MS => ("success", "Complete", None),
        State::Waiting(reason) => ("waiting", reason, Some(reason.to_owned())),
        _ => return None,
    };
    Some(Activity {
        id: format!("antigravity-{id}"),
        provider: "gemini".into(),
        name: "Antigravity".into(),
        state: state.into(),
        detail: detail.into(),
        waiting_for,
        since: modified,
        queued: 0,
    })
}

pub(super) fn read(roots: &[PathBuf], now: u64) -> Vec<Activity> {
    // Swift selects the newest transcript per install, then the newest *live* session.
    // An expired transcript in one install must not hide a pending question in another.
    roots
        .iter()
        .filter_map(|root| {
            let entries = std::fs::read_dir(root.join("brain")).ok()?;
            let (id, path, modified) = entries
                .flatten()
                .filter_map(|entry| {
                    let path = entry.path().join(".system_generated/logs/transcript.jsonl");
                    Some((
                        entry.file_name().to_string_lossy().into_owned(),
                        path.clone(),
                        mtime_ms(&path)?,
                    ))
                })
                .max_by_key(|(_, _, modified)| *modified)?;
            session(root, &id, &path, modified, now)
        })
        .max_by_key(|s| s.since)
        .into_iter()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn transcript(root: &Path, id: &str, text: &str) -> PathBuf {
        let path = root
            .join("brain")
            .join(id)
            .join(".system_generated/logs/transcript.jsonl");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, text).unwrap();
        path
    }
    #[test]
    fn parses_turn_end_bookkeeping_tools_questions_and_feedback() {
        let input = "{\"type\":\"USER_INPUT\"}\n";
        assert_eq!(parse(input), State::Busy);
        assert_eq!(
            parse(&format!(
                "{input}{{\"type\":\"PLANNER_RESPONSE\"}}\n{{\"type\":\"CHECKPOINT\"}}\npartial"
            )),
            State::Idle
        );
        assert_eq!(
            parse(&format!("{input}{{\"type\":\"TOOL_RESPONSE\"}}")),
            State::Busy
        );
        assert_eq!(parse(&format!("{input}{{\"type\":\"PLANNER_RESPONSE\",\"tool_calls\":[{{\"name\":\"agent.ask_question\"}}]}}")), State::Waiting("Question"));
        for name in [
            "write_to_file",
            "replace_file_content",
            "multi_replace_file_content",
        ] {
            let response = serde_json::json!({"type":"PLANNER_RESPONSE","tool_calls":[{"name":name,"arguments":{"ArtifactMetadata":{"RequestFeedback":true}}}]});
            assert_eq!(
                parse(&format!("{input}{response}")),
                State::Waiting("Approval")
            );
        }
        assert_eq!(parse("{\"type\":\"PLANNER_RESPONSE\",\"tool_calls\":[{\"name\":\"write_to_file\",\"arguments\":{}}]}"), State::Busy);
        // A subsequent tool response resolves the preceding question; reverse order is essential.
        assert_eq!(parse("{\"type\":\"PLANNER_RESPONSE\",\"tool_calls\":[{\"name\":\"ask_question\"}]}\n{\"type\":\"TOOL_RESPONSE\"}"), State::Busy);
    }
    #[test]
    fn busy_and_success_expire_but_waiting_does_not() {
        let root = tempfile::tempdir().unwrap();
        let path = transcript(root.path(), "fixture", "{\"type\":\"USER_INPUT\"}");
        assert_eq!(
            session(root.path(), "fixture", &path, 1000, 61_000)
                .unwrap()
                .state,
            "busy"
        );
        assert!(session(root.path(), "fixture", &path, 1000, 61_001).is_none());
        std::fs::write(&path, "{\"type\":\"PLANNER_RESPONSE\"}").unwrap();
        assert_eq!(
            session(root.path(), "fixture", &path, 1000, 10_000)
                .unwrap()
                .state,
            "success"
        );
        assert!(session(root.path(), "fixture", &path, 1000, 10_001).is_none());
        std::fs::write(
            &path,
            "{\"type\":\"PLANNER_RESPONSE\",\"tool_calls\":[{\"name\":\"ask_question\"}]}",
        )
        .unwrap();
        let s = session(root.path(), "fixture", &path, 1000, 86_400_000).unwrap();
        assert_eq!(s.waiting_for.as_deref(), Some("Question"));
        assert_eq!(s.since, 1000);
    }
    #[test]
    fn permission_status_uses_latest_step_and_read_only_database() {
        let root = tempfile::tempdir().unwrap();
        let path = transcript(root.path(), "fixture", "{\"type\":\"USER_INPUT\"}");
        let folder = root.path().join("conversations");
        assert!(session(root.path(), "fixture", &path, 1000, 1001).is_some());
        assert!(!folder.exists());
        std::fs::create_dir_all(&folder).unwrap();
        let db = rusqlite::Connection::open(folder.join("fixture.db")).unwrap();
        db.execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE steps(idx INTEGER,status INTEGER); INSERT INTO steps VALUES(1,1),(2,2);").unwrap();
        assert_eq!(
            session(root.path(), "fixture", &path, 1000, 100_000)
                .unwrap()
                .waiting_for
                .as_deref(),
            Some("Permission")
        );
        db.execute_batch("INSERT INTO steps VALUES(3,1)").unwrap();
        assert_eq!(
            session(root.path(), "fixture", &path, 1000, 1001)
                .unwrap()
                .state,
            "busy"
        );
        assert_eq!(
            db.query_row("SELECT COUNT(*) FROM steps", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            3
        );
    }
    #[test]
    fn each_root_contributes_its_newest_live_session() {
        let root = tempfile::tempdir().unwrap();
        let a = root.path().join("a");
        let b = root.path().join("b");
        let waiting = transcript(
            &a,
            "waiting",
            "{\"type\":\"PLANNER_RESPONSE\",\"tool_calls\":[{\"name\":\"ask_question\"}]}",
        );
        let ended = transcript(&b, "ended", "{\"type\":\"PLANNER_RESPONSE\"}");
        let set_time =
            |path: &Path, seconds| {
                std::fs::File::options()
                    .write(true)
                    .open(path)
                    .unwrap()
                    .set_times(std::fs::FileTimes::new().set_modified(
                        std::time::UNIX_EPOCH + std::time::Duration::from_secs(seconds),
                    ))
                    .unwrap()
            };
        set_time(&waiting, 10);
        set_time(&ended, 20);
        let sessions = read(&[a, b], 100_000);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].id, "antigravity-waiting");
    }
    #[test]
    fn tail_is_bounded_even_with_a_large_transcript() {
        let root = tempfile::tempdir().unwrap();
        let text = format!(
            "{}\n{{\"type\":\"USER_INPUT\"}}",
            "x".repeat(TAIL_BYTES as usize * 2)
        );
        let path = transcript(root.path(), "fixture", &text);
        let text = tail(&path).unwrap();
        assert_eq!(text.len(), TAIL_BYTES as usize);
        assert_eq!(parse(&text), State::Busy);
    }
}
