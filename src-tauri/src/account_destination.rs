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

#[cfg(not(target_os = "macos"))]
async fn installed_app(_app: &AppHandle, _bundle: &'static str) -> bool { false }

async fn resolve(app: &AppHandle, id: &str) -> Option<(AccountDestination, Target)> {
    if crate::smoke::root().is_some() { return None; }
    let row = crate::providers::get_providers(app.clone())
        .into_iter().find(|row| row.id == id && row.enabled)?;
    if let Some((bundle, name)) = owner_app(id) {
        if installed_app(app, bundle).await {
            return Some((AccountDestination {
                kind: "app",
                label: name.into(),
                help: format!("Opens {name}, which is where this account is signed in."),
            }, Target::App(bundle)));
        }
    }
    let (url, host) = safe_account_url(row.account.as_ref()?.manage_url.as_deref()?)?;
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

#[cfg(not(target_os = "macos"))]
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
