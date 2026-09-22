//! Swift provider parity. One serial worker, bounded replies, per-provider backoff and cache.
//! Credentials owned by another CLI are borrowed read-only; no token refresh or redirects.
mod gemini_logs;
mod kiro;
mod parse;
mod profiles;
mod transport;

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
        guidance: "设置 MINIMAX_CODING_API_KEY 或在账户设置保存密钥。",
    },
    Descriptor {
        id: "ollama-cloud",
        name: "Ollama Cloud",
        headline: "monthly",
        guidance: "设置 OLLAMA_API_KEY 或在账户设置保存密钥。",
    },
];
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Preferences {
    pub disabled: BTreeSet<String>,
    pub minimax_china: bool,
    pub gemini_token_budget: Option<u64>,
}
#[derive(Clone, Serialize)]
pub struct Reading {
    pub id: String,
    pub name: String,
    pub headline: String,
    pub guidance: String,
    pub enabled: bool,
    pub snap: UsageSnapshot,
}
#[derive(Default)]
struct Store {
    snapshots: BTreeMap<String, UsageSnapshot>,
    requested: BTreeSet<String>,
}
static STORE: OnceLock<Mutex<Store>> = OnceLock::new();
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
        })
    })
}
fn cache_path() -> std::path::PathBuf {
    crate::config::config_path().with_file_name("providers-usage.json")
}
pub fn enabled(app: &AppHandle, id: &str) -> bool {
    let st = app.state::<crate::AppState>();
    let cfg = st.cfg.lock().unwrap();
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
            crate::usage::request_refresh();
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
#[tauri::command]
pub fn get_providers(app: AppHandle) -> Vec<Reading> {
    let mut result: Vec<Reading> = CATALOG
        .iter()
        .map(|p| Reading {
            id: p.id.into(),
            name: p.name.into(),
            headline: p.headline.into(),
            guidance: p.guidance.into(),
            enabled: enabled(&app, p.id),
            snap: snapshot(p.id),
        })
        .collect();
    for p in profile_list() {
        result.push(Reading {
            id: p.id.clone(),
            name: p.name,
            headline: p.headline.into(),
            guidance: "请在该账户对应的 CLI 配置目录登录".into(),
            enabled: enabled(&app, &p.id),
            snap: snapshot(&p.id),
        });
    }
    let own = snapshot("claude");
    if own.status != "absent" {
        result.push(Reading {
            id: "claude".into(),
            name: "Claude".into(),
            headline: "session".into(),
            guidance: String::new(),
            enabled: enabled(&app, "claude"),
            snap: own,
        });
    }
    result.extend(crate::custom_endpoint::readings(&app));
    result
}
fn profile_list() -> Vec<profiles::Profile> {
    profiles::discover(&dirs::home_dir().unwrap_or_default())
}
pub fn publish_profile(app: &AppHandle, id: &str, snap: UsageSnapshot) {
    let mut st = store().lock().unwrap();
    st.snapshots.insert(id.into(), snap);
    if let Ok(bytes) = serde_json::to_vec(&st.snapshots) {
        let _ = persist(&cache_path(), &bytes);
    }
    drop(st);
    let _ = app.emit("providers", get_providers(app.clone()));
}

#[tauri::command]
pub fn set_provider_enabled(app: AppHandle, id: String, value: bool) -> Result<(), String> {
    if !crate::custom_endpoint::readings(&app)
        .iter()
        .any(|p| p.id == id)
        && !CATALOG.iter().any(|p| p.id == id)
        && !crate::TRAY_PROVIDER_IDS.contains(&id.as_str())
        && !profile_list().iter().any(|p| p.id == id)
    {
        return Err("未知供应商".into());
    }
    {
        let state = app.state::<crate::AppState>();
        let mut cfg = state.cfg.lock().unwrap();
        let mut next = cfg.clone();
        if let Some(key) = id.strip_prefix("custom-endpoint-") {
            if let Some(e) = next.custom_endpoints.iter_mut().find(|e| e.id == key) {
                e.enabled = value;
            }
        }
        if value {
            next.providers.disabled.remove(&id);
        } else {
            next.providers.disabled.insert(id.clone());
        }
        crate::config::save_checked(&next)?;
        *cfg = next;
    }
    if value {
        crate::refresh_provider(&app, &id);
    }
    let _ = app.emit("providers", get_providers(app.clone()));
    let disabled = app
        .state::<crate::AppState>()
        .cfg
        .lock()
        .unwrap()
        .providers
        .disabled
        .clone();
    let _ = app.emit("disabled_providers", disabled);
    Ok(())
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
    std::thread::spawn(move || {
        crate::activity::lower_thread_priority();
        let mut next = BTreeMap::<String, u64>::new();
        loop {
            for descriptor in CATALOG {
                let id = descriptor.id;
                if !enabled(&app, id) {
                    continue;
                }
                let forced = store().lock().unwrap().requested.remove(id);
                let now = crate::now_ms();
                let old = snapshot(id);
                if now < old.backoff_until || (!forced && now < *next.get(id).unwrap_or(&0)) {
                    continue;
                }
                let china = app
                    .state::<crate::AppState>()
                    .cfg
                    .lock()
                    .unwrap()
                    .providers
                    .minimax_china;
                let result = if id == "kiro" {
                    kiro::read()
                } else if id == "gemini-api" {
                    let budget = app
                        .state::<crate::AppState>()
                        .cfg
                        .lock()
                        .unwrap()
                        .providers
                        .gemini_token_budget;
                    gemini_logs::read(&dirs::home_dir().unwrap_or_default(), budget)
                } else if matches!(id, "ollama-local" | "lmstudio") {
                    let prefs = app
                        .state::<crate::AppState>()
                        .cfg
                        .lock()
                        .unwrap()
                        .local_runtime
                        .clone();
                    crate::local_runtime::fetch(
                        id,
                        if id == "ollama-local" {
                            &prefs.ollama
                        } else {
                            &prefs.lmstudio
                        },
                        &prefs.disabled_models,
                    )
                } else {
                    transport::fetch(id, china)
                };
                // Turning a provider off while a request is in flight prevents publishing it.
                if !enabled(&app, id) {
                    continue;
                }
                let snap = match result {
                    Ok(windows) => UsageSnapshot {
                        status: "ok".into(),
                        windows,
                        fetched_at: crate::now_ms(),
                        note: String::new(),
                        backoff_until: 0,
                    },
                    Err(e) => failure(old, e, crate::now_ms()),
                };
                next.insert(
                    id.into(),
                    crate::now_ms()
                        + if matches!(id, "ollama-local" | "lmstudio") {
                            15_000
                        } else {
                            300_000
                        },
                );
                {
                    let mut s = store().lock().unwrap();
                    s.snapshots.insert(id.into(), snap);
                    if let Ok(bytes) = serde_json::to_vec(&s.snapshots) {
                        let _ = persist(&cache_path(), &bytes);
                    }
                }
                let _ = app.emit("providers", get_providers(app.clone()));
            }
            for p in profile_list().into_iter().filter(|p| p.kind != "claude") {
                if !enabled(&app, &p.id) {
                    continue;
                }
                let forced = store().lock().unwrap().requested.remove(&p.id);
                let now = crate::now_ms();
                let old = snapshot(&p.id);
                if now < old.backoff_until || (!forced && now < *next.get(&p.id).unwrap_or(&0)) {
                    continue;
                }
                let snap = if p.kind == "codex" {
                    crate::codex::read_profile(&p.home, old)
                } else {
                    crate::antigravity::read_profile(&p.home, old)
                };
                next.insert(p.id.clone(), crate::now_ms() + 300_000);
                if enabled(&app, &p.id) {
                    publish_profile(&app, &p.id, snap);
                }
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    });
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
    Throttle(u64),
    Invalid,
    Network,
}
fn failure(mut old: UsageSnapshot, e: Failure, now: u64) -> UsageSnapshot {
    let (status, note) = match e {
        Failure::Absent => ("absent", "未找到登录凭据"),
        Failure::Auth => ("needsAuth", "登录已失效，请在原应用重新登录"),
        Failure::Expired => ("needsAuth", "凭据已过期，请在原应用续期"),
        Failure::Denied => ("accessDenied", "服务拒绝访问，请检查账户权限"),
        Failure::Throttle(seconds) => {
            old.backoff_until = now.saturating_add(seconds.max(60).saturating_mul(1000));
            ("backoff", "服务限流，等待重试时间")
        }
        Failure::Invalid => ("error", "服务未返回可识别的用量数据"),
        Failure::Network => ("error", "无法连接服务，保留上次读数"),
    };
    old.status = status.into();
    old.note = note.into();
    old
}

#[cfg(test)]
mod tests {
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
}
