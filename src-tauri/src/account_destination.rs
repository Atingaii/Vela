use tauri::AppHandle;

/// Only a provider ID crosses the IPC boundary. The app/URL is re-resolved from our own account
/// reading for each click; the WebView cannot supply an arbitrary program path or website.
#[derive(Clone, serde::Serialize)]
pub struct AccountDestination {
    pub kind: &'static str,
    pub label: String,
    pub help: String,
}

enum Target {
    App(&'static str),
    Website(String),
}

fn owner_app(id: &str) -> Option<(&'static str, &'static str)> {
    Some(match id {
        "codex" => ("com.openai.codex", "Codex"),
        "cursor" => ("com.todesktop.230313mzl4w4u92", "Cursor"),
        "gemini" => ("com.google.antigravity", "Antigravity"),
        "devin" => ("com.exafunction.windsurf", "Devin"),
        "ollama-local" => ("com.electron.ollama", "Ollama"),
        "lmstudio" => ("ai.elementlabs.lmstudio", "LM Studio"),
        // Named Codex/Antigravity profiles belong to a CLI directory, not the default GUI login.
        _ => return None,
    })
}

fn safe_account_url(raw: &str) -> Option<(String, String)> {
    let parsed = tauri::Url::parse(raw).ok()?;
    if parsed.scheme() != "https" || !parsed.username().is_empty() || parsed.password().is_some() {
        return None;
    }
    let host = parsed.host_str()?.to_owned();
    Some((parsed.to_string(), host))
}

#[cfg(target_os = "macos")]
async fn installed_app(app: &AppHandle, bundle: &'static str) -> bool {
    use objc2_app_kit::NSWorkspace;
    use objc2_foundation::NSString;
    let (tx, mut rx) = tauri::async_runtime::channel(1);
    if app.run_on_main_thread(move || {
        let found = NSWorkspace::sharedWorkspace()
            .URLForApplicationWithBundleIdentifier(&NSString::from_str(bundle))
            .is_some();
        let _ = tx.try_send(found);
    }).is_err() { return false; }
    rx.recv().await.unwrap_or(false)
}

#[cfg(windows)]
fn windows_executable(bundle: &str) -> Option<&'static str> {
    Some(match bundle {
        "com.openai.codex" => "Codex.exe",
        "com.todesktop.230313mzl4w4u92" => "Cursor.exe",
        "com.google.antigravity" => "Antigravity.exe",
        "com.exafunction.windsurf" => "Windsurf.exe",
        "com.electron.ollama" => "Ollama.exe",
        "ai.elementlabs.lmstudio" => "LM Studio.exe",
        _ => return None,
    })
}

/// App Paths is Windows' own installed-application registration. Do not treat a macOS bundle ID
/// as an executable or launch a guessed location from the user's PATH.
#[cfg(windows)]
fn windows_app_path(bundle: &str) -> Option<std::path::PathBuf> {
    use windows::core::HSTRING;
    use windows::Win32::System::Registry::{
        RegGetValueW, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE,
        RRF_RT_REG_EXPAND_SZ, RRF_RT_REG_SZ,
    };
    let executable = windows_executable(bundle)?;
    let key = HSTRING::from(format!(
        "Software\\Microsoft\\Windows\\CurrentVersion\\App Paths\\{executable}"
    ));
    let default_value = HSTRING::from("");
    for root in [HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE] {
        let mut value = [0u16; 4096];
        let mut bytes = (value.len() * std::mem::size_of::<u16>()) as u32;
        let status = unsafe {
            RegGetValueW(root, &key, &default_value, RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ,
                None, Some(value.as_mut_ptr().cast()), Some(&mut bytes))
        };
        if !status.is_ok() { continue; }
        let Some(len) = value.iter().position(|unit| *unit == 0) else { continue };
        let Ok(raw) = String::from_utf16(&value[..len]) else { continue };
        let path = std::path::PathBuf::from(raw);
        if path.is_absolute() && path.is_file()
            && path.file_name().is_some_and(|name| name.to_string_lossy().eq_ignore_ascii_case(executable)) {
            return Some(path);
        }
    }
    None
}

#[cfg(windows)]
async fn installed_app(_app: &AppHandle, bundle: &'static str) -> bool {
    windows_app_path(bundle).is_some()
}

#[cfg(not(any(target_os = "macos", windows)))]
async fn installed_app(_app: &AppHandle, _bundle: &'static str) -> bool { false }

async fn resolve(app: &AppHandle, id: &str) -> Option<(AccountDestination, Target)> {
    if crate::smoke::root().is_some() { return None; }
    let row = crate::providers::get_providers(app.clone())
        .into_iter().find(|row| row.id == id);
    // Default six rings come from AppState, not the provider catalog. A missing Reading must not
    // erase a real connected Codex/Cursor/Antigravity app destination from Accounts.
    let enabled = row.as_ref().map(|row| row.enabled).unwrap_or_else(|| {
        crate::TRAY_PROVIDER_IDS.contains(&id) && crate::providers::enabled(app, id)
    });
    if !enabled { return None; }
    if let Some((bundle, name)) = owner_app(id) {
        if installed_app(app, bundle).await {
            return Some((AccountDestination {
                kind: "app",
                label: name.into(),
                help: format!("Opens {name}, which is where this account is signed in."),
            }, Target::App(bundle)));
        }
    }
    let manage_url = row.as_ref().and_then(|row| row.account.as_ref())
        .and_then(|account| account.manage_url.as_deref())
        .map(str::to_owned)
        .or_else(|| {
            // The default Codex profile's local auth identity is the same evidence Swift uses
            // before offering its browser fallback. Never open a generic sign-in page merely
            // because an account switch is enabled.
            (id == "codex" && dirs::home_dir()
                .is_some_and(|home| crate::codex::account_identity(&home.join(".codex")).is_some()))
                .then_some("https://chatgpt.com/#settings/Account".to_string())
        })?;
    let (url, host) = safe_account_url(&manage_url)?;
    Some((AccountDestination {
        kind: "website",
        label: host.clone(),
        help: format!("Opens {host} in your browser. That site has its own sign-in, separate from the credential read here."),
    }, Target::Website(url)))
}

#[tauri::command]
pub async fn get_account_destination(app: AppHandle, id: String) -> Option<AccountDestination> {
    resolve(&app, &id).await.map(|(destination, _)| destination)
}

#[cfg(target_os = "macos")]
async fn open_app(app: &AppHandle, bundle: &'static str) -> Result<(), String> {
    use objc2_app_kit::NSWorkspace;
    use objc2_foundation::NSString;
    let (tx, mut rx) = tauri::async_runtime::channel(1);
    app.run_on_main_thread(move || {
        let workspace = NSWorkspace::sharedWorkspace();
        let opened = workspace
            .URLForApplicationWithBundleIdentifier(&NSString::from_str(bundle))
            .is_some_and(|url| workspace.openURL(&url));
        let _ = tx.try_send(opened);
    }).map_err(|error| error.to_string())?;
    if rx.recv().await.unwrap_or(false) { Ok(()) }
    else { Err("The account's application is no longer available.".into()) }
}

#[cfg(windows)]
async fn open_app(_app: &AppHandle, bundle: &'static str) -> Result<(), String> {
    use std::process::{Command, Stdio};
    let path = windows_app_path(bundle)
        .ok_or_else(|| "The account's application is no longer installed.".to_string())?;
    let mut child = Command::new(path)
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null())
        .spawn().map_err(|error| error.to_string())?;
    std::thread::spawn(move || { let _ = child.wait(); });
    Ok(())
}

#[cfg(not(any(target_os = "macos", windows)))]
async fn open_app(_app: &AppHandle, _bundle: &'static str) -> Result<(), String> {
    Err("The account's application is not available on this system.".into())
}

#[tauri::command]
pub async fn open_account_destination(app: AppHandle, id: String) -> Result<AccountDestination, String> {
    let (destination, target) = resolve(&app, &id).await
        .ok_or_else(|| "This connected account has no available destination.".to_string())?;
    match target {
        Target::App(bundle) => open_app(&app, bundle).await?,
        Target::Website(url) => crate::platform::open(std::ffi::OsStr::new(&url))
            .map_err(|error| error.to_string())?,
    }
    Ok(destination)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn owner_route_is_only_for_default_gui_accounts() {
        assert_eq!(owner_app("codex").unwrap().0, "com.openai.codex");
        assert_eq!(owner_app("gemini").unwrap().0, "com.google.antigravity");
        assert!(owner_app("codex-work").is_none());
        assert!(owner_app("antigravity-work").is_none());
        assert!(owner_app("custom-endpoint-example").is_none());
    }

    #[test]
    fn website_fallback_accepts_only_plain_https_accounts() {
        assert_eq!(safe_account_url("https://claude.ai/settings/usage").unwrap().1, "claude.ai");
        assert!(safe_account_url("http://claude.ai/").is_none());
        assert!(safe_account_url("https://name:pass@claude.ai/").is_none());
        assert!(safe_account_url("file:///Applications/Other.app").is_none());
    }
}
