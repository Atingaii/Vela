//! "Is it working?" for the non-Claude providers (Claude's local sessions go through the hooks +
//! transcript-watcher engine, not here).
//!
//! None of the three has a state field like Claude Code's, so each is labelled with whatever it
//! can honestly provide (the same trade-off upstream made):
//!   - Cursor: the `composerHeaders` rows (JSON) in the editor's `state.vscdb` — `unfinishedRunAt`
//!     is set for the duration of a run and cleared when it ends; `hasBlockingPendingActions` /
//!     `hasPendingPlan` = waiting on you. This is **real state**. The database is in WAL mode, so
//!     it must be opened as a plain read-only connection (immutable ignores the WAL and shows the
//!     world as of the last checkpoint).
//!   - Codex: the desktop app keeps turn state in `thread_turns` inside
//!     `~/.codex/thread_history_1.sqlite` (status = inProgress with an empty completed_at = running)
//!     — real state. The CLI / VS Code extension fall back to classifying the last entry of the
//!     rollout, with a silence threshold that depends on the entry type.
//!   - Claude cloud sessions: no local transcript, so they are inferred from the desktop app's
//!     network throughput (marked ~).
//!   - Antigravity: bounded transcript tail + read-only permission status, matching Swift.
//!
//! Polled every 2 s (upstream cadence), broadcast only on change. Cost discipline: database
//! Cursor/Codex connections stay open, their queries are gated by mtime; the Codex rollout tail
//! is re-read only when its mtime changed, PowerShell runs only occasionally to find the network
//! process pid, and the thread runs at lowered priority.

use crate::AppState;
use serde::Serialize;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

const INTERVAL: Duration = Duration::from_secs(2);
mod antigravity;

#[derive(Clone, Serialize, Debug, PartialEq)]
pub struct Activity {
    /// Stable source identity; never a position in the current activity array.
    pub id: String,
    /// Provider id other than claude: codex / cursor / gemini
    pub provider: String,
    /// busy | waiting | success | idle
    pub state: String,
    pub name: String,
    pub detail: String,
    pub waiting_for: Option<String>,
    /// ms epoch
    pub since: u64,
    #[serde(default)]
    pub queued: u32,
    #[serde(default)]
    pub focusable: bool,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn mtime_ms(p: &std::path::Path) -> Option<u64> {
    std::fs::metadata(p)
        .ok()?
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|d| d.as_millis() as u64)
}

/// Persistent connection + change gating: the query runs again only when the database file (or its
/// -wal) changed mtime; otherwise the last result is reused. Cursor's state.vscdb is over 2 GB, and
/// reopening it every 2 s for a table scan slowed the whole machine (typing lagged).
struct DbCache {
    path: std::path::PathBuf,
    conn: Option<rusqlite::Connection>,
    sig: (u64, u64),
    last: Vec<Activity>,
    checked_once: bool,
}

impl DbCache {
    fn new(path: std::path::PathBuf) -> Self {
        Self {
            path,
            conn: None,
            sig: (0, 0),
            last: Vec::new(),
            checked_once: false,
        }
    }
    fn signature(&self) -> (u64, u64) {
        let wal = {
            let mut o = self.path.as_os_str().to_owned();
            o.push("-wal");
            std::path::PathBuf::from(o)
        };
        (
            mtime_ms(&self.path).unwrap_or(0),
            mtime_ms(&wal).unwrap_or(0),
        )
    }
    /// Calls f only when something changed (or on the first run); f returning None means the query failed → drop the connection and reopen next time
    fn refresh<F: FnOnce(&rusqlite::Connection) -> Option<Vec<Activity>>>(
        &mut self,
        f: F,
    ) -> Vec<Activity> {
        let sig = self.signature();
        if self.checked_once && sig == self.sig {
            return self.last.clone();
        }
        self.sig = sig;
        self.checked_once = true;
        if self.conn.is_none() {
            self.conn = open_ro(&self.path);
        }
        let Some(conn) = self.conn.as_ref() else {
            self.last.clear();
            return Vec::new();
        };
        match f(conn) {
            Some(v) => self.last = v,
            None => {
                self.conn = None;
                self.last.clear();
            }
        }
        self.last.clone()
    }
}

/// Everything the probe thread keeps between ticks
struct Ctx {
    cursor: DbCache,
    codex_home: std::path::PathBuf,
    codex_turns: DbCache,
    codex_names: Option<rusqlite::Connection>,
    rollout_path: Option<std::path::PathBuf>,
    rollout_checked_at: u64,
    rollout_sig: u64,
    rollout_last: Vec<Activity>,
}

impl Ctx {
    fn new() -> Self {
        Self::for_codex(dirs::home_dir().unwrap_or_default().join(".codex"))
    }
    fn for_codex(home: std::path::PathBuf) -> Self {
        Self {
            cursor: DbCache::new(crate::cursor::store_url().unwrap_or_default()),
            codex_turns: DbCache::new(home.join("thread_history_1.sqlite")),
            codex_home: home,
            codex_names: None,
            rollout_path: None,
            rollout_checked_at: 0,
            rollout_sig: 0,
            rollout_last: Vec::new(),
        }
    }
}

// ---------------- Cursor ----------------

fn open_ro(path: &std::path::Path) -> Option<rusqlite::Connection> {
    use rusqlite::OpenFlags;
    if !path.is_file() {
        return None;
    }
    rusqlite::Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()
}

const CURSOR_STALE_MS: u64 = 15 * 60_000;

#[cfg(target_os = "macos")]
fn cursor_launch_ms() -> Option<u64> {
    use objc2_app_kit::NSWorkspace;
    let apps = NSWorkspace::sharedWorkspace().runningApplications();
    let cursor = apps
        .iter()
        .find(|app| {
            app.bundleIdentifier()
                .is_some_and(|bundle| bundle.to_string() == "com.todesktop.230313mzl4w4u92")
        })
        .or_else(|| {
            apps.iter().find(|app| {
                app.bundleURL()
                    .and_then(|url| url.lastPathComponent())
                    .is_some_and(|name| name.to_string() == "Cursor.app")
            })
        })?;
    // NSRunningApplication often has no launchDate. Swift uses distantPast
    // in that case, preserving only the 15-minute staleness gate.
    Some(
        cursor
            .launchDate()
            .map(|date| (date.timeIntervalSince1970() * 1000.0).max(0.0) as u64)
            .unwrap_or(0),
    )
}

#[cfg(windows)]
fn cursor_launch_ms() -> Option<u64> {
    use windows::Win32::{
        Foundation::CloseHandle,
        System::Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
            TH32CS_SNAPPROCESS,
        },
    };
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0).ok()? };
    let mut entry = PROCESSENTRY32W::default();
    entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
    let mut launched = None;
    let mut current = unsafe { Process32FirstW(snapshot, &mut entry).is_ok() };
    while current {
        let len = entry
            .szExeFile
            .iter()
            .position(|character| *character == 0)
            .unwrap_or(entry.szExeFile.len());
        if String::from_utf16_lossy(&entry.szExeFile[..len]).eq_ignore_ascii_case("Cursor.exe") {
            launched =
                crate::claude_session_monitor::process_start_ms(entry.th32ProcessID).or(Some(0));
            break;
        }
        current = unsafe { Process32NextW(snapshot, &mut entry).is_ok() };
    }
    let _ = unsafe { CloseHandle(snapshot) };
    launched
}

#[cfg(not(any(target_os = "macos", windows)))]
fn cursor_launch_ms() -> Option<u64> {
    None
}

fn cursor_flag(value: Option<&serde_json::Value>) -> bool {
    match value {
        Some(serde_json::Value::Bool(value)) => *value,
        Some(serde_json::Value::Number(value)) => value.as_i64().is_some_and(|number| number != 0),
        Some(serde_json::Value::String(value)) => {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes"
            )
        }
        _ => false,
    }
}

fn cursor_date(value: Option<&serde_json::Value>) -> Option<u64> {
    value?
        .as_f64()
        .filter(|date| date.is_finite() && *date >= 0.0)
        .map(|date| date as u64)
}

fn cursor_session(
    json: &str,
    is_subagent: bool,
    launched_at: Option<u64>,
    now: u64,
) -> Option<Activity> {
    let head: serde_json::Value = serde_json::from_str(json).ok()?;
    let id = head.get("composerId")?.as_str()?;
    if is_subagent || cursor_flag(head.get("isSubagent")) {
        return None;
    }
    let blocked = cursor_flag(head.get("hasBlockingPendingActions"))
        || cursor_flag(head.get("hasPendingPlan"));
    let run_start = cursor_date(head.get("unfinishedRunAt"));
    let last_write = cursor_date(head.get("conversationCheckpointLastUpdatedAt"))
        .or_else(|| cursor_date(head.get("lastUpdatedAt")));
    let created = cursor_date(head.get("createdAt"));
    let touched = last_write.or(run_start).or(created);
    let stamp = last_write.or(run_start);
    let current_run = match (run_start, launched_at, stamp) {
        (Some(_), Some(launched), Some(stamp)) => stamp >= launched,
        _ => false,
    };
    let age = stamp.map(|stamp| now.saturating_sub(stamp));
    let running = current_run && age.is_some_and(|age| age <= CURSOR_STALE_MS);
    let success = current_run
        && age.is_some_and(|age| age > CURSOR_STALE_MS && age <= CURSOR_STALE_MS + 9_000);
    let finished = current_run
        && age.is_some_and(|age| age > CURSOR_STALE_MS + 9_000 && age <= CURSOR_STALE_MS + 15_000);
    let current_wait = if !blocked {
        false
    } else {
        let recently_touched =
            touched.is_some_and(|touched| now.saturating_sub(touched) <= CURSOR_STALE_MS);
        match (launched_at, touched) {
            (Some(launched), Some(touched)) => touched >= launched || recently_touched,
            (Some(_), None) => true,
            (None, _) => recently_touched,
        }
    };
    let state = if current_wait {
        "waiting"
    } else if running {
        "busy"
    } else if success {
        "success"
    } else if finished {
        "idle"
    } else {
        return None;
    };
    Some(Activity {
        id: format!("cursor.{id}"),
        provider: "cursor".into(),
        state: state.into(),
        name: head
            .get("name")
            .and_then(|value| value.as_str())
            .unwrap_or("Untitled chat")
            .into(),
        detail: head
            .get("subtitle")
            .and_then(|value| value.as_str())
            .unwrap_or("Cursor")
            .into(),
        waiting_for: current_wait.then(|| "needs your input".into()),
        since: (if running { run_start } else { None })
            .or(last_write)
            .or(created)
            .unwrap_or(now),
        queued: 0,
        focusable: false,
    })
}

fn cursor_activity(ctx: &mut Ctx) -> Vec<Activity> {
    // The connection remains open; the query and state conversion run on each
    // tick because an unchanged row crosses the stale/success/idle boundaries.
    if ctx.cursor.conn.is_none() {
        ctx.cursor.conn = open_ro(&ctx.cursor.path);
    }
    let Some(conn) = ctx.cursor.conn.as_ref() else {
        return Vec::new();
    };
    let launched = cursor_launch_ms();
    let now = now_ms();
    let rows = (|| {
        let mut stmt = conn.prepare("SELECT value, isSubagent FROM composerHeaders WHERE isArchived = 0 ORDER BY recency DESC LIMIT 40").ok()?;
        let rows = stmt
            .query_map([], |row| {
                let json: String = row.get(0)?;
                let flag: rusqlite::types::Value = row.get(1)?;
                Ok((json, flag))
            })
            .ok()?;
        let mut out = Vec::new();
        for row in rows.flatten() {
            let subagent = match row.1 {
                rusqlite::types::Value::Integer(value) => value != 0,
                rusqlite::types::Value::Text(value) => matches!(
                    value.trim().to_ascii_lowercase().as_str(),
                    "1" | "true" | "yes"
                ),
                _ => false,
            };
            if let Some(activity) = cursor_session(&row.0, subagent, launched, now) {
                out.push(activity);
            }
        }
        out.sort_by_key(|activity| std::cmp::Reverse(activity.since));
        Some(out)
    })();
    match rows {
        Some(rows) => rows,
        None => {
            ctx.cursor.conn = None;
            Vec::new()
        }
    }
}

// ---------------- Codex ----------------

/// The last meaningful entry at the tail of a rollout says which step Codex is on.
/// Lines look like {"timestamp","type":"response_item"|"turn_context"|"event_msg"|…,"payload":{…}};
/// task_started/task_complete events are not always written, so the decision rests on the entry
/// type plus how long the file has been silent:
///   function call (a tool is running, or waiting for your approval) → busy, for up to 10 minutes;
///   tool output / user message / turn context / reasoning → the model is deciding the next step,
///   busy while silent for < 120 s (long thinking has to be tolerated);
///   assistant message → could be the final answer or narration along the way, busy while silent for < 4 s;
///   turn_aborted → idle. Bookkeeping lines such as token_count are skipped.
#[derive(Clone, Copy, PartialEq, Debug)]
enum CodexStep {
    Tool,
    Thinking,
    AsstMsg,
    Aborted,
}

fn codex_last_step(text: &str) -> Option<(CodexStep, u64)> {
    for line in text.lines().rev().filter(|l| !l.trim().is_empty()) {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        let ts = v
            .get("timestamp")
            .and_then(|x| x.as_str())
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .map(|d| d.timestamp_millis().max(0) as u64)
            .unwrap_or(0);
        let kind = v.get("type").and_then(|x| x.as_str()).unwrap_or("");
        let p = v.get("payload").cloned().unwrap_or(serde_json::Value::Null);
        let pt = p.get("type").and_then(|x| x.as_str()).unwrap_or("");
        let step = match kind {
            "turn_context" => Some(CodexStep::Thinking),
            "response_item" => match pt {
                "function_call" | "local_shell_call" | "custom_tool_call" | "web_search_call" => {
                    Some(CodexStep::Tool)
                }
                "function_call_output" | "custom_tool_call_output" | "reasoning" => {
                    Some(CodexStep::Thinking)
                }
                "message" => match p.get("role").and_then(|x| x.as_str()).unwrap_or("") {
                    "assistant" => Some(CodexStep::AsstMsg),
                    "user" => Some(CodexStep::Thinking),
                    _ => None, // system/developer messages say nothing about state
                },
                _ => None,
            },
            "event_msg" => match pt {
                "turn_aborted" | "task_complete" => Some(CodexStep::Aborted), // newer builds do write task_complete: an explicit end
                "task_started" | "item_started" | "exec_command_begin" => Some(CodexStep::Thinking),
                "user_message" => Some(CodexStep::Thinking),
                "agent_message" => Some(CodexStep::AsstMsg),
                "agent_reasoning" | "agent_reasoning_raw_content" => Some(CodexStep::Thinking),
                _ => None, // token_count and other bookkeeping lines
            },
            _ => None,
        };
        if let Some(st) = step {
            return Some((st, ts));
        }
    }
    None
}

/// The desktop app's real state: table `thread_turns` in `~/.codex/thread_history_1.sqlite`
/// (status = inProgress / completed…, started_at in seconds, empty completed_at = still running).
/// The app maintains this turn table itself, which is far more reliable than a file mtime. Guard
/// against "inProgress forever after a crash": no new item for the thread in the last 10 minutes
/// (`thread_items.created_at_ms`) while the turn started more than 2 minutes ago → treated as stale.
fn codex_turns_in_progress(ctx: &mut Ctx) -> Vec<Activity> {
    let now = now_ms();
    if ctx.codex_names.is_none() {
        ctx.codex_names = open_ro(&ctx.codex_home.join("state_5.sqlite"));
    }
    let names = ctx.codex_names.as_ref();
    ctx.codex_turns.refresh(|conn| {
        let mut stmt = conn
            .prepare("SELECT thread_id, started_at FROM thread_turns WHERE status = 'inProgress' ORDER BY started_at DESC LIMIT 8")
            .ok()?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, rusqlite::types::Value>(1)?))).ok()?;
        let mut out = Vec::new();
        for (thread_id, started) in rows.flatten() {
            let started_ms = match started {
                rusqlite::types::Value::Integer(i) => (i as u64) * if i > 10_000_000_000 { 1 } else { 1000 },
                rusqlite::types::Value::Real(f) => (f * if f > 10_000_000_000.0 { 1.0 } else { 1000.0 }) as u64,
                _ => 0,
            };
            // The thread's latest item: freshness, and whether it is waiting for approval
            let (last_ms, last_type): (Option<i64>, Option<String>) = conn
                .query_row(
                    "SELECT created_at_ms, item_type FROM thread_items WHERE thread_id = ?1 ORDER BY created_at_ms DESC LIMIT 1",
                    [&thread_id],
                    |r| Ok((r.get::<_, Option<i64>>(0)?, r.get::<_, Option<String>>(1)?)),
                )
                .unwrap_or((None, None));
            let last = last_ms.map(|v| v as u64).unwrap_or(started_ms);
            let fresh = now.saturating_sub(last) <= 10 * 60_000 || now.saturating_sub(started_ms) <= 2 * 60_000;
            if !fresh {
                continue;
            }
            let mut name = String::new();
            if let Some(c) = names {
                if let Ok((title, first, nick)) = c.query_row(
                    "SELECT COALESCE(title,''), COALESCE(first_user_message,''), COALESCE(agent_nickname,'') FROM threads WHERE id = ?1",
                    [&thread_id],
                    |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?)),
                ) {
                    name = if !title.trim().is_empty() {
                        title
                    } else if !first.trim().is_empty() {
                        first.chars().take(40).collect()
                    } else if !nick.trim().is_empty() {
                        format!("Agent {nick}")
                    } else {
                        String::new()
                    };
                }
            }
            if name.is_empty() {
                name = "Codex".into();
            }
            let lt = last_type.unwrap_or_default().to_lowercase();
            let waiting = lt.contains("approval") || lt.contains("permission") || lt.contains("request_user");
            out.push(Activity {
                id: format!("codex-{thread_id}"),
                provider: "codex".into(),
                state: if waiting { "waiting" } else { "busy" }.into(),
                name,
                detail: if waiting { "needs your input".into() } else { "Working".into() },
                waiting_for: waiting.then(|| "needs your input".into()),
                since: started_ms,
                queued: 0,
                focusable: false,
            });
        }
        Some(out)
    })
}

fn codex_activity(ctx: &mut Ctx) -> Vec<Activity> {
    // 1. The desktop app's real state
    let turns = codex_turns_in_progress(ctx);
    if !turns.is_empty() {
        return turns;
    }
    // 2. CLI / extension: locate the rollout every 30 s; skip the 256 KB tail read when its mtime has not changed
    let now = now_ms();
    if now.saturating_sub(ctx.rollout_checked_at) > 30_000 || ctx.rollout_path.is_none() {
        ctx.rollout_checked_at = now;
        ctx.rollout_path = crate::codex::newest_rollout_in(&ctx.codex_home);
    }
    let Some(p) = ctx.rollout_path.clone() else {
        return vec![];
    };
    let mtime = mtime_ms(&p).unwrap_or(0);
    if mtime == ctx.rollout_sig {
        // Content unchanged: only re-evaluate whether the silence has timed out
        return ctx
            .rollout_last
            .iter()
            .filter(|a| now.saturating_sub(a.since) <= 10 * 60_000)
            .cloned()
            .collect();
    }
    ctx.rollout_sig = mtime;
    ctx.rollout_last.clear();
    if let Some(text) = crate::codex::tail_text(&p) {
        if let Some((step, ts)) = codex_last_step(&text) {
            let at = ts.max(mtime);
            let quiet = now.saturating_sub(at);
            let busy = match step {
                CodexStep::Tool => quiet <= 10 * 60_000,
                CodexStep::Thinking => quiet <= 120_000,
                CodexStep::AsstMsg => quiet <= 4_000,
                CodexStep::Aborted => false,
            };
            if busy {
                ctx.rollout_last = vec![Activity {
                    id: format!(
                        "codex-rollout-{}",
                        p.file_stem().unwrap_or_default().to_string_lossy()
                    ),
                    provider: "codex".into(),
                    state: "busy".into(),
                    name: "Codex".into(),
                    detail: "Working".into(),
                    waiting_for: None,
                    since: at,
                    queued: 0,
                    focusable: false,
                }];
            }
        }
    }
    ctx.rollout_last.clone()
}

// ---------------- Claude desktop (cloud sessions): network-activity heuristic ----------------

/// Cloud sessions leave no local transcript, so the four-state engine cannot see them. Next best
/// thing: while output is streaming, the Claude desktop app keeps receiving data from the network
/// (Winsock goes through AFD IOCTLs, which land in the Other counter of the process I/O counters).
/// Sampled every 2 s; a rate above the threshold means "streaming". Explicitly marked as inferred
/// (~); the first 60 samples go to run.log so the threshold can be calibrated.
struct IoSample {
    at: u64,
    other: u64,
    read: u64,
}
static CLAUDE_IO: std::sync::Mutex<Option<IoSample>> = std::sync::Mutex::new(None);
static CLAUDE_LAST_ACTIVE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
const CLAUDE_RATE_BPS: f64 = 2_500.0; // socket traffic of the network service process only; the idle heartbeat is far below this, streaming far above
const CLAUDE_HOLD_MS: u64 = 10_000; // tool calls often leave 2–4 s gaps with zero traffic; holding for 10 s avoids flicker
static CLAUDE_HITS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

/// Pid of the Claude desktop app's (Electron) network service child: its command line contains
/// `network.mojom.NetworkService`. All socket traffic goes through it, so the IOCTL noise of the
/// GPU/renderer processes (driver calls count as Other too) stays out. Found once and cached;
/// looked up again when the process disappears or every 5 minutes. The command line comes from
/// PowerShell, so that cost is paid only on a lookup.
static CLAUDE_NET_PID: std::sync::Mutex<(u32, u64)> = std::sync::Mutex::new((0, 0));

#[cfg(windows)]
fn claude_net_pid(maps: &crate::focus::ProcMaps) -> Option<u32> {
    let now = now_ms();
    {
        let g = CLAUDE_NET_PID.lock().unwrap();
        let (pid, at) = *g;
        if pid != 0
            && maps
                .name
                .get(&pid)
                .map(|n| n == "claude.exe")
                .unwrap_or(false)
            && now.saturating_sub(at) < 5 * 60_000
        {
            return Some(pid);
        }
        // Cache a miss for 60 s too: otherwise a PowerShell run every 2 s (a few hundred ms of CPU each) becomes the next source of lag
        if pid == 0 && at != 0 && now.saturating_sub(at) < 60_000 {
            return None;
        }
        // Claude desktop is not running at all: no need for PowerShell
        if !maps.name.values().any(|n| n == "claude.exe") {
            return None;
        }
    }
    let mut cmd = std::process::Command::new("powershell");
    cmd.args([
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        "Get-CimInstance Win32_Process -Filter \"Name='claude.exe'\" | Where-Object { $_.CommandLine -like '*network.mojom.NetworkService*' } | Select-Object -First 1 -ExpandProperty ProcessId",
    ]);
    cmd.stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    use std::os::windows::process::CommandExt;
    cmd.creation_flags(0x0800_0000);
    let pid: u32 = match cmd
        .output()
        .ok()
        .and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse().ok())
    {
        Some(p) => p,
        None => {
            *CLAUDE_NET_PID.lock().unwrap() = (0, now);
            return None;
        }
    };
    *CLAUDE_NET_PID.lock().unwrap() = (pid, now);
    crate::applog(&format!("claude net pid = {pid}"));
    Some(pid)
}

#[cfg(windows)]
fn claude_io_bytes() -> Option<(u64, u64)> {
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Threading::{
        GetProcessIoCounters, OpenProcess, IO_COUNTERS, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    let maps = crate::focus::proc_maps();
    let net_pid = claude_net_pid(&maps)?;
    let mut other = 0u64;
    let mut read = 0u64;
    let mut n = 0;
    for pid in maps.name.keys() {
        if *pid != net_pid {
            continue;
        }
        unsafe {
            let Ok(h) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, *pid) else {
                continue;
            };
            let mut io = IO_COUNTERS::default();
            if GetProcessIoCounters(h, &mut io).is_ok() {
                other = other.saturating_add(io.OtherTransferCount);
                read = read.saturating_add(io.ReadTransferCount);
                n += 1;
            }
            let _ = CloseHandle(h);
        }
    }
    if n == 0 {
        None
    } else {
        Some((other, read))
    }
}
#[cfg(not(windows))]
fn claude_io_bytes() -> Option<(u64, u64)> {
    None
}

fn claude_activity() -> Vec<Activity> {
    let now = now_ms();
    let Some((other, read)) = claude_io_bytes() else {
        return vec![];
    };
    let mut guard = CLAUDE_IO.lock().unwrap();
    let (rate_other, rate_read) = match guard.as_ref() {
        Some(prev) if now > prev.at && other >= prev.other && read >= prev.read => {
            let dt = (now - prev.at) as f64 / 1000.0;
            (
                (other - prev.other) as f64 / dt,
                (read - prev.read) as f64 / dt,
            )
        }
        _ => (0.0, 0.0),
    };
    *guard = Some(IoSample {
        at: now,
        other,
        read,
    });
    drop(guard);
    static SAMPLES: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    if SAMPLES.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 240 {
        crate::applog(&format!(
            "claude io: net {:.0} B/s, disk {:.0} B/s",
            rate_other, rate_read
        ));
    }
    // Two consecutive samples (≈4 s) above the threshold; a single spike (heartbeat, sync) does not count
    if rate_other >= CLAUDE_RATE_BPS {
        if CLAUDE_HITS.fetch_add(1, std::sync::atomic::Ordering::Relaxed) >= 1 {
            CLAUDE_LAST_ACTIVE.store(now, std::sync::atomic::Ordering::Relaxed);
        }
    } else {
        CLAUDE_HITS.store(0, std::sync::atomic::Ordering::Relaxed);
    }
    let last = CLAUDE_LAST_ACTIVE.load(std::sync::atomic::Ordering::Relaxed);
    if last > 0 && now.saturating_sub(last) <= CLAUDE_HOLD_MS {
        vec![Activity {
            id: "claude-desktop-network".into(),
            provider: "claude".into(),
            state: "busy".into(),
            name: "Claude".into(),
            detail: "Streaming (network)".into(),
            waiting_for: None,
            since: last,
            queued: 0,
            focusable: false,
        }]
    } else {
        vec![]
    }
}

// ---------------- Antigravity ----------------

fn antigravity_activity() -> Vec<Activity> {
    antigravity_activity_in(&crate::antigravity::state_roots())
}
fn antigravity_activity_in(roots: &[std::path::PathBuf]) -> Vec<Activity> {
    antigravity::read(roots, now_ms())
}

// ---------------- Putting it together ----------------

#[derive(Clone, Copy, Default)]
pub struct Presence {
    codex: bool,
    gemini: bool,
}

fn presence() -> Presence {
    Presence {
        codex: crate::codex::present(),
        gemini: crate::antigravity::present(),
    }
}

fn profile_activity(
    profile: &crate::providers::profiles::Profile,
    contexts: &mut std::collections::BTreeMap<String, Ctx>,
) -> Vec<Activity> {
    let rows = match profile.kind {
        "codex" => codex_activity(
            contexts
                .entry(profile.id.clone())
                .or_insert_with(|| Ctx::for_codex(profile.home.clone())),
        ),
        "antigravity" => antigravity_activity_in(std::slice::from_ref(&profile.home)),
        _ => Vec::new(),
    };
    rows.into_iter()
        .map(|mut row| {
            row.id = format!("{}:{}", profile.id, row.id);
            row.provider = profile.id.clone();
            row
        })
        .collect()
}

/// For doctor: the raw material behind the Codex working-state decision
pub fn probe() -> String {
    let now = now_ms();
    let Some(p) = crate::codex::newest_rollout() else {
        return "Codex activity: no rollout found".into();
    };
    let age = now.saturating_sub(mtime_ms(&p).unwrap_or(0)) / 1000;
    let step = crate::codex::tail_text(&p).and_then(|t| codex_last_step(&t));
    let tail: Vec<String> = crate::codex::tail_text(&p)
        .map(|t| {
            t.lines()
                .rev()
                .filter(|l| !l.trim().is_empty())
                .take(6)
                .map(|l| {
                    serde_json::from_str::<serde_json::Value>(l)
                        .map(|v| {
                            format!(
                                "{}/{}/{}",
                                v.get("type").and_then(|x| x.as_str()).unwrap_or("?"),
                                v.pointer("/payload/type")
                                    .and_then(|x| x.as_str())
                                    .unwrap_or("-"),
                                v.pointer("/payload/role")
                                    .and_then(|x| x.as_str())
                                    .unwrap_or("-")
                            )
                        })
                        .unwrap_or_else(|_| "(not a JSON line)".into())
                })
                .collect()
        })
        .unwrap_or_default();
    format!(
        "Codex activity: rollout={} modified {age}s ago | last step={:?} | last 6 lines (type/payload.type/role)=[{}]",
        p.display(),
        step.map(|(s, ts)| format!("{s:?} @{}s ago", now.saturating_sub(ts) / 1000)),
        tail.join(", ")
    )
}

#[cfg(windows)]
pub fn lower_thread_priority() {
    use windows::Win32::System::Threading::{
        GetCurrentThread, SetThreadPriority, THREAD_PRIORITY_BELOW_NORMAL,
    };
    unsafe {
        let _ = SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
    }
}
#[cfg(not(windows))]
pub fn lower_thread_priority() {}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        lower_thread_priority(); // the probe always yields to foreground input
        let mut ctx = Ctx::new();
        let mut last: Vec<Activity> = Vec::new();
        let mut pres = presence();
        let profiles = crate::providers::profiles::at_launch(&dirs::home_dir().unwrap_or_default());
        let mut contexts = std::collections::BTreeMap::new();
        let mut tick: u32 = 0;
        loop {
            // Presence checks (finding the exe, reading credentials) once a minute are plenty; the 2 s tick does only stats and a query
            if tick.is_multiple_of(30) {
                pres = presence();
            }
            tick = tick.wrapping_add(1);
            let (disabled, disabled_models) = {
                let state = app.state::<AppState>();
                let cfg = state.cfg.lock().unwrap();
                (
                    cfg.providers.disabled.clone(),
                    cfg.local_runtime.disabled_models.clone(),
                )
            };
            let local_rows = if disabled.contains("ollama-local") && disabled.contains("lmstudio") {
                Vec::new()
            } else {
                crate::local_runtime::activity_rows(&disabled_models)
                    .into_iter()
                    .filter(|row| {
                        row.provider
                            .split_once(":model:")
                            .is_some_and(|(runtime, _)| !disabled.contains(runtime))
                    })
                    .collect::<Vec<_>>()
            };
            let generations: std::collections::BTreeMap<String, u64> = [
                "claude",
                "cursor",
                "codex",
                "gemini",
                "grok",
                "gemini-api",
                "kimi",
            ]
            .into_iter()
            .map(str::to_owned)
            .chain(profiles.iter().map(|p| p.id.clone()))
            .chain(local_rows.iter().map(|row| row.provider.clone()))
            .map(|id| {
                let generation = crate::providers::generation(&id);
                (id, generation)
            })
            .collect();
            let mut found = Vec::new();
            if !disabled.contains("claude") {
                found.extend(claude_activity());
            }
            if !disabled.contains("cursor") {
                found.extend(cursor_activity(&mut ctx));
            }
            if pres.codex && !disabled.contains("codex") {
                found.extend(codex_activity(&mut ctx));
            }
            if pres.gemini && !disabled.contains("gemini") {
                found.extend(antigravity_activity());
            }
            let now = now_ms();
            if !disabled.contains("grok") {
                found.extend(crate::grok_activity::read(now));
            }
            if !disabled.contains("gemini-api") {
                found.extend(crate::gemini_api_activity::read(now));
            }
            if !disabled.contains("kimi") {
                found.extend(crate::kimi_activity::read(now));
            }
            found.extend(local_rows);
            for profile in profiles.iter().filter(|p| !disabled.contains(&p.id)) {
                found.extend(profile_activity(profile, &mut contexts));
            }
            contexts.retain(|id, _| !disabled.contains(id));
            crate::providers::with_lifecycle(|current| {
                let (disabled, disabled_models) = {
                    let state = app.state::<AppState>();
                    let cfg = state.cfg.lock().unwrap();
                    (
                        cfg.providers.disabled.clone(),
                        cfg.local_runtime.disabled_models.clone(),
                    )
                };
                found.retain(|row| {
                    !disabled.contains(&row.provider)
                        && !disabled_models.contains(&row.provider)
                        && row
                            .provider
                            .split_once(":model:")
                            .map_or(true, |(runtime, _)| !disabled.contains(runtime))
                        && generations.get(&row.provider).copied()
                            == Some(current.get(&row.provider).copied().unwrap_or(0))
                });
                if found != last {
                    // Log the first 20 state changes (with the Codex raw material) so thresholds can be calibrated
                    static LOGGED: std::sync::atomic::AtomicU32 =
                        std::sync::atomic::AtomicU32::new(0);
                    if LOGGED.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 20 {
                        crate::applog(&format!(
                            "activity: {:?} | {}",
                            found
                                .iter()
                                .map(|a| format!("{}:{}", a.provider, a.state))
                                .collect::<Vec<_>>(),
                            probe()
                        ));
                    }
                    last = found.clone();
                    {
                        let st = app.state::<AppState>();
                        *st.activity.lock().unwrap() = found.clone();
                    }
                    crate::notifications::observe(&app);
                    let _ = app.emit("activity", &found);
                }
            });
            std::thread::sleep(INTERVAL);
        }
    });
}

#[cfg(test)]
mod account_tests {
    use super::*;

    #[test]
    fn cursor_run_retires_through_success_and_idle_without_a_database_write() {
        let start = 1_000_000u64;
        let header = serde_json::json!({
            "composerId":"one", "unfinishedRunAt":start,
            "conversationCheckpointLastUpdatedAt":start,
            "name":"A task"
        })
        .to_string();
        let state = |now| cursor_session(&header, false, Some(start - 1), now).map(|row| row.state);
        assert_eq!(state(start + 1).as_deref(), Some("busy"));
        assert_eq!(
            state(start + CURSOR_STALE_MS + 1).as_deref(),
            Some("success")
        );
        assert_eq!(
            state(start + CURSOR_STALE_MS + 10_000).as_deref(),
            Some("idle")
        );
        assert_eq!(state(start + CURSOR_STALE_MS + 16_000), None);
        assert_eq!(cursor_session(&header, false, None, start + 1), None);
        assert_eq!(
            cursor_session(&header, false, Some(start + 1), start + 2),
            None
        );
    }

    #[test]
    fn cursor_wait_survives_same_launch_but_subagents_never_appear() {
        let start = 1_000_000u64;
        let header = serde_json::json!({
            "composerId":"approval", "hasPendingPlan":true,
            "createdAt":start, "lastUpdatedAt":start
        })
        .to_string();
        assert_eq!(
            cursor_session(&header, false, Some(start - 1), start + 8 * 60 * 60_000)
                .map(|row| row.state),
            Some("waiting".into())
        );
        assert!(cursor_session(&header, false, None, start + 8 * 60 * 60_000).is_none());
        assert!(cursor_session(&header, true, Some(0), start + 1).is_none());
    }
    fn codex_fixture(home: &std::path::Path, title: &str) {
        std::fs::create_dir_all(home).unwrap();
        let conn = rusqlite::Connection::open(home.join("thread_history_1.sqlite")).unwrap();
        conn.execute_batch("CREATE TABLE thread_turns(thread_id TEXT,status TEXT,started_at INTEGER); CREATE TABLE thread_items(thread_id TEXT,created_at_ms INTEGER,item_type TEXT);").unwrap();
        conn.execute(
            "INSERT INTO thread_turns VALUES ('same-thread','inProgress',?1)",
            [now_ms() as i64],
        )
        .unwrap();
        let names = rusqlite::Connection::open(home.join("state_5.sqlite")).unwrap();
        names.execute_batch("CREATE TABLE threads(id TEXT,title TEXT,first_user_message TEXT,agent_nickname TEXT);").unwrap();
        names
            .execute(
                "INSERT INTO threads VALUES ('same-thread',?1,'','')",
                [title],
            )
            .unwrap();
    }
    #[test]
    fn codex_profiles_use_their_own_turns_names_and_stable_ids() {
        let d = tempfile::tempdir().unwrap();
        let mut contexts = std::collections::BTreeMap::new();
        let make = |slug: &str| crate::providers::profiles::Profile {
            id: format!("codex-{slug}"),
            name: slug.into(),
            kind: "codex",
            home: d.path().join(slug),
            headline: "primary",
        };
        let work = make("work");
        let personal = make("personal");
        codex_fixture(&work.home, "Work fixture");
        codex_fixture(&personal.home, "Personal fixture");
        let a = profile_activity(&work, &mut contexts);
        let b = profile_activity(&personal, &mut contexts);
        assert_eq!(a[0].name, "Work fixture");
        assert_eq!(b[0].name, "Personal fixture");
        assert_eq!(a[0].provider, "codex-work");
        assert_ne!(a[0].id, b[0].id);
        assert_eq!(profile_activity(&work, &mut contexts)[0].id, a[0].id);
    }
    #[test]
    fn antigravity_profile_does_not_borrow_another_accounts_transcript() {
        let d = tempfile::tempdir().unwrap();
        let path = d.path().join("work/brain/fixture/.system_generated/logs");
        std::fs::create_dir_all(&path).unwrap();
        std::fs::write(path.join("transcript.jsonl"), "{\"type\":\"USER_INPUT\"}\n").unwrap();
        assert_eq!(antigravity_activity_in(&[d.path().join("work")]).len(), 1);
        assert!(antigravity_activity_in(&[d.path().join("personal")]).is_empty());
    }
}
