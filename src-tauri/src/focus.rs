//! Jump back to the nearest owning terminal window of a live agent process.

#[cfg(any(windows, test))]
fn window_distance(chain: &[u32], parents: &std::collections::HashMap<u32, u32>, pid: u32) -> Option<usize> {
    if let Some(distance) = chain.iter().position(|&ancestor| ancestor == pid) {
        return Some(distance * 2);
    }
    let parent = parents.get(&pid)?;
    chain.iter().position(|&ancestor| ancestor == *parent)
        .map(|distance| distance * 2 + 1)
}

#[cfg(any(windows, test))]
fn is_non_terminal_shell(name: &str) -> bool {
    name.eq_ignore_ascii_case("explorer.exe") || name.eq_ignore_ascii_case("velo.exe")
}

#[cfg(windows)]
pub fn focus_terminal(agent_pid: u32) -> bool {
    use std::collections::HashMap;
    use windows::Win32::Foundation::{BOOL, HWND, LPARAM};
    use windows::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        EnumWindows, FlashWindowEx, GetForegroundWindow, GetWindowTextLengthW,
        GetWindowThreadProcessId, IsIconic, IsWindowVisible, SetForegroundWindow, ShowWindow,
        FLASHWINFO, FLASHW_ALL, SW_RESTORE,
    };

    if agent_pid == 0 {
        return false;
    }

    // 1) Full pid -> ppid snapshot
    let mut ppid_map: HashMap<u32, u32> = HashMap::new();
    let mut names: HashMap<u32, String> = HashMap::new();
    unsafe {
        let Ok(snap) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else {
            return false;
        };
        let mut entry = PROCESSENTRY32W {
            dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
            ..Default::default()
        };
        if Process32FirstW(snap, &mut entry).is_ok() {
            loop {
                ppid_map.insert(entry.th32ProcessID, entry.th32ParentProcessID);
                let len = entry.szExeFile.iter().position(|&ch| ch == 0)
                    .unwrap_or(entry.szExeFile.len());
                names.insert(entry.th32ProcessID,
                    String::from_utf16_lossy(&entry.szExeFile[..len]));
                if Process32NextW(snap, &mut entry).is_err() {
                    break;
                }
            }
        }
        let _ = windows::Win32::Foundation::CloseHandle(snap);
    }

    // 2) Agent's ancestry, nearest first. Explorer may own the terminal
    // process but must never win just because it is a higher ancestor.
    let mut chain: Vec<u32> = vec![agent_pid];
    let mut cur = agent_pid;
    for _ in 0..8 {
        match ppid_map.get(&cur) {
            Some(&p) if p != 0 && !chain.contains(&p) => {
                chain.push(p);
                cur = p;
            }
            _ => break,
        }
    }

    // 3) Enumerate visible top-level windows
    struct Cand {
        hwnd: isize,
        pid: u32,
    }
    let mut wins: Vec<Cand> = Vec::new();
    unsafe extern "system" fn cb(hwnd: HWND, l: LPARAM) -> BOOL {
        let v = &mut *(l.0 as *mut Vec<(isize, u32)>);
        if IsWindowVisible(hwnd).as_bool() && GetWindowTextLengthW(hwnd) > 0 {
            let mut pid = 0u32;
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
            v.push((hwnd.0 as isize, pid));
        }
        BOOL(1)
    }
    let mut raw: Vec<(isize, u32)> = Vec::new();
    unsafe {
        let _ = EnumWindows(Some(cb), LPARAM(&mut raw as *mut _ as isize));
    }
    for (h, p) in raw {
        wins.push(Cand { hwnd: h, pid: p });
    }

    // 4) Nearest matching owner (or its conhost child). Never choose Explorer
    // as the destination merely because it launched the terminal.
    let best = wins
        .iter()
        .filter(|w| !names.get(&w.pid).is_some_and(|name| is_non_terminal_shell(name)))
        .filter_map(|w| window_distance(&chain, &ppid_map, w.pid)
            .map(|distance| (distance, w.hwnd, w.pid)))
        .min_by_key(|(distance, _, _)| *distance);

    let Some((_, hwnd_raw, target_pid)) = best else {
        return false;
    };
    unsafe {
        let hwnd = HWND(hwnd_raw as *mut core::ffi::c_void);
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        let requested = SetForegroundWindow(hwnd).as_bool();
        let fi = FLASHWINFO {
            cbSize: std::mem::size_of::<FLASHWINFO>() as u32,
            hwnd,
            dwFlags: FLASHW_ALL,
            uCount: 2,
            dwTimeout: 0,
        };
        let mut foreground_pid = 0u32;
        let foreground = GetForegroundWindow();
        GetWindowThreadProcessId(foreground, Some(&mut foreground_pid));
        if foreground_pid == target_pid { return true; }
        if !requested { let _ = FlashWindowEx(&fi); }
    }
    false
}

#[cfg(not(any(windows, target_os = "macos")))]
pub fn focus_terminal(_claude_pid: u32) -> bool {
    false
}

// ---------------- Process and foreground helpers shared by seen-clears-it and the desktop jump-back ----------------

#[cfg(any(windows, target_os = "macos"))]
pub struct ProcMaps {
    pub ppid: std::collections::HashMap<u32, u32>,
    pub name: std::collections::HashMap<u32, String>, // lower-case exe name
}

#[cfg(windows)]
pub fn proc_maps() -> ProcMaps {
    use windows::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    };
    let mut m = ProcMaps {
        ppid: Default::default(),
        name: Default::default(),
    };
    unsafe {
        let Ok(snap) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else {
            return m;
        };
        let mut e = PROCESSENTRY32W {
            dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
            ..Default::default()
        };
        if Process32FirstW(snap, &mut e).is_ok() {
            loop {
                m.ppid.insert(e.th32ProcessID, e.th32ParentProcessID);
                let len = e.szExeFile.iter().position(|&c| c == 0).unwrap_or(260);
                m.name.insert(
                    e.th32ProcessID,
                    String::from_utf16_lossy(&e.szExeFile[..len]).to_lowercase(),
                );
                if Process32NextW(snap, &mut e).is_err() {
                    break;
                }
            }
        }
        let _ = windows::Win32::Foundation::CloseHandle(snap);
    }
    m
}

#[cfg(windows)]
pub fn fg_pid() -> u32 {
    use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};
    unsafe {
        let hwnd = GetForegroundWindow();
        if hwnd.0.is_null() {
            return 0;
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        pid
    }
}

#[cfg(any(windows, target_os = "macos"))]
pub fn chain_of(pid: u32, ppid: &std::collections::HashMap<u32, u32>) -> Vec<u32> {
    let mut chain = vec![pid];
    let mut cur = pid;
    for _ in 0..8 {
        match ppid.get(&cur) {
            Some(&p) if p != 0 && !chain.contains(&p) => {
                chain.push(p);
                cur = p;
            }
            _ => break,
        }
    }
    chain
}

/// Whether the foreground process belongs to a session's terminal window (itself on the chain, or its parent — the conhost case)
#[cfg(any(windows, target_os = "macos"))]
pub fn pid_hits_chain(pid: u32, chain: &[u32], maps: &ProcMaps) -> bool {
    chain.contains(&pid)
        || maps
            .ppid
            .get(&pid)
            .map(|p| chain.contains(p))
            .unwrap_or(false)
}

/// Focus the Claude desktop app's main window (the jump-back target for desktop sessions: the largest visible window whose process name contains claude)
#[cfg(windows)]
pub fn focus_claude_desktop() -> bool {
    use windows::Win32::Foundation::{BOOL, HWND, LPARAM, RECT};
    use windows::Win32::UI::WindowsAndMessaging::{
        EnumWindows, FlashWindowEx, GetForegroundWindow, GetWindowRect, GetWindowTextLengthW,
        GetWindowThreadProcessId, IsIconic, IsWindowVisible, SetForegroundWindow, ShowWindow,
        FLASHWINFO, FLASHW_ALL,
        SW_RESTORE,
    };
    let maps = proc_maps();
    unsafe extern "system" fn cb(hwnd: HWND, l: LPARAM) -> BOOL {
        let v = &mut *(l.0 as *mut Vec<(isize, u32)>);
        if IsWindowVisible(hwnd).as_bool() && GetWindowTextLengthW(hwnd) > 0 {
            let mut pid = 0u32;
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
            v.push((hwnd.0 as isize, pid));
        }
        BOOL(1)
    }
    let mut wins: Vec<(isize, u32)> = Vec::new();
    unsafe {
        let _ = EnumWindows(Some(cb), LPARAM(&mut wins as *mut _ as isize));
    }
    let mut best: Option<(isize, i64, u32)> = None;
    for (h, pid) in wins {
        let Some(name) = maps.name.get(&pid) else {
            continue;
        };
        if !name.contains("claude") || name.contains("vela") {
            continue;
        }
        let mut r = RECT::default();
        let area = unsafe {
            if GetWindowRect(HWND(h as *mut core::ffi::c_void), &mut r).is_ok() {
                ((r.right - r.left) as i64) * ((r.bottom - r.top) as i64)
            } else {
                0
            }
        };
        if best.map(|(_, a, _)| area > a).unwrap_or(true) {
            best = Some((h, area, pid));
        }
    }
    let Some((h, _, target_pid)) = best else {
        return false;
    };
    unsafe {
        let hwnd = HWND(h as *mut core::ffi::c_void);
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        let requested = SetForegroundWindow(hwnd).as_bool();
        let fi = FLASHWINFO {
            cbSize: std::mem::size_of::<FLASHWINFO>() as u32,
            hwnd,
            dwFlags: FLASHW_ALL,
            uCount: 2,
            dwTimeout: 0,
        };
        let mut foreground_pid = 0u32;
        GetWindowThreadProcessId(GetForegroundWindow(), Some(&mut foreground_pid));
        if foreground_pid == target_pid { return true; }
        if !requested { let _ = FlashWindowEx(&fi); }
    }
    false
}

#[cfg(not(any(windows, target_os = "macos")))]
pub fn focus_claude_desktop() -> bool {
    false
}

#[cfg(target_os = "macos")]
pub fn proc_maps() -> ProcMaps {
    let mut maps = ProcMaps {
        ppid: Default::default(),
        name: Default::default(),
    };
    // Only invoked when jumping back or while a completion needs acknowledgment.
    if let Ok(out) = std::process::Command::new("/bin/ps")
        .args(["-axo", "pid=,ppid=,comm="])
        .output()
    {
        for line in String::from_utf8_lossy(&out.stdout).lines().take(16384) {
            let mut parts = line.split_whitespace();
            if let (Some(pid), Some(parent)) = (
                parts.next().and_then(|s| s.parse().ok()),
                parts.next().and_then(|s| s.parse().ok()),
            ) {
                maps.ppid.insert(pid, parent);
                maps.name
                    .insert(pid, parts.collect::<Vec<_>>().join(" ").to_lowercase());
            }
        }
    }
    maps
}
#[cfg(target_os = "macos")]
pub fn fg_pid() -> u32 {
    use objc2_app_kit::NSWorkspace;
    unsafe {
        NSWorkspace::sharedWorkspace()
            .frontmostApplication()
            .map(|a| a.processIdentifier() as u32)
            .unwrap_or(0)
    }
}
#[cfg(target_os = "macos")]
pub(crate) fn activate(pid: u32) -> bool {
    use objc2_app_kit::{NSApplicationActivationOptions, NSRunningApplication};
    unsafe {
        NSRunningApplication::runningApplicationWithProcessIdentifier(pid as i32).is_some_and(
            |app| {
                app.activateWithOptions(NSApplicationActivationOptions::ActivateIgnoringOtherApps)
            },
        )
    }
}
#[cfg(target_os = "macos")]
fn bsd_info(pid: u32) -> Option<libc::proc_bsdinfo> {
    if pid <= 1 { return None; }
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
    let read = unsafe { libc::proc_pidinfo(pid as i32, libc::PROC_PIDTBSDINFO, 0,
        (&mut info as *mut libc::proc_bsdinfo).cast(), size) };
    (read == size).then_some(info)
}

#[cfg(target_os = "macos")]
pub(crate) fn ancestry(pid: u32) -> Vec<u32> {
    let mut chain = Vec::new();
    let mut current = pid;
    while chain.len() < 8 && current > 1 && !chain.contains(&current) {
        chain.push(current);
        let Some(parent) = bsd_info(current).map(|info| info.pbi_ppid) else { break };
        current = parent;
    }
    chain
}

#[cfg(target_os = "macos")]
pub(crate) fn owner_of(pid: u32) -> Option<(u32, String)> {
    use objc2_app_kit::NSRunningApplication;
    for candidate in ancestry(pid) {
        let app = unsafe { NSRunningApplication::runningApplicationWithProcessIdentifier(candidate as i32) };
        if let Some(bundle) = app.and_then(|app| app.bundleIdentifier()) {
            return Some((candidate, bundle.to_string()));
        }
    }
    None
}

#[cfg(target_os = "macos")]
pub(crate) fn tty_of(pid: u32) -> Option<String> {
    let dev = bsd_info(pid)?.e_tdev;
    if dev == u32::MAX { return None; }
    extern "C" { fn devname(dev: libc::dev_t, mode: libc::mode_t) -> *const libc::c_char; }
    let name = unsafe { devname(dev as libc::dev_t, libc::S_IFCHR as libc::mode_t) };
    if name.is_null() { None } else { unsafe { std::ffi::CStr::from_ptr(name).to_str().ok().map(str::to_owned) } }
}

#[cfg(target_os = "macos")]
pub(crate) fn cwd_of(pid: u32) -> Option<String> {
    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as i32;
    let read = unsafe { libc::proc_pidinfo(pid as i32, libc::PROC_PIDVNODEPATHINFO, 0,
        (&mut info as *mut libc::proc_vnodepathinfo).cast(), size) };
    if read != size { return None; }
    let path = info.pvi_cdir.vip_path.as_ptr().cast::<libc::c_char>();
    let bytes = unsafe { std::slice::from_raw_parts(path.cast::<u8>(), libc::MAXPATHLEN as usize) };
    let end = bytes.iter().position(|byte| *byte == 0)?;
    std::str::from_utf8(&bytes[..end]).ok().filter(|s| !s.is_empty()).map(str::to_owned)
}
#[cfg(target_os = "macos")]
pub(crate) fn claude_desktop_pid() -> Option<u32> {
    proc_maps()
        .name
        .iter()
        .find_map(|(pid, name)| name.ends_with("/claude.app/contents/macos/claude").then_some(*pid))
}

#[cfg(test)]
mod window_candidate_tests {
    use super::{is_non_terminal_shell, window_distance};
    use std::collections::HashMap;

    #[test]
    fn nearest_terminal_or_conhost_wins_over_explorer_ancestor() {
        let chain = [10, 20, 30, 40]; // agent, shell, terminal, explorer
        let parents = HashMap::from([(25,20), (30,40)]);
        let candidates = [(40,"explorer.exe"), (30,"WindowsTerminal.exe"),
            (25,"conhost.exe")];
        let best = candidates.into_iter()
            .filter(|(_,name)| !is_non_terminal_shell(name))
            .filter_map(|(pid,_)| window_distance(&chain, &parents, pid).map(|distance| (distance,pid)))
            .min();
        assert_eq!(best, Some((3,25)));
        assert_eq!(window_distance(&chain, &parents, 40), Some(6));
        assert_eq!(window_distance(&chain, &parents, 999), None);
    }
}
