//! Only state transitions notify; repeated watcher snapshots never flood the desktop.
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeSet, HashMap},
    sync::Mutex,
};
use tauri::{AppHandle, Emitter, Listener, Manager};
use tauri_plugin_notification::NotificationExt;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Preferences {
    pub attention: bool,
    pub done: bool,
    pub announce_session_end: bool,
    pub peek_seconds: u32,
    pub session_sound: bool,
    pub finished_sound: String,
    pub blocked_sound: String,
    pub announce_reset: bool,
    pub reset_sound: bool,
    pub reset_sound_name: String,
    pub announce_session_limit: bool,
    pub announce_weekly_limit: bool,
    pub limit_sound: bool,
    pub limit_sound_name: String,
    pub muted_providers: BTreeSet<String>,
}
impl Default for Preferences {
    fn default() -> Self {
        let finished = if cfg!(windows) {
            "Windows Notify System Generic"
        } else {
            "Glass"
        };
        let blocked = if cfg!(windows) {
            "Windows Notify Messaging"
        } else {
            "Funk"
        };
        Self {
            attention: false,
            done: false,
            announce_session_end: true,
            peek_seconds: 5,
            session_sound: true,
            finished_sound: finished.into(),
            blocked_sound: blocked.into(),
            announce_reset: true,
            reset_sound: true,
            reset_sound_name: finished.into(),
            announce_session_limit: true,
            announce_weekly_limit: true,
            limit_sound: true,
            limit_sound_name: blocked.into(),
            muted_providers: BTreeSet::new(),
        }
    }
}
#[derive(Debug, PartialEq)]
struct Transition {
    kind: &'static str,
    session_id: String,
}
#[derive(Default)]
struct Transitions(HashMap<String, String>);
impl Transitions {
    fn update(&mut self, snap: &crate::state::Snapshot, prefs: &Preferences) -> Vec<Transition> {
        self.0
            .retain(|id, _| snap.sessions.iter().any(|s| &s.id == id));
        let mut messages = Vec::new();
        for session in &snap.sessions {
            let previous = self.0.insert(session.id.clone(), session.state.clone());
            // Only leaving a known busy session announces. Startup, idle→waiting and
            // sessions disappearing are silent, matching SessionCompletionWatcher.
            if previous.as_deref() != Some("running") {
                continue;
            }
            match session.state.as_str() {
                "attention" if prefs.attention => messages.push(Transition {
                    kind: "attention",
                    session_id: session.id.clone(),
                }),
                "done" | "idle" if prefs.done => messages.push(Transition {
                    kind: "done",
                    session_id: session.id.clone(),
                }),
                _ => {}
            }
        }
        messages
    }
}
static SEEN: Mutex<Option<Transitions>> = Mutex::new(None);

pub fn observe(app: &AppHandle, snap: &crate::state::Snapshot) {
    let prefs = app
        .state::<crate::AppState>()
        .cfg
        .lock()
        .unwrap()
        .notifications
        .clone();
    let events = SEEN
        .lock()
        .unwrap()
        .get_or_insert_with(Transitions::default)
        .update(
            snap,
            &Preferences {
                attention: true,
                done: true,
                ..prefs.clone()
            },
        );
    let mut notified = BTreeSet::new();
    for transition in events {
        let event = transition.kind;
        if prefs.announce_session_end || prefs.session_sound {
            if prefs.announce_session_end {
                send_peek(
                    app,
                    "claude",
                    event,
                    "",
                    prefs.peek_seconds,
                    Some(transition.session_id),
                );
            }
            if prefs.session_sound {
                let _ = crate::chime::play(if event == "attention" {
                    &prefs.blocked_sound
                } else {
                    &prefs.finished_sound
                });
            }
        }
        if !(if event == "attention" {
            prefs.attention
        } else {
            prefs.done
        }) || !notified.insert(event)
        {
            continue;
        }

        // Do not put prompts, paths, or session titles onto the OS lock screen.
        let chinese = snap.lang_resolved.starts_with("zh");
        let body = match (event, chinese) {
            ("attention", true) => "有会话正在等待你的回应。",
            ("done", true) => "任务已完成，打开 Vela 查看会话。",
            ("attention", false) => "A session is waiting for your response.",
            _ => "A task finished. Open Vela to return to the session.",
        };
        if let Err(e) = app.notification().builder().title("Vela").body(body).show() {
            crate::applog(&format!("Notification failed: {e}"));
        }
    }
}
#[tauri::command]
pub fn get_notifications(state: tauri::State<crate::AppState>) -> Preferences {
    state.cfg.lock().unwrap().notifications.clone()
}
#[tauri::command]
pub fn set_notifications(app: AppHandle, prefs: Preferences) -> Result<Preferences, String> {
    if ![3, 5, 10].contains(&prefs.peek_seconds)
        || prefs.muted_providers.len() > 256
        || [
            &prefs.finished_sound,
            &prefs.blocked_sound,
            &prefs.reset_sound_name,
            &prefs.limit_sound_name,
        ]
        .iter()
        .any(|s| s.len() > 200)
    {
        return Err("通知设置无效".into());
    }
    if prefs.attention || prefs.done {
        use tauri_plugin_notification::PermissionState;
        let permission = app
            .notification()
            .request_permission()
            .map_err(|e| e.to_string())?;
        if permission != PermissionState::Granted {
            return Err("请先在系统设置中允许 Vela 发送通知。".into());
        }
    }
    let state = app.state::<crate::AppState>();
    let mut cfg = state.cfg.lock().unwrap();
    let mut next = cfg.clone();
    next.notifications = prefs.clone();
    crate::config::save_checked(&next)?;
    *cfg = next;
    Ok(prefs)
}
#[derive(Clone, Serialize)]
struct Peek {
    provider: String,
    kind: String,
    label: String,
    seconds: u32,
    session_id: Option<String>,
}
fn send_peek(
    app: &AppHandle,
    provider: &str,
    kind: &str,
    label: &str,
    seconds: u32,
    session_id: Option<String>,
) {
    let _ = app.emit(
        "notch_alert",
        Peek {
            provider: provider.into(),
            kind: kind.into(),
            label: label.into(),
            seconds,
            session_id,
        },
    );
}
#[tauri::command]
pub fn preview_notch_alert(app: AppHandle, kind: String) -> Result<(), String> {
    if !["reset", "sessionLimitReached", "weeklyLimitReached"].contains(&kind.as_str()) {
        return Err("未知提醒类型".into());
    }
    let seconds = app
        .state::<crate::AppState>()
        .cfg
        .lock()
        .unwrap()
        .notifications
        .peek_seconds;
    send_peek(&app, "claude", &kind, "Claude", seconds, None);
    Ok(())
}
pub fn start(app: AppHandle) {
    // Events only wake one coalescing worker; snapshots stay cached and never force HTTP.
    let (tx, rx) = std::sync::mpsc::sync_channel::<()>(1);
    for event in [
        "usage",
        "codex",
        "cursor",
        "grok",
        "antigravity",
        "glm",
        "providers",
        "appearance",
    ] {
        let tx = tx.clone();
        app.listen(event, move |_| {
            let _ = tx.try_send(());
        });
    }
    std::thread::spawn(move || {
        crate::activity::lower_thread_priority();
        let mut watcher = crate::usage_alerts::Watcher::default();
        let mut daily_mode = None;
        while rx.recv().is_ok() {
            let cfg = app.state::<crate::AppState>().cfg.lock().unwrap().clone();
            if daily_mode != Some(cfg.appearance.claude_daily_pace) {
                watcher = crate::usage_alerts::Watcher::default();
                daily_mode = Some(cfg.appearance.claude_daily_pace);
            }
            for option in crate::get_tray_options(app.clone()) {
                if !crate::providers::enabled(&app, &option.id) {
                    continue;
                }
                let snap = crate::snapshot_of(&app, &option.id);
                if snap.status != "ok" {
                    continue;
                }
                let head = crate::ring_window(
                    &option.id,
                    &snap.windows,
                    &cfg.antigravity_limit,
                    &cfg.antigravity_model,
                );
                let weekly = snap
                    .windows
                    .iter()
                    .find(|w| match option.id.as_str() {
                        id if crate::pace::claude(id) => {
                            if head.is_some_and(|h| h.id == crate::pace::DAILY_ID) {
                                w.id == "session"
                            } else {
                                matches!(w.id.as_str(), "weekly_all" | "seven_day" | "weekly")
                            }
                        }
                        "codex" => w.id == "secondary",
                        _ => w.id == "weekly_all" || w.id == "weekly" || w.id == "secondary",
                    })
                    .filter(|w| head.is_none_or(|h| h.id != w.id));
                for (window, is_weekly) in [(head, false), (weekly, true)] {
                    let Some(window) = window else { continue };
                    for e in watcher.observe(
                        &option.id,
                        window,
                        is_weekly,
                        crate::now_ms(),
                        cfg.notifications.muted_providers.contains(&option.id),
                    ) {
                        use crate::usage_alerts::Kind;
                        let p = &cfg.notifications;
                        let (enabled, kind, sound, name) = match e.kind {
                            Kind::Reset => (
                                p.announce_reset,
                                "reset",
                                p.reset_sound,
                                &p.reset_sound_name,
                            ),
                            Kind::SessionLimitReached => (
                                p.announce_session_limit,
                                "sessionLimitReached",
                                p.limit_sound,
                                &p.limit_sound_name,
                            ),
                            Kind::WeeklyLimitReached => (
                                p.announce_weekly_limit,
                                "weeklyLimitReached",
                                p.limit_sound,
                                &p.limit_sound_name,
                            ),
                            Kind::Threshold => {
                                let chinese = crate::resolved_lang(&cfg.lang).starts_with("zh");
                                let message = if chinese {
                                    format!(
                                        "{} · {} 已使用 {:.0}%",
                                        option.label,
                                        e.label,
                                        e.fraction * 100.
                                    )
                                } else {
                                    format!(
                                        "{} · {}: {:.0}% used",
                                        option.label,
                                        e.label,
                                        e.fraction * 100.
                                    )
                                };
                                let _ = app
                                    .notification()
                                    .builder()
                                    .title("Vela")
                                    .body(message)
                                    .show();
                                continue;
                            }
                        };
                        if enabled {
                            send_peek(&app, &option.id, kind, &e.label, p.peek_seconds, None);
                        }
                        if enabled && sound {
                            let _ = crate::chime::play(name);
                        }
                    }
                }
            }
            // A burst of provider events costs one cached pass every half second at most.
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
    });
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn repeated_snapshots_and_disabled_notifications_are_silent() {
        let mut store = crate::state::Store::default();
        let mut t = Transitions::default();
        let snap = store.snapshot("en", "en", true, false);
        assert!(t
            .update(
                &snap,
                &Preferences {
                    attention: true,
                    done: true,
                    ..Default::default()
                }
            )
            .is_empty());
        // Test transitions with a serialized session shape built explicitly in fixtures below.
        let session = crate::state::Session {
            id: "test".into(),
            title: "private".into(),
            state: "done".into(),
            started: 0,
            total: 0,
            last: String::new(),
            attn: String::new(),
            prompt: String::new(),
            model: String::new(),
            ppid: 0,
            last_event: 0,
            cwd: String::new(),
            last_hook: 0,
        };
        let mut snap = snap;
        snap.sessions.push(session);
        assert_eq!(
            t.update(
                &snap,
                &Preferences {
                    done: true,
                    attention: false,
                    ..Default::default()
                }
            ),
            Vec::<Transition>::new()
        );
        assert!(t
            .update(
                &snap,
                &Preferences {
                    done: true,
                    attention: true,
                    ..Default::default()
                }
            )
            .is_empty());
        snap.sessions[0].state = "running".into();
        t.update(&snap, &Preferences::default());
        snap.sessions[0].state = "attention".into();
        assert!(t.update(&snap, &Preferences::default()).is_empty());
        assert!(t
            .update(
                &snap,
                &Preferences {
                    attention: true,
                    done: true,
                    ..Default::default()
                }
            )
            .is_empty());
        snap.sessions[0].state = "running".into();
        t.update(&snap, &Preferences::default());
        // A newer idle session must not steal the completed session's click target.
        let mut other = snap.sessions[0].clone();
        other.id = "newer".into();
        other.started = 10;
        other.state = "idle".into();
        snap.sessions.push(other);
        snap.sessions[0].state = "done".into();
        let enabled = Preferences {
            done: true,
            attention: true,
            ..Default::default()
        };
        assert_eq!(
            t.update(&snap, &enabled),
            vec![Transition {
                kind: "done",
                session_id: "test".into()
            }]
        );
        assert!(t.update(&snap, &enabled).is_empty());
        snap.sessions.clear();
        t.update(&snap, &Preferences::default());
        assert!(t.0.is_empty());
    }
}
