//! Terminal-specific tab selection from Swift TerminalTabFocus at 117a38b8.
//! All subprocess and sysctl work runs on a blocking worker, never the AppKit or IPC thread.

#[cfg(target_os = "macos")]
use std::{io::Read, process::{Command, Stdio}, time::{Duration, Instant}};

#[cfg(target_os = "macos")]
fn script_literal(value: &str) -> Option<String> {
    if value.len() > 4096 || value.chars().any(char::is_control) { return None; }
    Some(value.replace('\\', "\\\\").replace('"', "\\\""))
}

#[cfg(target_os = "macos")]
fn path_candidates(cwd: &str) -> Vec<String> {
    let mut paths = vec![cwd.to_string()];
    let resolved = std::fs::canonicalize(cwd).ok().map(|p| p.to_string_lossy().to_string());
    if let Some(path) = &resolved { if path != cwd { paths.push(path.clone()); } }
    for path in [Some(cwd.to_string()), resolved].into_iter().flatten() {
        if let Some(stripped) = path.strip_prefix("/private/") {
            paths.push(format!("/{stripped}"));
        } else if path.starts_with('/') {
            paths.push(format!("/private{path}"));
        }
    }
    let mut seen = std::collections::HashSet::new();
    paths.into_iter().filter(|p| seen.insert(p.clone())).collect()
}

#[cfg(target_os = "macos")]
fn path_condition(cwd: &str) -> Option<String> {
    let parts: Vec<String> = path_candidates(cwd).into_iter()
        .filter_map(|p| script_literal(&p).map(|p| format!("working directory of term is \"{p}\"")))
        .collect();
    if parts.is_empty() { None } else { Some(parts.join(" or ")) }
}

#[cfg(target_os = "macos")]
fn environment_surface(pid: u32) -> Option<String> {
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid as i32];
    let mut size: libc::size_t = 0;
    if unsafe { libc::sysctl(mib.as_mut_ptr(), 3, std::ptr::null_mut(), &mut size, std::ptr::null_mut(), 0) } != 0
        || size <= 4 || size > 1_048_576 { return None; }
    let mut bytes = vec![0u8; size];
    if unsafe { libc::sysctl(mib.as_mut_ptr(), 3, bytes.as_mut_ptr().cast(), &mut size, std::ptr::null_mut(), 0) } != 0 {
        return None;
    }
    bytes.get(4..size)?.split(|byte| *byte == 0)
        .filter_map(|part| part.strip_prefix(b"CMUX_SURFACE_ID="))
        .find_map(|part| std::str::from_utf8(part).ok().filter(|s| !s.is_empty()).map(str::to_owned))
}

#[cfg(target_os = "macos")]
fn cmux_surface(pid: u32) -> Option<String> {
    for candidate in crate::focus::ancestry(pid) {
        if let Some(surface) = environment_surface(candidate) { return Some(surface); }
    }
    None
}

#[cfg(target_os = "macos")]
fn drain<R: Read>(mut reader: R) -> Vec<u8> {
    let mut kept = Vec::new();
    let mut buffer = [0u8; 1024];
    while let Ok(n) = reader.read(&mut buffer) {
        if n == 0 { break; }
        let room = 8192usize.saturating_sub(kept.len());
        kept.extend_from_slice(&buffer[..n.min(room)]);
    }
    kept
}

#[cfg(target_os = "macos")]
fn run_osascript(script: &str) -> bool {
    let Ok(mut child) = Command::new("/usr/bin/osascript").args(["-e", script])
        .stdout(Stdio::piped()).stderr(Stdio::piped()).spawn() else { return false; };
    let (tx, rx) = std::sync::mpsc::channel();
    if let Some(stdout) = child.stdout.take() {
        let tx = tx.clone();
        std::thread::spawn(move || { let _ = tx.send((true, drain(stdout))); });
    }
    if let Some(stderr) = child.stderr.take() {
        let tx = tx.clone();
        std::thread::spawn(move || { let _ = tx.send((false, drain(stderr))); });
    }
    drop(tx);
    let deadline = Instant::now() + Duration::from_secs(3);
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            _ => { let _ = child.kill(); let _ = child.wait(); break None; }
        }
    };
    let mut output = None;
    for _ in 0..2 {
        if let Ok((is_stdout, bytes)) = rx.recv_timeout(Duration::from_secs(1)) {
            if is_stdout { output = Some(bytes); }
        }
    }
    status.is_some_and(|s| s.success()) && output.is_some_and(|bytes| {
        String::from_utf8_lossy(&bytes).trim() == "found"
    })
}

#[cfg(target_os = "macos")]
fn cmux_script(condition: &str) -> String {
    format!("tell application \"cmux\"\nrepeat with w in windows\nrepeat with t in tabs of w\nrepeat with term in terminals of t\nif {condition} then\nselect tab t\nfocus term\nactivate window w\nreturn \"found\"\nend if\nend repeat\nend repeat\nend repeat\nend tell")
}

/// Best effort: failures still let the caller raise the owning app.
#[cfg(target_os = "macos")]
pub fn select_tab(bundle_id: &str, pid: u32, tty: Option<&str>, cwd: Option<&str>) -> bool {
    let script = match bundle_id {
        "com.cmuxterm.app" => {
            let condition = cmux_surface(pid).and_then(|id| script_literal(&id)
                .map(|id| format!("id of term is \"{id}\"")))
                .or_else(|| cwd.and_then(path_condition));
            condition.map(|condition| cmux_script(&condition))
        }
        "com.apple.Terminal" => tty.and_then(script_literal).map(|tty| format!(
            "tell application \"Terminal\"\nrepeat with w in windows\nrepeat with t in tabs of w\nif tty of t is \"/dev/{tty}\" then\nset selected of t to true\nset index of w to 1\nreturn \"found\"\nend if\nend repeat\nend repeat\nend tell"
        )),
        "com.googlecode.iterm2" => tty.and_then(script_literal).map(|tty| format!(
            "tell application \"iTerm2\"\nrepeat with w in windows\nrepeat with t in tabs of w\nrepeat with s in sessions of t\nif tty of s is \"/dev/{tty}\" then\nselect s\nselect t\nselect w\nreturn \"found\"\nend if\nend repeat\nend repeat\nend repeat\nend tell"
        )),
        "com.mitchellh.ghostty" => cwd.and_then(path_condition).map(|condition| format!(
            "tell application \"Ghostty\"\nrepeat with w in windows\nrepeat with t in tabs of w\nrepeat with term in terminals of t\nif {condition} then\nfocus term\nreturn \"found\"\nend if\nend repeat\nend repeat\nend repeat\nend tell"
        )),
        _ => None,
    };
    script.as_deref().is_some_and(run_osascript)
}

#[cfg(test)]
#[cfg(target_os = "macos")]
mod tests {
    use super::*;
    #[test]
    fn path_candidates_match_private_alias_without_duplicates() {
        assert_eq!(path_candidates("/private/tmp/velo-no-such-folder"),
            vec!["/private/tmp/velo-no-such-folder", "/tmp/velo-no-such-folder"]);
    }
    #[test]
    fn applescript_values_cannot_break_the_predicate() {
        assert_eq!(script_literal("a\\b\"c"), Some("a\\\\b\\\"c".into()));
        assert_eq!(script_literal("a\nreturn \"found\""), None);
    }
}
