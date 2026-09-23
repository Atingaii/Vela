//! Kimi Code process-to-session activity, translated from KimiActivityMonitor.swift.
use crate::activity::Activity;
use serde_json::Value;
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::UNIX_EPOCH;

const STALE_MS: u64 = 90_000;
const TAIL_BYTES: u64 = 65_536;
#[cfg(target_os = "macos")]
const PROC_ALL_PIDS: u32 = 1; // sys/proc_info.h

#[derive(Clone)]
struct Process {
    pid: u32,
    started_at: Option<u64>,
    cwd: String,
}
static FOCUS: OnceLock<Mutex<HashMap<String, (u32, Option<u64>)>>> = OnceLock::new();
fn focus_map() -> &'static Mutex<HashMap<String, (u32, Option<u64>)>> {
    FOCUS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Only current monitor-owned process IDs may be focused, and PID reuse is rechecked.
pub fn focus_target(id: &str) -> Option<u32> {
    let (pid, start) = *focus_map().lock().ok()?.get(id)?;
    (start.is_some()
        && crate::claude_session_monitor::process_start_ms(pid) == start
        && kimi_identity(pid))
    .then_some(pid)
}

pub fn read(now_ms: u64) -> Vec<Activity> {
    if crate::smoke::root().is_some() {
        if let Ok(mut held) = focus_map().lock() {
            held.clear();
        }
        return Vec::new();
    }
    let root = std::env::var_os("KIMI_CODE_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| dirs::home_dir().map(|home| home.join(".kimi-code")));
    root.map(|path| read_at(&path, now_ms, processes()))
        .unwrap_or_default()
}

fn read_at(root: &Path, now_ms: u64, mut live: Vec<Process>) -> Vec<Activity> {
    let mut sessions = index(root);
    let mut focus = HashMap::new();
    live.sort_by(|a, b| b.started_at.unwrap_or(0).cmp(&a.started_at.unwrap_or(0)));
    let mut out = Vec::new();
    for process in live {
        if !alive(process.pid, process.started_at) {
            continue;
        }
        let key = resolve(&process.cwd);
        let Some(session_dir) = sessions.remove(&key) else {
            continue;
        };
        let row = session(&session_dir, &process, now_ms);
        if row.focusable {
            focus.insert(row.id.clone(), (process.pid, process.started_at));
        }
        out.push(row);
    }
    if let Ok(mut held) = focus_map().lock() {
        *held = focus;
    }
    out.sort_by(|a, b| b.since.cmp(&a.since).then_with(|| a.id.cmp(&b.id)));
    out
}

fn index(root: &Path) -> HashMap<String, PathBuf> {
    // The index is append-only; only the recent bounded tail matters for current sessions.
    let mut out = HashMap::new();
    let Some(bytes) = tail(&root.join("session_index.jsonl"), 4 * 1024 * 1024) else {
        return out;
    };
    for line in String::from_utf8_lossy(&bytes).lines() {
        let Ok(row) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let (Some(work), Some(dir)) = (
            row.get("workDir").and_then(Value::as_str),
            row.get("sessionDir").and_then(Value::as_str),
        ) else {
            continue;
        };
        if !work.is_empty() && !dir.is_empty() {
            out.insert(resolve(work), PathBuf::from(dir));
        }
    }
    out
}

fn resolve(path: &str) -> String {
    #[cfg(windows)]
    {
        let resolved = fs::canonicalize(path).unwrap_or_else(|_| PathBuf::from(path));
        return windows_text_path(&resolved.to_string_lossy());
    }
    #[cfg(not(windows))]
    {
        let mut value = path
            .split('/')
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join("/");
        if path.starts_with('/') {
            value.insert(0, '/');
        }
        for alias in ["/private/var", "/private/tmp", "/private/etc"] {
            if value == alias || value.starts_with(&format!("{alias}/")) {
                return value.trim_start_matches("/private").to_owned();
            }
        }
        value
    }
}

#[cfg(windows)]
fn windows_text_path(path: &str) -> String {
    path.replace('\\', "/").trim_end_matches('/').to_lowercase()
}

fn tail(path: &Path, max: u64) -> Option<Vec<u8>> {
    let mut file = File::open(path).ok()?;
    let size = file.metadata().ok()?.len();
    file.seek(SeekFrom::Start(size.saturating_sub(max))).ok()?;
    let mut bytes = Vec::new();
    file.take(max).read_to_end(&mut bytes).ok()?;
    Some(bytes)
}

fn modified_ms(path: &Path) -> Option<u64> {
    fs::metadata(path)
        .ok()?
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|at| at.as_millis() as u64)
}

enum Turn {
    Busy(Option<u64>),
    Finished(u64),
    Waiting(u64, Option<String>),
}

fn turn(bytes: &[u8], now_ms: u64) -> Option<Turn> {
    let text = std::str::from_utf8(bytes).ok()?;
    let mut approval_resolved = false;
    for line in text.lines().rev() {
        let Ok(mut record) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if record.get("type").and_then(Value::as_str) == Some("context.append_loop_event") {
            if let Some(event) = record.get("event").filter(|value| value.is_object()) {
                record = event.clone();
            }
        }
        if record
            .get("agentId")
            .and_then(Value::as_str)
            .is_some_and(|id| id != "main")
        {
            continue;
        }
        let Some(kind) = record.get("type").and_then(Value::as_str) else {
            continue;
        };
        let at = record.get("time").and_then(Value::as_u64);
        match kind {
            "approval.requested" => {
                if approval_resolved {
                    continue;
                }
                let summary = ["tool", "toolName", "name", "command", "summary"]
                    .iter()
                    .find_map(|key| {
                        record
                            .get(*key)
                            .and_then(Value::as_str)
                            .filter(|value| !value.is_empty())
                            .map(str::to_owned)
                    });
                return Some(Turn::Waiting(at.unwrap_or(now_ms), summary));
            }
            "approval.resolved" => {
                approval_resolved = true;
            }
            "turn.prompt" | "prompt.accepted" => return Some(Turn::Busy(at)),
            "turn.ended" => return Some(Turn::Finished(at.unwrap_or(now_ms))),
            "context.append_loop_event"
            | "content.part"
            | "step.begin"
            | "step.end"
            | "tool.call"
            | "tool.result"
            | "think"
            | "text"
            | "llm.request" => return Some(Turn::Busy(at)),
            _ => {}
        }
    }
    None
}

fn session(dir: &Path, process: &Process, now_ms: u64) -> Activity {
    let wire = dir.join("agents/main/wire.jsonl");
    let modified = modified_ms(&wire);
    let state = tail(&wire, TAIL_BYTES).and_then(|bytes| turn(&bytes, now_ms));
    let path = Path::new(&process.cwd);
    let leaf = path
        .file_name()
        .map(|part| part.to_string_lossy().into_owned())
        .unwrap_or_default();
    let parent = path
        .parent()
        .and_then(Path::file_name)
        .map(|part| part.to_string_lossy().into_owned())
        .unwrap_or_default();
    let name = if !parent.is_empty() {
        format!("{parent}/{leaf}")
    } else if !leaf.is_empty() {
        leaf
    } else {
        "Kimi".into()
    };
    // The owner is the terminal application, not the CLI binary itself.
    let detail = surface(process.pid);
    let (state, since, waiting_for) = match state {
        Some(Turn::Waiting(at, what)) => ("waiting", at, what),
        Some(Turn::Busy(at))
            if modified.is_some_and(|mtime| now_ms.saturating_sub(mtime) <= STALE_MS) =>
        {
            ("busy", at.or(modified).unwrap_or(now_ms), None)
        }
        Some(Turn::Busy(_)) => ("idle", modified.unwrap_or(now_ms), None),
        Some(Turn::Finished(at)) if now_ms.saturating_sub(at) <= 10_000 => ("success", at, None),
        Some(Turn::Finished(at)) => ("idle", at, None),
        None => ("idle", modified.unwrap_or(now_ms), None),
    };
    Activity {
        id: format!(
            "kimi.{}",
            dir.file_name().unwrap_or_default().to_string_lossy()
        ),
        provider: "kimi".into(),
        state: state.into(),
        name,
        detail,
        waiting_for,
        since,
        queued: 0,
        focusable: process.started_at.is_some() && kimi_identity(process.pid),
    }
}

#[cfg(target_os = "macos")]
fn surface(pid: u32) -> String {
    // The common Activity model does not expose processID, but this text matches
    // the owning surface used by the source tooltip. Bundle IDs are kept internal.
    match crate::focus::owner_of(pid).map(|(_, bundle)| bundle) {
        Some(bundle) if bundle == "com.apple.Terminal" => "Terminal".into(),
        Some(bundle) if bundle == "com.googlecode.iterm2" => "iTerm".into(),
        _ => "Terminal".into(),
    }
}
#[cfg(not(target_os = "macos"))]
fn surface(_: u32) -> String {
    "Terminal".into()
}

#[cfg(target_os = "macos")]
fn alive(pid: u32, started_at: Option<u64>) -> bool {
    if pid == 0 {
        return false;
    }
    let result = unsafe { libc::kill(pid as i32, 0) };
    if result != 0 && std::io::Error::last_os_error().raw_os_error() != Some(libc::EPERM) {
        return false;
    }
    if let (Some(expected), Some(actual)) = (
        started_at,
        crate::claude_session_monitor::process_start_ms(pid),
    ) {
        return actual.abs_diff(expected) < 2_000;
    }
    true
}
#[cfg(target_os = "macos")]
fn kimi_identity(pid: u32) -> bool {
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
    if unsafe {
        libc::proc_pidinfo(
            pid as i32,
            libc::PROC_PIDTBSDINFO,
            0,
            std::ptr::from_mut(&mut info).cast(),
            size,
        )
    } != size
    {
        return false;
    }
    let comm = unsafe { std::ffi::CStr::from_ptr(info.pbi_comm.as_ptr()) }.to_string_lossy();
    if comm == "kimi-code" || comm == "kimi" {
        return true;
    }
    let mut path = vec![0i8; libc::MAXPATHLEN as usize];
    (unsafe { libc::proc_pidpath(pid as i32, path.as_mut_ptr().cast(), path.len() as u32) }) > 0
        && unsafe { std::ffi::CStr::from_ptr(path.as_ptr()) }
            .to_string_lossy()
            .ends_with("/.kimi-code/bin/kimi")
}
#[cfg(windows)]
fn alive(pid: u32, started_at: Option<u64>) -> bool {
    let (Some(expected), Some(actual)) = (
        started_at,
        crate::claude_session_monitor::process_start_ms(pid),
    ) else {
        return false;
    };
    expected == actual
}
#[cfg(all(not(target_os = "macos"), not(windows)))]
fn alive(_: u32, _: Option<u64>) -> bool {
    false
}
#[cfg(windows)]
fn kimi_identity(pid: u32) -> bool {
    windows_process(pid).is_some()
}
#[cfg(all(not(target_os = "macos"), not(windows)))]
fn kimi_identity(_: u32) -> bool {
    false
}

#[cfg(target_os = "macos")]
fn processes() -> Vec<Process> {
    let mut count = unsafe { libc::proc_listpids(PROC_ALL_PIDS, 0, std::ptr::null_mut(), 0) };
    if count <= 0 {
        return Vec::new();
    }
    let mut pids = vec![0i32; count as usize / std::mem::size_of::<i32>() + 16];
    count = unsafe {
        libc::proc_listpids(
            PROC_ALL_PIDS,
            0,
            pids.as_mut_ptr().cast(),
            (pids.len() * 4) as i32,
        )
    };
    if count <= 0 {
        return Vec::new();
    }
    pids.into_iter()
        .take((count as usize) / 4)
        .filter_map(|pid| {
            if pid <= 0 {
                return None;
            }
            let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
            let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
            if unsafe {
                libc::proc_pidinfo(
                    pid,
                    libc::PROC_PIDTBSDINFO,
                    0,
                    std::ptr::from_mut(&mut info).cast(),
                    size,
                )
            } != size
            {
                return None;
            }
            let comm =
                unsafe { std::ffi::CStr::from_ptr(info.pbi_comm.as_ptr()) }.to_string_lossy();
            if comm != "kimi-code" && comm != "kimi" {
                let mut path = vec![0i8; libc::MAXPATHLEN as usize];
                if unsafe { libc::proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) }
                    <= 0
                    || !unsafe { std::ffi::CStr::from_ptr(path.as_ptr()) }
                        .to_string_lossy()
                        .ends_with("/.kimi-code/bin/kimi")
                {
                    return None;
                }
            }
            let cwd = crate::focus::cwd_of(pid as u32)?;
            Some(Process {
                pid: pid as u32,
                started_at: crate::claude_session_monitor::process_start_ms(pid as u32),
                cwd,
            })
        })
        .collect()
}
#[cfg(windows)]
fn windows_process_info(pid: u32) -> Option<(PathBuf, String, u64)> {
    use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};
    let mut system = System::new();
    system.refresh_processes_specifics(
        ProcessesToUpdate::Some(&[Pid::from_u32(pid)]),
        true,
        ProcessRefreshKind::nothing()
            .with_exe(UpdateKind::Always)
            .with_cwd(UpdateKind::Always),
    );
    let process = system.process(Pid::from_u32(pid))?;
    let exe = process.exe()?.to_path_buf();
    let cwd = process.cwd()?.to_string_lossy().into_owned();
    let started_at = crate::claude_session_monitor::process_start_ms(pid)?;
    if cwd.is_empty() {
        return None;
    }
    Some((exe, cwd, started_at))
}
#[cfg(windows)]
fn windows_process(pid: u32) -> Option<Process> {
    let (exe, cwd, started_at) = windows_process_info(pid)?;
    let name = exe.file_stem()?.to_string_lossy();
    if !matches!(name.to_ascii_lowercase().as_str(), "kimi" | "kimi-code") {
        return None;
    }
    Some(Process {
        pid,
        started_at: Some(started_at),
        cwd,
    })
}
#[cfg(windows)]
fn processes() -> Vec<Process> {
    use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System};
    let mut system = System::new();
    system.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::nothing());
    let candidates = system
        .processes()
        .iter()
        .filter(|(_, process)| {
            matches!(
                process
                    .name()
                    .to_string_lossy()
                    .to_ascii_lowercase()
                    .as_str(),
                "kimi.exe" | "kimi-code.exe"
            )
        })
        .map(|(pid, _)| *pid)
        .collect::<Vec<_>>();
    if candidates.is_empty() {
        return Vec::new();
    }
    candidates
        .into_iter()
        .filter_map(|pid| windows_process(pid.as_u32()))
        .collect()
}
#[cfg(all(not(target_os = "macos"), not(windows)))]
fn processes() -> Vec<Process> {
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(windows)]
    #[test]
    fn windows_own_child_cwd_exe_and_precise_birth() {
        use std::process::{Child, Command, Stdio};
        use std::time::Duration;
        struct ChildGuard(Child);
        impl Drop for ChildGuard {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
        let temp = tempfile::tempdir().unwrap();
        let child = Command::new("cmd.exe")
            .args(["/Q", "/K"])
            .current_dir(temp.path())
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut guard = ChildGuard(child);
        let pid = guard.0.id();
        let mut found = None;
        for _ in 0..30 {
            found = windows_process_info(pid);
            if found.is_some() {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        let (exe, cwd, birth) = found.expect("own child process must expose exe, cwd and birth");
        assert_eq!(
            exe.file_stem()
                .unwrap()
                .to_string_lossy()
                .to_ascii_lowercase(),
            "cmd"
        );
        assert_eq!(resolve(&cwd), resolve(&temp.path().to_string_lossy()));
        assert!(alive(pid, Some(birth)));
        assert!(!alive(pid, Some(birth + 1)), "birth must match exactly");
        guard.0.kill().unwrap();
        guard.0.wait().unwrap();
        assert!(windows_process_info(pid).is_none());
    }
    #[test]
    fn wire_state_ignores_bookkeeping_subagents_and_resolved_approval() {
        let at = 1_789_140_953_652;
        let records=format!("{{\"type\":\"turn.prompt\",\"agentId\":\"main\",\"time\":{at}}}\n{{\"type\":\"context.append_loop_event\",\"event\":{{\"type\":\"approval.requested\",\"tool\":\"Bash\",\"time\":{at}}}}}\n{{\"type\":\"context.append_loop_event\",\"event\":{{\"type\":\"approval.resolved\",\"time\":{at}}}}}\n{{\"type\":\"usage.record\"}}\n{{\"type\":\"turn.ended\",\"agentId\":\"subagent\"}}");
        assert!(matches!(turn(records.as_bytes(),at),Some(Turn::Busy(Some(value))) if value==at));
        let waiting =
            format!("{{\"type\":\"approval.requested\",\"tool\":\"Bash\",\"time\":{at}}}");
        assert!(
            matches!(turn(waiting.as_bytes(),at),Some(Turn::Waiting(_,Some(tool))) if tool=="Bash")
        );
    }
    #[cfg(not(windows))]
    #[test]
    fn path_normalization_is_text_only() {
        assert_eq!(resolve("/private/var//tmp/"), "/var/tmp");
        assert_eq!(resolve("/Users//me/project/"), "/Users/me/project");
    }

    #[cfg(windows)]
    #[test]
    fn windows_path_normalization_keeps_drive_and_unc_identity() {
        assert_eq!(
            windows_text_path("C:\\Users\\ME\\project\\"),
            "c:/users/me/project"
        );
        assert_eq!(
            windows_text_path("\\\\server\\share\\Kimi\\"),
            "//server/share/kimi"
        );
    }
}
