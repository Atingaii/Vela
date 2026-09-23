//! Signed preview updates, matching Sparkle's silent check and relaunch handoff.
//!
//! Tauri's Windows installer exits the running app immediately. Automatic checks therefore
//! download and verify only; a later launch verifies the cache and current signed feed again
//! before handing it to the platform installer. Manual Install is an explicit immediate handoff.

use serde::Serialize;
use std::sync::{atomic::{AtomicU64, Ordering}, Mutex, MutexGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_updater::UpdaterExt;

const CHECK_TIMEOUT: Duration = Duration::from_secs(45);
const STARTUP_CHECK_TIMEOUT: Duration = Duration::from_secs(3);
const AUTOMATIC_INTERVAL: Duration = Duration::from_secs(24 * 60 * 60);

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
    /// A signed automatic download will be applied at the next launch.
    pub staged: Option<String>,
    pub up_to_date: bool,
    pub last_checked_ms: Option<u64>,
    /// Set when the last check or install failed, for the page to show quietly.
    pub message: Option<String>,
}

static STATE: Mutex<Option<UpdateState>> = Mutex::new(None);
static REQUEST: AtomicU64 = AtomicU64::new(0);

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
    let last_checked_ms = app.state::<crate::AppState>().cfg.lock().unwrap().last_update_check_ms;
    let next = UpdateState {
        configured: configured(app),
        automatic: automatic(app),
        last_checked_ms,
        ..next
    };
    *state() = Some(next.clone());
    let _ = app.emit("update_state", &next);
}

fn set_for(app: &AppHandle, request: u64, next: UpdateState) {
    let configured = configured(app);
    let (enabled, last_checked_ms) = {
        let app_state = app.state::<crate::AppState>();
        let config = app_state.cfg.lock().unwrap();
        (config.automatic_updates, config.last_update_check_ms)
    };
    let next = UpdateState {
        configured,
        automatic: configured && enabled,
        last_checked_ms,
        ..next
    };
    let mut status = state();
    if !current(request) { return; }
    *status = Some(next.clone());
    drop(status);
    if current(request) {
        let _ = app.emit("update_state", &next);
    }
}

fn current(request: u64) -> bool {
    REQUEST.load(Ordering::Acquire) == request
}

fn clear_for(request: u64) {
    let _gate = consent();
    if current(request) {
        crate::updater_stage::clear();
    }
}

fn begin(app: &AppHandle, checking: bool, expected: Option<u64>, available: Option<String>) -> Option<u64> {
    let configured = configured(app);
    let automatic = automatic(app);
    let mut current = state();
    if expected.is_some_and(|id| !self::current(id))
        || current
            .as_ref()
            .is_some_and(|s| s.installing || (s.checking && expected.is_none()))
    {
        return None;
    }
    let next = UpdateState {
        configured,
        automatic,
        checking,
        installing: !checking,
        available: available.or_else(|| current.as_ref().and_then(|s| s.available.clone())),
        staged: current.as_ref().and_then(|s| s.staged.clone()),
        up_to_date: false,
        last_checked_ms: current.as_ref().and_then(|s| s.last_checked_ms),
        message: None,
    };
    *current = Some(next.clone());
    let request = if let Some(expected) = expected {
        expected
    } else {
        REQUEST.fetch_add(1, Ordering::AcqRel).wrapping_add(1)
    };
    drop(current);
    let _ = app.emit("update_state", &next);
    Some(request)
}

#[tauri::command]
pub fn get_update_state(app: AppHandle) -> UpdateState {
    let mut current = state().clone().unwrap_or_default();
    current.configured = configured(&app);
    let (enabled, generation, last_checked_ms) = {
        let app_state = app.state::<crate::AppState>();
        let config = app_state.cfg.lock().unwrap();
        (config.automatic_updates, config.automatic_updates_generation, config.last_update_check_ms)
    };
    current.automatic = current.configured && enabled;
    current.last_checked_ms = last_checked_ms;
    if current.staged.is_none() && current.automatic {
        current.staged = crate::updater_stage::read()
            .filter(|stage| stage.consent_generation == generation)
            .map(|stage| stage.version);
    }
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
    if !on {
        crate::updater_stage::clear();
    }
    drop(gate);
    REQUEST.fetch_add(1, Ordering::AcqRel);
    set(&app, UpdateState::default());
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
    if before != on {
        next.automatic_updates_generation = next.automatic_updates_generation.wrapping_add(1);
    }
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

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn record_check(app: &AppHandle) {
    let state = app.state::<crate::AppState>();
    let mut config = state.cfg.lock().unwrap();
    let mut next = config.clone();
    next.last_update_check_ms = Some(now_ms());
    if crate::config::save_checked(&next).is_ok() {
        *config = next;
    }
}

fn bounded_check_with_timeout(app: &AppHandle, timeout: Duration) -> Result<Option<tauri_plugin_updater::Update>, String> {
    let updater = app.updater_builder()
        .timeout(timeout)
        .build()
        .map_err(|error| error.to_string())?;
    tauri::async_runtime::block_on(async {
        tokio::time::timeout(timeout, updater.check())
            .await
            .map_err(|_| "The update check timed out".to_string())?
            .map_err(|error| error.to_string())
    })
}

fn bounded_check(app: &AppHandle) -> Result<Option<tauri_plugin_updater::Update>, String> {
    bounded_check_with_timeout(app, CHECK_TIMEOUT)
}

fn bounded_download(app: &AppHandle, update: &tauri_plugin_updater::Update) -> Result<Vec<u8>, String> {
    crate::updater_stage::download_verified(app, update)
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
    let (ticket, generation) = if background {
        let gate = consent();
        let app_state = app.state::<crate::AppState>();
        let config = app_state.cfg.lock().unwrap();
        (gate.ticket(config.automatic_updates && configured(&app)), Some(config.automatic_updates_generation))
    } else {
        (None, None)
    };
    if background && ticket.is_none() {
        return;
    }
    let Some(request) = begin(&app, true, None, None) else { return; };
    std::thread::spawn(move || {
        if background
            && ticket.is_some_and(|ticket| {
                let gate = consent();
                !gate.permits(ticket, automatic(&app))
            })
        {
            set_for(&app, request, UpdateState::default());
            return;
        }
        let result = bounded_check(&app);
        if !current(request) { return; }
        record_check(&app);
        match result {
            Ok(Some(update)) => {
                crate::applog(&format!("updater: {} is available", update.version));
                let available = Some(update.version.clone());
                let allowed = ticket.is_some_and(|ticket| {
                    let gate = consent();
                    gate.permits(ticket, automatic(&app))
                });
                if allowed && begin(&app, false, Some(request), available.clone()).is_some() {
                    std::thread::spawn(move || run_stage(app, update, ticket.unwrap(), generation.unwrap(), request));
                } else {
                    set_for(
                        &app,
                        request,
                        UpdateState {
                            available,
                            ..Default::default()
                        },
                    );
                }
            }
            Ok(None) => {
                crate::applog("updater: this is the newest release");
                clear_for(request);
                set_for(&app, request, UpdateState { up_to_date: true, ..Default::default() });
            }
            // Never a dialogue and never a badge: a check that could not be made says nothing
            // about whether an update exists, and the app it is running in works perfectly well.
            Err(error) => {
                crate::applog(&format!("updater: check failed ({error})"));
                set_for(
                    &app,
                    request,
                    UpdateState {
                        message: Some(if error.contains("timed out") {
                            "The update check did not finish. Try again later.".into()
                        } else {
                            "Could not reach the update server. Velo will try again later.".into()
                        }),
                        ..Default::default()
                    },
                );
            }
        }
    });
}

/// A requested manual installation is an explicit platform handoff. On Windows NSIS exits the
/// app; automatic checks never take this path.
#[tauri::command]
pub fn install_update(app: AppHandle) {
    if !configured(&app) {
        return;
    }
    let Some(request) = begin(&app, false, None, None) else { return; };
    std::thread::spawn(move || {
        let result = bounded_check(&app);
        if !current(request) { return; }
        record_check(&app);
        match result {
            Ok(Some(update)) => run_install(app, update, request),
            Ok(None) => set_for(&app, request, UpdateState { up_to_date: true, ..Default::default() }),
            Err(error) => install_failed(&app, request, error),
        }
    });
}

fn install_failed(app: &AppHandle, request: u64, error: String) {
    if !current(request) { return; }
    crate::applog(&format!("updater: install failed ({error})"));
    let available = state().as_ref().and_then(|s| s.available.clone());
    set_for(
        app,
        request,
        UpdateState {
            available,
            message: Some("Could not install the update".into()),
            ..Default::default()
        },
    );
}

fn run_install(app: AppHandle, update: tauri_plugin_updater::Update, request: u64) {
    // The plugin verifies the package signature and its signed version before returning bytes.
    let bytes = match bounded_download(&app, &update) {
        Ok(bytes) => bytes,
        Err(error) => return install_failed(&app, request, error),
    };
    if !current(request) { return; }
    if bytes.is_empty() || bytes.len() > crate::updater_stage::MAX_PACKAGE_BYTES {
        install_failed(&app, request, "Invalid updater package size".into());
        return;
    }
    let result = update.install(bytes);
    match result {
        Ok(()) => {
            crate::applog("updater: explicit platform installation handed off");
            set_for(
                &app,
                request,
                UpdateState {
                    message: Some("Update handed to the platform installer.".into()),
                    ..Default::default()
                },
            );
            #[cfg(target_os = "macos")]
            app.restart();
        }
        Err(error) => install_failed(&app, request, error.to_string()),
    }
}

fn run_stage(
    app: AppHandle,
    update: tauri_plugin_updater::Update,
    ticket: u64,
    generation: u64,
    request: u64,
) {
    let bytes = match bounded_download(&app, &update) {
        Ok(bytes) => bytes,
        Err(error) => return install_failed(&app, request, error),
    };
    if !current(request) { return; }
    let mut stage = crate::updater_stage::Stage {
        version: update.version.clone(),
        signature: update.signature.clone(),
        url: update.download_url.to_string(),
        target: update.target.clone(),
        consent_generation: generation,
        sha256: String::new(),
        filename: String::new(),
    };
    // The gate serializes the final cache commit with a saved preference change. A disable
    // request that wins first rejects this download; one that wins later removes the cache.
    let gate = consent();
    let app_state = app.state::<crate::AppState>();
    let current = app_state.cfg.lock().unwrap();
    if !self::current(request)
        || !gate.permits(ticket, current.automatic_updates)
        || current.automatic_updates_generation != generation
    {
        return;
    }
    let result = crate::updater_stage::write_in(&crate::updater_stage::directory(), &mut stage, &bytes);
    drop(current);
    drop(gate);
    match result {
        Ok(()) => {
            crate::applog(&format!("updater: signed {} staged for next launch", stage.version));
            set_for(&app, request, UpdateState {
                available: Some(stage.version.clone()),
                staged: Some(stage.version),
                message: Some("Update downloaded and will install when Velo next launches.".into()),
                ..Default::default()
            });
        }
        Err(error) => install_failed(&app, request, error),
    }
}

fn resume_startup(app: AppHandle, port: u16, first_launch: bool) {
    if crate::smoke::update_verification() {
        crate::smoke::update_report(&app, false, "install", "Platform updater did not complete");
        return;
    }
    let handle = app.clone();
    let queued = app.run_on_main_thread(move || {
        if let Err(error) = crate::finish_setup(handle, port, first_launch) {
            crate::applog(&format!("updater: could not resume startup ({error})"));
        }
    });
    if let Err(error) = queued {
        crate::applog(&format!("updater: could not schedule normal startup ({error})"));
    }
}

/// Called before any application window, collector, or login flow starts. A writable cache is
/// only a transport: compare it with today's offered release, then re-verify minisign and the
/// signed version before Tauri gets the bytes. Network failure leaves the cache for a later boot.
/// Returns true only when an installer worker owns startup and will resume normal setup on
/// failure. This keeps every collector and login flow stopped until the relaunch handoff ends.
pub fn apply_staged_on_launch(app: &AppHandle, port: u16, first_launch: bool) -> bool {
    let Some(stage) = crate::updater_stage::read() else { return false; };
    let (enabled, generation) = {
        let app_state = app.state::<crate::AppState>();
        let config = app_state.cfg.lock().unwrap();
        (config.automatic_updates, config.automatic_updates_generation)
    };
    if !configured(app) || !enabled || stage.consent_generation != generation {
        crate::updater_stage::clear();
        return false;
    }
    if semver::Version::parse(&stage.version)
        .is_ok_and(|staged| staged <= app.package_info().version)
    {
        crate::updater_stage::clear();
        return false;
    }
    let timeout = if crate::smoke::update_verification() { CHECK_TIMEOUT } else { STARTUP_CHECK_TIMEOUT };
    let update = match bounded_check_with_timeout(app, timeout) {
        Ok(Some(update)) => update,
        Ok(None) => {
            crate::updater_stage::clear();
            return false;
        }
        Err(error) => {
            crate::applog(&format!("updater: staged check deferred ({error})"));
            return false;
        }
    };
    if stage.version != update.version
        || stage.signature != update.signature
        || stage.url != update.download_url.as_str()
        || stage.target != update.target
    {
        crate::updater_stage::clear();
        return false;
    }
    let Some(pubkey) = app.config().plugins.0.get("updater")
        .and_then(|value| value.get("pubkey"))
        .and_then(|value| value.as_str()) else { return false; };
    let bytes = match crate::updater_stage::read_verified_in(
        &crate::updater_stage::directory(), &stage, pubkey,
    ) {
        Ok(bytes) => bytes,
        Err(error) => {
            crate::applog(&format!("updater: rejected staged package ({error})"));
            crate::updater_stage::clear();
            return false;
        }
    };
    #[cfg(target_os = "macos")]
    if !silent_install_writable() {
        set(app, UpdateState {
            available: Some(stage.version.clone()),
            staged: Some(stage.version),
            message: Some("This copy cannot be updated silently. Install Velo in a writable Applications folder or choose Install.".into()),
            ..Default::default()
        });
        return false;
    }
    let gate = consent();
    let still_permitted = {
        let app_state = app.state::<crate::AppState>();
        let config = app_state.cfg.lock().unwrap();
        config.automatic_updates && config.automatic_updates_generation == stage.consent_generation
    };
    if still_permitted {
        // On macOS the plugin's permission escalation dispatches to the main thread. Do not
        // invoke install() from setup's main thread, where that branch would deadlock. The
        // event loop has begun by the time this worker reaches the handoff.
        let app = app.clone();
        std::thread::spawn(move || {
            let gate = consent();
            let permitted = {
                let app_state = app.state::<crate::AppState>();
                let config = app_state.cfg.lock().unwrap();
                config.automatic_updates && config.automatic_updates_generation == stage.consent_generation
            };
            if !permitted {
                resume_startup(app, port, first_launch);
                return;
            }
            let result = update.install(bytes);
            drop(gate);
            match result {
                Ok(()) => {
                    crate::applog("updater: staged platform installation handed off");
                    crate::updater_stage::clear();
                    #[cfg(target_os = "macos")]
                    app.restart();
                }
                Err(error) => {
                    crate::applog(&format!("updater: staged install failed ({error})"));
                    resume_startup(app, port, first_launch);
                }
            }
        });
        drop(gate);
        true
    } else {
        drop(gate);
        false
    }
}

/// Explicit verification mode for a disposable installation only. It uses the production
/// feed, bounded download, signature rule, and stage writer; normal app setup never runs.
pub fn start_update_verification(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        let result = (|| -> Result<String, String> {
            if !configured(&app) { return Err("Signed updater feed is not configured".into()); }
            let update = bounded_check(&app)?.ok_or("The feed offered no newer version")?;
            if crate::smoke::update_expected() != Some(update.version.as_str()) {
                return Err("The feed offered an unexpected version".into());
            }
            let bytes = bounded_download(&app, &update)?;
            let generation = app.state::<crate::AppState>().cfg.lock().unwrap().automatic_updates_generation;
            let mut stage = crate::updater_stage::Stage {
                version: update.version.clone(),
                signature: update.signature.clone(),
                url: update.download_url.to_string(),
                target: update.target.clone(),
                consent_generation: generation,
                sha256: String::new(),
                filename: String::new(),
            };
            crate::updater_stage::write_in(&crate::updater_stage::directory(), &mut stage, &bytes)?;
            let root = crate::smoke::root().ok_or("Missing isolated update root")?;
            let marker = serde_json::json!({
                "from":env!("CARGO_PKG_VERSION"),"to":update.version,"sha256":stage.sha256,
            });
            std::fs::write(root.join("update-staged.json"), marker.to_string())
                .map_err(|e| e.to_string())?;
            Ok(stage.version)
        })();
        match result {
            Ok(version) => crate::smoke::update_report(&app, true, "staged", &version),
            Err(error) => {
                crate::applog(&format!("updater: isolated verification failed ({error})"));
                crate::smoke::update_report(&app, false, "staged", &error);
            }
        }
    });
}

/// Sparkle defaults to automatic daily checks. The first one waits for the initial UI and
/// collectors; subsequent checks continue while the app is running instead of stopping at boot.
pub fn check_on_launch(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        let last = app.state::<crate::AppState>().cfg.lock().unwrap().last_update_check_ms;
        std::thread::sleep(next_check_delay(now_ms(), last));
        loop {
            if automatic(&app) {
                check(app.clone(), true);
            }
            std::thread::sleep(AUTOMATIC_INTERVAL);
        }
    });
}

fn next_check_delay(now: u64, last: Option<u64>) -> Duration {
    let interval_ms = AUTOMATIC_INTERVAL.as_millis() as u64;
    match last {
        None => Duration::from_secs(20),
        Some(last) if now < last => AUTOMATIC_INTERVAL,
        Some(last) => Duration::from_millis(interval_ms.saturating_sub(now - last))
            .max(Duration::from_secs(20)),
    }
}

#[cfg(target_os = "macos")]
fn silent_install_writable() -> bool {
    use std::os::unix::fs::MetadataExt;
    let Ok(executable) = std::env::current_exe() else { return false; };
    let Some(bundle) = executable.ancestors().find(|part| part.extension().is_some_and(|ext| ext == "app")) else {
        return false;
    };
    let Some(parent) = bundle.parent() else { return false; };
    let Ok(metadata) = std::fs::metadata(bundle) else { return false; };
    // This is intentionally conservative. The plugin otherwise falls back to an admin
    // AppleScript prompt, which is inappropriate for a silent automatic relaunch.
    metadata.uid() == unsafe { libc::geteuid() }
        && tempfile::NamedTempFile::new_in(parent).is_ok()
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
        assert_eq!(config.automatic_updates_generation, 0);
        assert!(gate.permits(ticket, config.automatic_updates));
        change_preference(&mut gate, &mut config, false, |_| Ok(())).unwrap();
        assert!(!config.automatic_updates);
        assert_eq!(config.automatic_updates_generation, 1);
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

    #[test]
    fn automatic_schedule_remembers_last_check_across_restarts_and_clock_changes() {
        let day = AUTOMATIC_INTERVAL.as_millis() as u64;
        assert_eq!(next_check_delay(1_000, None), Duration::from_secs(20));
        assert_eq!(next_check_delay(1_000 + day / 4, Some(1_000)), Duration::from_millis(day * 3 / 4));
        assert_eq!(next_check_delay(1_000 + day, Some(1_000)), Duration::from_secs(20));
        assert_eq!(next_check_delay(900, Some(1_000)), AUTOMATIC_INTERVAL);
    }

    #[test]
    fn old_result_cannot_own_a_new_request() {
        let active = AtomicU64::new(1);
        let old = active.load(Ordering::Acquire);
        let new = active.fetch_add(1, Ordering::AcqRel) + 1;
        assert_ne!(active.load(Ordering::Acquire), old);
        assert_eq!(active.load(Ordering::Acquire), new);
    }
}
