//! Only state transitions notify; repeated watcher snapshots never flood the desktop.
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, sync::Mutex};
use tauri::{AppHandle, Manager};
use tauri_plugin_notification::NotificationExt;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Preferences {
    pub attention: bool,
    pub done: bool,
}
#[derive(Default)]
struct Transitions(HashMap<String, String>);
impl Transitions {
    fn update(&mut self, snap: &crate::state::Snapshot, prefs: &Preferences) -> Vec<&'static str> {
        self.0
            .retain(|id, _| snap.sessions.iter().any(|s| &s.id == id));
        let mut messages = Vec::new();
        for session in &snap.sessions {
            let previous = self.0.insert(session.id.clone(), session.state.clone());
            if previous.as_deref() == Some(&session.state) {
                continue;
            }
            match session.state.as_str() {
                "attention" if prefs.attention => messages.push("attention"),
                "done" if prefs.done => messages.push("done"),
                _ => {}
            }
        }
        messages.sort_unstable();
        messages.dedup(); // one notification per transition kind per broadcast
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
        .update(snap, &prefs);
    for event in events {
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
                    done: true
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
                    attention: false
                }
            ),
            vec!["done"]
        );
        assert!(t
            .update(
                &snap,
                &Preferences {
                    done: true,
                    attention: true
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
                    done: true
                }
            )
            .is_empty());
        snap.sessions.clear();
        t.update(&snap, &Preferences::default());
        assert!(t.0.is_empty());
    }
}
