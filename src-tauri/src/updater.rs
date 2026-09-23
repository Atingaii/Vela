//! Keeping the Windows app up to date, the way Sparkle keeps the Mac one up to date.
//!
//! Until this existed there was no update path on Windows at all: someone who installed
//! `Velo-Setup.exe` stayed on that build for good, because nothing in the app ever
//! mentioned that a newer one had been cut. Every release reached them only if they
//! happened to look at the repository again.
//!
//! The feed is `latest.json` on the newest GitHub release, written by the Windows Package
//! workflow beside the installer it describes — the same `releases/latest/download/` URL the
//! README links to, so there is one place a release is published and one place it is read.
//!
//! What it does *not* do is nag. A check that fails — no network, a feed that has not been
//! written yet, a signature that does not verify — leaves the app exactly as it was and says
//! so only in the log. The Mac's updater was hanging on "Checking…" as recently as 1.14.0;
//! the lesson taken from that is that an update check is never worth blocking on.

use serde::Serialize;
use std::sync::{Mutex, MutexGuard};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_updater::UpdaterExt;

/// What the Settings page shows next to the version.
///
/// `checking` is deliberately not a state the page can get stuck in: every path that sets it
/// also sets something else before it returns.
#[derive(Clone, Serialize, Default)]
pub struct UpdateState {
    pub configured: bool,
    pub automatic: bool,
    /// The version on offer, when one is newer than this build.
    pub available: Option<String>,
    /// True only between a check starting and finishing.
    pub checking: bool,
    /// True while the download and install are running.
    pub installing: bool,
    /// Set when the last check or install failed, for the page to show quietly.
    pub message: Option<String>,
}

static STATE: Mutex<Option<UpdateState>> = Mutex::new(None);

/// Serializes preference changes with the final handoff to the platform installer. A check or
/// download never holds this lock. The epoch also rejects an old request after off -> on.
#[derive(Default)]
struct ConsentGate {
    epoch: u64,
}

impl ConsentGate {
    fn ticket(&self, enabled: bool) -> Option<u64> {
        enabled.then_some(self.epoch)
    }

    fn changed(&mut self, before: bool, after: bool) {
        if before != after {
            self.epoch = self.epoch.wrapping_add(1);
        }
    }

    fn permits(&self, ticket: u64, enabled: bool) -> bool {
        enabled && self.epoch == ticket
    }
}

static CONSENT: Mutex<ConsentGate> = Mutex::new(ConsentGate { epoch: 0 });

fn consent() -> MutexGuard<'static, ConsentGate> {
    CONSENT.lock().unwrap_or_else(|e| e.into_inner())
}

/// The status lock guards one small struct. Poisoning it would take the About pane down with
/// `unwrap`, which is a steep price for a version string, so take it back and carry on.
fn state() -> std::sync::MutexGuard<'static, Option<UpdateState>> {
    STATE.lock().unwrap_or_else(|e| e.into_inner())
}

fn set(app: &AppHandle, next: UpdateState) {
    let next = UpdateState {
        configured: configured(app),
        automatic: automatic(app),
        ..next
    };
    *state() = Some(next.clone());
    let _ = app.emit("update_state", &next);
}

fn begin(app: &AppHandle, checking: bool, from_check: bool, available: Option<String>) -> bool {
    let configured = configured(app);
    let automatic = automatic(app);
    let mut current = state();
    if current
        .as_ref()
        .is_some_and(|s| s.installing || (s.checking && !from_check))
    {
        return false;
    }
    let next = UpdateState {
        configured,
        automatic,
        checking,
        installing: !checking,
        available: available.or_else(|| current.as_ref().and_then(|s| s.available.clone())),
        message: None,
    };
    *current = Some(next.clone());
    drop(current);
    let _ = app.emit("update_state", &next);
    true
}

#[tauri::command]
pub fn get_update_state(app: AppHandle) -> UpdateState {
    let mut current = state().clone().unwrap_or_default();
    current.configured = configured(&app);
    current.automatic = automatic(&app);
    current
}

fn automatic(app: &AppHandle) -> bool {
    configured(app)
        && app
            .state::<crate::AppState>()
            .cfg
            .lock()
            .unwrap()
            .automatic_updates
}

#[tauri::command]
pub async fn set_automatic_updates(app: AppHandle, on: bool) -> Result<(), String> {
    ensure_preference_allowed(on, configured(&app))?;
    let mut gate = consent();
    let state = app.state::<crate::AppState>();
    let mut config = state.cfg.lock().unwrap();
    change_preference(&mut gate, &mut config, on, crate::config::save_checked)?;
    drop(config);
    drop(gate);
    let _ = app.emit("update_state", get_update_state(app.clone()));
    if on {
        check(app, true);
    }
    Ok(())
}

fn ensure_preference_allowed(on: bool, signed_feed: bool) -> Result<(), String> {
    if on && !signed_feed {
        Err("当前预览版尚未提供自动更新，请从官网下载新版。".into())
    } else {
        Ok(())
    }
}

fn change_preference(
    gate: &mut ConsentGate,
    config: &mut crate::config::Config,
    on: bool,
    save: impl FnOnce(&crate::config::Config) -> Result<(), String>,
) -> Result<(), String> {
    let before = config.automatic_updates;
    let mut next = config.clone();
    next.automatic_updates = on;
    // A failed disk write must not change either the live preference or the consent epoch.
    save(&next)?;
    *config = next;
    gate.changed(before, on);
    Ok(())
}

/// The placeholder that ships in `tauri.conf.json` until a signing key exists.
const UNSET_PUBKEY: &str = "REPLACE_WITH_TAURI_PUBLIC_KEY";

/// Whether a real signing key has been configured.
///
/// A build made before the key was generated would otherwise check a feed it can never
/// verify, and report a failure every time for a reason the user can do nothing about.
/// Silence is the right answer there.
fn configured(app: &AppHandle) -> bool {
    let Some(updater) = app.config().plugins.0.get("updater") else {
        return false;
    };
    let key = updater.get("pubkey").and_then(|v| v.as_str());
    let endpoints = updater.get("endpoints").and_then(|v| v.as_array());
    signed_feed_configured(key, endpoints)
}

fn signed_feed_configured(key: Option<&str>, endpoints: Option<&Vec<serde_json::Value>>) -> bool {
    key.is_some_and(|key| !key.trim().is_empty() && key.trim() != UNSET_PUBKEY)
        && endpoints.is_some_and(|urls| {
            !urls.is_empty()
                && urls
                    .iter()
                    .all(|url| url.as_str().is_some_and(|url| url.starts_with("https://")))
        })
}

/// Looks for a newer release. Answers immediately; the result arrives as `update_state`.
///
/// Called once a few seconds after launch, and again whenever someone opens Settings and
/// presses Check. Nothing here touches the notch.
#[tauri::command]
pub fn check_for_update(app: AppHandle) {
    check(app, false);
}

fn check(app: AppHandle, background: bool) {
    if !configured(&app) {
        return;
    }
    // A later opt-in cannot authorize a check that began while automatic updates were off.
    let ticket = if background {
        let gate = consent();
        gate.ticket(automatic(&app))
    } else {
        None
    };
    if background && ticket.is_none() {
        return;
    }
    if !begin(&app, true, false, None) {
        return;
    }
    std::thread::spawn(move || {
        if background
            && ticket.is_some_and(|ticket| {
                let gate = consent();
                !gate.permits(ticket, automatic(&app))
            })
        {
            set(&app, UpdateState::default());
            return;
        }
        let result = tauri::async_runtime::block_on(async { app.updater()?.check().await });
        match result {
            Ok(Some(update)) => {
                crate::applog(&format!("updater: {} is available", update.version));
                let available = Some(update.version.clone());
                let allowed = ticket.is_some_and(|ticket| {
                    let gate = consent();
                    gate.permits(ticket, automatic(&app))
                });
                if allowed && begin(&app, false, true, available.clone()) {
                    std::thread::spawn(move || run_install(app, update, ticket, available));
                } else {
                    set(
                        &app,
                        UpdateState {
                            available,
                            ..Default::default()
                        },
                    );
                }
            }
            Ok(None) => {
                crate::applog("updater: this is the newest release");
                set(&app, UpdateState::default());
            }
            // Never a dialogue and never a badge: a check that could not be made says nothing
            // about whether an update exists, and the app it is running in works perfectly well.
            Err(e) => {
                crate::applog(&format!("updater: check failed ({})", error_class(&e)));
                set(
                    &app,
                    UpdateState {
                        message: Some("Could not check for updates".into()),
                        ..Default::default()
                    },
                );
            }
        }
    });
}

/// Downloads the newer installer and runs it. The app is replaced and restarted by NSIS.
#[tauri::command]
pub fn install_update(app: AppHandle) {
    if !configured(&app) {
        return;
    }
    if !begin(&app, false, false, None) {
        return;
    }
    std::thread::spawn(move || {
        let result = tauri::async_runtime::block_on(async { app.updater()?.check().await });
        match result {
            Ok(Some(update)) => run_install(app, update, None, None),
            Ok(None) => set(&app, UpdateState::default()),
            Err(error) => install_failed(&app, error),
        }
    });
}

fn error_class(error: &tauri_plugin_updater::Error) -> &'static str {
    use tauri_plugin_updater::Error;
    match error {
        Error::Reqwest(_) | Error::Network(_) | Error::ReleaseNotFound => "network",
        Error::Minisign(_) | Error::Base64(_) | Error::SignatureUtf8(_) => "signature",
        Error::Io(_) => "filesystem",
        _ => "updater",
    }
}

fn install_failed(app: &AppHandle, error: tauri_plugin_updater::Error) {
    crate::applog(&format!(
        "updater: install failed ({})",
        error_class(&error)
    ));
    let available = state().as_ref().and_then(|s| s.available.clone());
    set(
        app,
        UpdateState {
            available,
            message: Some("Could not install the update".into()),
            ..Default::default()
        },
    );
}

fn run_install(
    app: AppHandle,
    update: tauri_plugin_updater::Update,
    ticket: Option<u64>,
    available: Option<String>,
) {
    // Tauri verifies the signature before download() returns. install() is a separate,
    // irreversible platform handoff, so an automatic job checks consent again at that edge.
    let bytes = tauri::async_runtime::block_on(update.download(|_, _| {}, || {}));
    let bytes = match bytes {
        Ok(bytes) => bytes,
        Err(error) => return install_failed(&app, error),
    };

    let gate = consent();
    if ticket.is_some_and(|ticket| !gate.permits(ticket, automatic(&app))) {
        drop(gate);
        set(
            &app,
            UpdateState {
                available,
                ..Default::default()
            },
        );
        return;
    }
    // Holding the same gate used by set_automatic_updates means a completed off request can
    // never be followed by this old job starting the installer. Once install() starts, the
    // platform installer itself cannot be cancelled.
    let result = update.install(bytes);
    drop(gate);
    match result {
        Ok(()) => {
            crate::applog("updater: platform installation returned successfully");
            set(
                &app,
                UpdateState {
                    message: Some("Update installed; restart the app to finish".into()),
                    ..Default::default()
                },
            );
        }
        Err(error) => install_failed(&app, error),
    }
}

/// One check shortly after launch.
///
/// Delayed rather than immediate: the first seconds belong to reading usage and drawing the
/// notch, and an update that has waited since the last release can wait twenty more seconds.
pub fn check_on_launch(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_secs(20));
        if automatic(&app) {
            check(app, true);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{mpsc, Arc, Mutex};
    use std::time::Duration;

    #[test]
    fn unsigned_or_missing_feed_cannot_enable_automatic_updates() {
        let url = serde_json::json!("https://example.test/latest.json");
        assert!(!signed_feed_configured(None, Some(&vec![url.clone()])));
        assert!(!signed_feed_configured(
            Some(UNSET_PUBKEY),
            Some(&vec![url.clone()])
        ));
        assert!(!signed_feed_configured(Some("signed-key"), None));
        assert!(!signed_feed_configured(Some("signed-key"), Some(&vec![])));
        assert!(!signed_feed_configured(
            Some("signed-key"),
            Some(&vec![serde_json::json!("http://example.test/latest.json")]),
        ));
        assert!(signed_feed_configured(Some("signed-key"), Some(&vec![url])));
        assert!(ensure_preference_allowed(true, false).is_err());
        assert!(ensure_preference_allowed(false, false).is_ok());
    }

    #[test]
    fn failed_save_keeps_live_preference_and_old_consent_ticket() {
        let mut gate = ConsentGate::default();
        let mut config = crate::config::Config {
            automatic_updates: true,
            ..Default::default()
        };
        let ticket = gate.ticket(config.automatic_updates).unwrap();
        let error = change_preference(&mut gate, &mut config, false, |_| Err("disk full".into()));
        assert_eq!(error, Err("disk full".into()));
        assert!(config.automatic_updates);
        assert!(gate.permits(ticket, config.automatic_updates));
        change_preference(&mut gate, &mut config, false, |_| Ok(())).unwrap();
        assert!(!config.automatic_updates);
        assert!(!gate.permits(ticket, config.automatic_updates));
    }

    #[test]
    fn an_old_download_cannot_install_after_off_then_on() {
        let mut gate = ConsentGate::default();
        let ticket = gate.ticket(true).unwrap();
        gate.changed(true, false);
        assert!(!gate.permits(ticket, false));
        gate.changed(false, true);
        assert!(!gate.permits(ticket, true));
        assert!(gate.permits(gate.ticket(true).unwrap(), true));
    }

    #[test]
    fn disabling_waits_for_install_handoff_and_prevents_a_later_one() {
        let gate = Arc::new(Mutex::new(ConsentGate::default()));
        let ticket = gate.lock().unwrap().ticket(true).unwrap();
        let (started_tx, started_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let installing = Arc::clone(&gate);
        let install = std::thread::spawn(move || {
            let guard = installing.lock().unwrap();
            assert!(guard.permits(ticket, true));
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            // This stands for the synchronous, irreversible install() handoff.
        });
        started_rx.recv().unwrap();
        let disabling = Arc::clone(&gate);
        let (attempt_tx, attempt_rx) = mpsc::channel();
        let (done_tx, done_rx) = mpsc::channel();
        let disable = std::thread::spawn(move || {
            attempt_tx.send(()).unwrap();
            let mut guard = disabling.lock().unwrap();
            guard.changed(true, false);
            done_tx.send(()).unwrap();
        });
        attempt_rx.recv().unwrap();
        assert!(done_rx.recv_timeout(Duration::from_millis(50)).is_err());
        release_tx.send(()).unwrap();
        install.join().unwrap();
        disable.join().unwrap();
        assert!(!gate.lock().unwrap().permits(ticket, true));
    }
}
