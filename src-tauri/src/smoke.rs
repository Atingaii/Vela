//! Opt-in installation check. Uses an empty caller-owned directory and no providers.
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use tauri::Manager;

static ROOT: OnceLock<PathBuf> = OnceLock::new();
static VISUAL: OnceLock<bool> = OnceLock::new();
static SWIFT_FIXTURE: OnceLock<bool> = OnceLock::new();
static SWIFT_ROWS: OnceLock<Vec<crate::providers::Reading>> = OnceLock::new();
static UPDATE_EXPECTED: OnceLock<String> = OnceLock::new();

pub fn update_verification() -> bool {
    UPDATE_EXPECTED.get().is_some()
}

pub fn update_expected() -> Option<&'static str> {
    UPDATE_EXPECTED.get().map(String::as_str)
}

pub fn update_marker() -> bool {
    root().is_some_and(|root| root.join("update-staged.json").is_file())
}

pub fn update_report(app: &tauri::AppHandle, success: bool, phase: &str, detail: &str) {
    if let Some(root) = root() {
        let report = serde_json::json!({
            "success":success,"phase":phase,"detail":detail,
            "version":env!("CARGO_PKG_VERSION"),"expected":update_expected(),
            "package_version":app.package_info().version.to_string(),
            "executable":std::env::current_exe().ok().map(|p| p.display().to_string()),
        });
        let _ = std::fs::write(root.join("update-verification-result.json"), report.to_string());
    }
    app.exit(if success { 0 } else { 1 });
}

pub fn visual() -> bool {
    VISUAL.get().copied().unwrap_or(false)
}

pub fn swift_fixture() -> bool {
    visual() && SWIFT_FIXTURE.get().copied().unwrap_or(false)
}

pub fn configure(args: &[String]) -> Result<(), String> {
    let mode = args.get(1).map(String::as_str);
    if !matches!(mode, Some("--smoke-test" | "--visual-test" | "--verify-update")) {
        return Ok(());
    }
    let verification = mode == Some("--verify-update");
    if verification {
        if args.len() != 5 || args[3] != "--expect" || semver::Version::parse(&args[4]).is_err() {
            return Err("expected --verify-update <isolated-temp-root> --expect <version>".into());
        }
        #[cfg(windows)]
        if std::env::var("CI").ok().as_deref() != Some("true") {
            return Err("Windows update verification is only allowed on an isolated CI runner".into());
        }
    }
    let swift = match if verification { &[][..] } else { args.get(3..).unwrap_or(&[]) } {
        [] => false,
        [flag, name] if mode == Some("--visual-test") && flag == "--fixture" && name == "swift" => {
            true
        }
        _ => return Err("expected --visual-test <empty-directory> [--fixture swift]".into()),
    };
    let dir = args
        .get(2)
        .ok_or("--smoke-test requires an empty output directory")?;
    let path = Path::new(dir);
    std::fs::create_dir_all(path).map_err(|e| e.to_string())?;
    if !verification && std::fs::read_dir(path)
        .map_err(|e| e.to_string())?
        .next()
        .is_some()
    {
        return Err("smoke output directory must be empty".into());
    }
    let root = path.canonicalize().map_err(|e| e.to_string())?;
    if verification {
        let temp = std::env::temp_dir().canonicalize().map_err(|e| e.to_string())?;
        let executable = std::env::current_exe()
            .and_then(|path| path.canonicalize()).map_err(|e| e.to_string())?;
        if !root.starts_with(&temp) || !executable.starts_with(&root) {
            return Err("update verification requires an executable inside its isolated temp root".into());
        }
        if std::fs::read_dir(&root).map_err(|e| e.to_string())?
            .filter_map(Result::ok)
            .any(|entry| entry.file_name() == "config.json")
            && !root.join("update-staged.json").is_file()
        {
            return Err("update verification root contains an unrelated configuration".into());
        }
        let _ = UPDATE_EXPECTED.set(args[4].clone());
    }
    ROOT.set(root)
        .map_err(|_| "smoke already configured".to_string())?;
    let _ = VISUAL.set(mode == Some("--visual-test"));
    let _ = SWIFT_FIXTURE.set(swift);
    Ok(())
}

pub fn root() -> Option<&'static PathBuf> {
    ROOT.get()
}

pub fn start(app: &tauri::AppHandle) {
    crate::settings_window::open_for_smoke(app);
    if visual() {
        return;
    }
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_secs(30));
        finish(&app, false, false, false);
    });
}

/// Six synthetic providers reproduce the user's clipped stack without starting collectors.
pub fn seed_visual(app: &tauri::AppHandle) {
    let state = app.state::<crate::AppState>();
    {
        let mut config = state.cfg.lock().unwrap();
        config.notch_on_hover = false;
        if swift_fixture() {
            seed_swift_visual_scene(&mut config);
            config.notch_selection_explicit = true;
            config.notch_slots = ["claude", "openai", "third"]
                .into_iter()
                .map(|provider| crate::config::TraySlot {
                    provider: provider.into(),
                })
                .collect();
            config.notch_providers = config
                .notch_slots
                .iter()
                .map(|slot| slot.provider.clone())
                .collect();
        }
    }
    if swift_fixture() {
        let rows = make_swift_rows();
        *state.usage.lock().unwrap() = rows[0].snap.clone();
        let _ = SWIFT_ROWS.set(rows);
        return;
    }
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
            has_fraction: Some(true),
            group: None,
            money: None,
            detail: None,
            used_text: None,
            prefers_used_text: false,
            band_override: None,
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

/// The isolated side-by-side screenshot scene from the pinned Swift reference.
/// Only `--visual-test <empty> --fixture swift` calls this; production defaults
/// and existing user settings are never rewritten to match the photograph.
fn seed_swift_visual_scene(config: &mut crate::config::Config) {
    config.notch_edge = "left".into();
    config.scale = 0.8;
    config.weekly_ring = "outside".into();
    config.show_move_handle = false;
    config.notch_visible = true;
    config.notch_on_hover = false;
    config.appearance.surface_style = "solid".into();
    config.appearance.show_usage_pace = true;
    config.appearance.folds_for_fullscreen = false;
    config.appearance.reset_time = "automatic".into();
    config.appearance.weekly_dashed = false;
    config.appearance.claude_daily_pace = false;
    config.appearance.custom_scale = None;
}

/// `Sources/Model/Fixtures.swift` at 117a38b8. IDs, ordering, labels, fractions and reset
/// cadence are intentionally the old three-provider design fixture, not production accounts.
/// This is reachable only under the isolated visual-test root and never starts collectors.
fn make_swift_rows() -> Vec<crate::providers::Reading> {
    use chrono::{Duration, Local, TimeZone};
    let now = Local::now();
    let millis = now.timestamp_millis() as u64;
    // Swift uses startOfDay(for: now + 24h), which differs from the next
    // calendar date across some daylight-saving transitions.
    let tomorrow = (now + Duration::hours(24)).date_naive();
    let midnight = Local
        .from_local_datetime(&tomorrow.and_hms_opt(0, 0, 0).expect("valid midnight"))
        .earliest()
        .expect("local next midnight")
        .timestamp_millis() as u64;
    let window = |id: &str, label: &str, used: f64, resets_at: u64, derived: bool| {
        crate::usage::LimitWindow {
            id: id.into(),
            label: label.into(),
            used,
            resets_at: Some(resets_at),
            derived,
            ..Default::default()
        }
    };
    let row = |id: &str, name: &str, headline: &str, fidelity: crate::usage::Fidelity, windows| {
        crate::providers::Reading {
            id: id.into(),
            name: name.into(),
            headline: headline.into(),
            guidance: String::new(),
            enabled: true,
            was_refused_access: false,
            needs_sign_in_renewal: false,
            account: None,
            snap: crate::usage::UsageSnapshot {
                status: "ok".into(),
                fetched_at: millis,
                windows,
                fidelity,
                ..Default::default()
            },
        }
    };
    vec![
        row(
            "claude",
            "Claude",
            "claude.session",
            crate::usage::Fidelity::Derived,
            vec![
                window(
                    "claude.session",
                    "Current session",
                    0.73,
                    millis + 51 * 60_000,
                    true,
                ),
                window("claude.all", "All models", 0.07, midnight, true),
            ],
        ),
        row(
            "openai",
            "OpenAI",
            "openai.session",
            crate::usage::Fidelity::Manual,
            vec![window(
                "openai.session",
                "Current session",
                0.21,
                millis + 3 * 60 * 60_000,
                true,
            )],
        ),
        row(
            "third",
            "Perplexity",
            "third.daily",
            crate::usage::Fidelity::Manual,
            vec![window("third.daily", "Daily quota", 0.52, midnight, true)],
        ),
    ]
}

pub fn swift_rows() -> Option<Vec<crate::providers::Reading>> {
    SWIFT_ROWS.get().filter(|_| swift_fixture()).cloned()
}

pub fn swift_snapshot(id: &str) -> Option<crate::usage::UsageSnapshot> {
    swift_rows()?
        .into_iter()
        .find(|row| row.id == id)
        .map(|row| row.snap)
}

fn finish(app: &tauri::AppHandle, page_ready: bool, helper_present: bool, presence_ok: bool) {
    let Some(root) = root() else { return };
    let success = page_ready && helper_present && presence_ok;
    let report = serde_json::json!({
        "success":success,"version":env!("CARGO_PKG_VERSION"),
        "package_version":app.package_info().version.to_string(),
        "os":std::env::consts::OS,"arch":std::env::consts::ARCH,
        "settings_webview_and_ipc":page_ready,"bundled_helper":helper_present,
        "windows_taskbar_proxy": if cfg!(windows) { Some(presence_ok) } else { None },
        "update_verification_executable": if update_verification() {
            std::env::current_exe().ok().map(|path| path.display().to_string())
        } else { None },
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
    #[cfg(windows)]
    let presence_ok = crate::settings_window::windows_taskbar_smoke_ok(&app);
    #[cfg(not(windows))]
    let presence_ok = true;
    finish(&app, ready && visible, present, presence_ok);
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
    fn swift_visual_scene_is_isolated_from_production_defaults() {
        let normal = crate::config::Config::default();
        let mut visual = normal.clone();
        super::seed_swift_visual_scene(&mut visual);
        assert_eq!(visual.notch_edge, "left");
        assert_eq!(visual.scale, 0.8);
        assert_eq!(visual.weekly_ring, "outside");
        assert!(!visual.show_move_handle);
        assert!(visual.notch_visible);
        assert!(!visual.notch_on_hover);
        assert_eq!(visual.appearance.surface_style, "solid");
        assert!(visual.appearance.show_usage_pace);
        assert!(!visual.appearance.folds_for_fullscreen);
        assert_eq!(visual.appearance.reset_time, "automatic");
        assert!(!visual.appearance.weekly_dashed);
        assert!(!visual.appearance.claude_daily_pace);
        assert!(visual.appearance.custom_scale.is_none());
        assert_ne!(normal.notch_edge, visual.notch_edge);
        assert_ne!(
            normal.appearance.surface_style,
            visual.appearance.surface_style
        );
    }
    #[test]
    fn swift_design_fixture_keeps_original_order_and_readings() {
        let rows = super::make_swift_rows();
        assert_eq!(
            rows.iter().map(|row| row.id.as_str()).collect::<Vec<_>>(),
            ["claude", "openai", "third"]
        );
        assert_eq!(
            rows.iter().map(|row| row.name.as_str()).collect::<Vec<_>>(),
            ["Claude", "OpenAI", "Perplexity"]
        );
        assert_eq!(
            rows[0]
                .snap
                .windows
                .iter()
                .map(|window| window.used)
                .collect::<Vec<_>>(),
            [0.73, 0.07]
        );
        assert_eq!(rows[1].snap.windows[0].used, 0.21);
        assert_eq!(rows[2].snap.windows[0].used, 0.52);
        assert_eq!(
            rows[0].snap.windows[0].resets_at.unwrap() - rows[0].snap.fetched_at,
            51 * 60_000
        );
        assert_eq!(
            rows[1].snap.windows[0].resets_at.unwrap() - rows[1].snap.fetched_at,
            3 * 60 * 60_000
        );
    }

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
