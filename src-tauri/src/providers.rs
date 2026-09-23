//! Swift provider parity. One serial worker, bounded replies, per-provider backoff and cache.
//! Credentials owned by another CLI are borrowed read-only; no token refresh or redirects.
mod gemini_logs;
mod kiro;
mod parse;
pub(crate) mod profiles;
mod transport;

pub(crate) fn parse_minimax_web(body: &str) -> Result<crate::usage::UsageSnapshot, Failure> {
    let value = serde_json::from_str(body).map_err(|_| Failure::Invalid)?;
    parse::reading("minimax", &value)
}

use crate::usage::UsageSnapshot;
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{Mutex, OnceLock},
    time::Duration,
};
use tauri::{AppHandle, Emitter, Manager};

#[derive(Clone, Serialize)]
pub struct Descriptor {
    pub id: &'static str,
    pub name: &'static str,
    pub headline: &'static str,
    pub guidance: &'static str,
}
pub const CATALOG: &[Descriptor] = &[
    Descriptor {
        id: "kiro",
        name: "Kiro",
        headline: "credits",
        guidance: "在 kiro-cli 中登录；用量来自 CLI /usage。",
    },
    Descriptor {
        id: "gemini-api",
        name: "Gemini API",
        headline: "month",
        guidance: "读取 Gemini CLI、OpenCode、Hermes 本地用量记录，不读取 API key。",
    },
    Descriptor {
        id: "ollama-local",
        name: "Ollama Local",
        headline: "models",
        guidance: "启动本机 Ollama 服务。",
    },
    Descriptor {
        id: "lmstudio",
        name: "LM Studio",
        headline: "models",
        guidance: "在 LM Studio 启动本机服务并加载模型。",
    },
    Descriptor {
        id: "opencode",
        name: "OpenCode",
        headline: "rolling",
        guidance: "在 OpenCode 登录 OpenCode Go。",
    },
    Descriptor {
        id: "kimi",
        name: "Kimi",
        headline: "rolling",
        guidance: "运行 kimi login 登录 Kimi Code。",
    },
    Descriptor {
        id: "copilot",
        name: "GitHub Copilot",
        headline: "premium_interactions",
        guidance: "运行 gh auth login，或设置 GH_TOKEN。",
    },
    Descriptor {
        id: "devin",
        name: "Devin",
        headline: "daily",
        guidance: "登录 Devin Desktop 或 Devin CLI。",
    },
    Descriptor {
        id: "commandcode",
        name: "Command Code",
        headline: "monthly",
        guidance: "登录 Command Code CLI。",
    },
    Descriptor {
        id: "minimax",
        name: "MiniMax",
        headline: "session",
        guidance: "设置 Coding Plan 密钥，或在 Velo 中登录 MiniMax。",
    },
    Descriptor {
        id: "ollama-cloud",
        name: "Ollama Cloud",
        headline: "monthly",
        guidance: "设置 OLLAMA_API_KEY 或在账户设置保存密钥。",
    },
    Descriptor {
        id: "deepseek",
        name: "DeepSeek",
        headline: "spend",
        guidance: "在 Velo 中登录 DeepSeek Platform。",
    },
    Descriptor {
        id: "qianwenai",
        name: "QianwenAI",
        headline: "week",
        guidance: "在 Velo 中登录 QianwenAI。",
    },
];
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Preferences {
    pub disabled: BTreeSet<String>,
    /// Swift's persisted on-list. None is a pre-migration configuration.
    pub connected: Option<BTreeSet<String>>,
    /// A disconnected account stays off when it is rediscovered later.
    pub seen: BTreeSet<String>,
    pub minimax_china: bool,
    pub gemini_token_budget: Option<u64>,
}

fn default_on_family(id: &str) -> bool {
    id == "claude" || id.starts_with("claude-") || id == "codex" || id.starts_with("codex-")
}

fn discovered_ids(cfg: &crate::config::Config) -> BTreeSet<String> {
    let mut ids: BTreeSet<String> = crate::TRAY_PROVIDER_IDS
        .iter()
        .map(|id| (*id).to_string())
        .collect();
    ids.extend(CATALOG.iter().map(|p| p.id.to_string()));
    if crate::smoke::root().is_none() {
        ids.extend(
            profiles::at_launch(&dirs::home_dir().unwrap_or_default())
                .into_iter()
                .map(|p| p.id),
        );
    }
    ids.extend(
        cfg.custom_endpoints
            .iter()
            .map(|endpoint| format!("custom-endpoint-{}", endpoint.id)),
    );
    ids
}

/// Swift Preferences.reconcile: first install connects only Claude/Codex;
/// a legacy off-list is inverted once; then only *new* default-family ids
/// auto-connect. Absence from discovery never erases the stored choice.
pub fn reconcile_connections(cfg: &mut crate::config::Config, legacy_config_exists: bool) -> bool {
    let discovered = discovered_ids(cfg);
    reconcile_with_discovered(cfg, &discovered, legacy_config_exists)
}

fn reconcile_with_discovered(
    cfg: &mut crate::config::Config,
    discovered: &BTreeSet<String>,
    legacy_config_exists: bool,
) -> bool {
    let has_legacy_choice = has_legacy_connection_choice(cfg, legacy_config_exists);
    let mut changed = reconcile_preferences(&mut cfg.providers, discovered, has_legacy_choice);
    for endpoint in &cfg.custom_endpoints {
        let id = format!("custom-endpoint-{}", endpoint.id);
        let connected = cfg.providers.connected.as_mut().unwrap();
        if endpoint.enabled {
            changed |= connected.insert(id.clone());
            changed |= cfg.providers.disabled.remove(&id);
        } else {
            changed |= connected.remove(&id);
            changed |= cfg.providers.disabled.insert(id.clone());
        }
    }
    changed
}

fn has_legacy_connection_choice(cfg: &crate::config::Config, legacy_config_exists: bool) -> bool {
    // Earlier Velo versions eagerly wrote config.json even when the person
    // had never chosen a connection. Only a saved off-list or explicit notch
    // selection proves that an all-on legacy state was intentional.
    legacy_config_exists
        && (!cfg.providers.disabled.is_empty()
            || cfg.notch_selection_explicit
            || !cfg.notch_slots.is_empty()
            || !cfg.notch_providers.is_empty())
}

fn reconcile_preferences(
    prefs: &mut Preferences,
    discovered: &BTreeSet<String>,
    legacy_config_exists: bool,
) -> bool {
    let before = (
        prefs.disabled.clone(),
        prefs.connected.clone(),
        prefs.seen.clone(),
    );
    let mut connected = match prefs.connected.take() {
        Some(mut current) => {
            for id in discovered.difference(&prefs.seen) {
                if default_on_family(id) {
                    current.insert(id.clone());
                }
            }
            current
        }
        None if legacy_config_exists => discovered.difference(&prefs.disabled).cloned().collect(),
        None => discovered
            .iter()
            .filter(|id| default_on_family(id))
            .cloned()
            .collect(),
    };
    prefs.seen.extend(discovered.iter().cloned());
    for id in discovered {
        if connected.contains(id) {
            prefs.disabled.remove(id);
        } else {
            prefs.disabled.insert(id.clone());
        }
    }
    prefs.connected = Some(connected);
    before
        != (
            prefs.disabled.clone(),
            prefs.connected.clone(),
            prefs.seen.clone(),
        )
}
#[derive(Clone, Serialize)]
pub struct AccountSummary {
    pub label: Option<String>,
    pub plan: Option<String>,
    pub source: String,
    pub manage_url: Option<String>,
}

#[derive(Clone, Serialize)]
pub struct Reading {
    pub id: String,
    pub name: String,
    pub headline: String,
    pub guidance: String,
    pub enabled: bool,
    pub snap: UsageSnapshot,
    #[serde(default)]
    pub was_refused_access: bool,
    #[serde(default)]
    pub needs_sign_in_renewal: bool,
    #[serde(default)]
    pub account: Option<AccountSummary>,
}

fn profile_account(profile: &profiles::Profile, snap: &UsageSnapshot) -> Option<AccountSummary> {
    match profile.kind {
        "claude" => {
            let label = crate::usage::account_label(&profile.id);
            (label.is_some() || snap.plan.is_some()).then(|| AccountSummary {
                label,
                plan: snap.plan.clone(),
                source: if profile.id == "claude" {
                    "Claude Code".into()
                } else {
                    format!("Claude Code in {}", profile.home.display())
                },
                manage_url: Some("https://claude.ai/settings/usage".into()),
            })
        }
        "codex" => {
            crate::codex::account_identity(&profile.home).map(|(label, plan)| AccountSummary {
                label,
                plan,
                source: format!("Codex in {}", profile.home.display()),
                manage_url: Some("https://chatgpt.com/#settings/Account".into()),
            })
        }
        _ => None,
    }
}
#[derive(Default)]
struct Store {
    snapshots: BTreeMap<String, UsageSnapshot>,
    requested: BTreeSet<String>,
    rate_limit_attempts: BTreeMap<String, u32>,
}
static STORE: OnceLock<Mutex<Store>> = OnceLock::new();
// Serializes a connection change with the final write of an in-flight reading.
// The lock order is lifecycle -> config -> snapshot store; never take it while
// holding either config or a provider's snapshot lock.
static LIFECYCLE: OnceLock<Mutex<BTreeMap<String, u64>>> = OnceLock::new();
fn lifecycle() -> &'static Mutex<BTreeMap<String, u64>> {
    LIFECYCLE.get_or_init(|| Mutex::new(BTreeMap::new()))
}

pub(crate) fn generation(id: &str) -> u64 {
    lifecycle().lock().unwrap().get(id).copied().unwrap_or(0)
}

// This is the commit predicate used by every collector. The caller holds the
// lifecycle mutex through `write`, so a disconnect cannot slip between the
// generation check and a cache, archive, or completion-event write.
fn guarded_commit<R>(
    epochs: &BTreeMap<String, u64>,
    id: &str,
    expected: u64,
    is_enabled: bool,
    write: impl FnOnce() -> R,
) -> Option<R> {
    (is_enabled && epochs.get(id).copied().unwrap_or(0) == expected).then(write)
}

pub(crate) fn with_current(
    app: &AppHandle,
    id: &str,
    expected: u64,
    commit: impl FnOnce(),
) -> bool {
    let epochs = lifecycle().lock().unwrap();
    guarded_commit(&epochs, id, expected, enabled(app, id), commit).is_some()
}

pub(crate) fn commit_if_current<R>(
    app: &AppHandle,
    id: &str,
    expected: u64,
    commit: impl FnOnce() -> Result<R, String>,
) -> Result<R, String> {
    let epochs = lifecycle().lock().unwrap();
    guarded_commit(&epochs, id, expected, enabled(app, id), commit)
        .unwrap_or_else(|| Err("账户已断开或配置已变化".into()))
}

pub(crate) fn with_lifecycle<R>(commit: impl FnOnce(&BTreeMap<String, u64>) -> R) -> R {
    let epochs = lifecycle().lock().unwrap();
    commit(&epochs)
}
pub(crate) fn with_lifecycle_mut<R>(commit: impl FnOnce(&mut BTreeMap<String, u64>) -> R) -> R {
    let mut epochs = lifecycle().lock().unwrap();
    commit(&mut epochs)
}
fn store() -> &'static Mutex<Store> {
    STORE.get_or_init(|| {
        let snapshots: BTreeMap<String, UsageSnapshot> = std::fs::read(cache_path())
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        Mutex::new(Store {
            snapshots: snapshots
                .into_iter()
                .map(|(id, mut s)| {
                    if !s.windows.is_empty() {
                        s.status = "stale".into();
                    }
                    (id, s)
                })
                .collect(),
            requested: BTreeSet::new(),
            rate_limit_attempts: BTreeMap::new(),
        })
    })
}
fn purge_disabled(app: &AppHandle) {
    let disabled = get_disabled_providers(app.clone());
    if disabled.is_empty() {
        return;
    }
    let mut s = store().lock().unwrap();
    let before = s.snapshots.len();
    s.snapshots.retain(|id, _| !disabled.contains(id));
    s.requested.retain(|id| !disabled.contains(id));
    if s.snapshots.len() != before {
        if let Ok(bytes) = serde_json::to_vec(&s.snapshots) {
            let _ = persist(&cache_path(), &bytes);
        }
    }
}
fn cache_path() -> std::path::PathBuf {
    crate::config::config_path().with_file_name("providers-usage.json")
}
pub fn enabled(app: &AppHandle, id: &str) -> bool {
    let st = app.state::<crate::AppState>();
    let cfg = st.cfg.lock().unwrap();
    if let Some((runtime, model)) = local_model_id(id) {
        return !cfg.providers.disabled.contains(runtime)
            && !cfg.local_runtime.disabled_models.contains(id)
            // Velo's first model preference used a slash key; reading it
            // keeps existing choices until the source-shaped key is saved.
            && !cfg
                .local_runtime
                .disabled_models
                .contains(&format!("{runtime}/{model}"));
    }
    !cfg.providers.disabled.contains(id)
        && id
            .strip_prefix("custom-endpoint-")
            .map(|key| {
                cfg.custom_endpoints
                    .iter()
                    .any(|e| e.id == key && e.enabled)
            })
            .unwrap_or(true)
}

fn local_model_id(id: &str) -> Option<(&str, &str)> {
    let (runtime, model) = id.split_once(":model:")?;
    (matches!(runtime, "ollama-local" | "lmstudio") && !model.is_empty())
        .then_some((runtime, model))
}
pub fn snapshot(id: &str) -> UsageSnapshot {
    store()
        .lock()
        .unwrap()
        .snapshots
        .get(id)
        .cloned()
        .unwrap_or_else(|| UsageSnapshot {
            status: "absent".into(),
            ..Default::default()
        })
}
pub fn request(id: &str) -> bool {
    if let Some(p) = profile_list().into_iter().find(|p| p.id == id) {
        if p.kind == "claude" {
            crate::usage::request_profile_refresh(id);
            return true;
        }
    } else if !CATALOG.iter().any(|p| p.id == id) {
        return false;
    }
    let mut s = store().lock().unwrap();
    if s.snapshots
        .get(id)
        .is_some_and(|v| v.backoff_until > crate::now_ms())
    {
        return false;
    }
    s.requested.insert(id.into());
    true
}

fn queue_after_web_auth(st: &mut Store, id: &str, now: u64) -> bool {
    if id == "minimax"
        && st
            .snapshots
            .get(id)
            .is_some_and(|snapshot| snapshot.backoff_until > now)
    {
        return false;
    }
    if id != "minimax" {
        if let Some(snapshot) = st.snapshots.get_mut(id) {
            snapshot.backoff_until = 0;
        }
    }
    st.requested.insert(id.into());
    true
}

/// Authentication confirmation has its own targeted refresh in UsageStore.
/// DeepSeek and QianwenAI do not have a provider-owned rate limiter, so an
/// old account's generic HTTP backoff must not delay the new account. MiniMax
/// does retain its own retry deadline across sign-out in the pinned Swift
/// source, and continues to honor that deadline here.
pub(crate) fn request_after_web_auth(app: &AppHandle, id: &str) -> bool {
    if !matches!(id, "deepseek" | "qianwenai" | "minimax") {
        return false;
    }
    let expected = generation(id);
    let mut requested = false;
    with_current(app, id, expected, || {
        if !crate::web_session::signed_in(id) {
            return;
        }
        let mut st = store().lock().unwrap();
        requested = queue_after_web_auth(&mut st, id, crate::now_ms());
        if requested && id != "minimax" {
            // Persist the cleared old-account backoff, so a restart before the
            // new fetch cannot reintroduce it from the archive.
            if let Ok(bytes) = serde_json::to_vec(&st.snapshots) {
                let _ = persist(&cache_path(), &bytes);
            }
        }
    });
    requested
}
#[tauri::command]
pub fn get_providers(app: AppHandle) -> Vec<Reading> {
    if let Some(rows) = crate::smoke::swift_rows() {
        return rows;
    }
    // Every other isolated smoke/visual/update mode has synthetic built-in
    // snapshots from its own fixture. Account metadata must not inspect the
    // real user's CLI homes, keychains or local runtime inventory there.
    if crate::smoke::root().is_some() {
        return Vec::new();
    }
    purge_disabled(&app);
    let minimax_china = app
        .state::<crate::AppState>()
        .cfg
        .lock()
        .unwrap()
        .providers
        .minimax_china;
    let mut result: Vec<Reading> = CATALOG
        .iter()
        .map(|p| Reading {
            id: p.id.into(),
            name: p.name.into(),
            headline: p.headline.into(),
            guidance: p.guidance.into(),
            enabled: enabled(&app, p.id),
            was_refused_access: false,
            needs_sign_in_renewal: false,
            account: match p.id {
                "copilot" => transport::copilot_account().map(|label| AccountSummary {
                    label: Some(label),
                    plan: None,
                    source: "GitHub".into(),
                    manage_url: Some("https://github.com/settings/copilot".into()),
                }),
                "commandcode" => transport::commandcode_account().map(|label| AccountSummary {
                    label,
                    plan: None,
                    source: "Command Code".into(),
                    manage_url: Some("https://commandcode.ai".into()),
                }),
                "kiro" => kiro::account(snapshot("kiro").plan),
                "devin" => transport::devin_account(),
                "minimax" => transport::minimax_account_present().then(|| AccountSummary {
                    label: None,
                    plan: snapshot("minimax").plan,
                    source: "MiniMax".into(),
                    manage_url: Some(format!(
                        "https://platform.{}/user-center/payment/coding-plan",
                        if minimax_china { "minimaxi.com" } else { "minimax.io" }
                    )),
                }),
                "gemini-api" => gemini_logs::account(
                    &dirs::home_dir().unwrap_or_default(),
                    &snapshot("gemini-api"),
                ),
                _ => None,
            },
            snap: if enabled(&app, p.id) {
                snapshot(p.id)
            } else {
                UsageSnapshot::default()
            },
        })
        .collect();
    for (id, name, headline, guidance) in [
        ("codex", "Codex", "primary", "在 Codex 中登录。"),
        (
            "cursor",
            "Cursor",
            "included",
            "在 Cursor 或 cursor-agent 中登录。",
        ),
        ("grok", "Grok", "credits", "运行 grok login 登录。"),
        (
            "gemini",
            "Antigravity",
            "session",
            "在 Antigravity 中登录。",
        ),
        (
            "glm",
            "z.ai",
            "session",
            "在使用 GLM Coding Plan 的工具中配置密钥。",
        ),
    ] {
        let active = enabled(&app, id);
        let snap = if active {
            crate::snapshot_of(&app, id)
        } else {
            UsageSnapshot::default()
        };
        let account = active.then(|| builtin_account(id, &snap)).flatten();
        result.push(Reading {
            id: id.into(),
            name: name.into(),
            headline: headline.into(),
            guidance: guidance.into(),
            enabled: active,
            was_refused_access: false,
            needs_sign_in_renewal: false,
            account,
            snap,
        });
    }
    for runtime in ["ollama-local", "lmstudio"] {
        if !enabled(&app, runtime) {
            continue;
        }
        let runtime_snapshot = crate::snapshot_of(&app, runtime);
        let runtime_name = crate::provider_label(runtime);
        for (id, snap) in crate::local_runtime::all_cell_snapshots(runtime, &runtime_snapshot) {
            let Some(model) = snap.local_model.as_ref() else {
                continue;
            };
            result.push(Reading {
                enabled: enabled(&app, &id),
                name: model.name.clone(),
                headline: String::new(),
                guidance: format!("Loaded in {runtime_name}."),
                was_refused_access: false,
                needs_sign_in_renewal: false,
                account: None,
                id,
                snap,
            });
        }
    }
    for p in profile_list() {
        let active = enabled(&app, &p.id);
        let snap = if active {
            snapshot(&p.id)
        } else {
            UsageSnapshot::default()
        };
        let account = active.then(|| profile_account(&p, &snap)).flatten();
        result.push(Reading {
            id: p.id.clone(),
            name: p.name,
            headline: p.headline.into(),
            guidance: "请在该账户对应的 CLI 配置目录登录".into(),
            enabled: active,
            was_refused_access: p.kind == "claude"
                && crate::usage::was_refused_claude_access(&p.id),
            needs_sign_in_renewal: crate::usage::needs_sign_in_renewal(&p.id),
            snap,
            account,
        });
    }
    let own = if enabled(&app, "claude") {
        snapshot("claude")
    } else {
        UsageSnapshot::default()
    };
    if own.status != "absent" || crate::usage::was_refused_claude_access("claude") {
        result.push(Reading {
            id: "claude".into(),
            name: "Claude".into(),
            headline: "session".into(),
            guidance: String::new(),
            enabled: enabled(&app, "claude"),
            was_refused_access: crate::usage::was_refused_claude_access("claude"),
            needs_sign_in_renewal: crate::usage::needs_sign_in_renewal("claude"),
            account: if enabled(&app, "claude") {
                let label = crate::usage::account_label("claude");
                (label.is_some() || own.plan.is_some()).then(|| AccountSummary {
                    label,
                    plan: own.plan.clone(),
                    source: "Claude Code".into(),
                    manage_url: Some("https://claude.ai/settings/usage".into()),
                })
            } else {
                None
            },
            snap: own,
        });
    }
    result.extend(crate::custom_endpoint::readings(&app));
    result
}
pub(crate) fn emit_metadata(app: &AppHandle) {
    let _ = app.emit("providers", get_providers(app.clone()));
}
fn builtin_account(id: &str, snap: &UsageSnapshot) -> Option<AccountSummary> {
    match id {
        "codex" => {
            let home = dirs::home_dir()?.join(".codex");
            let (label, plan) = crate::codex::account_identity(&home)?;
            Some(AccountSummary {
                label,
                plan,
                source: "Codex".into(),
                manage_url: Some("https://chatgpt.com/#settings/Account".into()),
            })
        }
        "cursor" => {
            let (label, plan, source) = crate::cursor::account_identity()?;
            Some(AccountSummary {
                label,
                plan,
                source: source.into(),
                manage_url: Some("https://cursor.com/dashboard".into()),
            })
        }
        "grok" => Some(AccountSummary {
            label: crate::grok::account_label()?,
            plan: None,
            source: "Grok".into(),
            manage_url: Some("https://grok.com/?_s=usage".into()),
        }),
        "gemini" => crate::antigravity::account_summary(),
        "glm" => {
            let (source, manage) = crate::glm::account_source()?;
            Some(AccountSummary {
                label: None,
                plan: snap.plan.clone(),
                source,
                manage_url: Some(manage.into()),
            })
        }
        _ => None,
    }
}
fn profile_list() -> Vec<profiles::Profile> {
    if crate::smoke::root().is_some() {
        return Vec::new();
    }
    profiles::at_launch(&dirs::home_dir().unwrap_or_default())
}

/// Only the Codex family is needed when its extra usage display changes.
/// Use the captured launch registry so changing Appearance does not refresh
/// unrelated provider metadata or request credentials.
pub(crate) fn codex_profile_ids() -> Vec<String> {
    if crate::smoke::root().is_some() {
        return Vec::new();
    }
    let mut ids = vec!["codex".to_string()];
    ids.extend(
        profile_list()
            .into_iter()
            .filter(|profile| profile.kind == "codex")
            .map(|profile| profile.id),
    );
    ids
}

pub(crate) fn claude_named_profiles() -> Vec<(String, std::path::PathBuf)> {
    profile_list()
        .into_iter()
        .filter(|profile| profile.kind == "claude")
        .filter_map(|profile| {
            profile
                .id
                .strip_prefix("claude-")
                .map(|slug| (slug.into(), profile.home))
        })
        .collect()
}
fn publish_profile_unchecked(app: &AppHandle, id: &str, snap: UsageSnapshot) {
    let mut st = store().lock().unwrap();
    st.snapshots.insert(id.into(), snap);
    if let Ok(bytes) = serde_json::to_vec(&st.snapshots) {
        let _ = persist(&cache_path(), &bytes);
    }
    drop(st);
    let _ = app.emit("providers", get_providers(app.clone()));
    crate::refresh::complete(id);
}

pub fn publish_profile_if_current(
    app: &AppHandle,
    id: &str,
    epoch: u64,
    snap: UsageSnapshot,
) -> bool {
    with_current(app, id, epoch, || publish_profile_unchecked(app, id, snap))
}

fn forget_snapshot(id: &str) {
    let mut s = store().lock().unwrap();
    s.requested.remove(id);
    s.rate_limit_attempts.remove(id);
    s.snapshots.remove(id);
    if let Ok(bytes) = serde_json::to_vec(&s.snapshots) {
        let _ = persist(&cache_path(), &bytes);
    }
}

pub(crate) fn forget_local_reading(id: &str) {
    forget_snapshot(id);
    crate::local_runtime::forget_models(id);
}

fn forget_native(app: &AppHandle, id: &str) {
    match id {
        "claude" => crate::usage::forget_profile(app, id),
        "codex" => crate::codex::forget(app),
        "cursor" => crate::cursor::forget(app),
        "grok" => crate::grok::forget(app),
        "gemini" => crate::antigravity::forget(app),
        "glm" => crate::glm::forget(app),
        _ if id.starts_with("claude-") => crate::usage::forget_profile(app, id),
        _ => {}
    }
}

fn web_reading(app: &AppHandle, id: &str, china: bool) -> Option<Result<UsageSnapshot, Failure>> {
    use crate::web_session::WebSessionError;
    match tauri::async_runtime::block_on(crate::web_session::fetch_snapshot(app, id, china)) {
        Ok(snapshot) => Some(Ok(snapshot)),
        // A sign-in is in progress; it does not invalidate the last reading.
        Err(WebSessionError::Busy) => None,
        Err(WebSessionError::NeedsAuth) => Some(Err(Failure::Auth)),
        Err(WebSessionError::BadStatus(429) | WebSessionError::BusinessStatus(429))
            if id == "minimax" =>
        {
            Some(Err(Failure::MiniMaxThrottle(None)))
        }
        Err(WebSessionError::BadStatus(429)) => Some(Err(Failure::Throttle(60))),
        Err(WebSessionError::NothingMetered) => Some(Err(Failure::Unsupported(
            match id {
                "minimax" => "MiniMax reported no usage windows",
                "qianwenai" => "QianwenAI reported no Token Plan usage",
                _ => "The provider reported no usage windows",
            },
        ))),
        Err(WebSessionError::Api(code)) => Some(Err(Failure::Api(code))),
        Err(WebSessionError::BusinessStatus(code)) => {
            Some(Err(Failure::Api(format!("Provider error {code}"))))
        }
        Err(WebSessionError::Unavailable | WebSessionError::Temporary) => {
            Some(Err(Failure::Network))
        }
        Err(WebSessionError::BadStatus(code)) => {
            Some(Err(Failure::Api(format!("Provider error {code}"))))
        }
        Err(WebSessionError::Invalid) => Some(Err(Failure::Invalid)),
    }
}

/// An explicit browser sign-out invalidates any provider read already in flight,
/// even though the provider remains enabled and may be signed into again.
pub(crate) fn revoke_web_session(app: &AppHandle, id: &str) -> Result<u64, String> {
    if !matches!(id, "deepseek" | "qianwenai" | "minimax") {
        return Err("未知浏览器账户".into());
    }
    let epoch = with_lifecycle_mut(|epochs| {
        let epoch = crate::web_session::revoke_owned(id).map_err(|error| error.to_string())?;
        *epochs.entry(id.into()).or_default() += 1;
        forget_snapshot(id);
        Ok::<u64, String>(epoch)
    })?;
    {
        let state = app.state::<crate::AppState>();
        let mut activity = state.activity.lock().unwrap();
        activity.retain(|row| row.provider != id);
        let _ = app.emit("activity", &*activity);
    }
    let _ = app.emit("providers", get_providers(app.clone()));
    if id == "minimax" {
        request(id);
    }
    Ok(epoch)
}

#[tauri::command]
pub fn set_provider_enabled(app: AppHandle, id: String, value: bool) -> Result<(), String> {
    if let Some((runtime, model)) = local_model_id(&id) {
        let runtime_snapshot = crate::snapshot_of(&app, runtime);
        if !crate::local_runtime::all_cell_snapshots(runtime, &runtime_snapshot)
            .iter()
            .any(|(cell, _)| cell == &id)
        {
            return Err("模型未加载".into());
        }
        {
            let state = app.state::<crate::AppState>();
            let mut cfg = state.cfg.lock().unwrap();
            let mut next = cfg.clone();
            let disabled = &mut next.local_runtime.disabled_models;
            disabled.remove(&format!("{runtime}/{model}"));
            if value {
                disabled.remove(&id);
            } else {
                disabled.insert(id.clone());
            }
            crate::config::save_checked(&next)?;
            *cfg = next;
        }
        let _ = app.emit("providers", get_providers(app.clone()));
        let _ = app.emit("disabled_providers", get_disabled_providers(app.clone()));
        let _ = app.emit("notch_slots", crate::get_notch_slots(app.clone()));
        crate::broadcast(&app);
        return Ok(());
    }
    if !crate::custom_endpoint::readings(&app)
        .iter()
        .any(|p| p.id == id)
        && !CATALOG.iter().any(|p| p.id == id)
        && !crate::TRAY_PROVIDER_IDS.contains(&id.as_str())
        && !profile_list().iter().any(|p| p.id == id)
    {
        return Err("未知供应商".into());
    }
    let available: Vec<String> = crate::get_tray_options(app.clone())
        .into_iter()
        .map(|p| p.id)
        .collect();
    let mut epochs = lifecycle().lock().unwrap();
    {
        let state = app.state::<crate::AppState>();
        let mut cfg = state.cfg.lock().unwrap();
        let mut next = cfg.clone();
        set_connection(&mut next, &available, &id, value);
        crate::config::save_checked(&next)?;
        *cfg = next;
    }
    *epochs.entry(id.clone()).or_default() += 1;
    let web_revocation = if !value && matches!(id.as_str(), "deepseek" | "qianwenai" | "minimax") {
        Some(crate::web_session::revoke_owned(&id))
    } else {
        None
    };
    if !value {
        if id == "kiro" {
            kiro::forget();
        }
        // Vela owns these two keys. CLI credentials are borrowed and must remain untouched.
        if matches!(id.as_str(), "minimax" | "ollama-cloud") {
            let _ = crate::secrets::delete_owned_provider_secret(&id);
            if id == "minimax" {
                let _ = crate::secrets::delete_owned_provider_secret("minimax-cookie");
            }
        }
        forget_snapshot(&id);
        forget_native(&app, &id);
        if id == "claude" || id.starts_with("claude-") {
            app.state::<crate::AppState>()
                .store
                .lock()
                .unwrap()
                .clear_provider_sessions(&id);
        }
        {
            let state = app.state::<crate::AppState>();
            let mut activity = state.activity.lock().unwrap();
            activity.retain(|row| row.provider != id);
            let _ = app.emit("activity", &*activity);
        }
        if matches!(id.as_str(), "ollama-local" | "lmstudio") {
            crate::local_runtime::forget_models(&id);
        }
    }
    drop(epochs);
    if matches!(id.as_str(), "ollama-local" | "lmstudio") {
        crate::local_runtime::reconcile(&app);
    }
    if let Some(Ok(epoch)) = web_revocation {
        let app = app.clone();
        let id = id.clone();
        tauri::async_runtime::spawn(async move {
            let _ = crate::web_session::sign_out_revoked(&app, &id, epoch).await;
        });
    }
    if !value {
        crate::broadcast(&app);
    }
    if value {
        crate::refresh_provider(&app, &id);
    }
    let _ = app.emit("providers", get_providers(app.clone()));
    let disabled = get_disabled_providers(app.clone());
    let _ = app.emit("disabled_providers", disabled);
    let _ = app.emit("notch_slots", crate::get_notch_slots(app.clone()));
    if let Some(Err(error)) = web_revocation {
        return Err(error.to_string());
    }
    Ok(())
}

/// Swift's account switch changes collection and ring membership together. Persist this as one
/// transaction so a failed write cannot leave a hidden account collecting in the background.
fn set_connection(cfg: &mut crate::config::Config, available: &[String], id: &str, value: bool) {
    if cfg.providers.connected.is_none() {
        cfg.providers.connected = Some(
            available
                .iter()
                .filter(|candidate| !cfg.providers.disabled.contains(*candidate))
                .cloned()
                .collect(),
        );
    }
    let connected = cfg.providers.connected.as_mut().unwrap();
    if value {
        connected.insert(id.into());
    } else {
        connected.remove(id);
    }
    cfg.providers.seen.insert(id.into());
    if !cfg.notch_selection_explicit && cfg.notch_slots.is_empty() {
        cfg.notch_slots = available
            .iter()
            .filter(|id| !cfg.providers.disabled.contains(*id))
            .map(|id| crate::config::TraySlot {
                provider: id.clone(),
            })
            .collect();
    }
    cfg.notch_selection_explicit = true;
    cfg.notch_slots.retain(|s| s.provider != id || value);
    if value && !cfg.notch_slots.iter().any(|s| s.provider == id) {
        cfg.notch_slots.push(crate::config::TraySlot {
            provider: id.into(),
        });
    }
    cfg.notch_providers = cfg.notch_slots.iter().map(|s| s.provider.clone()).collect();
    if let Some(key) = id.strip_prefix("custom-endpoint-") {
        if let Some(e) = cfg.custom_endpoints.iter_mut().find(|e| e.id == key) {
            e.enabled = value;
        }
    }
    if value {
        cfg.providers.disabled.remove(id);
    } else {
        cfg.providers.disabled.insert(id.into());
    }
}
#[tauri::command]
pub fn get_disabled_providers(app: AppHandle) -> BTreeSet<String> {
    let state = app.state::<crate::AppState>();
    let c = state.cfg.lock().unwrap();
    let mut ids = c.providers.disabled.clone();
    ids.extend(
        c.custom_endpoints
            .iter()
            .filter(|e| !e.enabled)
            .map(|e| format!("custom-endpoint-{}", e.id)),
    );
    ids.extend(c.local_runtime.disabled_models.iter().cloned());
    ids.extend(c.notch_slots.iter().filter_map(|slot| {
        let (runtime, _) = local_model_id(&slot.provider)?;
        c.providers
            .disabled
            .contains(runtime)
            .then(|| slot.provider.clone())
    }));
    ids
}
#[tauri::command]
pub fn get_provider_settings(app: AppHandle) -> Preferences {
    app.state::<crate::AppState>()
        .cfg
        .lock()
        .unwrap()
        .providers
        .clone()
}
#[tauri::command]
pub fn set_provider_settings(
    app: AppHandle,
    minimax_china: bool,
    gemini_token_budget: Option<u64>,
) -> Result<(), String> {
    if gemini_token_budget.is_some_and(|n| n == 0 || n > 9_007_199_254_740_991) {
        return Err("请输入有效的月度 token 预算".into());
    }
    let st = app.state::<crate::AppState>();
    let mut cfg = st.cfg.lock().unwrap();
    let mut next = cfg.clone();
    next.providers.minimax_china = minimax_china;
    next.providers.gemini_token_budget = gemini_token_budget;
    crate::config::save_checked(&next)?;
    *cfg = next;
    drop(cfg);
    request("minimax");
    request("gemini-api");
    Ok(())
}

pub fn start(app: AppHandle) {
    purge_disabled(&app);
    std::thread::spawn(move || {
        crate::activity::lower_thread_priority();
        let discovered_profiles = profile_list();
        let mut last_attempt = BTreeMap::<(String, u64), u64>::new();
        let mut in_flight = BTreeMap::<(String, u64), InFlight>::new();
        let (finished, completed) = std::sync::mpsc::channel::<(String, u64)>();
        // Custom probes share one HTTP gate. Keep at most one scheduled probe
        // outstanding, so dozens of endpoints cannot build a stale queue.
        let mut custom_last_attempt = BTreeMap::<(String, u64), u64>::new();
        let mut custom_in_flight: Option<(String, u64)> = None;
        let (custom_finished, custom_completed) = std::sync::mpsc::channel::<(String, u64)>();
        loop {
            while let Ok(key) = completed.try_recv() {
                in_flight.remove(&key);
            }
            while let Ok(key) = custom_completed.try_recv() {
                if custom_in_flight.as_ref() == Some(&key) {
                    custom_in_flight = None;
                }
            }
            let now = crate::now_ms();
            for ((id, epoch), flight) in &mut in_flight {
                if !flight.reported && now.saturating_sub(flight.started) >= 60_000 {
                    flight.reported = true;
                    let current = snapshot(id);
                    with_current(&app, id, *epoch, || {
                        if matches!(id.as_str(), "ollama-local" | "lmstudio") {
                            crate::local_runtime::forget_models(id);
                        }
                        publish_profile_unchecked(&app, id, timed_out(current, now));
                    });
                }
            }
            let busy = remote_busy(&app);
            for descriptor in CATALOG {
                let id = descriptor.id;
                if !enabled(&app, id) {
                    continue;
                }
                let epoch = generation(id);
                let key = (id.to_owned(), epoch);
                if in_flight.contains_key(&key) {
                    continue;
                }
                let old = snapshot(id);
                let forced = store().lock().unwrap().requested.remove(id);
                let interval = if matches!(id, "ollama-local" | "lmstudio") {
                    1_000
                } else if busy {
                    60_000
                } else {
                    300_000
                };
                if !should_collect(now, last_attempt.get(&key).copied(), interval, forced, &old) {
                    continue;
                }
                last_attempt.insert(key.clone(), now);
                in_flight.insert(
                    key.clone(),
                    InFlight {
                        started: now,
                        reported: false,
                    },
                );
                let app = app.clone();
                let finished = finished.clone();
                std::thread::spawn(move || {
                    collect_catalog(&app, id, epoch, old);
                    let _ = finished.send((id.into(), epoch));
                });
            }
            for profile in discovered_profiles
                .iter()
                .filter(|profile| profile.kind != "claude")
            {
                let id = &profile.id;
                if !enabled(&app, id) {
                    continue;
                }
                let epoch = generation(id);
                let key = (id.clone(), epoch);
                if in_flight.contains_key(&key) {
                    continue;
                }
                let old = snapshot(id);
                let forced = store().lock().unwrap().requested.remove(id);
                let interval = if busy { 60_000 } else { 300_000 };
                if !should_collect(now, last_attempt.get(&key).copied(), interval, forced, &old) {
                    continue;
                }
                last_attempt.insert(key.clone(), now);
                in_flight.insert(
                    key.clone(),
                    InFlight {
                        started: now,
                        reported: false,
                    },
                );
                let app = app.clone();
                let profile = profile.clone();
                let finished = finished.clone();
                std::thread::spawn(move || {
                    let snap = if profile.kind == "codex" {
                        crate::codex::read_profile(&profile.home, old)
                    } else {
                        crate::antigravity::read_profile(&profile.home, old)
                    };
                    publish_profile_if_current(&app, &profile.id, epoch, snap);
                    let _ = finished.send((profile.id, epoch));
                });
            }
            if crate::smoke::root().is_none() && custom_in_flight.is_none() {
                let endpoints: Vec<_> = app
                    .state::<crate::AppState>()
                    .cfg
                    .lock()
                    .unwrap()
                    .custom_endpoints
                    .iter()
                    .filter(|endpoint| endpoint.enabled)
                    .map(|endpoint| endpoint.id.clone())
                    .collect();
                let candidates: Vec<_> = endpoints
                    .into_iter()
                    .filter_map(|id| {
                        let provider_id = format!("custom-endpoint-{id}");
                        enabled(&app, &provider_id).then(|| (id, generation(&provider_id)))
                    })
                    .collect();
                custom_last_attempt.retain(|key, _| candidates.contains(key));
                let interval = if busy { 60_000 } else { 300_000 };
                if let Some((id, epoch)) =
                    next_custom_probe(crate::now_ms(), interval, &candidates, &custom_last_attempt)
                {
                    custom_last_attempt.insert((id.clone(), epoch), crate::now_ms());
                    custom_in_flight = Some((id.clone(), epoch));
                    let app = app.clone();
                    let finished = custom_finished.clone();
                    tauri::async_runtime::spawn(async move {
                        let _ = crate::custom_endpoint::probe_custom_endpoint_at_epoch(
                            app,
                            id.clone(),
                            epoch,
                        )
                        .await;
                        let _ = finished.send((id, epoch));
                    });
                }
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    });
}

struct InFlight {
    started: u64,
    reported: bool,
}

fn next_custom_probe(
    now: u64,
    interval: u64,
    candidates: &[(String, u64)],
    last_attempt: &BTreeMap<(String, u64), u64>,
) -> Option<(String, u64)> {
    candidates
        .iter()
        .filter(|key| {
            last_attempt
                .get(*key)
                .is_none_or(|last| now.saturating_sub(*last) >= interval)
        })
        .min_by_key(|key| last_attempt.get(*key).copied().unwrap_or(0))
        .cloned()
}

fn should_collect(
    now: u64,
    previous: Option<u64>,
    interval: u64,
    forced: bool,
    old: &UsageSnapshot,
) -> bool {
    if now < old.backoff_until {
        return false;
    }
    forced
        || previous.is_none_or(|last| {
            now.saturating_sub(last) >= interval
                || old.windows.iter().any(|window| {
                    window
                        .resets_at
                        .is_some_and(|reset| reset > last && reset <= now)
                })
        })
}

/// Swift UsageStore ticks every 60 seconds, refreshing all remote providers
/// while an enabled session is busy, on a quota rollover, or after 300 idle
/// seconds. Built-in collectors keep their own serial worker and epoch gate;
/// this shared wait supplies the same due decision without another poller.
fn remote_busy(app: &AppHandle) -> bool {
    let state = app.state::<crate::AppState>();
    let disabled = state.cfg.lock().unwrap().providers.disabled.clone();
    let activities = state.activity.lock().unwrap().clone();
    let renew_pid = crate::usage::renewal_pid();
    let sessions = state
        .store
        .lock()
        .unwrap()
        .snapshot_filtered("en", "en", false, false, &disabled)
        .sessions;
    busy_from_rows(&activities, &sessions, &disabled, renew_pid)
        || (enabled(app, "lmstudio") && crate::lmstudio_metrics::is_busy())
}

fn busy_from_rows(
    activities: &[crate::activity::Activity],
    sessions: &[crate::state::Session],
    disabled: &BTreeSet<String>,
    renew_pid: Option<u32>,
) -> bool {
    let activity_busy = activities.iter().any(|row| {
        let parent_disabled = row
            .provider
            .split_once(":model:")
            .is_some_and(|(parent, _)| disabled.contains(parent));
        row.state == "busy" && !disabled.contains(&row.provider) && !parent_disabled
    });
    let claude_busy = sessions.iter().any(|session| {
        session.state == crate::state::ST_RUNNING
            && !disabled.contains(&session.provider)
            && Some(session.ppid) != renew_pid
    });
    activity_busy || claude_busy
}

fn remote_reset_due(app: &AppHandle, last: u64, now: u64) -> bool {
    let rolled = |snap: &UsageSnapshot| {
        snap.windows.iter().any(|window| {
            window
                .resets_at
                .is_some_and(|reset| reset > last && reset <= now)
        })
    };
    let snapshots = store().lock().unwrap().snapshots.clone();
    if snapshots
        .iter()
        .any(|(id, snap)| enabled(app, id) && rolled(snap))
    {
        return true;
    }
    let state = app.state::<crate::AppState>();
    let reset_due = [
        ("claude", &state.usage),
        ("codex", &state.codex),
        ("cursor", &state.cursor),
        ("grok", &state.grok),
        ("gemini", &state.antigravity),
        ("glm", &state.glm),
    ]
    .into_iter()
    .any(|(id, snapshot)| enabled(app, id) && rolled(&snapshot.lock().unwrap()));
    reset_due
}

fn remote_due(last: u64, now: u64, busy: bool, reset_due: bool) -> bool {
    busy || reset_due || now.saturating_sub(last) >= 300_000
}

pub(crate) fn wait_remote_due(
    app: &AppHandle,
    requested: &std::sync::atomic::AtomicBool,
    last: u64,
) {
    use std::sync::atomic::Ordering;
    let mut tick = last.saturating_add(60_000);
    loop {
        if requested.swap(false, Ordering::Relaxed) {
            return;
        }
        let now = crate::now_ms();
        if now >= tick {
            if remote_due(
                last,
                now,
                remote_busy(app),
                remote_reset_due(app, last, now),
            ) {
                return;
            }
            tick = tick.saturating_add(((now - tick) / 60_000 + 1) * 60_000);
        }
        std::thread::sleep(Duration::from_secs(1));
    }
}

fn timed_out(mut old: UsageSnapshot, now: u64) -> UsageSnapshot {
    if old.windows.is_empty() {
        old.status = "error".into();
        old.note = "no response".into();
    } else if now.saturating_sub(old.fetched_at) >= 900_000 {
        old.status = "stale".into();
    }
    old
}

fn collect_catalog(app: &AppHandle, id: &'static str, epoch: u64, old: UsageSnapshot) {
    let china = app
        .state::<crate::AppState>()
        .cfg
        .lock()
        .unwrap()
        .providers
        .minimax_china;
    let mut model_update = None;
    let result = if matches!(id, "deepseek" | "qianwenai") {
        web_reading(app, id, china)
    } else if id == "minimax" {
        match transport::fetch(id, china) {
            Err(Failure::Absent) => web_reading(app, id, china),
            other => Some(other),
        }
    } else if id == "kiro" {
        Some(kiro::read(app, epoch))
    } else if id == "gemini-api" {
        let budget = app
            .state::<crate::AppState>()
            .cfg
            .lock()
            .unwrap()
            .providers
            .gemini_token_budget;
        Some(gemini_logs::read(
            &dirs::home_dir().unwrap_or_default(),
            budget,
        ))
    } else if matches!(id, "ollama-local" | "lmstudio") {
        let prefs = app
            .state::<crate::AppState>()
            .cfg
            .lock()
            .unwrap()
            .local_runtime
            .clone();
        Some(
            crate::local_runtime::fetch(
                id,
                if id == "ollama-local" {
                    &prefs.ollama
                } else {
                    &prefs.lmstudio
                },
                &prefs.disabled_models,
            )
            .map(|(windows, reading)| {
                model_update = Some(reading);
                UsageSnapshot {
                    windows,
                    ..Default::default()
                }
            }),
        )
    } else {
        Some(transport::fetch(id, china))
    };
    let Some(result) = result else { return };
    with_current(app, id, epoch, || {
        let snap = match result {
            Ok(mut reading) => {
                reading.status = "ok".into();
                reading.fetched_at = crate::now_ms();
                store().lock().unwrap().rate_limit_attempts.remove(id);
                reading
            }
            Err(Failure::OpenCodeThrottle(hint) | Failure::MiniMaxThrottle(hint)) => {
                let mut st = store().lock().unwrap();
                let attempts = st.rate_limit_attempts.entry(id.into()).or_default();
                let delay = open_code_backoff(*attempts, hint);
                *attempts = attempts.saturating_add(1);
                drop(st);
                failure(old, Failure::Throttle(delay), crate::now_ms())
            }
            Err(error) if matches!(id, "ollama-local" | "lmstudio") => {
                let mut failed = failure(UsageSnapshot::default(), error, crate::now_ms());
                if failed.note == "无法连接服务，保留上次读数" {
                    failed.note = "无法连接本地服务".into();
                }
                failed
            }
            Err(error) => failure(old, error, crate::now_ms()),
        };
        if let Some(reading) = model_update {
            crate::local_runtime::commit_models(id, reading);
        } else if matches!(id, "ollama-local" | "lmstudio") {
            crate::local_runtime::forget_models(id);
        }
        publish_profile_unchecked(app, id, snap)
    });
}

fn open_code_backoff(attempts: u32, retry_after: Option<u64>) -> u64 {
    60u64
        .saturating_mul(1u64 << attempts.min(4))
        .max(retry_after.unwrap_or(0))
        .min(900)
}
pub(crate) fn persist(path: &std::path::Path, bytes: &[u8]) -> Result<(), String> {
    use std::io::Write;
    let parent = path.parent().ok_or("Missing parent")?;
    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let mut temp = tempfile::NamedTempFile::new_in(parent).map_err(|e| e.to_string())?;
    temp.write_all(bytes)
        .and_then(|_| temp.as_file().sync_all())
        .map_err(|e| e.to_string())?;
    temp.persist(path).map_err(|e| e.error.to_string())?;
    Ok(())
}
#[derive(Debug)]
pub(super) enum Failure {
    Absent,
    Auth,
    Expired,
    Denied,
    Unsupported(&'static str),
    Throttle(u64),
    OpenCodeThrottle(Option<u64>),
    MiniMaxThrottle(Option<u64>),
    MissingEndpoint,
    Api(String),
    Invalid,
    Network,
}
fn failure(mut old: UsageSnapshot, e: Failure, now: u64) -> UsageSnapshot {
    match &e {
        Failure::Auth => {
            return UsageSnapshot {
                status: "needsAuth".into(),
                note: "登录已失效，请在原应用重新登录".into(),
                ..Default::default()
            };
        }
        Failure::Expired => {
            return UsageSnapshot {
                status: "needsAuth".into(),
                note: "凭据已过期，请在原应用续期".into(),
                ..Default::default()
            };
        }
        Failure::Unsupported(reason) => {
            return UsageSnapshot {
                status: "unsupported".into(),
                note: (*reason).into(),
                ..Default::default()
            };
        }
        _ => {}
    }
    let (status, note) = match e {
        Failure::Absent => ("absent", "未找到登录凭据".into()),
        Failure::Auth => unreachable!(),
        Failure::Expired => unreachable!(),
        Failure::Denied => ("accessDenied", "服务拒绝访问，请检查账户权限".into()),
        Failure::Unsupported(_) => unreachable!(),
        Failure::Throttle(seconds) => {
            old.backoff_until = now.saturating_add(seconds.max(60).saturating_mul(1000));
            ("backoff", "服务限流，等待重试时间".into())
        }
        Failure::OpenCodeThrottle(_) => ("backoff", "服务限流，等待重试时间".into()),
        Failure::MiniMaxThrottle(_) => ("backoff", "服务限流，等待重试时间".into()),
        Failure::MissingEndpoint => ("error", "服务用量端点不存在".into()),
        Failure::Api(code) => ("error", code),
        Failure::Invalid => ("error", "服务未返回可识别的用量数据".into()),
        Failure::Network => ("error", "无法连接服务，保留上次读数".into()),
    };
    // The pinned UsageStore retains a previous reading's explicit stale
    // state after a transient failure, even if its timestamp is recent (for
    // example, just after restoring the archive on launch).
    if old.status != "stale" || old.windows.is_empty() {
        old.status = status.into();
    }
    old.note = note;
    old
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Barrier, Mutex};

    #[test]
    fn scheduler_uses_busy_and_idle_intervals_and_rollover_once() {
        let old = UsageSnapshot {
            windows: vec![crate::usage::LimitWindow {
                id: "weekly".into(),
                resets_at: Some(90_000),
                ..Default::default()
            }],
            ..Default::default()
        };
        assert!(should_collect(0, None, 300_000, false, &old));
        assert!(!should_collect(59_999, Some(0), 60_000, false, &old));
        assert!(should_collect(60_000, Some(0), 60_000, false, &old));
        assert!(!should_collect(89_999, Some(60_000), 300_000, false, &old));
        assert!(should_collect(90_000, Some(60_000), 300_000, false, &old));
        assert!(!should_collect(91_000, Some(90_000), 300_000, false, &old));
    }

    #[test]
    fn custom_scheduler_starts_new_ids_and_epochs_once_without_queueing() {
        let a = ("a".to_string(), 1);
        let b = ("b".to_string(), 1);
        let candidates = vec![a.clone(), b.clone()];
        let mut attempts = BTreeMap::new();
        assert_eq!(
            next_custom_probe(1_000, 300_000, &candidates, &attempts),
            Some(a.clone())
        );
        attempts.insert(a.clone(), 1_000);
        assert_eq!(
            next_custom_probe(1_001, 300_000, &candidates, &attempts),
            Some(b.clone())
        );
        attempts.insert(b, 1_001);
        assert_eq!(
            next_custom_probe(60_999, 60_000, &candidates, &attempts),
            None
        );
        assert_eq!(
            next_custom_probe(61_000, 60_000, &candidates, &attempts),
            Some(a)
        );
        assert_eq!(
            next_custom_probe(1_002, 300_000, &[("a".into(), 2)], &attempts),
            Some(("a".into(), 2))
        );
        assert_eq!(next_custom_probe(500_000, 300_000, &[], &attempts), None);
    }

    #[test]
    fn builtin_due_rule_matches_sixty_second_ticks() {
        assert!(!remote_due(100_000, 160_000, false, false));
        assert!(remote_due(100_000, 160_000, true, false));
        assert!(remote_due(100_000, 160_000, false, true));
        assert!(!remote_due(100_000, 399_999, false, false));
        assert!(remote_due(100_000, 400_000, false, false));
    }

    #[test]
    fn live_claude_registry_makes_builtin_due_at_sixty_seconds() {
        let mut store = crate::state::Store::default();
        store.replace_registry(vec![crate::claude_session_monitor::LiveSession {
            id: "claude.42".into(),
            session_id: Some("session-a".into()),
            provider: "claude".into(),
            name: "work".into(),
            detail: "working".into(),
            state: "busy",
            waiting_for: None,
            since: 100_000,
            pid: 42,
            process_started_at: Some(1),
            cwd: "/tmp/work".into(),
        }]);
        let disabled = BTreeSet::new();
        let sessions = store
            .snapshot_filtered("en", "en", false, false, &disabled)
            .sessions;
        assert_eq!(sessions[0].state, crate::state::ST_RUNNING);
        assert!(remote_due(
            100_000,
            160_000,
            busy_from_rows(&[], &sessions, &disabled, None),
            false
        ));
        assert!(!busy_from_rows(&[], &sessions, &disabled, Some(42)));
        let disabled = BTreeSet::from(["claude".to_string()]);
        assert!(!busy_from_rows(&[], &sessions, &disabled, None));
    }

    #[test]
    fn disabled_activity_cannot_hold_remote_collectors_in_busy_cadence() {
        let rows = vec![crate::activity::Activity {
            id: "model-task".into(),
            provider: "lmstudio:model:instance-a".into(),
            state: "busy".into(),
            name: "generating".into(),
            detail: String::new(),
            waiting_for: None,
            since: 100_000,
            queued: 0,
            focusable: false,
        }];
        assert!(busy_from_rows(&rows, &[], &BTreeSet::new(), None));
        assert!(!busy_from_rows(
            &rows,
            &[],
            &BTreeSet::from(["lmstudio".to_string()]),
            None
        ));
        assert!(!busy_from_rows(
            &rows,
            &[],
            &BTreeSet::from(["lmstudio:model:instance-a".to_string()]),
            None
        ));
    }

    #[test]
    fn stalled_provider_ages_without_destroying_recent_evidence() {
        let old = UsageSnapshot {
            status: "ok".into(),
            fetched_at: 100_000,
            windows: vec![crate::usage::LimitWindow {
                id: "session".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        assert_eq!(timed_out(old.clone(), 100_000 + 60_000).status, "ok");
        assert_eq!(timed_out(old, 100_000 + 900_000).status, "stale");
        assert_eq!(timed_out(UsageSnapshot::default(), 0).status, "error");
    }

    #[test]
    fn opencode_throttle_doubles_and_honors_server_floor() {
        assert_eq!(open_code_backoff(0, None), 60);
        assert_eq!(open_code_backoff(1, Some(90)), 120);
        assert_eq!(open_code_backoff(2, Some(500)), 500);
        assert_eq!(open_code_backoff(10, None), 900);
        assert_eq!(open_code_backoff(10, Some(1200)), 900);
    }

    #[test]
    fn unsupported_plan_discards_old_metered_windows() {
        let old = UsageSnapshot {
            status: "ok".into(),
            windows: vec![crate::usage::LimitWindow {
                id: "rolling".into(),
                used: 0.8,
                ..Default::default()
            }],
            ..Default::default()
        };
        let result = failure(old, Failure::Unsupported("No Go plan"), 0);
        assert_eq!(result.status, "unsupported");
        assert!(result.windows.is_empty());
        assert_eq!(result.note, "No Go plan");
    }

    #[test]
    fn first_install_and_new_profiles_follow_swift_seen_connection_rules() {
        let discovered: BTreeSet<String> = ["claude", "codex", "cursor", "glm"]
            .into_iter()
            .map(str::to_owned)
            .collect();
        let mut prefs = Preferences::default();
        assert!(reconcile_preferences(&mut prefs, &discovered, false));
        assert_eq!(
            prefs.connected.as_ref().unwrap(),
            &["claude", "codex"]
                .into_iter()
                .map(|id| id.to_string())
                .collect::<BTreeSet<_>>()
        );
        assert!(prefs.disabled.contains("cursor"));
        prefs.connected.as_mut().unwrap().remove("claude");
        prefs.disabled.insert("claude".into());
        let mut later = discovered.clone();
        later.extend(["claude-work".into(), "codex-work".into(), "kimi".into()]);
        reconcile_preferences(&mut prefs, &later, false);
        assert!(!prefs.connected.as_ref().unwrap().contains("claude"));
        assert!(prefs.connected.as_ref().unwrap().contains("claude-work"));
        assert!(prefs.connected.as_ref().unwrap().contains("codex-work"));
        assert!(prefs.disabled.contains("kimi"));
        prefs.connected.as_mut().unwrap().remove("claude-work");
        prefs.disabled.insert("claude-work".into());
        reconcile_preferences(&mut prefs, &discovered, false); // temporarily absent
        reconcile_preferences(&mut prefs, &later, false); // rediscovered
        assert!(prefs.disabled.contains("claude-work"));
    }

    #[test]
    fn a_saved_legacy_off_list_is_inverted_once() {
        let discovered: BTreeSet<String> = ["claude", "codex", "cursor"]
            .into_iter()
            .map(str::to_owned)
            .collect();
        let mut prefs = Preferences::default();
        prefs.disabled.insert("cursor".into());
        reconcile_preferences(&mut prefs, &discovered, true);
        assert!(prefs.connected.as_ref().unwrap().contains("codex"));
        assert!(!prefs.connected.as_ref().unwrap().contains("cursor"));
        assert_eq!(prefs.seen, discovered);
    }

    #[test]
    fn auto_written_old_config_is_not_mistaken_for_an_explicit_all_on_choice() {
        let mut cfg = crate::config::Config::default();
        assert!(!has_legacy_connection_choice(&cfg, true));
        cfg.providers.disabled.insert("cursor".into());
        assert!(has_legacy_connection_choice(&cfg, true));
        cfg.providers.disabled.clear();
        cfg.notch_selection_explicit = true;
        assert!(has_legacy_connection_choice(&cfg, true));
        cfg.notch_selection_explicit = false;
        cfg.notch_providers.push("cursor".into());
        assert!(has_legacy_connection_choice(&cfg, true));
        assert!(!has_legacy_connection_choice(&cfg, false));
    }

    #[test]
    fn late_result_after_disconnect_and_reconnect_cannot_recreate_account_data() {
        #[derive(Default)]
        struct Writes {
            snapshots: BTreeMap<String, u32>,
            archive: BTreeMap<String, u32>,
            completions: Vec<String>,
        }
        let gate = Mutex::new(BTreeMap::<String, u64>::new());
        let writes = Mutex::new(Writes::default());
        let reading_started = Barrier::new(2);
        let release_old_result = Barrier::new(2);

        std::thread::scope(|scope| {
            scope.spawn(|| {
                let captured = gate.lock().unwrap().get("account-a").copied().unwrap_or(0);
                reading_started.wait();
                release_old_result.wait();
                let epochs = gate.lock().unwrap();
                let accepted = guarded_commit(&epochs, "account-a", captured, true, || {
                    let mut out = writes.lock().unwrap();
                    out.snapshots.insert("account-a".into(), 99);
                    out.archive.insert("account-a".into(), 99);
                    out.completions.push("account-a".into());
                });
                assert!(
                    accepted.is_none(),
                    "an old read must lose even when enabled again"
                );
            });

            reading_started.wait();
            {
                let mut epochs = gate.lock().unwrap();
                *epochs.entry("account-a".into()).or_default() += 1; // off
                let mut out = writes.lock().unwrap();
                out.snapshots.remove("account-a");
                out.archive.remove("account-a");
                *epochs.entry("account-a".into()).or_default() += 1; // on
            }
            release_old_result.wait();
        });

        let epochs = gate.lock().unwrap();
        assert!(guarded_commit(&epochs, "account-b", 0, true, || {
            let mut out = writes.lock().unwrap();
            out.snapshots.insert("account-b".into(), 7);
            out.archive.insert("account-b".into(), 7);
            out.completions.push("account-b".into());
        })
        .is_some());
        let out = writes.lock().unwrap();
        assert!(!out.snapshots.contains_key("account-a"));
        assert!(!out.archive.contains_key("account-a"));
        assert_eq!(out.completions, ["account-b"]);
        assert_eq!(out.snapshots.get("account-b"), Some(&7));
    }

    #[test]
    fn account_connection_preserves_order_and_an_explicit_empty_selection() {
        let mut cfg = crate::config::Config::default();
        let ids = vec!["claude".into(), "codex".into()];
        super::set_connection(&mut cfg, &ids, "claude", false);
        assert!(cfg.providers.disabled.contains("claude"));
        assert_eq!(cfg.notch_providers, ["codex"]);
        super::set_connection(&mut cfg, &ids, "codex", false);
        assert!(cfg.notch_selection_explicit && cfg.notch_slots.is_empty());
        super::set_connection(&mut cfg, &ids, "claude", true);
        assert_eq!(cfg.notch_providers, ["claude"]);
        assert!(!cfg.providers.disabled.contains("claude"));
        assert!(cfg.providers.disabled.contains("codex"));
        super::set_connection(&mut cfg, &ids, "claude", true);
        assert_eq!(cfg.notch_providers, ["claude"]);
    }
    use super::*;
    #[test]
    fn failure_does_not_invent_or_erase_usage() {
        let old = UsageSnapshot {
            fetched_at: 42,
            ..Default::default()
        };
        let failed = failure(old, Failure::Throttle(7200), 1000);
        assert_eq!(failed.backoff_until, 7_201_000);
        assert_eq!(failed.fetched_at, 42);
        assert!(failed.windows.is_empty());
        assert_eq!(
            failure(failed, Failure::Denied, 2000).status,
            "accessDenied"
        );
    }

    #[test]
    fn signed_out_web_account_discards_old_quota_but_business_error_keeps_it() {
        let old = UsageSnapshot {
            status: "ok".into(),
            fetched_at: 42,
            backoff_until: 9000,
            windows: vec![crate::usage::LimitWindow {
                id: "spend".into(),
                used: 0.8,
                has_fraction: Some(true),
                ..Default::default()
            }],
            ..Default::default()
        };
        let business = failure(old.clone(), Failure::Api("Bad Request".into()), 1000);
        assert_eq!(business.status, "error");
        assert_eq!(business.note, "Bad Request");
        assert_eq!(business.windows.len(), 1);
        assert_eq!(business.windows[0].id, "spend");
        let signed_out = failure(old, Failure::Auth, 1000);
        assert_eq!(signed_out.status, "needsAuth");
        assert!(signed_out.windows.is_empty());
        assert_eq!(signed_out.fetched_at, 0);
        assert_eq!(signed_out.backoff_until, 0);
        let expired = failure(business, Failure::Expired, 1000);
        assert_eq!(expired.status, "needsAuth");
        assert!(expired.windows.is_empty());
        assert_eq!(expired.fetched_at, 0);
        let explicit_stale = failure(
            UsageSnapshot {
                status: "stale".into(),
                fetched_at: 950,
                windows: vec![crate::usage::LimitWindow {
                    id: "spend".into(),
                    ..Default::default()
                }],
                ..Default::default()
            },
            Failure::Network,
            1000,
        );
        assert_eq!(explicit_stale.status, "stale");
        assert_eq!(explicit_stale.note, "无法连接服务，保留上次读数");
    }

    #[test]
    fn authentication_refresh_reaches_due_rule_after_old_account_backoff() {
        let old = UsageSnapshot {
            backoff_until: 120_000,
            ..Default::default()
        };
        assert!(!should_collect(1_000, Some(0), 60_000, true, &old));
        let mut st = Store::default();
        st.snapshots.insert("qianwenai".into(), old.clone());
        assert!(queue_after_web_auth(&mut st, "qianwenai", 1_000));
        assert!(st.requested.contains("qianwenai"));
        assert!(should_collect(
            1_000,
            Some(0),
            60_000,
            st.requested.contains("qianwenai"),
            st.snapshots.get("qianwenai").unwrap()
        ));
        st.snapshots.insert("minimax".into(), old);
        assert!(!queue_after_web_auth(&mut st, "minimax", 1_000));
        assert_eq!(st.snapshots["minimax"].backoff_until, 120_000);
    }
}
