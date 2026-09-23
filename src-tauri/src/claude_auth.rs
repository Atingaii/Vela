//! User-initiated sign-in through the standalone Claude Code CLI. OAuth stays in
//! the CLI: no codes, tokens, browser URLs or credential writes cross widget IPC.
use serde::Serialize;
use std::{
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    },
    time::{Duration, Instant},
};

static BUSY: AtomicBool = AtomicBool::new(false);
static MESSAGE: Mutex<String> = Mutex::new(String::new());

/// The lock guards one short line of status text. A panic while it is held would
/// poison it and take the whole card down with `unwrap`, which is a steep price
/// for a string nobody has to trust — so take it back and carry on.
fn message() -> std::sync::MutexGuard<'static, String> {
    MESSAGE.lock().unwrap_or_else(|e| e.into_inner())
}

#[derive(Serialize)]
pub struct AuthState {
    pub busy: bool,
    pub message: String,
}

pub fn state() -> AuthState {
    AuthState {
        busy: BUSY.load(Ordering::Acquire),
        message: message().clone(),
    }
}

/// Shared with background renewal so the two native clients cannot rotate the
/// same credential at once. Drop also releases the gate on spawn/error paths.
pub struct AuthGuard;
pub fn try_acquire() -> Option<AuthGuard> {
    BUSY.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .ok()
        .map(|_| AuthGuard)
}
impl Drop for AuthGuard {
    fn drop(&mut self) {
        BUSY.store(false, Ordering::Release);
    }
}

pub fn usage_succeeded() {
    if !BUSY.load(Ordering::Acquire) {
        message().clear();
    }
}

// No interpolated shell input: even paths containing apostrophes arrive in env.
const LOGIN_SCRIPT: &str = "$Host.UI.RawUI.WindowTitle = 'Velo - Claude sign-in'; Write-Host 'Complete sign-in in your browser. Paste any code in this window.'; & $env:VELA_CLAUDE_CLI auth login --claudeai; $loginResult = $LASTEXITCODE; if ($loginResult -eq 0) { Write-Host 'Sign-in complete. Velo will refresh automatically.'; Start-Sleep -Seconds 2 } else { Write-Host 'Sign-in failed or cancelled. Retry from Velo.'; Start-Sleep -Seconds 8 }; exit $loginResult";

#[cfg(windows)]
fn login_command(
    cli: &std::path::Path,
    profile_dir: Option<&std::path::Path>,
) -> Result<Command, String> {
    let root = std::env::var_os("SystemRoot").ok_or("Windows directory unavailable.")?;
    let mut cmd = Command::new(
        std::path::PathBuf::from(root).join("System32/WindowsPowerShell/v1.0/powershell.exe"),
    );
    cmd.args(["-NoLogo", "-NoProfile", "-Command", LOGIN_SCRIPT])
        .env("VELA_CLAUDE_CLI", cli);
    cmd.current_dir(dirs::home_dir().ok_or("Home directory unavailable.")?);
    // A widget launched inside a Claude session must not inherit that session's
    // auth or take the headless refresh-token login branch instead of the browser.
    for (key, _) in std::env::vars_os() {
        let k = key.to_string_lossy();
        if k == "CLAUDECODE"
            || k.starts_with("CLAUDE_CODE_")
            || matches!(
                k.as_ref(),
                "CLAUDE_CONFIG_DIR" | "ANTHROPIC_API_KEY" | "ANTHROPIC_AUTH_TOKEN"
            )
        {
            cmd.env_remove(&key);
        }
    }
    if let Some(dir) = profile_dir {
        cmd.env("CLAUDE_CONFIG_DIR", dir);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0000_0010); // visible console only after a user's click
    }
    Ok(cmd)
}

#[cfg(target_os = "macos")]
fn login_command(
    cli: &std::path::Path,
    profile_dir: Option<&std::path::Path>,
) -> Result<Command, String> {
    let path = cli.to_str().ok_or("CLI path must be UTF-8")?;
    let config_arg = profile_dir
        .map(|dir| {
            dir.to_str()
                .map(|value| format!("CLAUDE_CONFIG_DIR={}", crate::platform::shell_quote(value)))
                .ok_or("Profile directory must be UTF-8")
        })
        .transpose()?
        .unwrap_or_else(|| "-u CLAUDE_CONFIG_DIR".into());
    let shell = format!("env -u CLAUDECODE -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN {config_arg} {} auth login --claudeai", crate::platform::shell_quote(path));
    // Script source is constant. Shell text travels as an AppleScript argv value.
    let mut cmd = Command::new("/usr/bin/osascript");
    cmd.args([
        "-e",
        r#"on run argv
 tell application "Terminal"
  activate
  set loginTab to do script (item 1 of argv)
  repeat while busy of loginTab
   delay 1
  end repeat
 end tell
end run"#,
        &shell,
    ]);
    cmd.stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    Ok(cmd)
}
#[cfg(not(any(windows, target_os = "macos")))]
fn login_command(
    _cli: &std::path::Path,
    _profile_dir: Option<&std::path::Path>,
) -> Result<Command, String> {
    Err("Interactive login is supported on macOS and Windows".into())
}

fn terminate(child: &mut Child) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        if let Some(root) = std::env::var_os("SystemRoot") {
            // A .cmd CLI may have node children: terminate only this owned tree.
            let _ = Command::new(std::path::PathBuf::from(root).join("System32/taskkill.exe"))
                .args(["/PID", &child.id().to_string(), "/T", "/F"])
                .creation_flags(0x0800_0000)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }
    }
    let _ = child.kill();
    let _ = child.wait();
}

fn wait_child(child: &mut Child, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(250)),
            _ => {
                terminate(child);
                return false;
            }
        }
    }
}

pub fn start_login_for(id: Option<&str>) -> Result<(), String> {
    let id = id.unwrap_or("claude").to_string();
    let profile_dir =
        crate::usage::profile_directory_for_id(&id).ok_or("Invalid Claude profile")?;
    let cli = crate::usage::find_cli()
        .ok_or("Claude Code CLI not found. Install the standalone CLI first.")?;
    let guard = try_acquire().ok_or("Claude sign-in or renewal is already running.")?;
    let mut cmd = login_command(&cli, profile_dir.as_deref())?;
    let mut child = cmd
        .spawn()
        .map_err(|_| "Unable to open Claude sign-in window.")?;
    *message() = "Complete sign-in in the browser or terminal window.".into();
    std::thread::spawn(move || {
        let ok = wait_child(&mut child, Duration::from_secs(15 * 60));
        *message() = if ok {
            "Login window finished. Refreshing usage to verify sign-in..."
        } else {
            "Sign-in cancelled, failed or timed out. Try again."
        }
        .into();
        drop(guard);
        crate::usage::request_profile_refresh(&id);
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn gate_excludes_login_and_renewal_and_releases_on_drop() {
        let guard = try_acquire().unwrap();
        assert!(try_acquire().is_none());
        assert!(state().busy);
        drop(guard);
        assert!(!state().busy);
        assert!(try_acquire().is_some());
    }
    #[test]
    #[cfg(windows)]
    fn paths_are_data_not_shell_source() {
        let path = std::path::Path::new(r"C:\fixture with spaces\O'Brien\claude.cmd");
        let cmd = login_command(path, None).unwrap();
        assert!(cmd
            .get_args()
            .all(|arg| !arg.to_string_lossy().contains("O'Brien")));
        assert!(cmd
            .get_envs()
            .any(|(k, v)| k == "VELA_CLAUDE_CLI" && v == Some(path.as_os_str())));
    }
    #[test]
    #[cfg(target_os = "macos")]
    fn named_profile_is_quoted_and_default_clears_inherited_dir() {
        let cli = std::path::Path::new("/tmp/O'Brien/claude");
        let profile = std::path::Path::new("/tmp/work $(touch injected)");
        let named = login_command(cli, Some(profile)).unwrap();
        let named_command = named.get_args().last().unwrap().to_string_lossy();
        assert!(named_command.contains("CLAUDE_CONFIG_DIR='/tmp/work $(touch injected)'"));
        assert!(named_command.contains("'/tmp/O'\\''Brien/claude'"));
        let default = login_command(cli, None).unwrap();
        let default_command = default.get_args().last().unwrap().to_string_lossy();
        assert!(default_command.contains("-u CLAUDE_CONFIG_DIR"));
    }
    #[test]
    #[cfg(windows)]
    fn child_process_fixture() {
        // This test is also an owned process fixture. A fresh test binary is much more
        // predictable on CI than PowerShell startup, while still exercising real exit codes.
        match std::env::var("VELA_CLAUDE_AUTH_CHILD").as_deref() {
            Ok("failure") => std::process::exit(7),
            Ok("sleep") => std::thread::sleep(Duration::from_secs(30)),
            _ => {}
        }
    }
    #[test]
    #[cfg(windows)]
    fn failed_exit_and_timeout_are_reaped() {
        use std::os::windows::process::CommandExt;
        let binary = std::env::current_exe().unwrap();
        let fixture = |outcome: &str| {
            Command::new(&binary)
                .args(["--exact", "claude_auth::tests::child_process_fixture"])
                .env("VELA_CLAUDE_AUTH_CHILD", outcome)
                .creation_flags(0x0800_0000)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap()
        };
        let mut child = fixture("failure");
        assert!(!wait_child(&mut child, Duration::from_secs(10)));
        assert_eq!(child.try_wait().unwrap().unwrap().code(), Some(7));
        let mut child = fixture("success");
        assert!(wait_child(&mut child, Duration::from_secs(10)));
        assert!(child.try_wait().unwrap().unwrap().success());
        let mut child = fixture("sleep");
        let start = Instant::now();
        assert!(!wait_child(&mut child, Duration::from_millis(300)));
        assert!(start.elapsed() < Duration::from_secs(10));
        assert!(child.try_wait().unwrap().is_some());
    }
}
