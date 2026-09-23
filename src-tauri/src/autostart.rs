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

// Swift Preferences uses SMAppService.mainApp. Checking for a LaunchAgent plist reports enabled
// even when macOS has refused or disabled the login item in System Settings.
#[cfg(target_os = "macos")]
#[link(name = "ServiceManagement", kind = "framework")]
extern "C" {}

#[cfg(target_os = "macos")]
fn has_sm_app_service() -> bool {
    objc2_foundation::NSProcessInfo::processInfo().operatingSystemVersion().majorVersion >= 13
}

#[cfg(target_os = "macos")]
fn service_status() -> Option<isize> {
    use objc2::{msg_send, runtime::{AnyClass, AnyObject}};
    if !has_sm_app_service() { return None; }
    objc2::rc::autoreleasepool(|_| {
        let class = AnyClass::get(c"SMAppService")?;
        let service: *mut AnyObject = unsafe { msg_send![class, mainAppService] };
        if service.is_null() { return None; }
        Some(unsafe { msg_send![service, status] })
    })
}

#[cfg(target_os = "macos")]
fn set_service(on: bool) -> Result<String, String> {
    use objc2::{msg_send, runtime::{AnyClass, AnyObject}};
    use objc2_foundation::NSError;
    if service_status().is_none() { return Err("ServiceManagement is unavailable".into()); }
    objc2::rc::autoreleasepool(|_| {
        let class = AnyClass::get(c"SMAppService")
            .ok_or_else(|| "ServiceManagement is unavailable".to_string())?;
        let service: *mut AnyObject = unsafe { msg_send![class, mainAppService] };
        if service.is_null() { return Err("Login item service is unavailable".into()); }
        let mut error: *mut NSError = std::ptr::null_mut();
        let ok: bool = if on {
            unsafe { msg_send![service, registerAndReturnError: &mut error] }
        } else {
            unsafe { msg_send![service, unregisterAndReturnError: &mut error] }
        };
        if !ok {
            let detail = if error.is_null() { String::new() } else {
                unsafe { (*error).localizedDescription().to_string() }
            };
            return Err(if detail.is_empty() {
                "macOS refused this — try moving Velo to /Applications.".into()
            } else { format!("macOS refused this — try moving Velo to /Applications. {detail}") });
        }
        let status: isize = unsafe { msg_send![service, status] };
        if on && status != 1 {
            return Err("macOS requires approval for Velo in System Settings → Login Items".into());
        }
        Ok(if on { "Start at login enabled" } else { "Start at login disabled" }.into())
    })
}
#[cfg(target_os = "macos")]
fn legacy_agent_path() -> Result<std::path::PathBuf, String> {
    Ok(dirs::home_dir().ok_or("Home directory unavailable")?
        .join("Library/LaunchAgents/com.atingaii.vela.plist"))
}

#[cfg(target_os = "macos")]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LegacyItem { Absent, Owned, Unrecognized }

#[cfg(target_os = "macos")]
fn legacy_item() -> LegacyItem {
    let Ok(path) = legacy_agent_path() else { return LegacyItem::Absent };
    let Ok(meta) = std::fs::symlink_metadata(&path) else { return LegacyItem::Absent };
    if !meta.is_file() || meta.file_type().is_symlink() { return LegacyItem::Unrecognized; }
    let Ok(value) = plist::Value::from_file(&path) else { return LegacyItem::Unrecognized };
    if owned_legacy_value(&value, &std::env::current_exe().unwrap_or_default()) {
        LegacyItem::Owned
    } else { LegacyItem::Unrecognized }
}

#[cfg(target_os = "macos")]
fn owned_legacy_value(value: &plist::Value, current_exe: &std::path::Path) -> bool {
    let Some(dict) = value.as_dictionary() else { return false };
    if dict.get("Label").and_then(plist::Value::as_string) != Some("com.atingaii.vela") {
        return false;
    }
    let Some(args) = dict.get("ProgramArguments").and_then(plist::Value::as_array) else {
        return false;
    };
    if args.len() != 2 || args[1].as_string() != Some("--silent") {
        return false;
    }
    let Some(executable) = args[0].as_string() else { return false };
    let executable = std::path::Path::new(executable);
    let same_current = executable.is_absolute() && executable == current_exe;
    let from_velo_bundle = executable.file_name().is_some_and(|name| name == "velo")
        && executable.parent().is_some_and(|path| path.file_name().is_some_and(|name| name == "MacOS"))
        && executable.parent().and_then(std::path::Path::parent)
            .is_some_and(|path| path.file_name().is_some_and(|name| name == "Contents"))
        && executable.parent().and_then(std::path::Path::parent)
            .and_then(std::path::Path::parent)
            .is_some_and(|path| path.file_name().is_some_and(|name| name == "Velo.app"));
    same_current || (executable.is_absolute() && from_velo_bundle)
}

#[cfg(target_os = "macos")]
fn remove_owned_legacy() -> Result<(), String> {
    match legacy_item() {
        LegacyItem::Absent => Ok(()),
        LegacyItem::Owned => std::fs::remove_file(legacy_agent_path()?).map_err(|e| e.to_string()),
        LegacyItem::Unrecognized => Err("An unrecognized Velo-named LaunchAgent exists; inspect it before changing login settings".into()),
    }
}

#[cfg(target_os = "macos")]
pub fn problem() -> Option<String> {
    if legacy_item() == LegacyItem::Unrecognized {
        return Some("An unrecognized Velo-named LaunchAgent exists. Login-item changes are disabled until it is inspected.".into());
    }
    if has_sm_app_service() && service_status() == Some(2) {
        return Some("macOS requires approval in System Settings → Login Items.".into());
    }
    None
}
#[cfg(not(target_os = "macos"))]
pub fn problem() -> Option<String> { None }

// Velo's minimum macOS version is 12, one release before SMAppService. Keep its prior launch
// agent only on that older system; macOS 13+ always reports the OS login-item status.
#[cfg(target_os = "macos")]
fn legacy_set(on: bool) -> Result<String, String> {
    let path = legacy_agent_path()?;
    if !on {
        remove_owned_legacy()?;
        return Ok("Start at login disabled".into());
    }
    if legacy_item() == LegacyItem::Unrecognized {
        return Err("An unrecognized Velo-named LaunchAgent exists; inspect it before enabling login".into());
    }
    let exe = std::env::current_exe().map_err(|e| e.to_string())?
        .to_string_lossy().replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;");
    let plist = format!(r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>com.atingaii.vela</string>
<key>ProgramArguments</key><array><string>{exe}</string><string>--silent</string></array>
<key>RunAtLoad</key><true/></dict></plist>"#);
    std::fs::create_dir_all(path.parent().ok_or("Invalid launch agent path")?)
        .map_err(|e| e.to_string())?;
    std::fs::write(path, plist).map_err(|e| e.to_string())?;
    Ok("Start at login enabled".into())
}
#[cfg(target_os = "macos")]
pub fn is_enabled() -> bool {
    (has_sm_app_service() && service_status() == Some(1)) // SMAppServiceStatusEnabled
        || legacy_item() == LegacyItem::Owned
}
#[cfg(target_os = "macos")]
pub fn enable() -> Result<String, String> {
    if !has_sm_app_service() { return legacy_set(true); }
    if legacy_item() == LegacyItem::Unrecognized {
        return Err("An unrecognized Velo-named LaunchAgent exists; inspect it before enabling login".into());
    }
    let message = if service_status() == Some(1) {
        "Start at login enabled".into()
    } else { set_service(true)? };
    remove_owned_legacy()?;
    Ok(message)
}
#[cfg(target_os = "macos")]
pub fn disable() -> Result<String, String> {
    if !has_sm_app_service() { return legacy_set(false); }
    if legacy_item() == LegacyItem::Unrecognized {
        return Err("An unrecognized Velo-named LaunchAgent exists; inspect it before disabling login".into());
    }
    let message = if matches!(service_status(), Some(1 | 2)) {
        set_service(false)?
    } else { "Start at login disabled".into() };
    remove_owned_legacy()?;
    Ok(message)
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

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    fn legacy(executable: &str, label: &str) -> plist::Value {
        let mut dict = plist::Dictionary::new();
        dict.insert("Label".into(), plist::Value::String(label.into()));
        dict.insert("ProgramArguments".into(), plist::Value::Array(vec![
            plist::Value::String(executable.into()), plist::Value::String("--silent".into()),
        ]));
        plist::Value::Dictionary(dict)
    }
    #[test]
    fn only_velo_owned_legacy_item_is_migrated() {
        let current = std::path::Path::new("/Applications/Velo.app/Contents/MacOS/velo");
        assert!(owned_legacy_value(&legacy(current.to_str().unwrap(), "com.atingaii.vela"), current));
        assert!(!owned_legacy_value(&legacy("/tmp/unrelated", "com.atingaii.vela"), current));
        assert!(!owned_legacy_value(&legacy(current.to_str().unwrap(), "com.example.other"), current));
    }
}
