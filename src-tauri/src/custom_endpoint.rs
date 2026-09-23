//! OpenAI-compatible health/model discovery plus explicitly manual quota tracking.
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use std::io::{Read, Write};
use std::path::PathBuf;
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
    pub custom_icon_filename: Option<String>,
    pub unit: String,
    pub monthly_budget_usd: Option<f64>,
    pub current_spend_usd: Option<f64>,
    pub monthly_budget_tokens_m: Option<f64>,
    pub current_tokens_used_m: Option<f64>,
    /// Read-only compatibility for settings saved before separate currency/token amounts.
    pub budget: Option<f64>,
    pub used: f64,
    pub display_remaining: bool,
    pub show_currency: bool,
    pub latency_ms: Option<u64>,
    pub health: String,
    pub checked_at: Option<u64>,
    pub last_status_code: Option<u16>,
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
            custom_icon_filename: None,
            unit: "currency".into(),
            monthly_budget_usd: None,
            current_spend_usd: None,
            monthly_budget_tokens_m: None,
            current_tokens_used_m: None,
            budget: None,
            used: 0.,
            display_remaining: false,
            show_currency: false,
            latency_ms: None,
            health: "idle".into(),
            checked_at: None,
            last_status_code: None,
        }
    }
}
fn url(s: &str) -> Result<tauri::Url, String> {
    let u = tauri::Url::parse(s.trim()).map_err(|_| "请输入 HTTP 或 HTTPS 地址")?;
    if !matches!(u.scheme(), "http" | "https")
        || u.host_str().is_none()
        || !u.username().is_empty()
        || u.password().is_some()
    {
        return Err("地址不能包含凭据".into());
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
        || [e.budget, e.monthly_budget_usd, e.monthly_budget_tokens_m]
            .into_iter()
            .flatten()
            .any(|n| !n.is_finite() || n <= 0.)
        || [e.current_spend_usd, e.current_tokens_used_m]
            .into_iter()
            .flatten()
            .any(|n| !n.is_finite() || n < 0.)
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
    if e.custom_icon_filename
        .as_deref()
        .is_some_and(|filename| !valid_icon_filename(&e.id, filename))
    {
        return Err("自定义图标文件名无效".into());
    }
    Ok(())
}
impl Endpoint {
    fn active_budget(&self) -> Option<f64> {
        if self.unit == "tokens" {
            self.monthly_budget_tokens_m.or(self.budget)
        } else {
            self.monthly_budget_usd.or(self.budget)
        }
    }
    fn active_used(&self) -> f64 {
        if self.unit == "tokens" {
            self.current_tokens_used_m.unwrap_or(self.used)
        } else {
            self.current_spend_usd.unwrap_or(self.used)
        }
    }
}
fn icon_dir() -> PathBuf {
    crate::config::config_path().with_file_name("CustomIcons")
}
fn verified_icon_dir(create: bool) -> Option<PathBuf> {
    let dir = icon_dir();
    if create {
        std::fs::create_dir_all(&dir).ok()?;
    }
    let metadata = std::fs::symlink_metadata(&dir).ok()?;
    (metadata.is_dir() && !metadata.file_type().is_symlink()).then_some(dir)
}
fn validate_png(bytes: &[u8]) -> Result<(), String> {
    if bytes.len() > 2 * 1024 * 1024 || !bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Err("只接受 PNG 图标，且不得超过 2 MiB".into());
    }
    let mut decoder = png::Decoder::new_with_limits(
        std::io::Cursor::new(bytes),
        png::Limits {
            bytes: 8 * 1024 * 1024,
        },
    );
    let info = decoder.read_header_info().map_err(|_| "PNG 图标无效")?;
    if info.width == 0 || info.height == 0 || info.width > 512 || info.height > 512 {
        return Err("图标尺寸不得超过 512 像素".into());
    }
    let mut reader = decoder.read_info().map_err(|_| "PNG 图标无效")?;
    let output_size = reader.output_buffer_size();
    if output_size > 8 * 1024 * 1024 {
        return Err("PNG 图标过大".into());
    }
    let mut output = vec![0; output_size];
    reader.next_frame(&mut output).map_err(|_| "PNG 图标无效")?;
    Ok(())
}
fn valid_icon_filename(id: &str, filename: &str) -> bool {
    let Some(suffix) = filename.strip_prefix(&format!("{id}-")) else {
        return false;
    };
    let Some(nonce) = suffix.strip_suffix(".png") else {
        return false;
    };
    nonce.len() == 16 && nonce.bytes().all(|byte| byte.is_ascii_hexdigit())
}
pub fn icon_png_for(endpoint: &Endpoint) -> Option<Vec<u8>> {
    let filename = endpoint.custom_icon_filename.as_deref()?;
    if !valid_icon_filename(&endpoint.id, filename) {
        return None;
    }
    let path = verified_icon_dir(false)?.join(filename);
    let metadata = std::fs::symlink_metadata(&path).ok()?;
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() > 2 * 1024 * 1024
    {
        return None;
    }
    let bytes = std::fs::read(path).ok()?;
    validate_png(&bytes).ok()?;
    Some(bytes)
}
fn remove_icon_if_unreferenced(filename: &str, endpoints: &[Endpoint]) {
    if endpoints
        .iter()
        .any(|endpoint| endpoint.custom_icon_filename.as_deref() == Some(filename))
    {
        return;
    }
    let Some((id, _)) = filename
        .strip_suffix(".png")
        .and_then(|stem| stem.rsplit_once('-'))
    else {
        return;
    };
    if !valid_icon_filename(id, filename)
        || id.is_empty()
        || !id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return;
    }
    let Some(path) = verified_icon_dir(false).map(|dir| dir.join(filename)) else {
        return;
    };
    if std::fs::symlink_metadata(&path)
        .is_ok_and(|metadata| metadata.is_file() && !metadata.file_type().is_symlink())
    {
        let _ = std::fs::remove_file(path);
    }
}
#[tauri::command]
pub fn save_custom_icon(id: String, png_base64: String) -> Result<String, String> {
    if id.is_empty()
        || id.len() > 64
        || !id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return Err("端点 ID 无效".into());
    }
    if png_base64.len() > 3 * 1024 * 1024 {
        return Err("图标过大".into());
    }
    let png = STANDARD.decode(png_base64).map_err(|_| "图标数据无效")?;
    validate_png(&png)?;
    let filename = format!("{id}-{:016x}.png", rand::random::<u64>());
    let dir = verified_icon_dir(true).ok_or("无法创建图标目录")?;
    let path = dir.join(&filename);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .map_err(|_| "无法保存图标")?;
    file.write_all(&png).map_err(|_| "无法保存图标")?;
    Ok(filename)
}
#[tauri::command]
pub fn get_custom_icon(app: AppHandle, id: String) -> Option<String> {
    let endpoint = get_custom_endpoints(app)
        .into_iter()
        .find(|endpoint| endpoint.id == id)?;
    let bytes = icon_png_for(&endpoint)?;
    Some(format!("data:image/png;base64,{}", STANDARD.encode(bytes)))
}
#[tauri::command]
pub fn discard_custom_icon(app: AppHandle, filename: String) {
    let endpoints = get_custom_endpoints(app);
    remove_icon_if_unreferenced(&filename, &endpoints);
}
fn format_token_m(millions: f64) -> String {
    if millions >= 1000. {
        format!("{:.1}B", millions / 1000.)
    } else if millions >= 10. {
        format!("{:.0}M", millions)
    } else if millions >= 1. {
        let n = (millions * 10.).round() / 10.;
        if n.fract() == 0. {
            format!("{n:.0}M")
        } else {
            format!("{n:.1}M")
        }
    } else if millions > 0. {
        let n = (millions * 10000.).round() / 10.;
        if n.fract() == 0. {
            format!("{n:.0}k")
        } else {
            format!("{n:.1}k")
        }
    } else {
        "0M".into()
    }
}
fn next_month_start_ms() -> Option<u64> {
    use chrono::{Datelike, TimeZone};
    let now = chrono::Local::now();
    let (year, month) = if now.month() == 12 {
        (now.year() + 1, 1)
    } else {
        (now.year(), now.month() + 1)
    };
    chrono::Local
        .with_ymd_and_hms(year, month, 1, 0, 0, 0)
        .earliest()
        .map(|date| date.timestamp_millis() as u64)
}
fn endpoint_window(e: &Endpoint) -> crate::usage::LimitWindow {
    use crate::usage::{LimitWindow, UsageBand};
    let budget = e.active_budget();
    let spent = e.active_used();
    let has_budget = budget.is_some_and(|n| n > 0.);
    let remaining = budget.filter(|_| has_budget).map(|n| (n - spent).max(0.));
    let display = if has_budget && e.display_remaining {
        remaining.unwrap_or(0.)
    } else {
        spent
    };
    let (used_text, budget_text) = if e.unit == "tokens" {
        (
            format_token_m(display),
            budget.filter(|_| has_budget).map(format_token_m),
        )
    } else {
        (
            format!("${display:.2}"),
            budget.filter(|_| has_budget).map(|n| format!("${n:.2}")),
        )
    };
    let fraction = budget
        .map(|total| (spent / total).clamp(0., 1.))
        .unwrap_or(0.);
    let detail = if let Some(total) = budget_text {
        Some(if e.unit == "tokens" {
            if e.display_remaining {
                format!("{used_text} / {total} tokens remaining")
            } else {
                format!("{used_text} / {total} tokens")
            }
        } else if e.display_remaining {
            format!("{used_text} / {total} remaining")
        } else {
            format!("{used_text} / {total}")
        })
    } else if e.unit == "tokens" {
        Some(format!("{used_text} tokens"))
    } else {
        Some(used_text.clone())
    };
    LimitWindow {
        id: (if e.unit == "tokens" {
            if has_budget {
                "token-budget"
            } else {
                "token-tracking"
            }
        } else if has_budget {
            "monthly-budget"
        } else {
            "spend-tracking"
        })
        .into(),
        label: (if e.unit == "tokens" {
            if has_budget {
                if e.display_remaining {
                    "Remaining Tokens"
                } else {
                    "Monthly Tokens"
                }
            } else {
                "Tokens Used"
            }
        } else if has_budget {
            if e.display_remaining {
                "Remaining Budget"
            } else {
                "Monthly Budget"
            }
        } else {
            "Total Spend"
        })
        .into(),
        used: if e.display_remaining {
            1. - fraction
        } else {
            fraction
        },
        has_fraction: Some(has_budget),
        used_text: Some(used_text),
        detail,
        prefers_used_text: e.show_currency || !has_budget,
        band_override: if e.display_remaining && has_budget {
            Some(UsageBand::from_used_fraction(fraction))
        } else {
            None
        },
        resets_at: has_budget.then(next_month_start_ms).flatten(),
        duration: has_budget.then_some(30. * 86400.),
        derived: true,
        ..Default::default()
    }
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
            let window = endpoint_window(&e);
            let headline = window.id.clone();
            let snap = crate::usage::UsageSnapshot {
                plan: None,
                status: if matches!(e.last_status_code, Some(401 | 403)) {
                    "needsAuth"
                } else if e.health == "unreachable" {
                    "stale"
                } else {
                    "ok"
                }
                .into(),
                windows: vec![window],
                fetched_at: e.checked_at.unwrap_or(0),
                note: format!("{} · {}", e.model, e.health),
                backoff_until: 0,
                fidelity: crate::usage::Fidelity::Derived,
                ..Default::default()
            };
            crate::providers::Reading {
                id: format!("custom-endpoint-{}", e.id),
                name: e.name.clone(),
                headline,
                guidance: "模型与连通性来自 /models；预算与已用量由用户填写。".into(),
                enabled: e.enabled,
                snap,
                was_refused_access: false,
                needs_sign_in_renewal: false,
                account: Some(crate::providers::AccountSummary {
                    label: Some(e.name),
                    plan: Some(if e.model.is_empty() {
                        e.url.clone()
                    } else {
                        e.model
                    }),
                    source: "Custom Endpoint".into(),
                    manage_url: url(&e.url)
                        .ok()
                        .filter(|url| url.scheme() == "https")
                        .map(|url| url.to_string()),
                }),
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
/// The Settings editor may reveal only the key of an endpoint saved by Velo.
/// Never serialize it into Endpoint, provider events, logs, or smoke fixtures.
#[tauri::command]
pub fn get_custom_endpoint_key(app: AppHandle, id: String) -> Result<Option<String>, String> {
    if !get_custom_endpoints(app)
        .iter()
        .any(|endpoint| endpoint.id == id)
    {
        return Err("端点不存在".into());
    }
    if crate::smoke::root().is_some() {
        return Ok(None);
    }
    Ok(crate::secrets::read(&format!("endpoint-{id}")).ok())
}
#[tauri::command]
pub fn save_custom_endpoint(app: AppHandle, mut endpoint: Endpoint) -> Result<(), String> {
    endpoint.header = endpoint.header.trim().to_string();
    if endpoint.header.is_empty() {
        endpoint.header = "Authorization".into();
    }
    validate(&endpoint)?;
    endpoint.models.truncate(200);
    let provider_id = format!("custom-endpoint-{}", endpoint.id);
    let removed_icon = crate::providers::with_lifecycle_mut(|epochs| {
        let state = app.state::<crate::AppState>();
        let mut cfg = state.cfg.lock().unwrap();
        let mut next = cfg.clone();
        if endpoint.enabled {
            next.providers.disabled.remove(&provider_id);
        } else {
            next.providers.disabled.insert(provider_id.clone());
        }
        // A saved custom endpoint is an explicit account choice. Keep Swift's
        // connected/seen registry in sync with the legacy disabled mirror.
        if let Some(connected) = next.providers.connected.as_mut() {
            if endpoint.enabled {
                connected.insert(provider_id.clone());
            } else {
                connected.remove(&provider_id);
            }
        }
        next.providers.seen.insert(provider_id.clone());
        let old_icon = next
            .custom_endpoints
            .iter()
            .find(|e| e.id == endpoint.id)
            .and_then(|e| e.custom_icon_filename.clone());
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
        *epochs.entry(provider_id.clone()).or_default() += 1;
        Ok::<Option<String>, String>(old_icon)
    })?;
    if let Some(filename) = removed_icon {
        remove_icon_if_unreferenced(&filename, &get_custom_endpoints(app.clone()));
    }
    crate::reload_glyphs(&app);
    let _ = app.emit("providers", crate::providers::get_providers(app.clone()));
    Ok(())
}
#[tauri::command]
pub fn delete_custom_endpoint(app: AppHandle, id: String) -> Result<(), String> {
    let removed_icon = crate::providers::with_lifecycle_mut(|epochs| {
        let state = app.state::<crate::AppState>();
        let mut cfg = state.cfg.lock().unwrap();
        let mut next = cfg.clone();
        if !next.custom_endpoints.iter().any(|e| e.id == id) {
            return Err("端点不存在".into());
        }
        let removed_icon = next
            .custom_endpoints
            .iter()
            .find(|e| e.id == id)
            .and_then(|e| e.custom_icon_filename.clone());
        next.custom_endpoints.retain(|e| e.id != id);
        let provider_id = format!("custom-endpoint-{id}");
        next.providers.disabled.remove(&provider_id);
        if let Some(connected) = next.providers.connected.as_mut() {
            connected.remove(&provider_id);
        }
        next.providers.seen.remove(&provider_id);
        crate::config::save_checked(&next)?;
        *cfg = next;
        *epochs.entry(provider_id).or_default() += 1;
        Ok::<Option<String>, String>(removed_icon)
    })?;
    if let Some(filename) = removed_icon {
        remove_icon_if_unreferenced(&filename, &get_custom_endpoints(app.clone()));
    }
    crate::reload_glyphs(&app);
    // Removing the saved endpoint makes it unreachable even if the vault item was already removed.
    let _ = crate::secrets::save_provider_secret(format!("endpoint-{id}"), String::new());
    let _ = app.emit("providers", crate::providers::get_providers(app.clone()));
    Ok(())
}
#[tauri::command]
pub async fn probe_custom_endpoint(app: AppHandle, id: String) -> Result<Endpoint, String> {
    let provider_id = format!("custom-endpoint-{id}");
    let epoch = crate::providers::generation(&provider_id);
    probe_custom_endpoint_at_epoch(app, id, epoch).await
}
pub(crate) async fn probe_custom_endpoint_at_epoch(
    app: AppHandle,
    id: String,
    epoch: u64,
) -> Result<Endpoint, String> {
    let provider_id = format!("custom-endpoint-{id}");
    let _permit = PROBE_GATE.lock().await;
    if !crate::providers::enabled(&app, &provider_id)
        || crate::providers::generation(&provider_id) != epoch
    {
        return Err("端点已断开或配置已变化".into());
    }
    let endpoint = get_custom_endpoints(app.clone())
        .into_iter()
        .find(|e| e.id == id)
        .ok_or("端点不存在")?;
    let original = endpoint.clone();
    let result = tauri::async_runtime::spawn_blocking(move || probe(endpoint))
        .await
        .map_err(|_| "检测任务失败")?;
    let updated = crate::providers::commit_if_current(&app, &provider_id, epoch, || {
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
        Ok(updated)
    })?;
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
    current.last_status_code = result.last_status_code;
    Ok(())
}
#[derive(Clone, Debug, Serialize)]
pub struct ProbeResult {
    pub health: String,
    pub latency_ms: u64,
    pub models: Vec<String>,
    pub error: Option<String>,
    pub status_code: Option<u16>,
}
fn valid_header(header: &str) -> bool {
    !header.is_empty()
        && header.len() <= 100
        && header
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}
fn probe_request(base_url: &str, header: &str, api_key: &str) -> ProbeResult {
    let started = std::time::Instant::now();
    let request = (|| -> Result<Vec<String>, String> {
        let mut target = url(base_url)?;
        // Swift checks the original URL string, including query/fragment, before
        // appending the component. Preserve that edge case for saved base URLs.
        if !base_url.trim().ends_with("/models") {
            target.set_path(&format!("{}/models", target.path().trim_end_matches('/')));
        }
        let agent = ureq::AgentBuilder::new()
            .timeout(std::time::Duration::from_secs(6))
            .redirects(0)
            .build();
        let mut request = agent.get(target.as_str());
        let key = api_key.trim();
        if !key.is_empty() {
            let value = if header.eq_ignore_ascii_case("Authorization")
                && !key.to_ascii_lowercase().starts_with("bearer ")
            {
                format!("Bearer {key}")
            } else {
                key.to_string()
            };
            request = request.set(header, &value);
        }
        let response = request.call().map_err(|error| match error {
            ureq::Error::Status(code, _) => format!("The endpoint answered {code}"),
            ureq::Error::Transport(transport) if transport.kind() == ureq::ErrorKind::Io => {
                "Could not reach the endpoint".into()
            }
            _ => "Could not reach the endpoint".into(),
        })?;
        let mut body = Vec::new();
        response
            .into_reader()
            .take(2 * 1024 * 1024 + 1)
            .read_to_end(&mut body)
            .map_err(|_| "无法读取响应")?;
        if body.len() > 2 * 1024 * 1024 {
            return Err("模型列表过大".into());
        }
        Ok(parse_model_list(&body))
    })();
    let elapsed = (started.elapsed().as_millis() as u64).max(1);
    match request {
        Ok(models) => ProbeResult {
            health: if elapsed > 800 { "slow" } else { "online" }.into(),
            latency_ms: elapsed,
            models,
            error: None,
            status_code: None,
        },
        Err(error) => ProbeResult {
            health: "unreachable".into(),
            latency_ms: elapsed,
            models: vec![],
            status_code: error
                .strip_prefix("The endpoint answered ")
                .and_then(|value| value.parse().ok()),
            error: Some(error),
        },
    }
}
fn parse_model_list(body: &[u8]) -> Vec<String> {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(body) else {
        return vec![];
    };
    let mut models: Vec<String> = if let Some(data) = v["data"].as_array() {
        data.iter()
            .filter_map(|m| m["id"].as_str())
            .map(str::to_owned)
            .collect()
    } else if let Some(data) = v["models"].as_array() {
        data.iter()
            .filter_map(|m| m["name"].as_str().or_else(|| m["id"].as_str()))
            .map(str::to_owned)
            .collect()
    } else {
        return vec![];
    };
    models.sort();
    models
        .into_iter()
        .filter(|value| !value.is_empty() && value.chars().count() <= 200)
        .take(200)
        .collect()
}
fn probe(mut e: Endpoint) -> Endpoint {
    let key = crate::secrets::read(&format!("endpoint-{}", e.id)).unwrap_or_default();
    let result = probe_request(&e.url, &e.header, &key);
    e.health = result.health;
    e.latency_ms = Some(result.latency_ms);
    e.checked_at = Some(crate::now_ms());
    e.last_status_code = result.status_code;
    if result.error.is_none() {
        e.models = result.models;
    }
    e
}
#[tauri::command]
pub async fn test_custom_endpoint_draft(
    base_url: String,
    api_key: String,
    header_key: String,
) -> Result<ProbeResult, String> {
    url(&base_url)?;
    let header_key = if header_key.trim().is_empty() {
        "Authorization".to_string()
    } else {
        header_key.trim().to_string()
    };
    if !valid_header(&header_key) || api_key.len() > 8192 || api_key.contains(['\r', '\n']) {
        return Err("凭据或请求头无效".into());
    }
    let _permit = PROBE_GATE.lock().await;
    tauri::async_runtime::spawn_blocking(move || probe_request(&base_url, &header_key, &api_key))
        .await
        .map_err(|_| "检测任务失败".into())
}
#[derive(Clone, Debug, Serialize)]
pub struct LocalPreset {
    pub name: String,
    pub url: String,
    pub header: String,
    pub model: String,
    pub icon: String,
    pub color: String,
}
type LocalCandidate = (&'static str, u16, &'static str, &'static str);
fn scan_candidates(candidates: &[LocalCandidate]) -> Vec<LocalPreset> {
    let handles: Vec<_> = candidates
        .iter()
        .copied()
        .map(|(name, port, icon, color)| {
            std::thread::spawn(move || {
                let target = format!("http://localhost:{port}/v1/models");
                let agent = ureq::AgentBuilder::new()
                    .timeout(std::time::Duration::from_millis(1200))
                    // Discovery sends no key; Swift uses URLSession's redirect policy here.
                    .redirects(10)
                    .build();
                agent.get(&target).call().ok().map(|_| LocalPreset {
                    name: format!("{name} (:{port})"),
                    url: format!("http://localhost:{port}/v1"),
                    header: "Authorization".into(),
                    model: String::new(),
                    icon: icon.into(),
                    color: color.into(),
                })
            })
        })
        .collect();
    let mut found: Vec<_> = handles
        .into_iter()
        .filter_map(|handle| handle.join().ok().flatten())
        .collect();
    found.sort_by(|a, b| a.name.cmp(&b.name));
    found
}
#[tauri::command]
pub async fn scan_local_engines() -> Result<Vec<LocalPreset>, String> {
    let _permit = PROBE_GATE.lock().await;
    tauri::async_runtime::spawn_blocking(|| {
        let candidates = [
            ("Local vLLM", 8000, "ollama", "#10B981"),
            ("Local llama.cpp", 8080, "lmstudio", "#8B5CF6"),
            ("Local LM Studio / Proxy", 1234, "lmstudio", "#8B5CF6"),
            ("Local Ollama", 11434, "ollama-local", "#14B8A6"),
            ("Local AI Server", 5000, "openai", "#3B82F6"),
        ];
        scan_candidates(&candidates)
    })
    .await
    .map_err(|_| "本地扫描失败".into())
}
#[cfg(test)]
mod tests {
    use super::*;
    fn fixture_response(status: &str, body: &str) -> (u16, std::thread::JoinHandle<String>) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let status = status.to_owned();
        let body = body.to_owned();
        let worker = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(std::time::Duration::from_secs(2)))
                .unwrap();
            let mut request = Vec::new();
            let mut buffer = [0; 1024];
            while !request.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
                let n = stream.read(&mut buffer).unwrap();
                if n == 0 {
                    break;
                }
                request.extend_from_slice(&buffer[..n]);
            }
            let reply=format!("HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len());
            stream.write_all(reply.as_bytes()).unwrap();
            String::from_utf8_lossy(&request).into_owned()
        });
        (port, worker)
    }
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
        e.url = "https://example.com/v1?tenant=a#models".into();
        assert!(validate(&e).is_ok());
        e.url = "https://example.com/v1".into();
        e.budget = Some(0.);
        assert!(validate(&e).is_err());
        e.budget = Some(100.);
        e.header = "Authorization\r\nHost".into();
        assert!(validate(&e).is_err());
    }
    #[test]
    fn draft_model_parser_accepts_both_source_shapes_and_bounds_list() {
        assert_eq!(
            parse_model_list(br#"{"data":[{"id":"z"},{"id":"a"},{"id":"a"}]}"#),
            vec!["a", "a", "z"]
        );
        assert_eq!(
            parse_model_list(br#"{"models":[{"name":"local"},{"id":"fallback"}]}"#),
            vec!["fallback", "local"]
        );
        assert!(parse_model_list(b"not json").is_empty());
        assert!(
            parse_model_list(
                format!("{{\"data\":[{}]}}", vec!["{\"id\":\"m\"}"; 250].join(",")).as_bytes()
            )
            .len()
                <= 200
        );
    }
    #[test]
    fn icon_filename_must_belong_to_endpoint() {
        assert!(valid_icon_filename(
            "abc-def",
            "abc-def-0123456789abcdef.png"
        ));
        assert!(!valid_icon_filename(
            "abc-def",
            "other-0123456789abcdef.png"
        ));
        assert!(!valid_icon_filename(
            "abc-def",
            "../abc-def-0123456789abcdef.png"
        ));
    }
    #[test]
    fn png_guard_checks_header_before_decode_and_rejects_truncation() {
        let mut valid = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut valid, 1, 1);
            encoder.set_color(png::ColorType::Rgba);
            encoder.set_depth(png::BitDepth::Eight);
            let mut writer = encoder.write_header().unwrap();
            writer.write_image_data(&[255, 0, 0, 255]).unwrap();
        }
        assert!(validate_png(&valid).is_ok());
        assert!(validate_png(&valid[..valid.len() / 2]).is_err());
        let mut huge = Vec::new();
        {
            let encoder = png::Encoder::new(&mut huge, 100_000, 100_000);
            let _writer = encoder.write_header().unwrap();
        }
        assert!(validate_png(&huge).is_err());
    }
    #[test]
    fn no_budget_still_shows_actual_manual_spend_when_remaining_is_selected() {
        let mut endpoint = Endpoint {
            unit: "currency".into(),
            used: 7.25,
            display_remaining: true,
            ..Default::default()
        };
        let window = endpoint_window(&endpoint);
        assert_eq!(window.id, "spend-tracking");
        assert_eq!(window.used_text.as_deref(), Some("$7.25"));
        assert_eq!(window.detail.as_deref(), Some("$7.25"));
        assert_eq!(window.has_fraction, Some(false));
        endpoint.unit = "tokens".into();
        endpoint.used = 2.5;
        let window = endpoint_window(&endpoint);
        assert_eq!(window.id, "token-tracking");
        assert_eq!(window.used_text.as_deref(), Some("2.5M"));
        assert_eq!(window.detail.as_deref(), Some("2.5M tokens"));
    }
    #[test]
    fn draft_probe_and_scan_use_only_fixture_loopback_and_keep_header_local() {
        let (port, worker) = fixture_response(
            "200 OK",
            r#"{"models":[{"name":"local-b"},{"name":"local-a"}]}"#,
        );
        let result = probe_request(
            &format!("http://127.0.0.1:{port}/v1"),
            "Authorization",
            "fixture-key",
        );
        let request = worker.join().unwrap();
        assert_eq!(result.health, "online");
        assert_eq!(result.models, vec!["local-a", "local-b"]);
        assert!(request.contains("GET /v1/models"));
        assert!(request
            .to_ascii_lowercase()
            .contains("authorization: bearer fixture-key"));
        let (port, worker) = fixture_response("200 OK", "{}");
        let found = scan_candidates(&[("Fixture", port, "openai", "#3B82F6")]);
        worker.join().unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].url, format!("http://localhost:{port}/v1"));
        let (port, worker) = fixture_response("401 Unauthorized", "{}");
        let denied = probe_request(&format!("http://127.0.0.1:{port}/v1"), "Authorization", "");
        worker.join().unwrap();
        assert_eq!(denied.status_code, Some(401));
        assert_eq!(denied.health, "unreachable");
        let (port, worker) = fixture_response("200 OK", r#"{"data":[{"id":"query-model"}]}"#);
        let query = probe_request(
            &format!("http://127.0.0.1:{port}/v1?tenant=a#models"),
            "Authorization",
            "",
        );
        let request = worker.join().unwrap();
        assert_eq!(query.models, vec!["query-model"]);
        assert!(request.contains("GET /v1/models?tenant=a HTTP/1.1"));
        assert!(!request.contains("#models"));
    }
}
