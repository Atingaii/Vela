//! OpenAI-compatible health/model discovery plus explicitly manual quota tracking.
use serde::{Deserialize, Serialize};
use std::io::Read;
// A refresh-all must not start one blocking HTTP worker per endpoint.
static PROBE_GATE: tauri::async_runtime::Mutex<()> = tauri::async_runtime::Mutex::const_new(());
use tauri::{AppHandle, Emitter, Manager};
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Endpoint {
    pub id: String,
    pub name: String,
    pub url: String,
    pub header: String,
    pub model: String,
    pub models: Vec<String>,
    pub enabled: bool,
    pub color: String,
    pub icon: String,
    pub unit: String,
    pub budget: Option<f64>,
    pub used: f64,
    pub display_remaining: bool,
    pub show_currency: bool,
    pub latency_ms: Option<u64>,
    pub health: String,
    pub checked_at: Option<u64>,
}
impl Default for Endpoint {
    fn default() -> Self {
        Self {
            id: String::new(),
            name: String::new(),
            url: String::new(),
            header: "Authorization".into(),
            model: String::new(),
            models: Vec::new(),
            enabled: true,
            color: "#6366f1".into(),
            icon: "openai".into(),
            unit: "currency".into(),
            budget: None,
            used: 0.,
            display_remaining: false,
            show_currency: false,
            latency_ms: None,
            health: "idle".into(),
            checked_at: None,
        }
    }
}
fn url(s: &str) -> Result<tauri::Url, String> {
    let u = tauri::Url::parse(s.trim()).map_err(|_| "请输入 HTTP 或 HTTPS 地址")?;
    if !matches!(u.scheme(), "http" | "https")
        || u.host_str().is_none()
        || !u.username().is_empty()
        || u.password().is_some()
        || u.query().is_some()
        || u.fragment().is_some()
    {
        return Err("地址不能包含凭据、查询参数或片段".into());
    }
    Ok(u)
}
fn validate(e: &Endpoint) -> Result<(), String> {
    if e.id.is_empty()
        || e.id.len() > 64
        || !e.id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
    {
        return Err("端点 ID 无效".into());
    }
    if e.name.trim().is_empty()
        || e.name.len() > 120
        || !e.used.is_finite()
        || e.used < 0.
        || e.budget.is_some_and(|n| !n.is_finite() || n <= 0.)
        || !matches!(e.unit.as_str(), "currency" | "tokens")
    {
        return Err("名称、预算或已用量无效".into());
    }
    if e.header.is_empty()
        || e.header.len() > 100
        || !e
            .header
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
    {
        return Err("凭据请求头无效".into());
    }
    if e.color.len() != 7
        || !e.color.starts_with('#')
        || !e.color[1..].bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err("颜色无效".into());
    }
    url(&e.url)?;
    Ok(())
}
pub fn readings(app: &AppHandle) -> Vec<crate::providers::Reading> {
    let endpoints = app
        .state::<crate::AppState>()
        .cfg
        .lock()
        .unwrap()
        .custom_endpoints
        .clone();
    endpoints
        .into_iter()
        .map(|e| {
            let label = if e.unit == "currency" {
                format!("Manual account usage · ${:.2}", e.used)
            } else {
                format!("Manual token usage · {:.0}", e.used)
            };
            let snap = crate::usage::UsageSnapshot {
                status: if e.health == "unreachable" {
                    "stale"
                } else {
                    "ok"
                }
                .into(),
                windows: vec![crate::usage::LimitWindow {
                    id: "manual".into(),
                    label,
                    used: e.budget.map(|b| e.used / b).unwrap_or(0.),
                    count: if e.budget.is_some() {
                        None
                    } else {
                        Some(e.used as i64)
                    },
                    resets_at: None,
                    duration: None,
                    derived: true,
                    group: None,
                }],
                fetched_at: e.checked_at.unwrap_or(0),
                note: format!(
                    "{} · {} · {}",
                    e.model,
                    e.health,
                    if e.display_remaining {
                        e.budget
                            .map(|b| format!("Remaining {:.2}", (b - e.used).max(0.)))
                            .unwrap_or_default()
                    } else {
                        String::new()
                    }
                ),
                backoff_until: 0,
            };
            crate::providers::Reading {
                id: format!("custom-endpoint-{}", e.id),
                name: e.name,
                headline: "manual".into(),
                guidance: "模型与连通性来自 /models；预算与已用量由用户填写。".into(),
                enabled: e.enabled,
                snap,
            }
        })
        .collect()
}
#[tauri::command]
pub fn get_custom_endpoints(app: AppHandle) -> Vec<Endpoint> {
    app.state::<crate::AppState>()
        .cfg
        .lock()
        .unwrap()
        .custom_endpoints
        .clone()
}
#[tauri::command]
pub fn save_custom_endpoint(app: AppHandle, mut endpoint: Endpoint) -> Result<(), String> {
    validate(&endpoint)?;
    endpoint.models.truncate(200);
    let state = app.state::<crate::AppState>();
    let mut cfg = state.cfg.lock().unwrap();
    let mut next = cfg.clone();
    let provider_id = format!("custom-endpoint-{}", endpoint.id);
    if endpoint.enabled {
        next.providers.disabled.remove(&provider_id);
    } else {
        next.providers.disabled.insert(provider_id);
    }
    if let Some(old) = next
        .custom_endpoints
        .iter_mut()
        .find(|e| e.id == endpoint.id)
    {
        *old = endpoint;
    } else {
        if next.custom_endpoints.len() >= 64 {
            return Err("最多支持 64 个自定义端点".into());
        }
        next.custom_endpoints.push(endpoint);
    }
    crate::config::save_checked(&next)?;
    *cfg = next;
    drop(cfg);
    let _ = app.emit("providers", crate::providers::get_providers(app.clone()));
    Ok(())
}
#[tauri::command]
pub fn delete_custom_endpoint(app: AppHandle, id: String) -> Result<(), String> {
    let state = app.state::<crate::AppState>();
    let mut cfg = state.cfg.lock().unwrap();
    let mut next = cfg.clone();
    if !next.custom_endpoints.iter().any(|e| e.id == id) {
        return Err("端点不存在".into());
    }
    next.custom_endpoints.retain(|e| e.id != id);
    crate::config::save_checked(&next)?;
    *cfg = next;
    drop(cfg);
    // Removing the saved endpoint makes it unreachable even if the vault item was already removed.
    let _ = crate::secrets::save_provider_secret(format!("endpoint-{id}"), String::new());
    let _ = app.emit("providers", crate::providers::get_providers(app.clone()));
    Ok(())
}
#[tauri::command]
pub async fn probe_custom_endpoint(app: AppHandle, id: String) -> Result<Endpoint, String> {
    let _permit = PROBE_GATE.lock().await;
    let endpoint = get_custom_endpoints(app.clone())
        .into_iter()
        .find(|e| e.id == id)
        .ok_or("端点不存在")?;
    let original = endpoint.clone();
    let result = tauri::async_runtime::spawn_blocking(move || probe(endpoint))
        .await
        .map_err(|_| "检测任务失败")?;
    let state = app.state::<crate::AppState>();
    let mut cfg = state.cfg.lock().unwrap();
    let mut next = cfg.clone();
    let current = next
        .custom_endpoints
        .iter_mut()
        .find(|e| e.id == id)
        .ok_or("端点已删除")?;
    merge_probe(current, &original, &result)?;
    let updated = current.clone();
    crate::config::save_checked(&next)?;
    *cfg = next;
    drop(cfg);
    let _ = app.emit("providers", crate::providers::get_providers(app.clone()));
    Ok(updated)
}
fn merge_probe(
    current: &mut Endpoint,
    original: &Endpoint,
    result: &Endpoint,
) -> Result<(), String> {
    // A late response must neither restore a deleted endpoint nor overwrite edits made in flight.
    if current.url != original.url || current.header != original.header {
        return Err("端点已修改，请重新检测".into());
    }
    current.models = result.models.clone();
    current.health = result.health.clone();
    current.latency_ms = result.latency_ms;
    current.checked_at = result.checked_at;
    Ok(())
}
fn probe(mut e: Endpoint) -> Endpoint {
    let started = std::time::Instant::now();
    let request = (|| -> Result<Vec<String>, String> {
        let mut target = url(&e.url)?;
        if !target.path().ends_with("/models") {
            target.set_path(&format!("{}/models", target.path().trim_end_matches('/')));
        }
        let agent = ureq::AgentBuilder::new()
            .timeout(std::time::Duration::from_secs(6))
            .redirects(0)
            .build();
        let mut request = agent.get(target.as_str());
        if let Ok(key) = crate::secrets::read(&format!("endpoint-{}", e.id)) {
            let value = if e.header.eq_ignore_ascii_case("Authorization") {
                format!("Bearer {key}")
            } else {
                key
            };
            request = request.set(&e.header, &value);
        }
        let response = request.call().map_err(|_| "连接失败")?;
        if response.status() != 200 {
            return Err("非正常 HTTP 响应".into());
        }
        let mut body = Vec::new();
        response
            .into_reader()
            .take(2 * 1024 * 1024 + 1)
            .read_to_end(&mut body)
            .map_err(|_| "无法读取响应")?;
        if body.len() > 2 * 1024 * 1024 {
            return Err("模型列表过大".into());
        }
        let v: serde_json::Value = serde_json::from_slice(&body).map_err(|_| "无效的模型列表")?;
        let data = v["data"].as_array().ok_or("响应不是 OpenAI 模型列表")?;
        let mut models: Vec<_> = data
            .iter()
            .filter_map(|m| m["id"].as_str())
            .filter(|s| !s.is_empty() && s.len() <= 200)
            .take(200)
            .map(str::to_owned)
            .collect();
        models.sort();
        models.dedup();
        Ok(models)
    })();
    let elapsed = started.elapsed().as_millis() as u64;
    e.latency_ms = Some(elapsed);
    e.checked_at = Some(crate::now_ms());
    match request {
        Ok(models) => {
            e.models = models;
            e.health = if elapsed > 800 { "slow" } else { "online" }.into();
        }
        Err(_) => {
            e.health = "unreachable".into();
        }
    }
    e
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn late_probe_preserves_edits_and_rejects_changed_destination() {
        let original = Endpoint {
            url: "http://127.0.0.1:1234/v1".into(),
            ..Default::default()
        };
        let mut edited = original.clone();
        edited.name = "Edited".into();
        edited.used = 10.;
        edited.enabled = false;
        let mut result = original.clone();
        result.health = "online".into();
        merge_probe(&mut edited, &original, &result).unwrap();
        assert_eq!(edited.name, "Edited");
        assert_eq!(edited.used, 10.);
        assert!(!edited.enabled);
        edited.url = "http://127.0.0.1:8080/v1".into();
        assert!(merge_probe(&mut edited, &original, &result).is_err());
    }
    #[test]
    fn endpoints_reject_ambiguous_secrets_and_invalid_budgets() {
        let mut e = Endpoint {
            id: "test".into(),
            name: "Test".into(),
            url: "http://127.0.0.1:1234/v1".into(),
            ..Default::default()
        };
        assert!(validate(&e).is_ok());
        e.url = "https://user:key@example.com/v1".into();
        assert!(validate(&e).is_err());
        e.url = "https://example.com/v1".into();
        e.budget = Some(0.);
        assert!(validate(&e).is_err());
        e.budget = Some(100.);
        e.header = "Authorization\r\nHost".into();
        assert!(validate(&e).is_err());
    }
}
