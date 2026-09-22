//! Read-only model discovery. Ollama memory and LM Studio model size are deliberately distinct.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{BTreeMap, BTreeSet},
    io::Read,
    sync::{Mutex, OnceLock},
    time::Duration,
};
use tauri::{AppHandle, Manager};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Preferences {
    pub ollama: String,
    pub lmstudio: String,
    pub disabled_models: BTreeSet<String>,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            ollama: "http://127.0.0.1:11434".into(),
            lmstudio: "http://127.0.0.1:1234".into(),
            disabled_models: BTreeSet::new(),
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Model {
    pub id: String,
    pub key: String,
    pub size: Option<u64>,
    pub size_kind: String,
    pub gpu_size: Option<u64>,
    pub context: Option<u64>,
    pub quantization: Option<String>,
    pub expires_at: Option<String>,
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
pub fn parse(id: &str, v: &Value) -> Result<Vec<Model>, String> {
    let mut result = Vec::new();
    let mut seen = BTreeSet::new();
    for m in v["models"].as_array().ok_or("服务没有返回模型列表")? {
        if id == "ollama-local" {
            let name = m["name"].as_str().ok_or("模型名称缺失")?;
            result.push(Model {
                id: name.into(),
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
) -> Result<Vec<crate::usage::LimitWindow>, super::providers::Failure> {
    let mut url = endpoint(address).map_err(|_| super::providers::Failure::Invalid)?;
    url.set_path(if id == "ollama-local" {
        "/api/ps"
    } else {
        "/api/v1/models"
    });
    // A literal loopback endpoint and no proxy/redirect prevents local credentials reaching another host.
    let response = ureq::AgentBuilder::new()
        .try_proxy_from_env(false)
        .redirects(0)
        .timeout(Duration::from_secs(3))
        .build()
        .get(url.as_str())
        .call()
        .map_err(|_| super::providers::Failure::Network)?;
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
    model_store().lock().unwrap().insert(
        id.into(),
        ModelReading {
            models: models.clone(),
            fetched_at: crate::now_ms(),
            address: address.into(),
        },
    );
    let mut windows = vec![crate::usage::LimitWindow {
        id: "models".into(),
        label: "Loaded models".into(),
        count: Some(models.len() as i64),
        used: 0.,
        resets_at: None,
        duration: None,
        derived: false,
        group: None,
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
            used: 0.,
            resets_at: None,
            duration: None,
            derived: false,
            group: Some("Context capacity · tokens".into()),
        });
    }
    Ok(windows)
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
#[tauri::command]
pub fn set_local_runtime_settings(app: AppHandle, prefs: Preferences) -> Result<(), String> {
    endpoint(&prefs.ollama)?;
    endpoint(&prefs.lmstudio)?;
    let st = app.state::<crate::AppState>();
    let mut cfg = st.cfg.lock().unwrap();
    let mut next = cfg.clone();
    next.local_runtime = prefs;
    crate::config::save_checked(&next)?;
    *cfg = next;
    drop(cfg);
    crate::providers::request("ollama-local");
    crate::providers::request("lmstudio");
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
    fn lmstudio_instances_are_distinct_and_disk_size_is_not_memory() {
        let models=parse("lmstudio",&json!({"models":[{"type":"embedding","key":"skip"},{"type":"llm","key":"qwen","size_bytes":100,"loaded_instances":[{"id":"one","config":{"context_length":8192}},{"id":"two"}]}]})).unwrap();
        assert_eq!(models.len(), 2);
        assert_eq!(models[0].size_kind, "modelSize");
        assert_eq!(models[0].context, Some(8192));
        assert_eq!(models[1].context, None);
        assert!(parse("ollama-local", &json!({"error":"bad route"})).is_err());
        assert!(parse("ollama-local", &json!({"models":[{"name":"x","size":-1}]})).is_err());
    }
}
