//! Release note window, once per version. A note is acknowledged only when it is dismissed;
//! a crash between showing and closing it leaves it eligible for the next launch.

use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

const LABEL: &str = "whats-new";
static SHOWING: AtomicBool = AtomicBool::new(false);

#[derive(Clone, serde::Serialize)]
pub struct ReleaseNote {
    version: &'static str,
    headline: &'static str,
    changes: Vec<ReleaseChange>,
    icon: String,
}

#[derive(Clone, serde::Serialize)]
struct ReleaseChange {
    title: &'static str,
    detail: &'static str,
}

/// Velo's own published notes. Codenotch's historical release text is not Velo release news.
fn note_for(version: &'static str) -> Option<ReleaseNote> {
    if version != "0.1.0" { return None; }
    Some(ReleaseNote {
        version,
        headline: "A first look at Velo's screen-edge companion.",
        changes: vec![
            ReleaseChange { title: "Your accounts at a glance",
                detail: "Connect supported coding tools in Settings to see their published usage windows." },
            ReleaseChange { title: "Make the notch yours",
                detail: "Choose which connected accounts appear and adjust its position and appearance." },
            ReleaseChange { title: "Return to Settings any time",
                detail: "Open Velo again, or use its Dock or menu bar entry when enabled." },
        ],
        icon: crate::trayicon::png_data_url(include_bytes!("../icons/icon.png"))
            .unwrap_or_default(),
    })
}

#[tauri::command]
pub fn get_whats_new_info() -> Option<ReleaseNote> {
    note_for(env!("CARGO_PKG_VERSION"))
}

fn decide(last_seen: Option<&str>, version: &str, has_note: bool) -> Decision {
    if last_seen == Some(version) { Decision::AlreadySeen }
    else if has_note { Decision::Show }
    else { Decision::RecordWithoutWindow }
}

#[derive(Debug, PartialEq, Eq)]
enum Decision { AlreadySeen, Show, RecordWithoutWindow }

pub fn show_if_needed(app: &AppHandle, first_launch: bool) {
    let version = env!("CARGO_PKG_VERSION");
    let decision = {
        let state = app.state::<crate::AppState>();
        let cfg = state.cfg.lock().unwrap();
        decide(cfg.last_seen_version.as_deref(), version, note_for(version).is_some())
    };
    match decision {
        Decision::AlreadySeen => introduce_if_first(app, first_launch),
        Decision::RecordWithoutWindow => {
            acknowledge(app, version);
            introduce_if_first(app, first_launch);
        }
        Decision::Show => {
            if SHOWING.swap(true, Ordering::AcqRel) { return; }
            let handle = app.clone();
            std::thread::spawn(move || {
                let app = handle.clone();
                let _ = handle.run_on_main_thread(move || {
                    if let Err(error) = open_now(&app, first_launch) {
                        SHOWING.store(false, Ordering::Release);
                        crate::applog(&format!("what's new window: {error}"));
                        // A failed window is not a dismissal: retain the note for next launch.
                        introduce_if_first(&app, first_launch);
                    }
                });
            });
        }
    }
}

fn acknowledge(app: &AppHandle, version: &str) {
    let state = app.state::<crate::AppState>();
    let mut cfg = state.cfg.lock().unwrap();
    let mut next = cfg.clone();
    next.last_seen_version = Some(version.into());
    match crate::config::save_checked(&next) {
        Ok(()) => *cfg = next,
        Err(error) => crate::applog(&format!("what's new state: {error}")),
    }
}

fn introduce_if_first(app: &AppHandle, first_launch: bool) {
    if !first_launch { return; }
    let handle = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(600));
        crate::settings_window::open(&handle);
    });
}

fn open_now(app: &AppHandle, first_launch: bool) -> tauri::Result<()> {
    if let Some(window) = app.get_webview_window(LABEL) {
        let _ = window.show();
        let _ = window.set_focus();
        return Ok(());
    }
    let title = title_for_lang(&crate::tray::language(app));
    let window = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("whats_new.html".into()))
        .title(title)
        .inner_size(420.0, 440.0)
        .resizable(false)
        .maximizable(false)
        .minimizable(false)
        .center()
        .build()?;
    let handle = app.clone();
    window.on_window_event(move |event| {
        if matches!(event, tauri::WindowEvent::Destroyed)
            && SHOWING.swap(false, Ordering::AcqRel)
        {
            acknowledge(&handle, env!("CARGO_PKG_VERSION"));
            if first_launch {
                crate::settings_window::open(&handle);
            } else {
                crate::settings_window::apply_presence(&handle);
            }
        }
    });
    #[cfg(target_os = "macos")]
    let _ = app.set_activation_policy(tauri::ActivationPolicy::Regular);
    let _ = window.show();
    let _ = window.set_focus();
    Ok(())
}

fn title_for_lang(lang: &str) -> &'static str {
    match lang {
        "zh" => "新变化", "zh-Hant" => "新變化", "ja" => "新機能",
        "ko" => "새로운 기능", "pt-BR" => "Novidades", "ru" => "Что нового",
        "uk" => "Що нового", _ => "What's New",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_dismissal_acknowledges_an_available_note() {
        assert_eq!(decide(None, "0.1.0", true), Decision::Show);
        assert_eq!(decide(Some("0.0.9"), "0.1.0", true), Decision::Show);
        assert_eq!(decide(Some("0.1.0"), "0.1.0", true), Decision::AlreadySeen);
        assert_eq!(decide(None, "0.2.0", false), Decision::RecordWithoutWindow);
    }
}
