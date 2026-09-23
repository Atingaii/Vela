//! Claude Code's live session registry, translated from ClaudeSessionMonitor,
//! ClaudeSessionRecord and ClaudeTranscript at the pinned Swift revision.
//! Only Claude-owned files are read. A registry row is shown only for its live PID.
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};
use tauri::{AppHandle, Manager};

const TAIL_BYTES: u64 = 64 * 1024;
const REUSE_TOLERANCE_MS: u64 = 5 * 60 * 1000;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LiveSession {
    pub id: String,
    pub session_id: Option<String>,
    pub provider: String,
    pub name: String,
    pub detail: String,
    pub state: &'static str,
    pub waiting_for: Option<String>,
    pub since: u64,
    pub pid: u32,
    pub cwd: String,
}

#[derive(Clone)]
struct Record {
    pid: u32,
    session_id: Option<String>,
    cwd: String,
    name: String,
    detail: String,
    state: &'static str,
    reports_status: bool,
    waiting_for: Option<String>,
    started_at: Option<u64>,
    since: u64,
}

fn timestamp(v: &Value) -> Option<u64> {
    v.as_u64().or_else(|| {
        v.as_f64()
            .filter(|x| x.is_finite() && *x >= 0.0)
            .map(|x| x as u64)
    })
}

fn parse_proc_start(s: &str) -> Option<u64> {
    let compact = s.split_whitespace().collect::<Vec<_>>().join(" ");
    let time = chrono::NaiveDateTime::parse_from_str(&compact, "%a %b %e %H:%M:%S %Y").ok()?;
    u64::try_from(time.and_utc().timestamp_millis()).ok()
}

impl Record {
    fn parse(v: &Value, fallback_since: u64) -> Option<Self> {
        let pid = v
            .get("pid")?
            .as_u64()
            .and_then(|n| u32::try_from(n).ok())
            .filter(|n| *n > 0)?;
        let cwd = v.get("cwd")?.as_str()?.to_string();
        let folder = Path::new(&cwd)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("claude")
            .to_string();
        let tempo = v.get("tempo").and_then(Value::as_str);
        let status = v.get("status").and_then(Value::as_str);
        let (state, reports_status) = match (tempo, status) {
            (Some("blocked"), _) | (_, Some("waiting")) => ("waiting", true),
            (Some("active"), _) | (_, Some("busy")) => ("busy", true),
            (Some("idle"), _) | (_, Some("idle")) => ("idle", true),
            _ => ("idle", false),
        };
        let surface = match v.get("entrypoint").and_then(Value::as_str) {
            Some("claude-desktop" | "claude-desktop-3p") => "Desktop",
            Some("claude-vscode") => "VS Code",
            Some("local-agent") => "Agent",
            _ => "Terminal",
        };
        let started_at = v.get("startedAt").and_then(timestamp).or_else(|| {
            v.get("procStart")
                .and_then(Value::as_str)
                .and_then(parse_proc_start)
        });
        let since = v
            .get("statusUpdatedAt")
            .and_then(timestamp)
            .or_else(|| v.get("updatedAt").and_then(timestamp))
            .or(started_at)
            .unwrap_or(fallback_since);
        Some(Self {
            pid,
            session_id: v
                .get("sessionId")
                .and_then(Value::as_str)
                .map(str::to_owned),
            cwd,
            name: v
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or(&folder)
                .to_string(),
            detail: format!("{surface} · {folder}"),
            state,
            reports_status,
            waiting_for: v
                .get("waitingFor")
                .or_else(|| v.get("needs"))
                .and_then(Value::as_str)
                .map(str::to_owned),
            started_at,
            since,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Turn {
    InFlight,
    Finished,
}

fn interrupted(message: &Value) -> bool {
    let content = &message["content"];
    content
        .as_str()
        .is_some_and(|s| s.starts_with("[Request interrupted by user"))
        || content.as_array().is_some_and(|blocks| {
            blocks.iter().any(|b| {
                b.get("text")
                    .and_then(Value::as_str)
                    .is_some_and(|s| s.starts_with("[Request interrupted by user"))
            })
        })
}

fn turn_in_tail(bytes: &[u8]) -> Option<Turn> {
    for line in bytes.split(|b| *b == b'\n').rev() {
        let Ok(v) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        if v.get("isSidechain").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        match v.get("type").and_then(Value::as_str) {
            Some("assistant") => {
                return Some(
                    if v.pointer("/message/stop_reason").and_then(Value::as_str) == Some("tool_use")
                    {
                        Turn::InFlight
                    } else {
                        Turn::Finished
                    },
                )
            }
            Some("user") => {
                return Some(if interrupted(&v["message"]) {
                    Turn::Finished
                } else {
                    Turn::InFlight
                })
            }
            _ => {}
        }
    }
    None
}

fn direct_transcript_path(projects: &Path, session_id: &str, cwd: &str) -> PathBuf {
    // Claude replaces both separators and dots, preserving all other characters.
    let slug: String = cwd
        .chars()
        .map(|c| if c == '/' || c == '.' { '-' } else { c })
        .collect();
    let file = format!("{session_id}.jsonl");
    projects.join(slug).join(file)
}

fn scan_transcript_path(projects: &Path, session_id: &str) -> Option<PathBuf> {
    let file = format!("{session_id}.jsonl");
    std::fs::read_dir(projects)
        .ok()?
        .flatten()
        .map(|entry| entry.path().join(&file))
        .find(|path| path.is_file())
}

fn tail(path: &Path) -> Option<Vec<u8>> {
    let mut file = std::fs::File::open(path).ok()?;
    let len = file.metadata().ok()?.len();
    file.seek(SeekFrom::Start(len.saturating_sub(TAIL_BYTES)))
        .ok()?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).ok()?;
    Some(bytes)
}

#[derive(Default)]
pub struct Monitor {
    entered: HashMap<String, (Turn, u64)>,
    cached: HashMap<String, (u64, u64, Option<Turn>)>,
    paths: HashMap<String, PathBuf>,
    scanned: HashSet<String>,
}

impl Monitor {
    fn transcript_activity(&mut self, projects: &Path, record: &Record) -> Option<(Turn, u64)> {
        let id = record.session_id.as_ref()?;
        // Claude may create the direct transcript after the registry file.
        // Only the expensive directory fallback is a one-shot scan.
        let direct = direct_transcript_path(projects, id, &record.cwd);
        let path = if direct.is_file() {
            direct
        } else if let Some(path) = self.paths.get(id).filter(|path| path.is_file()) {
            path.clone()
        } else {
            if !self.scanned.insert(id.clone()) {
                return None;
            }
            scan_transcript_path(projects, id)?
        };
        self.paths.insert(id.clone(), path.clone());
        let meta = std::fs::metadata(&path).ok()?;
        let size = meta.len();
        let modified = meta
            .modified()
            .ok()?
            .duration_since(UNIX_EPOCH)
            .ok()?
            .as_millis() as u64;
        let turn = match self.cached.get(id) {
            Some((old_mtime, old_size, turn)) if *old_mtime == modified && *old_size == size => {
                *turn
            }
            _ => {
                let turn = tail(&path).and_then(|bytes| turn_in_tail(&bytes));
                self.cached.insert(id.clone(), (modified, size, turn));
                turn
            }
        }?;
        if let Some((previous, since)) = self.entered.get(id).copied() {
            if previous == turn {
                return Some((turn, since));
            }
        }
        self.entered.insert(id.clone(), (turn, modified));
        Some((turn, modified))
    }

    pub fn read_profile(
        &mut self,
        home: &Path,
        provider: &str,
        ignored_pids: &HashSet<u32>,
    ) -> Vec<LiveSession> {
        let directory = home.join("sessions");
        let mut records: Vec<Record> = std::fs::read_dir(directory)
            .ok()
            .into_iter()
            .flat_map(|rd| rd.flatten())
            .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "json"))
            .filter_map(|entry| {
                let path = entry.path();
                let bytes = std::fs::read(&path).ok()?;
                let json = serde_json::from_slice::<Value>(&bytes).ok()?;
                let fallback = std::fs::metadata(&path)
                    .ok()?
                    .modified()
                    .ok()?
                    .duration_since(UNIX_EPOCH)
                    .ok()?
                    .as_millis() as u64;
                let record = Record::parse(&json, fallback)?;
                (!ignored_pids.contains(&record.pid) && is_alive(record.pid, record.started_at))
                    .then_some(record)
            })
            .collect();
        // A resumed session may have two live registry files. Keep the latest process.
        let mut newest: HashMap<String, Record> = HashMap::new();
        records.retain(|record| {
            if let Some(id) = &record.session_id {
                match newest.get(id) {
                    Some(held)
                        if held.started_at.unwrap_or(0) >= record.started_at.unwrap_or(0) => {}
                    _ => {
                        newest.insert(id.clone(), record.clone());
                    }
                }
                false
            } else {
                true
            }
        });
        records.extend(newest.into_values());
        let projects = home.join("projects");
        let mut out: Vec<LiveSession> = records
            .into_iter()
            .map(|record| {
                let mut state = record.state;
                let mut since = record.since;
                let mut waiting_for = record.waiting_for.clone();
                if !record.reports_status {
                    if let Some((turn, moved)) = self.transcript_activity(&projects, &record) {
                        state = if turn == Turn::InFlight {
                            "busy"
                        } else {
                            "idle"
                        };
                        since = moved;
                        waiting_for = None;
                    }
                }
                LiveSession {
                    id: if provider == "claude" {
                        format!("claude.{}", record.pid)
                    } else {
                        format!("{provider}.{}", record.pid)
                    },
                    session_id: record.session_id,
                    provider: provider.to_string(),
                    name: record.name,
                    detail: record.detail,
                    state,
                    waiting_for,
                    since,
                    pid: record.pid,
                    cwd: record.cwd,
                }
            })
            .collect();
        out.sort_by(|a, b| b.since.cmp(&a.since).then(a.id.cmp(&b.id)));
        out
    }
}

/// Two-second liveness and transcript tick, matching the Swift monitor. The
/// generation check covers account disconnect/reconnect while a scan is in flight.
pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        crate::activity::lower_thread_priority();
        let mut monitors: HashMap<String, Monitor> = HashMap::new();
        loop {
            let profiles: Vec<(String, PathBuf, u64)> = crate::usage::profile_dirs()
                .into_iter()
                .map(|home| {
                    let name = home
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or(".claude");
                    let id = if name == ".claude" {
                        "claude".to_string()
                    } else {
                        name.trim_start_matches('.').to_string()
                    };
                    let generation = crate::providers::generation(&id);
                    (id, home, generation)
                })
                .collect();
            let disabled = app
                .state::<crate::AppState>()
                .cfg
                .lock()
                .unwrap()
                .providers
                .disabled
                .clone();
            let mut rows = Vec::new();
            let ignored = crate::usage::renewal_pid()
                .into_iter()
                .collect::<HashSet<_>>();
            for (id, home, generation) in &profiles {
                if disabled.contains(id) {
                    continue;
                }
                rows.extend(
                    monitors
                        .entry(id.clone())
                        .or_default()
                        .read_profile(home, id, &ignored)
                        .into_iter()
                        .map(|row| (id.clone(), *generation, row)),
                );
            }
            monitors.retain(|id, _| profiles.iter().any(|(p, _, _)| p == id));
            let changed = crate::providers::with_lifecycle(|epochs| {
                let disabled = app
                    .state::<crate::AppState>()
                    .cfg
                    .lock()
                    .unwrap()
                    .providers
                    .disabled
                    .clone();
                let accepted = rows
                    .into_iter()
                    .filter(|(id, generation, _)| {
                        !disabled.contains(id)
                            && epochs.get(id).copied().unwrap_or(0) == *generation
                    })
                    .map(|(_, _, row)| row)
                    .collect();
                app.state::<crate::AppState>()
                    .store
                    .lock()
                    .unwrap()
                    .replace_registry(accepted)
            });
            if changed {
                crate::broadcast(&app);
            }
            std::thread::sleep(Duration::from_secs(2));
        }
    });
}

fn is_alive(pid: u32, started_at: Option<u64>) -> bool {
    #[cfg(unix)]
    {
        if unsafe { libc::kill(pid as i32, 0) } != 0
            && std::io::Error::last_os_error().raw_os_error() != Some(libc::EPERM)
        {
            return false;
        }
    }
    #[cfg(windows)]
    {
        use windows::Win32::Foundation::CloseHandle;
        use windows::Win32::System::Threading::{OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION};
        let Ok(handle) = (unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) })
        else {
            return false;
        };
        unsafe {
            let _ = CloseHandle(handle);
        }
    }
    if let (Some(expected), Some(actual)) = (started_at, process_start_ms(pid)) {
        return actual.abs_diff(expected) < REUSE_TOLERANCE_MS;
    }
    true
}

#[cfg(target_os = "macos")]
pub(crate) fn process_start_ms(pid: u32) -> Option<u64> {
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let len = std::mem::size_of::<libc::proc_bsdinfo>();
    let read = unsafe {
        libc::proc_pidinfo(
            pid as i32,
            libc::PROC_PIDTBSDINFO,
            0,
            &mut info as *mut _ as *mut _,
            len as i32,
        )
    };
    if read != len as i32 {
        return None;
    }
    Some(
        info.pbi_start_tvsec
            .saturating_mul(1000)
            .saturating_add(info.pbi_start_tvusec / 1000),
    )
}

#[cfg(windows)]
pub(crate) fn process_start_ms(pid: u32) -> Option<u64> {
    use windows::Win32::Foundation::{CloseHandle, FILETIME};
    use windows::Win32::System::Threading::{
        GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }.ok()?;
    let mut created = FILETIME::default();
    let mut exited = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut user = FILETIME::default();
    let result =
        unsafe { GetProcessTimes(handle, &mut created, &mut exited, &mut kernel, &mut user) };
    unsafe {
        let _ = CloseHandle(handle);
    }
    result.ok()?;
    let ticks = ((created.dwHighDateTime as u64) << 32) | created.dwLowDateTime as u64;
    Some(ticks.saturating_sub(116_444_736_000_000_000) / 10_000)
}

#[cfg(all(not(target_os = "macos"), not(windows)))]
fn process_start_ms(_pid: u32) -> Option<u64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[test]
    fn registry_tempo_status_and_stable_since() {
        let record = Record::parse(&serde_json::json!({"pid":1,"cwd":"/tmp/app","status":"busy","tempo":"blocked","waitingFor":"permission","startedAt":1000,"statusUpdatedAt":2500}), 9).unwrap();
        assert_eq!(record.state, "waiting");
        assert_eq!(record.waiting_for.as_deref(), Some("permission"));
        assert_eq!(record.since, 2500);
        assert!(record.reports_status);
        let desktop = Record::parse(
            &serde_json::json!({"pid":1,"cwd":"/tmp/app","entrypoint":"claude-desktop"}),
            6000,
        )
        .unwrap();
        assert_eq!(desktop.detail, "Desktop · app");
        assert!(!desktop.reports_status);
        assert_eq!(desktop.since, 6000);
    }
    #[test]
    fn transcript_only_uses_parent_conversation() {
        let bytes = b"{\"type\":\"assistant\",\"message\":{\"stop_reason\":\"end_turn\"}}\n{\"type\":\"user\",\"isSidechain\":true}\n{\"type\":\"bridge-session\"}\n";
        assert_eq!(turn_in_tail(bytes), Some(Turn::Finished));
        assert_eq!(
            turn_in_tail(b"{\"type\":\"assistant\",\"message\":{\"stop_reason\":\"tool_use\"}}\n"),
            Some(Turn::InFlight)
        );
        assert_eq!(turn_in_tail(b"{\"type\":\"user\",\"message\":{\"content\":\"[Request interrupted by user]\"}}\n"), Some(Turn::Finished));
    }
    #[test]
    fn proc_start_parses_utc_space_padded_day() {
        assert_eq!(
            parse_proc_start("Fri Aug  7 05:15:20 2026"),
            Some(1786079720000)
        );
    }

    #[test]
    fn live_registry_deduplicates_pid_rows_and_tracks_desktop_transcript() {
        let root = tempfile::tempdir().unwrap();
        let sessions = root.path().join("sessions");
        let projects = root.path().join("projects").join("-tmp-work");
        fs::create_dir_all(&sessions).unwrap();
        fs::create_dir_all(&projects).unwrap();
        let pid = std::process::id();
        let started = process_start_ms(pid).unwrap_or(1_700_000_000_000);
        for (file, offset, name) in [("old.json", 1000, "old"), ("new.json", 2000, "new")] {
            fs::write(sessions.join(file), serde_json::to_vec(&serde_json::json!({
                "pid":pid,"cwd":"/tmp/work","sessionId":"session-a","entrypoint":"claude-desktop",
                "name":name,"startedAt":started+offset
            })).unwrap()).unwrap();
        }
        fs::write(
            projects.join("session-a.jsonl"),
            b"{\"type\":\"user\",\"message\":{\"content\":\"hello\"}}\n",
        )
        .unwrap();
        let mut monitor = Monitor::default();
        let first = monitor.read_profile(root.path(), "claude", &HashSet::new());
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].name, "new");
        assert_eq!(first[0].state, "busy");
        let since = first[0].since;
        assert_eq!(
            monitor.read_profile(root.path(), "claude", &HashSet::new())[0].since,
            since
        );
        fs::write(
            projects.join("session-a.jsonl"),
            b"{\"type\":\"assistant\",\"message\":{\"stop_reason\":\"end_turn\"}}\n",
        )
        .unwrap();
        assert_eq!(
            monitor.read_profile(root.path(), "claude", &HashSet::new())[0].state,
            "idle"
        );
        assert!(monitor
            .read_profile(root.path(), "claude", &[pid].into_iter().collect())
            .is_empty());
    }

    #[test]
    fn direct_transcript_created_after_registry_is_found_on_next_poll() {
        let root = tempfile::tempdir().unwrap();
        let sessions = root.path().join("sessions");
        let projects = root.path().join("projects").join("-tmp-work");
        fs::create_dir_all(&sessions).unwrap();
        fs::create_dir_all(&projects).unwrap();
        let pid = std::process::id();
        let started = process_start_ms(pid).unwrap_or(1_700_000_000_000);
        fs::write(
            sessions.join("live.json"),
            serde_json::to_vec(&serde_json::json!({
                "pid":pid,"cwd":"/tmp/work","sessionId":"late-transcript",
                "entrypoint":"claude-desktop","startedAt":started
            }))
            .unwrap(),
        )
        .unwrap();
        let mut monitor = Monitor::default();
        assert_eq!(
            monitor.read_profile(root.path(), "claude", &HashSet::new())[0].state,
            "idle"
        );
        fs::write(
            projects.join("late-transcript.jsonl"),
            b"{\"type\":\"user\",\"message\":{\"content\":\"hello\"}}\n",
        )
        .unwrap();
        assert_eq!(
            monitor.read_profile(root.path(), "claude", &HashSet::new())[0].state,
            "busy"
        );
    }
}
