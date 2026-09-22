//! OS integration stays native; WebViews never get arbitrary process or file access.
use std::{
    ffi::OsStr,
    process::{Command, Stdio},
};

pub fn open(target: &OsStr) -> Result<(), String> {
    #[cfg(windows)]
    let mut cmd = {
        let mut c = Command::new("explorer.exe");
        c.arg(target);
        c
    };
    #[cfg(target_os = "macos")]
    let mut cmd = {
        let mut c = Command::new("/usr/bin/open");
        c.arg(target);
        c
    };
    #[cfg(not(any(windows, target_os = "macos")))]
    let mut cmd = {
        let mut c = Command::new("xdg-open");
        c.arg(target);
        c
    };
    cmd.stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    cmd.spawn()
        .map(|mut child| {
            std::thread::spawn(move || {
                let _ = child.wait();
            });
        })
        .map_err(|e| e.to_string())
}

#[cfg(target_os = "macos")]
pub fn left_button_down() -> bool {
    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn CGEventSourceButtonState(state: i32, button: u32) -> bool;
    }
    // Combined session state; left button. No event interception or input permission.
    unsafe { CGEventSourceButtonState(0, 0) }
}
#[cfg(not(any(windows, target_os = "macos")))]
pub fn left_button_down() -> bool {
    false
}

/// Shell-safe path used only in the user-requested Terminal login and Claude hook.
pub fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    #[test]
    fn quote_preserves_metacharacters_as_data() {
        assert_eq!(
            super::shell_quote("/a b/O'Brien/$(whoami)"),
            "'/a b/O'\\''Brien/$(whoami)'"
        );
    }
}

#[cfg(target_os = "macos")]
pub fn claude_keychain() -> Option<Vec<u8>> {
    use security_framework::item::{ItemClass, ItemSearchOptions, SearchResult};
    let items = ItemSearchOptions::new()
        .class(ItemClass::generic_password())
        .service("Claude Code-credentials")
        .load_data(true)
        .limit(100)
        .skip_authenticated_items(true)
        .search()
        .ok()?;
    // Credential rotations may create multiple items. Choose the latest expiry,
    // not the unspecified first result, without ever prompting on a timer.
    items
        .into_iter()
        .filter_map(|item| match item {
            SearchResult::Data(data) => {
                let v: serde_json::Value = serde_json::from_slice(&data).ok()?;
                let oauth = v.get("claudeAiOauth").unwrap_or(&v);
                oauth["accessToken"].as_str().filter(|s| !s.is_empty())?;
                Some((oauth["expiresAt"].as_u64().unwrap_or(0), data))
            }
            _ => None,
        })
        .max_by_key(|(expiry, _)| *expiry)
        .map(|(_, data)| data)
}
