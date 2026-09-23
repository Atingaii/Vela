//! An explicit, provider-owned browser login. The remote page has no Tauri
//! capability; its credentials stay in its isolated native WebView data store.
//! Only bounded numeric usage JSON and a token *digest* cross into Rust.

use crate::usage::{Fidelity, LimitWindow, MoneyBreakdown, UsageSnapshot};
use crate::web_sites::{self, Site};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::sync::{mpsc, Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager, Url, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

const MAX_RESULT_BYTES: usize = 4 * 1024 * 1024;
const EVAL_TIMEOUT: Duration = Duration::from_secs(8);
const PAGE_TIMEOUT: Duration = Duration::from_secs(10);
const SCRIPT_TIMEOUT: Duration = Duration::from_secs(25);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WebSessionError {
    Unavailable,
    NeedsAuth,
    Busy,
    Temporary,
    Invalid,
    BadStatus(u16),
}

impl std::fmt::Display for WebSessionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable => write!(f, "A private browser profile is unavailable on this OS"),
            Self::NeedsAuth => write!(f, "Sign in to this provider in Velo"),
            Self::Busy => write!(f, "The sign-in window is open"),
            Self::Temporary => write!(f, "The provider page did not finish loading"),
            Self::Invalid => write!(f, "The provider returned unreadable usage"),
            Self::BadStatus(code) => write!(f, "The provider returned HTTP {code}"),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct AuthenticationGate {
    baseline_fingerprint: Option<String>,
    saw_logout: bool,
    requires_new_fingerprint: bool,
    unauthenticated_samples: u8,
}

impl AuthenticationGate {
    fn new(baseline_fingerprint: Option<String>, switching: bool) -> Self {
        Self {
            baseline_fingerprint,
            requires_new_fingerprint: switching,
            ..Self::default()
        }
    }

    fn observe(&mut self, authenticated: bool, fingerprint: Option<&str>) -> bool {
        if !authenticated {
            self.unauthenticated_samples = self.unauthenticated_samples.saturating_add(1);
            if self.unauthenticated_samples >= if self.requires_new_fingerprint { 2 } else { 1 } {
                self.saw_logout = true;
            }
            return false;
        }
        self.unauthenticated_samples = 0;
        if !self.saw_logout {
            if self.baseline_fingerprint.is_none() {
                self.baseline_fingerprint = fingerprint.map(str::to_string);
            }
            return false;
        }
        self.fingerprint_changed(fingerprint)
    }

    fn accepts_on_close(&self, authenticated: bool, fingerprint: Option<&str>) -> bool {
        authenticated && self.fingerprint_changed(fingerprint)
    }

    fn fingerprint_changed(&self, fingerprint: Option<&str>) -> bool {
        !self.requires_new_fingerprint
            || self.baseline_fingerprint.is_none()
            || fingerprint.is_none()
            || self.baseline_fingerprint.as_deref() != fingerprint
    }
}

#[derive(Clone, Debug, Deserialize)]
struct AuthenticationState {
    authenticated: bool,
    fingerprint: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
struct PageResponse {
    status: u16,
    body: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct WebSessionState {
    pub id: String,
    pub supported: bool,
    pub signed_in: bool,
    pub sign_in_open: bool,
    pub reason: Option<&'static str>,
}

#[derive(Default)]
struct Session {
    window: Option<WebviewWindow>,
    site: Option<Site>,
    origin: String,
    loaded: bool,
    sign_in_open: bool,
    switching: bool,
    cleaning: bool,
    cleanup_started: bool,
    gate: Option<AuthenticationGate>,
    last_fingerprint: Option<String>,
    last_probed_url: Option<String>,
    epoch: u64,
}

static SESSIONS: OnceLock<Mutex<HashMap<String, Session>>> = OnceLock::new();
static STORE_LOCK: Mutex<()> = Mutex::new(());
static WINDOW_CREATE_LOCK: Mutex<()> = Mutex::new(());
static OPEN_LOCK: Mutex<()> = Mutex::new(());
static NONCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

fn sessions() -> &'static Mutex<HashMap<String, Session>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn state_path() -> std::path::PathBuf {
    crate::config::config_path().with_file_name("web-sessions.json")
}

fn read_flags() -> BTreeMap<String, bool> {
    std::fs::read_to_string(state_path())
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default()
}

fn write_signed_in_at(
    path: &std::path::Path,
    id: &str,
    value: bool,
) -> Result<(), WebSessionError> {
    let _guard = STORE_LOCK.lock().unwrap();
    let mut flags: BTreeMap<String, bool> = std::fs::read_to_string(path)
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default();
    flags.insert(id.into(), value);
    let parent = path.parent().ok_or(WebSessionError::Temporary)?;
    std::fs::create_dir_all(parent).map_err(|_| WebSessionError::Temporary)?;
    let temp = path.with_extension(format!("json.{}.tmp", std::process::id()));
    let bytes = serde_json::to_vec(&flags).map_err(|_| WebSessionError::Temporary)?;
    std::fs::write(&temp, bytes).map_err(|_| WebSessionError::Temporary)?;
    std::fs::rename(&temp, path).map_err(|_| WebSessionError::Temporary)
}

fn write_signed_in(id: &str, value: bool) -> Result<(), WebSessionError> {
    write_signed_in_at(&state_path(), id, value)
}

fn write_if_epoch_at(
    path: &std::path::Path,
    id: &str,
    epoch: u64,
    value: bool,
) -> Result<bool, WebSessionError> {
    let all = sessions().lock().unwrap();
    if !all.get(id).is_some_and(|s| s.epoch == epoch && !s.cleaning) {
        return Ok(false);
    }
    // All mutations use SESSIONS -> STORE_LOCK. A late response cannot alter
    // the next account's persisted flag between its epoch check and write.
    write_signed_in_at(path, id, value)?;
    Ok(true)
}

fn write_if_epoch(id: &str, epoch: u64, value: bool) -> Result<bool, WebSessionError> {
    write_if_epoch_at(&state_path(), id, epoch, value)
}

/// The persisted flag is meaningful only with a private native browser store.
pub fn signed_in(id: &str) -> bool {
    private_profiles_supported()
        && web_sites::site(id, false).is_some()
        && read_flags().get(id) == Some(&true)
}

pub fn sign_in_open(id: &str) -> bool {
    sessions()
        .lock()
        .unwrap()
        .get(id)
        .is_some_and(|s| s.sign_in_open)
}

pub fn state(id: &str) -> Result<WebSessionState, WebSessionError> {
    if web_sites::site(id, false).is_none() {
        return Err(WebSessionError::Invalid);
    }
    let supported = private_profiles_supported();
    Ok(WebSessionState {
        id: id.into(),
        supported,
        signed_in: signed_in(id),
        sign_in_open: sign_in_open(id),
        reason: (!supported)
            .then_some("Private browser profiles require macOS 14 or newer, or Windows"),
    })
}

#[cfg(target_os = "macos")]
fn private_profiles_supported() -> bool {
    static AVAILABLE: OnceLock<bool> = OnceLock::new();
    *AVAILABLE.get_or_init(|| {
        std::process::Command::new("/usr/bin/sw_vers")
            .arg("-productVersion")
            .output()
            .ok()
            .filter(|out| out.status.success())
            .and_then(|out| String::from_utf8(out.stdout).ok())
            .and_then(|text| text.split('.').next()?.parse::<u32>().ok())
            .is_some_and(|major| major >= 14)
    })
}

#[cfg(target_os = "windows")]
fn private_profiles_supported() -> bool {
    true
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn private_profiles_supported() -> bool {
    false
}

fn data_store_id(id: &str) -> [u8; 16] {
    let hash = Sha256::digest(
        format!(
            "Velo/web-session/v1/{}/{id}",
            crate::config::config_path().display()
        )
        .as_bytes(),
    );
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&hash[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    bytes
}

fn same_origin(url: &Url, origin: &str) -> bool {
    let Ok(expected) = Url::parse(origin) else {
        return false;
    };
    url.scheme() == "https"
        && url.scheme() == expected.scheme()
        && url.host_str().map(str::to_ascii_lowercase)
            == expected.host_str().map(str::to_ascii_lowercase)
        && url.port_or_known_default() == expected.port_or_known_default()
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn label(id: &str) -> String {
    format!("web-session-{id}")
}

fn window_for(app: &AppHandle, site: &Site) -> Result<WebviewWindow, WebSessionError> {
    if !private_profiles_supported() {
        return Err(WebSessionError::Unavailable);
    }
    let _create_guard = WINDOW_CREATE_LOCK.lock().unwrap();
    let (existing, start_epoch) = {
        let all = sessions().lock().unwrap();
        let session = all.get(site.id);
        if session.is_some_and(|s| s.cleaning) {
            return Err(WebSessionError::Busy);
        }
        (
            session.and_then(|s| s.window.clone()),
            session.map_or(0, |s| s.epoch),
        )
    };
    if let Some(existing) = existing {
        let mut all = sessions().lock().unwrap();
        if let Some(session) = all.get_mut(site.id) {
            if session.cleaning || session.epoch != start_epoch {
                return Err(WebSessionError::Busy);
            }
            if session.origin != site.origin {
                session.loaded = false;
            }
            session.origin = site.origin.into();
            session.site = Some(site.clone());
        }
        return Ok(existing);
    }
    let origin = Url::parse(site.origin).map_err(|_| WebSessionError::Invalid)?;
    {
        let mut all = sessions().lock().unwrap();
        let session = all.entry(site.id.into()).or_default();
        session.origin = site.origin.into();
        session.site = Some(site.clone());
        session.loaded = false;
    }
    let app_for_main = app.clone();
    let id = site.id.to_string();
    let title = format!("Sign in to {}", site.name);
    let (tx, rx) = mpsc::sync_channel(1);
    app.run_on_main_thread(move || {
        let builder =
            WebviewWindowBuilder::new(&app_for_main, label(&id), WebviewUrl::External(origin))
                .title(title)
                .inner_size(1100.0, 800.0)
                .center()
                .visible(false)
                .on_navigation(|url| url.scheme() == "https")
                .on_page_load({
                    let id = id.clone();
                    move |_window, payload| {
                        let mut all = sessions().lock().unwrap();
                        if let Some(session) = all.get_mut(&id) {
                            session.loaded = payload.event()
                                == tauri::webview::PageLoadEvent::Finished
                                && same_origin(payload.url(), &session.origin);
                        }
                    }
                });
        #[cfg(target_os = "macos")]
        let builder = builder.data_store_identifier(data_store_id(&id));
        #[cfg(target_os = "windows")]
        let builder = builder.data_directory(
            crate::config::config_path()
                .with_file_name("web-profiles")
                .join(&id),
        );
        let outcome = builder.build().map_err(|_| WebSessionError::Temporary);
        if let Ok(window) = &outcome {
            let app_for_event = app_for_main.clone();
            let id_for_event = id.clone();
            window.on_window_event(move |event| {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    if let Some(window) = app_for_event.get_webview_window(&label(&id_for_event)) {
                        let _ = window.hide();
                    }
                    let app = app_for_event.clone();
                    let id = id_for_event.clone();
                    std::thread::spawn(move || close_probe(&app, &id));
                }
            });
        }
        if let Err(error) = tx.send(outcome) {
            if let Ok(window) = error.0 {
                let _ = window.destroy();
            }
        }
    })
    .map_err(|_| WebSessionError::Temporary)?;
    let window = rx
        .recv_timeout(PAGE_TIMEOUT)
        .map_err(|_| WebSessionError::Temporary)??;
    let mut all = sessions().lock().unwrap();
    let session = all.entry(site.id.into()).or_default();
    session.window = Some(window.clone());
    session.origin = site.origin.into();
    session.site = Some(site.clone());
    // A disconnect may have revoked ownership while the main thread built
    // this window. Leave it visible to sign_out_revoked's cleanup, not to the
    // caller, which must not navigate a profile being removed.
    if session.cleaning || session.epoch != start_epoch {
        return Err(WebSessionError::Busy);
    }
    Ok(window)
}

fn loaded_same_origin(window: &WebviewWindow, site: &Site) -> bool {
    window
        .url()
        .ok()
        .is_some_and(|url| same_origin(&url, site.origin))
        && sessions()
            .lock()
            .unwrap()
            .get(site.id)
            .is_some_and(|s| s.loaded)
}

fn wait_loaded(window: &WebviewWindow, site: &Site) -> Result<(), WebSessionError> {
    for _ in 0..40 {
        if loaded_same_origin(window, site) {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    Err(WebSessionError::Temporary)
}

fn eval_sync(window: &WebviewWindow, script: String) -> Result<serde_json::Value, WebSessionError> {
    let (tx, rx) = mpsc::sync_channel(1);
    window
        .eval_with_callback(script, move |result| {
            let _ = tx.send(result);
        })
        .map_err(|_| WebSessionError::Temporary)?;
    let text = rx
        .recv_timeout(EVAL_TIMEOUT)
        .map_err(|_| WebSessionError::Temporary)?;
    if text.len() > MAX_RESULT_BYTES {
        return Err(WebSessionError::Invalid);
    }
    serde_json::from_str(&text).map_err(|_| WebSessionError::Invalid)
}

/// WebView.eval_with_callback is synchronous: await the site's async fetch in
/// its own page and poll a nonce-keyed JSON result. Never evaluate on SSO or
/// another origin, and do not expose the remote page to Tauri IPC.
fn eval_async_body(
    window: &WebviewWindow,
    site: &Site,
    body: &str,
) -> Result<String, WebSessionError> {
    if !loaded_same_origin(window, site) {
        return Err(WebSessionError::Temporary);
    }
    let nonce = NONCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let key = format!("velo{nonce}");
    let origin = serde_json::to_string(site.origin.trim_end_matches('/'))
        .map_err(|_| WebSessionError::Invalid)?;
    let start = format!(
        r#"(function(){{
      if (location.origin !== {origin}) return false;
      window.__veloSessionResults = window.__veloSessionResults || Object.create(null);
      window.__veloSessionResults['{key}'] = {{state:'pending'}};
      (async () => {{
        try {{
          const value = await (async () => {{ {body} }})();
          if (Object.prototype.hasOwnProperty.call(window.__veloSessionResults, '{key}')) window.__veloSessionResults['{key}'] = {{state:'done',value:value}};
        }} catch (_) {{if (Object.prototype.hasOwnProperty.call(window.__veloSessionResults, '{key}')) window.__veloSessionResults['{key}'] = {{state:'error'}};}}
      }})();
      return true;
    }})()"#
    );
    if eval_sync(window, start)? != serde_json::Value::Bool(true) {
        return Err(WebSessionError::Temporary);
    }
    let poll = format!("(function(){{if(location.origin!=={origin})return null;const all=window.__veloSessionResults||{{}};const v=all['{key}'];if(v&&v.state!=='pending')delete all['{key}'];return v||null;}})()");
    let deadline = std::time::Instant::now() + SCRIPT_TIMEOUT;
    let outcome = loop {
        if std::time::Instant::now() >= deadline {
            break Err(WebSessionError::Temporary);
        }
        if !loaded_same_origin(window, site) {
            break Err(WebSessionError::Temporary);
        }
        let value = match eval_sync(window, poll.clone()) {
            Ok(value) => value,
            Err(error) => break Err(error),
        };
        match value["state"].as_str() {
            Some("done") => {
                break value["value"]
                    .as_str()
                    .map(str::to_string)
                    .filter(|text| text.len() <= MAX_RESULT_BYTES)
                    .ok_or(WebSessionError::Invalid);
            }
            Some("error") => break Err(WebSessionError::Temporary),
            Some("pending") => std::thread::sleep(Duration::from_millis(100)),
            _ => break Err(WebSessionError::Temporary),
        }
    };
    let cleanup = format!("(function(){{if(location.origin!=={origin})return false;const all=window.__veloSessionResults;if(all)delete all['{key}'];return true;}})()");
    let _ = eval_sync(window, cleanup);
    outcome
}

fn auth_state(window: &WebviewWindow, site: &Site) -> Result<AuthenticationState, WebSessionError> {
    let raw = eval_async_body(window, site, &site.auth_script)?;
    serde_json::from_str(&raw).map_err(|_| WebSessionError::Invalid)
}

fn committed(app: &AppHandle, id: &str, epoch: u64, fingerprint: Option<String>) {
    let window = {
        let mut all = sessions().lock().unwrap();
        let Some(session) = all.get_mut(id) else {
            return;
        };
        if session.epoch != epoch || !session.sign_in_open || session.cleaning {
            return;
        }
        // Keep the epoch check and persisted flag in the same lock scope.
        if write_signed_in(id, true).is_err() {
            return;
        }
        session.last_fingerprint = fingerprint;
        session.sign_in_open = false;
        session.switching = false;
        session.gate = None;
        session.last_probed_url = None;
        session.window.clone()
    };
    if let Some(window) = window {
        let _ = window.hide();
    }
    if let Ok(state) = state(id) {
        let _ = app.emit("web_session_state", state);
    }
}

fn close_probe(app: &AppHandle, id: &str) {
    let (window, gate, epoch, site) = {
        let all = sessions().lock().unwrap();
        let Some(session) = all.get(id) else {
            return;
        };
        (
            session.window.clone(),
            session.gate.clone(),
            session.epoch,
            session.site.clone(),
        )
    };
    let (Some(window), Some(gate), Some(site)) = (window, gate, site) else {
        return;
    };
    if loaded_same_origin(&window, &site) {
        if let Ok(auth) = auth_state(&window, &site) {
            if gate.accepts_on_close(auth.authenticated, auth.fingerprint.as_deref()) {
                committed(app, id, epoch, auth.fingerprint);
                return;
            }
        }
    }
    let mut all = sessions().lock().unwrap();
    if let Some(session) = all.get_mut(id).filter(|s| s.epoch == epoch) {
        session.sign_in_open = false;
        session.switching = false;
        session.gate = None;
    }
    drop(all);
    if let Ok(state) = state(id) {
        let _ = app.emit("web_session_state", state);
    }
}

fn probe_open_page(app: &AppHandle, id: &str, epoch: u64) -> bool {
    let (window, site, url) = {
        let all = sessions().lock().unwrap();
        let Some(session) = all.get(id).filter(|s| s.epoch == epoch && s.sign_in_open) else {
            return true;
        };
        let (Some(window), Some(site)) = (session.window.clone(), session.site.clone()) else {
            return true;
        };
        let Ok(url) = window.url() else {
            return false;
        };
        if !same_origin(&url, site.origin) || !session.loaded {
            return false;
        }
        if session.last_probed_url.as_deref() == Some(url.as_str()) {
            return false;
        }
        (window, site, url.to_string())
    };
    {
        let mut all = sessions().lock().unwrap();
        let Some(session) = all
            .get_mut(id)
            .filter(|s| s.epoch == epoch && s.sign_in_open)
        else {
            return true;
        };
        session.last_probed_url = Some(url);
    }
    let Ok(auth) = auth_state(&window, &site) else {
        return false;
    };
    let accepted = {
        let mut all = sessions().lock().unwrap();
        let Some(session) = all
            .get_mut(id)
            .filter(|s| s.epoch == epoch && s.sign_in_open)
        else {
            return true;
        };
        session
            .gate
            .as_mut()
            .is_some_and(|gate| gate.observe(auth.authenticated, auth.fingerprint.as_deref()))
    };
    if accepted {
        committed(app, id, epoch, auth.fingerprint);
        return true;
    }
    false
}

fn open_sign_in_sync(
    app: &AppHandle,
    id: &str,
    switching: bool,
    minimax_china: bool,
) -> Result<WebSessionState, WebSessionError> {
    let _open_guard = OPEN_LOCK.lock().unwrap();
    let site = web_sites::site(id, minimax_china).ok_or(WebSessionError::Invalid)?;
    let existing = {
        let all = sessions().lock().unwrap();
        let session = all.get(id);
        if session.is_some_and(|s| s.cleaning) {
            return Err(WebSessionError::Busy);
        }
        session
            .filter(|s| s.sign_in_open)
            .and_then(|s| s.window.clone())
    };
    if let Some(window) = existing {
        window.show().map_err(|_| WebSessionError::Temporary)?;
        let _ = window.set_focus();
        return state(id);
    }
    let window = window_for(app, &site)?;
    let epoch = crate::providers::with_lifecycle_mut(|epochs| {
        let mut all = sessions().lock().unwrap();
        let session = all.entry(id.into()).or_default();
        if session.cleaning {
            return Err(WebSessionError::Busy);
        }
        *epochs.entry(id.into()).or_default() += 1;
        session.epoch = session.epoch.wrapping_add(1);
        session.gate = Some(AuthenticationGate::new(
            session.last_fingerprint.clone(),
            switching,
        ));
        session.sign_in_open = true;
        session.switching = switching;
        session.last_probed_url = None;
        session.loaded = false;
        session.site = Some(site.clone());
        session.origin = site.origin.into();
        Ok(session.epoch)
    })?;
    let origin = Url::parse(site.origin).map_err(|_| WebSessionError::Invalid)?;
    window
        .navigate(origin)
        .map_err(|_| WebSessionError::Temporary)?;
    window.show().map_err(|_| WebSessionError::Temporary)?;
    let _ = window.set_focus();
    if site.polls_during_sign_in {
        let app = app.clone();
        let id = id.to_string();
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_millis(1500));
            if probe_open_page(&app, &id, epoch) {
                break;
            }
        });
    }
    let result = state(id)?;
    let _ = app.emit("web_session_state", &result);
    Ok(result)
}

#[tauri::command]
pub async fn open_web_session(
    app: AppHandle,
    id: String,
    switching: bool,
    minimax_china: bool,
) -> Result<WebSessionState, String> {
    tauri::async_runtime::spawn_blocking(move || {
        open_sign_in_sync(&app, &id, switching, minimax_china)
    })
    .await
    .map_err(|_| WebSessionError::Temporary.to_string())?
    .map_err(|error| error.to_string())
}

#[tauri::command]
pub fn get_web_session_state(id: String) -> Result<WebSessionState, String> {
    state(&id).map_err(|error| error.to_string())
}

fn compact_count(value: i64) -> String {
    let abs = value.unsigned_abs();
    if abs >= 1_000_000 {
        format!("{:.1}M", value as f64 / 1_000_000.0)
    } else if abs >= 1_000 {
        format!("{:.1}K", value as f64 / 1_000.0)
    } else {
        value.to_string()
    }
}

fn parse_reading(site: &Site, body: &str) -> Result<UsageSnapshot, WebSessionError> {
    let now = now_ms();
    let mut snapshot = match site.id {
        "deepseek" => {
            let reading = crate::web_usage_detail::parse_deepseek(body)
                .map_err(|_| WebSessionError::Invalid)?;
            let summary = &reading.summary;
            let mut windows = vec![LimitWindow {
                id: "spend".into(),
                label: format!("Account usage ({})", summary.currency),
                used: summary.used_fraction(),
                has_fraction: Some(true),
                money: Some(MoneyBreakdown {
                    currency: summary.currency.clone(),
                    spent: summary.spent,
                    remaining: summary.balance,
                }),
                ..Default::default()
            }];
            if let Some(tokens) = summary.available_tokens {
                windows.push(LimitWindow {
                    id: "available-tokens".into(),
                    label: "Available tokens (estimate)".into(),
                    detail: Some(format!("{} available", compact_count(tokens))),
                    has_fraction: Some(false),
                    ..Default::default()
                });
            }
            UsageSnapshot {
                status: "ok".into(),
                fetched_at: now,
                windows,
                usage_detail: reading.detail,
                ..Default::default()
            }
        }
        "qianwenai" => {
            let window = web_sites::parse_qianwen(body, now).map_err(|error| match error {
                web_sites::QianwenError::NeedsAuth => WebSessionError::NeedsAuth,
                _ => WebSessionError::Invalid,
            })?;
            UsageSnapshot {
                status: "ok".into(),
                fetched_at: now,
                windows: vec![window],
                ..Default::default()
            }
        }
        "minimax" => {
            crate::providers::parse_minimax_web(body).map_err(|_| WebSessionError::Invalid)?
        }
        _ => return Err(WebSessionError::Invalid),
    };
    snapshot.fidelity = Fidelity::Derived;
    if snapshot.fetched_at == 0 {
        snapshot.fetched_at = now;
    }
    Ok(snapshot)
}

fn fetch_sync(
    app: &AppHandle,
    id: &str,
    minimax_china: bool,
) -> Result<UsageSnapshot, WebSessionError> {
    if !signed_in(id) {
        return Err(WebSessionError::NeedsAuth);
    }
    let site = web_sites::site(id, minimax_china).ok_or(WebSessionError::Invalid)?;
    if sign_in_open(id) && !site.polls_during_sign_in {
        return Err(WebSessionError::Busy);
    }
    if sessions()
        .lock()
        .unwrap()
        .get(id)
        .is_some_and(|s| s.switching)
    {
        return Err(WebSessionError::Busy);
    }
    let epoch = sessions()
        .lock()
        .unwrap()
        .get(id)
        .map_or(0, |session| session.epoch);
    let window = window_for(app, &site)?;
    // Qianwen's live sign-in poll is allowed, but a background usage read must
    // never navigate the SSO window away from the page the user is using.
    if sign_in_open(id) && !loaded_same_origin(&window, &site) {
        return Err(WebSessionError::Busy);
    }
    if !loaded_same_origin(&window, &site) {
        let origin = Url::parse(site.origin).map_err(|_| WebSessionError::Invalid)?;
        window
            .navigate(origin)
            .map_err(|_| WebSessionError::Temporary)?;
        wait_loaded(&window, &site)?;
    }
    let raw = eval_async_body(&window, &site, &site.read_script)?;
    let response: PageResponse =
        serde_json::from_str(&raw).map_err(|_| WebSessionError::Invalid)?;
    if matches!(response.status, 401 | 403 | 1004) {
        write_if_epoch(id, epoch, false)?;
        let _ = app.emit("web_session_state", state(id).ok());
        return Err(WebSessionError::NeedsAuth);
    }
    if !(200..300).contains(&response.status) {
        return Err(WebSessionError::BadStatus(response.status));
    }
    let reading = match parse_reading(&site, &response.body) {
        Err(WebSessionError::NeedsAuth) => {
            write_if_epoch(id, epoch, false)?;
            Err(WebSessionError::NeedsAuth)
        }
        result => result,
    }?;
    if !signed_in(id)
        || sessions()
            .lock()
            .unwrap()
            .get(id)
            .map_or(0, |session| session.epoch)
            != epoch
    {
        return Err(WebSessionError::NeedsAuth);
    }
    Ok(reading)
}

pub async fn fetch_snapshot(
    app: &AppHandle,
    id: &str,
    minimax_china: bool,
) -> Result<UsageSnapshot, WebSessionError> {
    let app = app.clone();
    let id = id.to_string();
    tauri::async_runtime::spawn_blocking(move || fetch_sync(&app, &id, minimax_china))
        .await
        .map_err(|_| WebSessionError::Temporary)?
}

/// Revoke ownership synchronously while the provider's generation lock is held.
/// The returned epoch is the only cleanup operation allowed to touch this
/// profile; a new sign-in stays blocked until that cleanup has completed.
pub fn revoke_owned(id: &str) -> Result<u64, WebSessionError> {
    if web_sites::site(id, false).is_none() {
        return Err(WebSessionError::Invalid);
    }
    revoke_owned_at(&state_path(), id)
}

fn revoke_owned_at(path: &std::path::Path, id: &str) -> Result<u64, WebSessionError> {
    let mut all = sessions().lock().unwrap();
    let session = all.entry(id.into()).or_default();
    if session.cleaning {
        return Ok(session.epoch);
    }
    // Persist while holding SESSIONS, the same lock order as commit/fetch.
    write_signed_in_at(path, id, false)?;
    session.epoch = session.epoch.wrapping_add(1);
    session.sign_in_open = false;
    session.switching = false;
    session.gate = None;
    session.last_fingerprint = None;
    session.loaded = false;
    session.last_probed_url = None;
    session.cleaning = true;
    session.cleanup_started = false;
    Ok(session.epoch)
}

pub async fn sign_out_revoked(
    app: &AppHandle,
    id: &str,
    epoch: u64,
) -> Result<(), WebSessionError> {
    let window = {
        let _create_guard = WINDOW_CREATE_LOCK.lock().unwrap();
        let mut all = sessions().lock().unwrap();
        let Some(session) = all.get_mut(id).filter(|s| s.epoch == epoch && s.cleaning) else {
            return Ok(());
        };
        if session.cleanup_started {
            return Ok(());
        }
        session.cleanup_started = true;
        session.window.take()
    };
    let mut result = Ok(());
    if let Some(window) = window {
        if window.clear_all_browsing_data().is_err() {
            result = Err(WebSessionError::Temporary);
        }
        if window.destroy().is_err() {
            result = Err(WebSessionError::Temporary);
        }
    }
    #[cfg(target_os = "macos")]
    if private_profiles_supported() {
        let profile = data_store_id(id);
        match app.fetch_data_store_identifiers().await {
            Ok(known) if known.contains(&profile) => {
                if app.remove_data_store(profile).await.is_err() {
                    result = Err(WebSessionError::Temporary);
                }
            }
            Err(_) => result = Err(WebSessionError::Temporary),
            _ => {}
        }
    }
    {
        let mut all = sessions().lock().unwrap();
        if let Some(session) = all.get_mut(id).filter(|s| s.epoch == epoch) {
            session.cleaning = result.is_err();
            session.cleanup_started = false;
        }
    }
    if let Ok(state) = state(id) {
        let _ = app.emit("web_session_state", state);
    }
    result
}

pub async fn sign_out(app: &AppHandle, id: &str) -> Result<(), WebSessionError> {
    let epoch =
        crate::providers::revoke_web_session(app, id).map_err(|_| WebSessionError::Temporary)?;
    sign_out_revoked(app, id, epoch).await
}

#[tauri::command]
pub async fn sign_out_web_session(app: AppHandle, id: String) -> Result<WebSessionState, String> {
    sign_out(&app, &id)
        .await
        .map_err(|error| error.to_string())?;
    state(&id).map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Barrier};

    #[test]
    fn auth_gate_requires_a_real_transition_and_new_identity_on_switch() {
        let mut ordinary = AuthenticationGate::new(None, false);
        assert!(!ordinary.observe(true, Some("old")));
        assert!(!ordinary.observe(false, None));
        assert!(ordinary.observe(true, Some("old")));
        let mut switching = AuthenticationGate::new(Some("old".into()), true);
        assert!(!switching.observe(true, Some("old")));
        assert!(!switching.observe(false, None));
        assert!(!switching.observe(true, Some("new")));
        assert!(!switching.observe(false, None));
        assert!(!switching.observe(false, None));
        assert!(!switching.observe(true, Some("old")));
        assert!(switching.observe(true, Some("new")));
        assert!(!AuthenticationGate::new(Some("same".into()), true)
            .accepts_on_close(true, Some("same")));
        assert!(AuthenticationGate::new(Some("same".into()), true)
            .accepts_on_close(true, Some("other")));
    }

    #[test]
    fn origin_gate_requires_exact_https_host_and_port() {
        let expected = "https://platform.deepseek.com/";
        assert!(same_origin(&Url::parse(expected).unwrap(), expected));
        for url in [
            "http://platform.deepseek.com/",
            "https://platform.deepseek.com.evil.test/",
            "https://www.platform.deepseek.com/",
            "https://platform.deepseek.com:444/",
        ] {
            assert!(!same_origin(&Url::parse(url).unwrap(), expected));
        }
    }

    #[test]
    fn profile_identifiers_are_deterministic_and_isolated() {
        assert_eq!(data_store_id("deepseek"), data_store_id("deepseek"));
        assert_ne!(data_store_id("deepseek"), data_store_id("qianwenai"));
        assert_eq!(data_store_id("deepseek")[6] & 0xf0, 0x40);
    }

    #[test]
    fn late_commit_cannot_restore_a_revoked_profile() {
        let id = format!("race-commit-{}", now_ms());
        let path = std::env::temp_dir().join(format!("velo-web-session-{id}.json"));
        let epoch = {
            let mut all = sessions().lock().unwrap();
            let session = all.entry(id.clone()).or_default();
            session.epoch = 1;
            session.sign_in_open = true;
            session.epoch
        };
        write_signed_in_at(&path, &id, true).unwrap();
        let barrier = Arc::new(Barrier::new(2));
        let worker = {
            let barrier = barrier.clone();
            let path = path.clone();
            let id = id.clone();
            std::thread::spawn(move || {
                barrier.wait();
                write_if_epoch_at(&path, &id, epoch, true).unwrap()
            })
        };
        let new_epoch = revoke_owned_at(&path, &id).unwrap();
        assert_ne!(new_epoch, epoch);
        barrier.wait();
        assert!(!worker.join().unwrap());
        let flags: BTreeMap<String, bool> =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(flags.get(&id), Some(&false));
        sessions().lock().unwrap().remove(&id);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn old_auth_failure_cannot_sign_out_a_new_epoch() {
        let id = format!("race-auth-{}", now_ms());
        let path = std::env::temp_dir().join(format!("velo-web-session-{id}.json"));
        {
            let mut all = sessions().lock().unwrap();
            all.entry(id.clone()).or_default().epoch = 4;
        }
        write_signed_in_at(&path, &id, true).unwrap();
        let barrier = Arc::new(Barrier::new(2));
        let worker = {
            let barrier = barrier.clone();
            let path = path.clone();
            let id = id.clone();
            std::thread::spawn(move || {
                barrier.wait();
                write_if_epoch_at(&path, &id, 4, false).unwrap()
            })
        };
        {
            let mut all = sessions().lock().unwrap();
            all.get_mut(&id).unwrap().epoch = 5;
        }
        barrier.wait();
        assert!(!worker.join().unwrap());
        let flags: BTreeMap<String, bool> =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(flags.get(&id), Some(&true));
        sessions().lock().unwrap().remove(&id);
        let _ = std::fs::remove_file(path);
    }
}
