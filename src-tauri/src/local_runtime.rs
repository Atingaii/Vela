//! Read-only model discovery. Ollama memory and LM Studio model size are deliberately distinct.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{BTreeMap, BTreeSet},
    io::Read,
    sync::{Mutex, OnceLock},
    time::Duration,
};
use tauri::{AppHandle, Emitter, Manager};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Preferences {
    pub ollama: String,
    /// The explicit relay opt-in from Swift's `ollamaMetricsEnabled`.
    pub ollama_metrics_enabled: bool,
    pub lmstudio: String,
    pub disabled_models: BTreeSet<String>,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            ollama: "http://127.0.0.1:11434".into(),
            ollama_metrics_enabled: false,
            lmstudio: "http://127.0.0.1:1234".into(),
            disabled_models: BTreeSet::new(),
        }
    }
}
impl Preferences {
    /// Early Velo builds used `runtime/name`; Swift uses the full model-cell id.
    pub fn normalize_disabled_models(&mut self) {
        self.disabled_models = self.disabled_models.iter().map(|key| {
            for runtime in ["ollama-local", "lmstudio"] {
                if let Some(name) = key.strip_prefix(&format!("{runtime}/")) {
                    return format!("{runtime}:model:{name}");
                }
            }
            key.clone()
        }).collect();
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Model {
    pub id: String,
    /// Swift's model.name: the loaded instance for LM Studio, model tag for Ollama.
    pub name: String,
    pub brand: Option<String>,
    pub key: String,
    pub size: Option<u64>,
    pub size_kind: String,
    pub gpu_size: Option<u64>,
    pub context: Option<u64>,
    pub quantization: Option<String>,
    pub expires_at: Option<String>,
}

pub fn model_brand(name: &str) -> Option<&'static str> {
    let lowercase = name.trim().to_lowercase();
    let base = lowercase.rsplit('/').next().unwrap_or_default().split(':').next().unwrap_or_default();
    const BRANDS: &[(&str, &[&str])] = &[
        ("deepseek", &["deepseek"]),
        ("qwen", &["qwen", "qwq", "qvq"]),
        ("gemma", &["gemma", "codegemma", "paligemma", "recurrentgemma", "shieldgemma", "embeddinggemma", "functiongemma", "medgemma"]),
        ("meta", &["llama", "meta-llama", "codellama"]),
        ("mistral", &["mistral", "ministral", "mixtral", "codestral", "devstral", "magistral"]),
    ];
    BRANDS.iter().find_map(|(brand, prefixes)| prefixes.iter().any(|prefix| {
        base.strip_prefix(prefix).is_some_and(|tail| tail.is_empty() || tail.chars().next()
            .is_some_and(|next| next.is_ascii_digit() || next == '-' || next == '_'))
    }).then_some(*brand))
}

pub fn memory_text(model: &Model) -> String {
    let bytes = model.gpu_size.filter(|size| *size > 0).or(model.size);
    let Some(bytes) = bytes else { return "—".into(); };
    let units = [("EB", 1024_f64.powi(6)), ("PB", 1024_f64.powi(5)),
        ("TB", 1024_f64.powi(4)), ("GB", 1024_f64.powi(3)),
        ("MB", 1024_f64.powi(2)), ("KB", 1024_f64), ("B", 1.)];
    let (unit, divisor) = units.into_iter().find(|(_, divisor)| bytes as f64 >= *divisor)
        .unwrap_or(("B", 1.));
    let value = bytes as f64 / divisor;
    let text = if (value.fract()).abs() < 0.05 { format!("{value:.0}") }
        else { format!("{value:.1}") };
    format!("{text} {unit}")
}
#[derive(Clone, Debug, Default, Serialize)]
pub struct ModelReading {
    pub models: Vec<Model>,
    pub fetched_at: u64,
    pub address: String,
}
static MODELS: OnceLock<Mutex<BTreeMap<String, ModelReading>>> = OnceLock::new();
fn model_store() -> &'static Mutex<BTreeMap<String, ModelReading>> {
    MODELS.get_or_init(|| Mutex::new(BTreeMap::new()))
}
#[tauri::command]
pub fn get_local_models() -> BTreeMap<String, ModelReading> {
    model_store().lock().unwrap().clone()
}
pub(crate) fn commit_models(id: &str, reading: ModelReading) {
    model_store().lock().unwrap().insert(id.into(), reading);
}
pub(crate) fn forget_models(id: &str) {
    model_store().lock().unwrap().remove(id);
}

/// A runtime is the collector; each loaded model is a separate notch cell.
/// Inventory is transient and cannot turn a failed or stopped runtime into old live cells.
pub(crate) fn all_cell_snapshots(
    id: &str,
    runtime: &crate::usage::UsageSnapshot,
) -> Vec<(String, crate::usage::UsageSnapshot)> {
    if runtime.status != "ok" { return Vec::new(); }
    let Some(reading) = model_store().lock().unwrap().get(id).cloned() else { return Vec::new(); };
    let mut cells = cell_snapshots_from_reading(id, runtime, &reading);
    if id == "ollama-local" {
        let activity = crate::ollama_relay::status();
        let shows = crate::ollama_relay::desired_enabled();
        for (_, snapshot) in &mut cells {
            snapshot.shows_local_performance = shows;
            if shows {
                let model = snapshot.local_model.as_ref().unwrap();
                let key = crate::ollama_stream::Observer::model_key(&model.name);
                snapshot.local_performance = activity.performances.get(&key).cloned()
                    .and_then(crate::local_metrics::Performance::from_ollama);
            }
        }
    } else if id == "lmstudio" {
        let now = crate::now_ms();
        for (cell, snapshot) in &mut cells {
            snapshot.local_performance = crate::lmstudio_metrics::performance(cell);
            snapshot.local_ledger = crate::lmstudio_metrics::ledger_summary(cell, now);
            snapshot.local_context_fraction = snapshot.local_ledger.as_ref()
                .and_then(|ledger| ledger.context_fraction(snapshot.local_model.as_ref().and_then(|model| model.context)));
        }
    }
    cells
}

fn cell_snapshots_from_reading(
    id: &str,
    runtime: &crate::usage::UsageSnapshot,
    reading: &ModelReading,
) -> Vec<(String, crate::usage::UsageSnapshot)> {
    if runtime.status != "ok" { return Vec::new(); }
    reading.models.iter().map(|model| {
        let cell_id = format!("{id}:model:{}", model.id);
        let snap = crate::usage::UsageSnapshot {
            status: runtime.status.clone(),
            fetched_at: runtime.fetched_at,
            fidelity: runtime.fidelity,
            local_model: Some(model.clone()),
            source_provider_id: Some(id.into()),
            local_runtime_measures_speed: id == "lmstudio",
            shows_local_performance: id == "lmstudio",
            ..Default::default()
        };
        (cell_id, snap)
    }).collect()
}

pub(crate) fn cell_snapshots(
    id: &str,
    runtime: &crate::usage::UsageSnapshot,
    disabled: &BTreeSet<String>,
) -> Vec<(String, crate::usage::UsageSnapshot)> {
    all_cell_snapshots(id, runtime).into_iter().filter(|(_, snap)| {
        snap.local_model.as_ref().is_some_and(|model| !disabled.contains(&format!("{id}:model:{}", model.id)))
    }).collect()
}

/// Live model work is keyed by the cell, not by the shared Ollama / LM Studio
/// runtime. A single busy model must not animate every model in that runtime.
pub(crate) fn activity_rows(disabled_models: &BTreeSet<String>) -> Vec<crate::activity::Activity> {
    let inventory = model_store().lock().unwrap().clone();
    activity_rows_from(&inventory, &crate::ollama_relay::status(),
        &crate::lmstudio_metrics::status(), disabled_models)
}

fn activity_rows_from(
    inventory: &BTreeMap<String, ModelReading>,
    relay: &crate::ollama_relay::RelayStatus,
    lmstudio: &crate::lmstudio_metrics::Status,
    disabled_models: &BTreeSet<String>,
) -> Vec<crate::activity::Activity> {
    let mut rows = Vec::new();
    if relay.ready {
        if let Some(reading) = inventory.get("ollama-local") {
            for model in &reading.models {
                let cell = format!("ollama-local:model:{}", model.id);
                if disabled_models.contains(&cell) { continue; }
                let key = crate::ollama_stream::Observer::model_key(&model.name);
                if let Some(&since) = relay.thinking_models.get(&key) {
                    rows.push(crate::activity::Activity {
                        id: cell.clone(), provider: cell, state: "busy".into(),
                        name: "Thinking".into(), detail: "Thinking".into(),
                        waiting_for: None, since, queued: 0, focusable: false,
                    });
                }
            }
        }
    }
    if lmstudio.linked {
        if let Some(reading) = inventory.get("lmstudio") {
            for model in &reading.models {
                let cell = format!("lmstudio:model:{}", model.id);
                if disabled_models.contains(&cell) { continue; }
                let Some(active) = lmstudio.activities.get(&cell) else { continue; };
                let (name, note) = match active.phase.as_str() {
                    "processingPrompt" | "processing_prompt" => ("Reading prompt", "Prompt"),
                    "generating" => ("Generating", "Generating"),
                    _ => continue,
                };
                rows.push(crate::activity::Activity {
                    id: cell.clone(), provider: cell, state: "busy".into(),
                    name: name.into(),
                    detail: if active.queued > 0 { format!("{note} · {} queued", active.queued) }
                        else { note.into() },
                    waiting_for: None, since: active.since, queued: active.queued,
                    focusable: false,
                });
            }
        }
    }
    rows
}

pub fn endpoint(input: &str) -> Result<tauri::Url, String> {
    let mut url = tauri::Url::parse(input.trim()).map_err(|_| "本地服务地址无效")?;
    if url.scheme() != "http"
        || !matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"))
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.path() != "/"
        || url.port() == Some(0)
    {
        return Err("请输入本机 HTTP 地址，例如 http://127.0.0.1:11434".into());
    }
    if url.host_str() == Some("localhost") {
        url.set_host(Some("127.0.0.1")).map_err(|_| "地址无效")?;
    }
    Ok(url)
}

/// On first use only, follow LM Studio's own configured HTTP port. A saved Velo address wins.
pub fn configured_lmstudio_address() -> Option<String> {
    let root = dirs::home_dir()?.join(".lmstudio/.internal/http-server-config.json");
    configured_lmstudio_address_from(&root)
}
fn configured_lmstudio_address_from(path: &std::path::Path) -> Option<String> {
    let file = std::fs::File::open(path).ok()?;
    let mut data = Vec::new();
    file.take(64 * 1024 + 1).read_to_end(&mut data).ok()?;
    if data.len() > 64 * 1024 { return None; }
    let value: Value = serde_json::from_slice(&data).ok()?;
    let port = value["port"].as_u64().filter(|port| (1..=65535).contains(port))?;
    Some(format!("http://127.0.0.1:{port}"))
}
pub fn parse(id: &str, v: &Value) -> Result<Vec<Model>, String> {
    let mut result = Vec::new();
    let mut seen = BTreeSet::new();
    for m in v["models"].as_array().ok_or("服务没有返回模型列表")? {
        if id == "ollama-local" {
            let name = m["name"].as_str().ok_or("模型名称缺失")?;
            result.push(Model {
                id: name.into(),
                name: name.into(),
                brand: model_brand(name).map(str::to_owned),
                key: name.into(),
                size: m["size"].as_u64(),
                size_kind: "memory".into(),
                gpu_size: m["size_vram"].as_u64(),
                context: m["context_length"].as_u64(),
                quantization: m["details"]["quantization_level"]
                    .as_str()
                    .map(str::to_owned),
                expires_at: m["expires_at"].as_str().map(str::to_owned),
            });
            for field in ["size", "size_vram", "context_length"] {
                if !m[field].is_null() && m[field].as_u64().is_none() {
                    return Err("模型数值无效".into());
                }
            }
        } else if m["type"] == "llm" {
            for instance in m["loaded_instances"].as_array().into_iter().flatten() {
                result.push(Model {
                    id: instance["id"].as_str().ok_or("实例名称缺失")?.into(),
                    name: instance["id"].as_str().ok_or("实例名称缺失")?.into(),
                    brand: model_brand(instance["id"].as_str().unwrap_or_default())
                        .or_else(|| model_brand(m["key"].as_str().unwrap_or_default())).map(str::to_owned),
                    key: m["key"].as_str().ok_or("模型名称缺失")?.into(),
                    size: m["size_bytes"].as_u64(),
                    size_kind: "modelSize".into(),
                    gpu_size: None,
                    context: instance["config"]["context_length"]
                        .as_u64()
                        .or_else(|| m["max_context_length"].as_u64()),
                    quantization: m["quantization"]["name"].as_str().map(str::to_owned),
                    expires_at: None,
                });
            }
        }
    }
    for m in &result {
        if m.id.trim().is_empty() || !seen.insert(&m.id) || m.context == Some(0) {
            return Err("模型名称或上下文无效".into());
        }
    }
    result.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(result)
}
pub fn fetch(
    id: &str,
    address: &str,
    disabled: &BTreeSet<String>,
) -> Result<(Vec<crate::usage::LimitWindow>, ModelReading), super::providers::Failure> {
    let mut url = endpoint(address).map_err(|_| super::providers::Failure::Invalid)?;
    url.set_path(if id == "ollama-local" {
        "/api/ps"
    } else {
        "/api/v1/models"
    });
    // A literal loopback endpoint and no proxy/redirect prevents local credentials reaching another host.
    let agent = ureq::AgentBuilder::new()
        .try_proxy_from_env(false)
        .redirects(0)
        .timeout(Duration::from_secs(3))
        .build();
    let request = agent.get(url.as_str());
    let request = if id == "lmstudio" {
        if let Some(token) = crate::secrets::lmstudio_token() {
            request.set("Authorization", &format!("Bearer {token}"))
        } else { request }
    } else { request };
    let response = request.call().map_err(|error| match error {
        ureq::Error::Status(401 | 403, _) => super::providers::Failure::Auth,
        ureq::Error::Status(_, _) => super::providers::Failure::Invalid,
        _ => super::providers::Failure::Network,
    })?;
    let mut bytes = Vec::new();
    response
        .into_reader()
        .take(2 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| super::providers::Failure::Network)?;
    if bytes.len() > 2 * 1024 * 1024 {
        return Err(super::providers::Failure::Invalid);
    }
    let value = serde_json::from_slice(&bytes).map_err(|_| super::providers::Failure::Invalid)?;
    let models = parse(id, &value).map_err(|_| super::providers::Failure::Invalid)?;
    let reading = ModelReading {
        models: models.clone(),
        fetched_at: crate::now_ms(),
        address: address.into(),
    };
    let mut windows = vec![crate::usage::LimitWindow {
        remaining: None,
        used_count: None,
        id: "models".into(),
        label: "Loaded models".into(),
        count: Some(models.len() as i64),
        has_fraction: Some(false),
        used: 0.,
        resets_at: None,
        duration: None,
        derived: false,
        group: None,
        ..Default::default()
    }];
    for m in models
        .into_iter()
        .filter(|m| m.context.is_some())
        .filter(|m| !disabled.contains(&format!("{id}/{}", m.id)))
    {
        let size = m
            .size
            .map(|n| {
                format!(
                    " · {} {:.1} GiB",
                    if m.size_kind == "memory" {
                        "Memory"
                    } else {
                        "Model size"
                    },
                    n as f64 / 1073741824.
                )
            })
            .unwrap_or_default();
        windows.push(crate::usage::LimitWindow {
            remaining: None,
            used_count: None,
            id: m.id.clone(),
            label: format!(
                "{}{}{}{}",
                m.id,
                size,
                m.quantization
                    .map(|q| format!(" · {q}"))
                    .unwrap_or_default(),
                if m.context.is_none() {
                    " · Context unknown"
                } else {
                    ""
                }
            ),
            count: m.context.map(|n| n.min(i64::MAX as u64) as i64),
            has_fraction: Some(false),
            used: 0.,
            resets_at: None,
            duration: None,
            derived: false,
            group: Some("Context capacity · tokens".into()),
            ..Default::default()
        });
    }
    Ok((windows, reading))
}
#[tauri::command]
pub fn get_local_runtime_settings(app: AppHandle) -> Preferences {
    app.state::<crate::AppState>()
        .cfg
        .lock()
        .unwrap()
        .local_runtime
        .clone()
}

#[derive(Clone, serde::Serialize)]
pub struct LocalActivity {
    pub relay: crate::ollama_relay::RelayStatus,
    pub lmstudio: crate::lmstudio_metrics::Status,
}

#[tauri::command]
pub fn get_local_runtime_activity() -> LocalActivity {
    LocalActivity { relay: crate::ollama_relay::status(), lmstudio: crate::lmstudio_metrics::status() }
}

/// Keep the relay lifecycle tied to the saved switch and provider connection.
/// The relay uses a direct loopback connector and never borrows API credentials.
pub fn reconcile(app: &AppHandle) {
    let state = app.state::<crate::AppState>();
    let cfg = state.cfg.lock().unwrap();
    let connected = cfg.providers.connected.as_ref()
        .is_some_and(|ids| ids.contains("ollama-local"))
        && !cfg.providers.disabled.contains("ollama-local");
    let enabled = connected && cfg.local_runtime.ollama_metrics_enabled;
    let endpoint = cfg.local_runtime.ollama.clone();
    let lmstudio_connected = cfg.providers.connected.as_ref()
        .is_some_and(|ids| ids.contains("lmstudio"))
        && !cfg.providers.disabled.contains("lmstudio");
    let lmstudio_endpoint = cfg.local_runtime.lmstudio.clone();
    drop(cfg);
    if !enabled { crate::ollama_relay::disallow(); }
    crate::ollama_relay::configure(enabled, &endpoint);
    crate::lmstudio_metrics::configure(lmstudio_connected, &lmstudio_endpoint);
}
#[tauri::command]
pub fn set_local_runtime_settings(app: AppHandle, mut prefs: Preferences) -> Result<(), String> {
    prefs.normalize_disabled_models();
    endpoint(&prefs.ollama)?;
    endpoint(&prefs.lmstudio)?;
    crate::providers::with_lifecycle_mut(|epochs| {
        let st = app.state::<crate::AppState>();
        let mut cfg = st.cfg.lock().unwrap();
        let old = cfg.local_runtime.clone();
        let mut next = cfg.clone();
        next.local_runtime = prefs;
        crate::config::save_checked(&next)?;
        let changed_ollama = old.ollama != next.local_runtime.ollama
            || old.disabled_models != next.local_runtime.disabled_models;
        let changed_lmstudio = old.lmstudio != next.local_runtime.lmstudio
            || old.disabled_models != next.local_runtime.disabled_models;
        *cfg = next;
        drop(cfg);
        for (id, changed) in [
            ("ollama-local", changed_ollama),
            ("lmstudio", changed_lmstudio),
        ] {
            if changed {
                *epochs.entry(id.into()).or_default() += 1;
                crate::providers::forget_local_reading(id);
            }
        }
        Ok::<(), String>(())
    })?;
    reconcile(&app);
    let _ = app.emit("providers", crate::providers::get_providers(app.clone()));
    for id in ["ollama-local", "lmstudio"] {
        if crate::providers::enabled(&app, id) {
            crate::providers::request(id);
        }
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn loopback_only_no_credentials_no_paths() {
        assert_eq!(
            endpoint("http://localhost:11434").unwrap().host_str(),
            Some("127.0.0.1")
        );
        for bad in [
            "http://example.com",
            "http://127.0.0.1.evil.test",
            "http://a@127.0.0.1",
            "http://127.0.0.1/path",
            "http://127.0.0.1?x=1",
        ] {
            assert!(endpoint(bad).is_err());
        }
    }
    #[test]
    fn lmstudio_configured_port_only_accepts_a_local_numeric_port() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("http-server-config.json");
        std::fs::write(&path, r#"{"port":4892}"#).unwrap();
        assert_eq!(configured_lmstudio_address_from(&path).as_deref(), Some("http://127.0.0.1:4892"));
        for bad in [r#"{"port":0}"#, r#"{"port":65536}"#, r#"{"port":"1234"}"#, "not json"] {
            std::fs::write(&path,bad).unwrap();
            assert!(configured_lmstudio_address_from(&path).is_none());
        }
    }
    #[test]
    fn lmstudio_instances_are_distinct_and_disk_size_is_not_memory() {
        let models=parse("lmstudio",&json!({"models":[{"type":"embedding","key":"skip"},{"type":"llm","key":"qwen","size_bytes":100,"loaded_instances":[{"id":"one","config":{"context_length":8192}},{"id":"two"}]}]})).unwrap();
        assert_eq!(models.len(), 2);
        assert_eq!(models[0].size_kind, "modelSize");
        assert_eq!(models[0].context, Some(8192));
        assert_eq!(models[1].context, None);
        assert!(parse("ollama-local", &json!({"error":"bad route"})).is_err());
        assert!(parse("ollama-local", &json!({"models":[{"name":"x","size":-1}]})).is_err());
    }

    #[test]
    fn loaded_models_have_independent_cells_and_share_runtime_polling() {
        let models = parse("lmstudio", &json!({"models":[{"type":"llm","key":"qwen","size_bytes":100,
            "loaded_instances":[{"id":"one"},{"id":"two"}]}]})).unwrap();
        let reading = ModelReading { models, fetched_at: 100, address: "http://127.0.0.1:1234".into() };
        let runtime = crate::usage::UsageSnapshot { status: "ok".into(), fetched_at: 110, ..Default::default() };
        let cells = cell_snapshots_from_reading("lmstudio", &runtime, &reading);
        assert_eq!(cells.iter().map(|(id,_)| id.as_str()).collect::<Vec<_>>(),
            vec!["lmstudio:model:one", "lmstudio:model:two"]);
        assert!(cells.iter().all(|(_,snap)| snap.windows.is_empty() && snap.local_runtime_measures_speed
            && snap.source_provider_id.as_deref() == Some("lmstudio") && snap.fetched_at == 110));
        assert_eq!(cells[0].1.local_model.as_ref().unwrap().name, "one");
        commit_models("lmstudio", reading);
        let disabled = BTreeSet::from(["lmstudio:model:one".to_string()]);
        let visible = cell_snapshots("lmstudio", &runtime, &disabled);
        assert_eq!(visible.iter().map(|(id,_)| id.as_str()).collect::<Vec<_>>(), vec!["lmstudio:model:two"]);
        assert_eq!(get_local_models()["lmstudio"].models.len(), 2);
        forget_models("lmstudio");
        let mut legacy = Preferences { disabled_models: BTreeSet::from(["lmstudio/one".into(), "ollama-local/model/x".into()]), ..Default::default() };
        legacy.normalize_disabled_models();
        assert!(legacy.disabled_models.contains("lmstudio:model:one"));
        assert!(legacy.disabled_models.contains("ollama-local:model:model/x"));
        let failed = crate::usage::UsageSnapshot { status: "error".into(), ..Default::default() };
        assert!(cell_snapshots_from_reading("lmstudio", &failed, &ModelReading::default()).is_empty());
    }
    #[test]
    fn one_busy_model_does_not_animate_its_siblings_or_disabled_cells() {
        fn model(id: &str) -> Model {
            Model { id: id.into(), name: id.into(), brand: None, key: id.into(),
                size: None, size_kind: "modelSize".into(), gpu_size: None,
                context: None, quantization: None, expires_at: None }
        }
        let inventory = BTreeMap::from([
            ("ollama-local".into(), ModelReading { models: vec![model("thinking"), model("idle")],
                ..Default::default() }),
            ("lmstudio".into(), ModelReading { models: vec![model("prompt"), model("idle")],
                ..Default::default() }),
        ]);
        let relay = crate::ollama_relay::RelayStatus {
            ready: true, status: "Ready".into(), address: "http://127.0.0.1:11435".into(),
            thinking_models: BTreeMap::from([("thinking:latest".into(), 100)]),
            performances: BTreeMap::new(),
        };
        let mut lm = crate::lmstudio_metrics::Status::default();
        lm.linked = true;
        lm.activities.insert("lmstudio:model:prompt".into(), crate::lmstudio_metrics::Activity {
            phase: "processingPrompt".into(), queued: 2, since: 200,
        });
        let rows = activity_rows_from(&inventory, &relay, &lm, &BTreeSet::new());
        assert_eq!(rows.iter().map(|row| row.provider.as_str()).collect::<Vec<_>>(),
            ["ollama-local:model:thinking", "lmstudio:model:prompt"]);
        assert_eq!(rows[1].queued, 2);
        assert_eq!(rows[1].detail, "Prompt · 2 queued");
        assert_eq!(activity_rows_from(&inventory, &relay, &lm,
            &BTreeSet::from(["lmstudio:model:prompt".into()])).len(), 1);
        assert!(activity_rows_from(&inventory,
            &crate::ollama_relay::RelayStatus { ready: false, ..relay },
            &crate::lmstudio_metrics::Status { linked: false, ..lm }, &BTreeSet::new()).is_empty());
    }
    #[test]
    fn model_brand_uses_name_prefix_before_architecture_or_tag() {
        assert_eq!(model_brand("registry/deepseek-r1-distill-qwen:7b"), Some("deepseek"));
        assert_eq!(model_brand("qwen3:latest"), Some("qwen"));
        assert_eq!(model_brand("meta-llama/Meta-Llama-3"), Some("meta"));
        assert_eq!(model_brand("my-qwen-model"), None);
        assert_eq!(model_brand("gemmach"), None);
    }
}
