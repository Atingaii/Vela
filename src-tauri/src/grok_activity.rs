//! Grok TUI registry and headless process activity, from GrokActivityMonitor.swift.
use crate::activity::Activity;
use serde_json::Value;
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::UNIX_EPOCH;

const STALE_MS: u64 = 45_000;
const TAIL_BYTES: u64 = 65_536;
// Exact sys/proc_info.h ABI: libc exposes proc_pidinfo and proc_fdinfo, but not this result.
#[cfg(target_os = "macos")]
const PROC_ALL_PIDS: u32 = 1;
#[cfg(target_os = "macos")]
const PROC_PIDFDVNODEPATHINFO: i32 = 2;
#[cfg(target_os = "macos")]
#[repr(C)]
struct ProcFileInfo {
    fi_openflags: u32,
    fi_status: u32,
    fi_offset: libc::off_t,
    fi_type: i32,
    fi_guardflags: u32,
}
#[cfg(target_os = "macos")]
#[repr(C)]
struct VnodeFdInfoWithPath {
    pfi: ProcFileInfo,
    pvip: libc::vnode_info_path,
}

#[derive(Clone)]
struct Process {
    pid: u32,
    started_at: u64,
    cwd: Option<String>,
    open_sessions: Vec<PathBuf>,
}
static FOCUS: OnceLock<Mutex<HashMap<String, (u32, u64)>>> = OnceLock::new();
fn focus_map() -> &'static Mutex<HashMap<String, (u32, u64)>> {
    FOCUS.get_or_init(|| Mutex::new(HashMap::new()))
}
pub fn focus_target(id: &str) -> Option<u32> {
    let (pid, start) = *focus_map().lock().ok()?.get(id)?;
    (grok_identity(pid) && process_start(pid) == Some(start)).then_some(pid)
}

pub fn read(now_ms: u64) -> Vec<Activity> {
    if crate::smoke::root().is_some() {
        if let Ok(mut held) = focus_map().lock() {
            held.clear();
        }
        return Vec::new();
    }
    let Some(home) = dirs::home_dir() else {
        if let Ok(mut held) = focus_map().lock() {
            held.clear();
        }
        return Vec::new();
    };
    let root = home.join(".grok/sessions");
    read_at(
        &home.join(".grok/active_sessions.json"),
        &root,
        now_ms,
        processes(&root),
    )
}

fn read_at(active: &Path, sessions: &Path, now_ms: u64, processes: Vec<Process>) -> Vec<Activity> {
    let mut out = Vec::new();
    let mut focus = HashMap::new();
    if let Some(bytes) = read_capped(active, 1024 * 1024) {
        if let Ok(rows) = serde_json::from_slice::<Vec<Value>>(&bytes) {
            for row in rows.iter().take(1024) {
                let Some(activity) = tui(row, sessions, now_ms) else {
                    continue;
                };
                if activity.focusable {
                    if let Some(pid) = row
                        .get("pid")
                        .and_then(Value::as_u64)
                        .and_then(|pid| u32::try_from(pid).ok())
                    {
                        if let Some(start) = process_start(pid) {
                            focus.insert(activity.id.clone(), (pid, start));
                        }
                    }
                }
                out.push(activity);
            }
        }
    }
    let runs = headless(&processes);
    for activity in &runs {
        if !activity.focusable {
            continue;
        }
        if let Some(process) = processes.iter().find(|process| {
            process.open_sessions.iter().any(|dir| {
                format!(
                    "grok.{}",
                    dir.file_name().unwrap_or_default().to_string_lossy()
                ) == activity.id
                    && kind(dir).as_deref() == Some("headless")
            })
        }) {
            focus.insert(activity.id.clone(), (process.pid, process.started_at));
        }
    }
    out.extend(runs);
    if let Ok(mut held) = focus_map().lock() {
        *held = focus;
    }
    out
}

fn read_capped(path: &Path, cap: u64) -> Option<Vec<u8>> {
    let mut file = File::open(path).ok()?;
    if file.metadata().ok()?.len() > cap {
        return None;
    }
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).ok()?;
    Some(bytes)
}
fn tail(path: &Path) -> Option<Vec<u8>> {
    let mut file = File::open(path).ok()?;
    let size = file.metadata().ok()?.len();
    file.seek(SeekFrom::Start(size.saturating_sub(TAIL_BYTES)))
        .ok()?;
    let mut bytes = Vec::new();
    file.take(TAIL_BYTES).read_to_end(&mut bytes).ok()?;
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
fn basename(path: &str) -> String {
    Path::new(path)
        .file_name()
        .map(|part| part.to_string_lossy().into_owned())
        .filter(|part| !part.is_empty())
        .unwrap_or_else(|| "Grok".into())
}

fn tui(row: &Value, root: &Path, now_ms: u64) -> Option<Activity> {
    let id = row.get("session_id")?.as_str()?.trim();
    if id.is_empty() || id.contains('/') || id == "." || id == ".." {
        return None;
    }
    if let Some(pid) = row.get("pid").and_then(Value::as_u64) {
        let opened = row.get("opened_at").and_then(date_ms);
        if !u32::try_from(pid).is_ok_and(|pid| alive(pid, opened)) {
            return None;
        }
    }
    let cwd = row.get("cwd").and_then(Value::as_str);
    let dir = session_directory(id, cwd, root)?;
    let at = modified_ms(&dir.join("updates.jsonl"))?;
    if now_ms.saturating_sub(at) > STALE_MS {
        return None;
    }
    let focusable = row
        .get("pid")
        .and_then(Value::as_u64)
        .and_then(|pid| u32::try_from(pid).ok())
        .is_some_and(|pid| grok_identity(pid) && process_start(pid).is_some());
    Some(Activity {
        id: format!("grok.{id}"),
        provider: "grok".into(),
        state: "busy".into(),
        name: cwd.map(basename).unwrap_or_else(|| "Grok".into()),
        detail: "Grok".into(),
        waiting_for: None,
        since: at,
        queued: 0,
        focusable,
    })
}

fn date_ms(value: &Value) -> Option<u64> {
    if let Some(number) = value.as_f64() {
        return Some(if number < 100_000_000_000.0 {
            (number * 1000.0) as u64
        } else {
            number as u64
        });
    }
    if let Some(text) = value.as_str() {
        if let Ok(date) = chrono::DateTime::parse_from_rfc3339(text) {
            return Some(date.timestamp_millis().max(0) as u64);
        }
        if let Ok(number) = text.parse::<f64>() {
            return date_ms(&Value::from(number));
        }
    }
    None
}

fn session_directory(id: &str, cwd: Option<&str>, root: &Path) -> Option<PathBuf> {
    if let Some(cwd) = cwd {
        let encoded = percent_encode(cwd);
        let dir = root.join(encoded).join(id);
        if dir.is_dir() {
            return Some(dir);
        }
    }
    fs::read_dir(root)
        .ok()?
        .flatten()
        .take(4096)
        .map(|entry| entry.path().join(id))
        .find(|path| path.is_dir())
}
fn percent_encode(text: &str) -> String {
    let mut result = String::new();
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
            result.push(byte as char);
        } else {
            result.push_str(&format!("%{byte:02X}"));
        }
    }
    result
}

fn headless(processes: &[Process]) -> Vec<Activity> {
    processes
        .iter()
        .filter_map(|process| {
            let dir = process
                .open_sessions
                .iter()
                .find(|dir| kind(dir) == Some("headless".into()))?;
            if !turn_open(&tail(&dir.join("updates.jsonl")).unwrap_or_default()) {
                return None;
            }
            Some(Activity {
                id: format!(
                    "grok.{}",
                    dir.file_name().unwrap_or_default().to_string_lossy()
                ),
                provider: "grok".into(),
                state: "busy".into(),
                name: process
                    .cwd
                    .as_deref()
                    .map(basename)
                    .unwrap_or_else(|| "Grok".into()),
                detail: "Grok".into(),
                waiting_for: None,
                since: process.started_at,
                queued: 0,
                focusable: process.started_at > 0
                    && grok_identity(process.pid)
                    && alive(process.pid, Some(process.started_at)),
            })
        })
        .collect()
}
fn kind(dir: &Path) -> Option<String> {
    let bytes = read_capped(&dir.join("summary.json"), 64 * 1024)?;
    serde_json::from_slice::<Value>(&bytes)
        .ok()?
        .get("session_kind")?
        .as_str()
        .map(str::to_owned)
}
fn turn_open(bytes: &[u8]) -> bool {
    let text = String::from_utf8_lossy(bytes);
    for line in text.lines().rev() {
        let Ok(row) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let Some(update) = row
            .pointer("/params/update/sessionUpdate")
            .and_then(Value::as_str)
        else {
            continue;
        };
        if update != "hook_execution" {
            return update != "turn_completed";
        }
    }
    true
}

#[cfg(any(target_os = "macos", windows))]
fn process_start(pid: u32) -> Option<u64> {
    crate::claude_session_monitor::process_start_ms(pid)
}
#[cfg(not(any(target_os = "macos", windows)))]
fn process_start(_: u32) -> Option<u64> {
    None
}

#[cfg(target_os = "macos")]
fn grok_identity(pid: u32) -> bool {
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
    if !comm.starts_with("grok") && comm != "agent" {
        return false;
    }
    let mut path = vec![0i8; libc::MAXPATHLEN as usize];
    if unsafe { libc::proc_pidpath(pid as i32, path.as_mut_ptr().cast(), path.len() as u32) } <= 0 {
        return false;
    }
    unsafe { std::ffi::CStr::from_ptr(path.as_ptr()) }
        .to_string_lossy()
        .contains("/.grok/downloads/grok-")
}
#[cfg(windows)]
fn grok_identity(pid: u32) -> bool {
    windows_process(pid).is_some()
}
#[cfg(all(not(target_os = "macos"), not(windows)))]
fn grok_identity(_: u32) -> bool {
    false
}

#[cfg(target_os = "macos")]
fn alive(pid: u32, opened: Option<u64>) -> bool {
    if pid == 0 {
        return false;
    }
    let result = unsafe { libc::kill(pid as i32, 0) };
    if result != 0 && std::io::Error::last_os_error().raw_os_error() != Some(libc::EPERM) {
        return false;
    }
    if let (Some(expected), Some(actual)) =
        (opened, crate::claude_session_monitor::process_start_ms(pid))
    {
        return actual.abs_diff(expected) < 2_000;
    }
    true
}
#[cfg(windows)]
fn alive(pid: u32, opened: Option<u64>) -> bool {
    let Some(actual) = crate::claude_session_monitor::process_start_ms(pid) else {
        return false;
    };
    opened.is_none_or(|expected| actual.abs_diff(expected) < 2_000)
}
#[cfg(all(not(target_os = "macos"), not(windows)))]
fn alive(_: u32, _: Option<u64>) -> bool {
    false
}

#[cfg(target_os = "macos")]
fn processes(root: &Path) -> Vec<Process> {
    let mut count = unsafe { libc::proc_listpids(PROC_ALL_PIDS, 0, std::ptr::null_mut(), 0) };
    if count <= 0 {
        return Vec::new();
    }
    let mut pids = vec![0i32; count as usize / 4 + 16];
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
        .take(count as usize / 4)
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
            if !comm.starts_with("grok") && comm != "agent" {
                return None;
            }
            let mut path = vec![0i8; libc::MAXPATHLEN as usize];
            if unsafe { libc::proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) } <= 0
            {
                return None;
            }
            if !unsafe { std::ffi::CStr::from_ptr(path.as_ptr()) }
                .to_string_lossy()
                .contains("/.grok/downloads/grok-")
            {
                return None;
            }
            Some(Process {
                pid: pid as u32,
                started_at: crate::claude_session_monitor::process_start_ms(pid as u32)
                    .unwrap_or(0),
                cwd: crate::focus::cwd_of(pid as u32),
                open_sessions: open_sessions(pid, root),
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
    let start = crate::claude_session_monitor::process_start_ms(pid)?;
    if cwd.is_empty() || !windows_grok_exe(&exe) {
        return None;
    }
    Some((exe, cwd, start))
}
#[cfg(windows)]
fn windows_grok_exe(exe: &Path) -> bool {
    let stem = exe
        .file_stem()
        .map(|part| part.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    if !stem.starts_with("grok") && stem != "agent" {
        return false;
    }
    exe.to_string_lossy()
        .replace('\\', "/")
        .to_ascii_lowercase()
        .contains("/.grok/downloads/grok-")
}
#[cfg(windows)]
fn windows_process(pid: u32) -> Option<Process> {
    let (_, cwd, started_at) = windows_process_info(pid)?;
    Some(Process {
        pid,
        started_at,
        cwd: Some(cwd),
        open_sessions: Vec::new(),
    })
}
#[cfg(windows)]
fn processes(root: &Path) -> Vec<Process> {
    use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System};
    let mut system = System::new();
    system.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::nothing());
    system
        .processes()
        .iter()
        .filter(|(_, process)| {
            let name = process.name().to_string_lossy().to_ascii_lowercase();
            name.starts_with("grok") || name == "agent.exe"
        })
        .filter_map(|(id, _)| {
            let mut process = windows_process(id.as_u32())?;
            process.open_sessions = windows_open_sessions(process.pid, root);
            Some(process)
        })
        .collect()
}
#[cfg(all(not(target_os = "macos"), not(windows)))]
fn processes(_: &Path) -> Vec<Process> {
    Vec::new()
}

#[cfg(target_os = "macos")]
fn open_sessions(pid: i32, root: &Path) -> Vec<PathBuf> {
    let size =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0) };
    if size <= 0 {
        return Vec::new();
    }
    let stride = std::mem::size_of::<libc::proc_fdinfo>();
    let mut fds =
        vec![unsafe { std::mem::zeroed::<libc::proc_fdinfo>() }; size as usize / stride + 8];
    let read = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDLISTFDS,
            0,
            fds.as_mut_ptr().cast(),
            (fds.len() * stride) as i32,
        )
    };
    if read <= 0 {
        return Vec::new();
    }
    let Ok(real_root) = fs::canonicalize(root) else {
        return Vec::new();
    };
    fds.into_iter()
        .take(read as usize / stride)
        .filter_map(|fd| {
            if fd.proc_fdtype != libc::PROX_FDTYPE_VNODE as u32 {
                return None;
            }
            let mut info: VnodeFdInfoWithPath = unsafe { std::mem::zeroed() };
            let size = std::mem::size_of::<VnodeFdInfoWithPath>() as i32;
            if unsafe {
                libc::proc_pidfdinfo(
                    pid,
                    fd.proc_fd,
                    PROC_PIDFDVNODEPATHINFO,
                    std::ptr::from_mut(&mut info).cast(),
                    size,
                )
            } != size
            {
                return None;
            }
            let path = unsafe { std::ffi::CStr::from_ptr(info.pvip.vip_path.as_ptr().cast()) }
                .to_string_lossy();
            let real_path = fs::canonicalize(path.as_ref()).ok()?;
            if real_path.file_name()? != "events.jsonl" || !real_path.starts_with(&real_root) {
                return None;
            }
            Some(real_path.parent()?.to_path_buf())
        })
        .collect()
}

#[cfg(windows)]
fn windows_open_sessions(pid: u32, root: &Path) -> Vec<PathBuf> {
    let Some(birth) = process_start(pid) else {
        return Vec::new();
    };
    windows_session_candidates(root)
        .into_iter()
        .filter_map(|(dir, events)| {
            windows_resource_users(&events)?
                .into_iter()
                .any(|(owner, started_at)| owner == pid && started_at == birth)
                .then_some(dir)
        })
        .collect()
}

#[cfg(windows)]
fn windows_session_candidates(root: &Path) -> Vec<(PathBuf, PathBuf)> {
    const MAX_GROUPS: usize = 1024;
    const MAX_DIRS: usize = 4096;
    const MAX_QUERIES: usize = 128;
    let Ok(real_root) = fs::canonicalize(root) else {
        return Vec::new();
    };
    let mut entries = Vec::new();
    let Ok(groups) = fs::read_dir(root) else {
        return Vec::new();
    };
    for group in groups.flatten().take(MAX_GROUPS) {
        let Ok(sessions) = fs::read_dir(group.path()) else {
            continue;
        };
        for session in sessions.flatten() {
            if entries.len() >= MAX_DIRS {
                break;
            }
            let Ok(dir) = fs::canonicalize(session.path()) else {
                continue;
            };
            if !dir.starts_with(&real_root) || kind(&dir).as_deref() != Some("headless") {
                continue;
            }
            if !turn_open(&tail(&dir.join("updates.jsonl")).unwrap_or_default()) {
                continue;
            }
            let events = dir.join("events.jsonl");
            let Ok(events) = fs::canonicalize(events) else {
                continue;
            };
            if events.parent() != Some(dir.as_path()) {
                continue;
            }
            entries.push((modified_ms(&events).unwrap_or(0), dir, events));
        }
        if entries.len() >= MAX_DIRS {
            break;
        }
    }
    entries.sort_by(|a, b| b.0.cmp(&a.0));
    entries.truncate(MAX_QUERIES);
    entries
        .into_iter()
        .map(|(_, dir, events)| (dir, events))
        .collect()
}

/// Restart Manager reports the processes actually using a file. This is read-only:
/// never call RmShutdown or RmRestart, and fail closed on any API error.
#[cfg(windows)]
fn windows_resource_users(path: &Path) -> Option<Vec<(u32, u64)>> {
    use std::os::windows::ffi::OsStrExt;
    use windows::core::{PCWSTR, PWSTR};
    use windows::Win32::Foundation::{ERROR_MORE_DATA, ERROR_SUCCESS};
    use windows::Win32::System::RestartManager::{
        RmEndSession, RmGetList, RmRegisterResources, RmStartSession, CCH_RM_SESSION_KEY,
        RM_PROCESS_INFO,
    };

    struct Session(u32);
    impl Drop for Session {
        fn drop(&mut self) {
            unsafe { RmEndSession(self.0) };
        }
    }
    let path = fs::canonicalize(path).ok()?;
    let wide = path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let mut handle = 0u32;
    let mut key = vec![0u16; CCH_RM_SESSION_KEY as usize + 1];
    if unsafe { RmStartSession(&mut handle, 0, PWSTR(key.as_mut_ptr())) } != ERROR_SUCCESS {
        return None;
    }
    let session = Session(handle);
    if unsafe { RmRegisterResources(session.0, Some(&[PCWSTR(wide.as_ptr())]), None, None) }
        != ERROR_SUCCESS
    {
        return None;
    }
    let mut needed = 0u32;
    let mut count = 0u32;
    let mut reasons = 0u32;
    let result = unsafe { RmGetList(session.0, &mut needed, &mut count, None, &mut reasons) };
    if result == ERROR_SUCCESS {
        return Some(Vec::new());
    }
    if result != ERROR_MORE_DATA || needed > 1024 {
        return None;
    }
    let mut rows = vec![RM_PROCESS_INFO::default(); needed as usize];
    count = rows.len() as u32;
    if unsafe {
        RmGetList(
            session.0,
            &mut needed,
            &mut count,
            Some(rows.as_mut_ptr()),
            &mut reasons,
        )
    } != ERROR_SUCCESS
    {
        return None;
    }
    Some(
        rows.into_iter()
            .take(count as usize)
            .map(|row| {
                let time = row.Process.ProcessStartTime;
                let ticks = ((time.dwHighDateTime as u64) << 32) | time.dwLowDateTime as u64;
                (
                    row.Process.dwProcessId,
                    ticks.saturating_sub(116_444_736_000_000_000) / 10_000,
                )
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(windows)]
    #[test]
    #[ignore = "run only as the child of windows_restart_manager_tracks_a_shared_open_file"]
    fn windows_file_holder_child() {
        let Some(events) = std::env::var_os("VELO_TEST_HELD_EVENTS") else {
            return;
        };
        let ready = std::env::var_os("VELO_TEST_HELD_READY").unwrap();
        let _held = File::open(events).unwrap();
        fs::write(ready, b"ready").unwrap();
        let mut byte = [0u8; 1];
        let _ = std::io::stdin().read(&mut byte);
    }
    #[cfg(windows)]
    #[test]
    fn windows_restart_manager_tracks_a_shared_open_file() {
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
        let events = temp.path().join("events.jsonl");
        let ready = temp.path().join("ready");
        fs::write(&events, b"").unwrap();
        let child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "grok_activity::tests::windows_file_holder_child",
                "--ignored",
                "--nocapture",
            ])
            .env("VELO_TEST_HELD_EVENTS", &events)
            .env("VELO_TEST_HELD_READY", &ready)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut guard = ChildGuard(child);
        let pid = guard.0.id();
        for _ in 0..50 {
            if ready.exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        assert!(ready.exists(), "own child did not open fixture file");
        let birth = crate::claude_session_monitor::process_start_ms(pid).unwrap();
        let mut owners = Vec::new();
        for _ in 0..20 {
            owners = windows_resource_users(&events).expect("read-only Restart Manager query");
            if owners.contains(&(pid, birth)) {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        assert!(
            owners.contains(&(pid, birth)),
            "shared open must be attributed to child PID and exact birth: {owners:?}"
        );
        drop(guard.0.stdin.take());
        guard.0.wait().unwrap();
        let owners = windows_resource_users(&events).unwrap();
        assert!(!owners.iter().any(|(owner, _)| *owner == pid));
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn kernel_vnode_path_abi_and_live_held_file() {
        assert_eq!(std::mem::size_of::<ProcFileInfo>(), 24);
        assert_eq!(std::mem::size_of::<VnodeFdInfoWithPath>(), 1200);
        assert_eq!(std::mem::offset_of!(VnodeFdInfoWithPath, pvip), 24);
        assert_eq!(
            std::mem::offset_of!(libc::vnode_info_path, vip_path) + 24,
            176
        );
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("sessions");
        let session = root.join("folder/run");
        fs::create_dir_all(&session).unwrap();
        let events = session.join("events.jsonl");
        fs::write(&events, "").unwrap();
        let held = File::open(&events).unwrap();
        let pid = unsafe { libc::getpid() };
        let resolved_session = fs::canonicalize(&session).unwrap();
        let opened = open_sessions(pid, &root);
        assert!(
            opened.contains(&resolved_session),
            "held paths: {opened:?}; expected: {resolved_session:?}"
        );
        drop(held);
        assert!(!open_sessions(pid, &root).contains(&resolved_session));
    }
    #[test]
    fn stop_hook_after_completion_does_not_reopen_headless_turn() {
        let complete = br#"{"params":{"update":{"sessionUpdate":"turn_completed"}}}
{"params":{"update":{"sessionUpdate":"hook_execution"}}}"#;
        assert!(!turn_open(complete));
        assert!(turn_open(
            br#"{"params":{"update":{"sessionUpdate":"hook_execution"}}}"#
        ));
        assert!(turn_open(br#"sessionUpdate":"turn_completed"}}}"#));
    }
    #[test]
    fn headless_requires_own_kind_and_live_turn() {
        let temp = tempfile::tempdir().unwrap();
        let dir = temp.path().join("folder/run-1");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("summary.json"), r#"{"session_kind":"headless"}"#).unwrap();
        fs::write(
            dir.join("updates.jsonl"),
            r#"{"params":{"update":{"sessionUpdate":"user_message_chunk"}}}"#,
        )
        .unwrap();
        let process = Process {
            pid: 4242,
            started_at: 100,
            cwd: Some("/code/app".into()),
            open_sessions: vec![dir.clone()],
        };
        assert_eq!(headless(&[process.clone()])[0].id, "grok.run-1");
        fs::write(
            dir.join("updates.jsonl"),
            r#"{"params":{"update":{"sessionUpdate":"turn_completed"}}}"#,
        )
        .unwrap();
        assert!(headless(&[process]).is_empty());
    }
    #[test]
    fn tui_uses_percent_encoded_directory_and_recency() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("sessions");
        let dir = root.join(percent_encode("/Users/me/app")).join("s1");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("updates.jsonl"), "{}").unwrap();
        let row = serde_json::json!({"session_id":"s1","cwd":"/Users/me/app"});
        let now = modified_ms(&dir.join("updates.jsonl")).unwrap();
        assert_eq!(tui(&row, &root, now).unwrap().name, "app");
        assert!(tui(&row, &root, now + STALE_MS + 1).is_none());
    }
}
