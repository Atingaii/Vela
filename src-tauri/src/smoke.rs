//! Opt-in installation check. Uses an empty caller-owned directory and no providers.
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use tauri::Manager;

static ROOT: OnceLock<PathBuf> = OnceLock::new();
static VISUAL: OnceLock<bool> = OnceLock::new();

pub fn visual() -> bool {
    VISUAL.get().copied().unwrap_or(false)
}

pub fn configure(args: &[String]) -> Result<(), String> {
    let mode = args.get(1).map(String::as_str);
    if !matches!(mode, Some("--smoke-test" | "--visual-test")) {
        return Ok(());
    }
    let dir = args
        .get(2)
        .ok_or("--smoke-test requires an empty output directory")?;
    let path = Path::new(dir);
    std::fs::create_dir_all(path).map_err(|e| e.to_string())?;
    if std::fs::read_dir(path)
        .map_err(|e| e.to_string())?
        .next()
        .is_some()
    {
        return Err("smoke output directory must be empty".into());
    }
    ROOT.set(path.canonicalize().map_err(|e| e.to_string())?)
        .map_err(|_| "smoke already configured".to_string())?;
    let _ = VISUAL.set(mode == Some("--visual-test"));
    Ok(())
}

pub fn root() -> Option<&'static PathBuf> {
    ROOT.get()
}

pub fn start(app: &tauri::AppHandle) {
    crate::settings_window::open(app);
    if visual() {
        return;
    }
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_secs(30));
        finish(&app, false, false);
    });
}

/// Six synthetic providers reproduce the user's clipped stack without starting collectors.
pub fn seed_visual(app: &tauri::AppHandle) {
    let state = app.state::<crate::AppState>();
    state.cfg.lock().unwrap().notch_on_hover = false;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;
    let sample = |id: &str, used: f64| crate::usage::UsageSnapshot {
        status: "ok".into(),
        fetched_at: now,
        plan: Some("Visual test".into()),
        windows: vec![crate::usage::LimitWindow {
            id: id.into(),
            label: "Session".into(),
            used,
            resets_at: Some(now + 7200000),
            duration: Some(18000.0),
            count: None,
            remaining: None,
            used_count: None,
            derived: false,
            group: None,
        }],
        ..Default::default()
    };
    *state.usage.lock().unwrap() = sample("session", 0.38);
    *state.codex.lock().unwrap() = sample("primary", 0.62);
    *state.cursor.lock().unwrap() = sample("included", 0.19);
    *state.grok.lock().unwrap() = sample("credits", 0.27);
    *state.glm.lock().unwrap() = sample("session", 0.41);
    *state.antigravity.lock().unwrap() = sample("session", 0.54);
}

fn finish(app: &tauri::AppHandle, page_ready: bool, helper_present: bool) {
    let Some(root) = root() else { return };
    let success = page_ready && helper_present;
    let report = serde_json::json!({
        "success":success,"version":env!("CARGO_PKG_VERSION"),
        "os":std::env::consts::OS,"arch":std::env::consts::ARCH,
        "settings_webview_and_ipc":page_ready,"bundled_helper":helper_present,
        "providers_started":false
    });
    let written = std::fs::write(root.join("smoke-result.json"), report.to_string()).is_ok();
    app.exit(if success && written { 0 } else { 1 });
}

#[tauri::command]
pub fn smoke_ready(
    app: tauri::AppHandle,
    window: tauri::WebviewWindow,
    ready: bool,
) -> Result<(), String> {
    if root().is_none() || window.label() != "settings" {
        return Err("installation check is not active".into());
    }
    let helper = if cfg!(windows) {
        "vela-hook.exe"
    } else {
        "vela-hook"
    };
    let present = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|p| p.join(helper).is_file()))
        .unwrap_or(false);
    let visible = app
        .get_webview_window("settings")
        .and_then(|w| w.is_visible().ok())
        .unwrap_or(false);
    finish(&app, ready && visible, present);
    Ok(())
}

pub const PAGE_CHECK: &str = r#"
window.addEventListener('DOMContentLoaded', () => setTimeout(async () => {
  let ready = false;
  try {
    const invoke = window.__TAURI__.core.invoke;
    const [lang, appearance] = await Promise.all([invoke('get_lang_resolved'), invoke('get_appearance')]);
    ready = typeof lang === 'string' && appearance && typeof appearance.watch === 'number'
      && ['tab-accounts','tab-appearance','tab-notifications'].every(id => !!document.getElementById(id))
      && document.title === 'Velo Settings' && document.body.getBoundingClientRect().width > 0;
  } catch (_) {}
  window.__TAURI__.core.invoke('smoke_ready', {ready:!!ready});
}, 400));
"#;

#[cfg(test)]
mod tests {
    #[test]
    fn installation_check_refuses_existing_data() {
        let dir = tempfile::tempdir().unwrap();
        let sentinel = dir.path().join("config.json");
        std::fs::write(&sentinel, "keep my settings").unwrap();
        let args = vec![
            "velo".into(),
            "--smoke-test".into(),
            dir.path().to_string_lossy().into_owned(),
        ];
        assert!(super::configure(&args).is_err());
        assert_eq!(
            std::fs::read_to_string(sentinel).unwrap(),
            "keep my settings"
        );
        assert!(super::root().is_none());
    }
}
