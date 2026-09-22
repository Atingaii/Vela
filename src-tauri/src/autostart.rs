//! Start at sign-in: an HKCU\...\Run registry value (per user, no administrator needed).
//! The command carries --silent: wait in the background, show no bar without sessions, appear when one starts.
//! Implemented with reg.exe, so no new dependency.

use std::process::Command;

const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
const NAME: &str = "Vela";

fn reg(args: &[&str]) -> Option<(bool, String)> {
    let mut c = Command::new("reg");
    c.args(args);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    c.output().ok().map(|o| {
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&o.stdout),
            String::from_utf8_lossy(&o.stderr)
        );
        (o.status.success(), text)
    })
}

#[cfg(windows)]
pub fn is_enabled() -> bool {
    reg(&["query", RUN_KEY, "/v", NAME])
        .map(|(ok, out)| ok && out.contains(NAME))
        .unwrap_or(false)
}

#[cfg(windows)]
pub fn enable() -> Result<String, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let val = format!("\"{}\" --silent", exe.display());
    match reg(&["add", RUN_KEY, "/v", NAME, "/t", "REG_SZ", "/d", &val, "/f"]) {
        Some((true, _)) => Ok("start at sign-in enabled (silent until a session appears)".into()),
        Some((false, out)) => Err(out),
        None => Err("reg.exe failed to run".into()),
    }
}

#[cfg(windows)]
pub fn disable() -> Result<String, String> {
    match reg(&["delete", RUN_KEY, "/v", NAME, "/f"]) {
        Some((true, _)) => Ok("start at sign-in disabled".into()),
        Some((false, out)) => {
            if out.to_lowercase().contains("unable to find") || out.contains("找不到") {
                // reg.exe answers in the OS language; "找不到" is the Chinese "unable to find"
                Ok("start at sign-in was not enabled".into())
            } else {
                Err(out)
            }
        }
        None => Err("reg.exe failed to run".into()),
    }
}

#[cfg(target_os = "macos")]
fn agent_path() -> Result<std::path::PathBuf, String> {
    Ok(dirs::home_dir()
        .ok_or("Home directory unavailable")?
        .join("Library/LaunchAgents/com.atingaii.vela.plist"))
}
#[cfg(target_os = "macos")]
pub fn is_enabled() -> bool {
    agent_path().is_ok_and(|p| p.is_file())
}
#[cfg(target_os = "macos")]
pub fn enable() -> Result<String, String> {
    let path = agent_path()?;
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let exe = exe
        .to_string_lossy()
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>com.atingaii.vela</string>
<key>ProgramArguments</key><array><string>{exe}</string><string>--silent</string></array>
<key>RunAtLoad</key><true/></dict></plist>"#
    );
    std::fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
    std::fs::write(path, plist).map_err(|e| e.to_string())?;
    Ok("Start at login enabled".into())
}
#[cfg(target_os = "macos")]
pub fn disable() -> Result<String, String> {
    let path = agent_path()?;
    if path.exists() {
        std::fs::remove_file(path).map_err(|e| e.to_string())?;
    }
    Ok("Start at login disabled".into())
}
#[cfg(not(any(windows, target_os = "macos")))]
pub fn is_enabled() -> bool {
    false
}
#[cfg(not(any(windows, target_os = "macos")))]
pub fn enable() -> Result<String, String> {
    Err("Login startup is supported on macOS and Windows".into())
}
#[cfg(not(any(windows, target_os = "macos")))]
pub fn disable() -> Result<String, String> {
    Ok("Disabled".into())
}
