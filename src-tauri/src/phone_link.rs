//! Optional LAN server implementing the pinned upstream Phone Link v3 contract.
mod auth;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    io::Read,
    net::IpAddr,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use tauri::{AppHandle, Emitter, Manager};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Preferences {
    pub enabled: bool,
    pub port: u16,
    pub devices: Vec<Device>,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            enabled: false,
            port: 8788,
            devices: Vec::new(),
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Device {
    pub device_id: String,
    pub name: String,
    pub platform: String,
    pub paired_at: u64,
    pub last_seen_at: u64,
    pub last_seen_ip: String,
}
struct Runtime {
    server: Arc<tiny_http::Server>,
    stop: Arc<AtomicBool>,
    pairing: auth::Pairing,
    gate: auth::Gate,
}
static RUNTIME: Mutex<Option<Runtime>> = Mutex::new(None);
static START_STOP: Mutex<()> = Mutex::new(());
fn now() -> u64 {
    crate::now_ms() / 1000
}
fn name() -> String {
    std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_else(|_| "Vela".into())
        .chars()
        .take(64)
        .collect()
}
fn hosts() -> Vec<String> {
    let mut ips = Vec::new();
    for interface in if_addrs::get_if_addrs().unwrap_or_default() {
        if interface.is_loopback()
            || [
                "utun", "bridge", "awdl", "llw", "lo", "tun", "docker", "veth",
            ]
            .iter()
            .any(|p| interface.name.starts_with(p))
        {
            continue;
        }
        if let IpAddr::V4(ip) = interface.ip() {
            if (ip.is_private() || ip.is_link_local()) && !ips.contains(&ip.to_string()) {
                ips.push(ip.to_string());
            }
        }
    }
    ips.truncate(4);
    ips
}
fn component(v: &str) -> String {
    v.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-_.~,".contains(&b) {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}
#[derive(Serialize)]
pub struct View {
    enabled: bool,
    port: u16,
    hosts: Vec<String>,
    devices: Vec<Device>,
    link: Option<String>,
    qr: Option<String>,
    expires_at: Option<u64>,
    pairing_state: String,
}
#[tauri::command]
pub fn get_phone_link(app: AppHandle, pairing: Option<bool>) -> Result<View, String> {
    let p = app
        .state::<crate::AppState>()
        .cfg
        .lock()
        .unwrap()
        .phone_link
        .clone();
    let hosts = hosts();
    let active = RUNTIME.lock().unwrap().is_some();
    let mut view = View {
        enabled: active,
        port: p.port,
        hosts: hosts.clone(),
        devices: p.devices,
        link: None,
        qr: None,
        expires_at: None,
        pairing_state: "closed".into(),
    };
    if pairing.unwrap_or(false) && active {
        let mut runtime = RUNTIME.lock().unwrap();
        let r = runtime.as_mut().ok_or("手机连接服务尚未就绪")?;
        r.pairing.refresh(now());
        view.pairing_state = r.pairing.state.into();
        if let Some(code) = r.pairing.code.as_ref().filter(|_| !hosts.is_empty()) {
            let link = format!(
                "codenotch://pair?v=3&h={}&p={}&c={}&n={}",
                component(&hosts.join(",")),
                p.port,
                code,
                component(&name())
            );
            view.qr = Some(
                qrcode::QrCode::new(link.as_bytes())
                    .map_err(|_| "无法生成二维码")?
                    .render::<qrcode::render::svg::Color>()
                    .min_dimensions(220, 220)
                    .build(),
            );
            view.link = Some(link);
            view.expires_at = Some(r.pairing.expires * 1000);
        }
    }
    Ok(view)
}
#[tauri::command]
pub fn set_phone_link(app: AppHandle, enabled: bool) -> Result<(), String> {
    let _gate = START_STOP.lock().unwrap();
    if enabled && !cfg!(any(windows, target_os = "macos")) {
        return Err("手机配对需要 macOS 或 Windows 的系统凭据库".into());
    }
    let mut running = RUNTIME.lock().unwrap();
    if enabled && running.is_some() {
        return Ok(());
    }
    let st = app.state::<crate::AppState>();
    let mut cfg = st.cfg.lock().unwrap();
    let mut next = cfg.clone();
    next.phone_link.enabled = enabled;
    let started = if enabled {
        if next.phone_link.port < 1024 {
            return Err("手机连接端口必须大于 1023".into());
        }
        Some((
            Arc::new(
                tiny_http::Server::http(("0.0.0.0", next.phone_link.port))
                    .map_err(|_| "手机连接端口无法监听，请检查端口占用和防火墙")?,
            ),
            auth::Pairing::new(),
        ))
    } else {
        None
    };
    crate::config::save_checked(&next)?;
    *cfg = next;
    drop(cfg);
    if let Some(old) = running.take() {
        old.stop.store(true, Ordering::Release);
        old.server.unblock();
    }
    if let Some((server, pairing)) = started {
        let stop = Arc::new(AtomicBool::new(false));
        *running = Some(Runtime {
            server: server.clone(),
            stop: stop.clone(),
            pairing,
            gate: auth::Gate::default(),
        });
        // Two bounded workers let health/pair/snapshot proceed while one phone
        // waits for refresh. No unbounded thread per HTTP request.
        for _ in 0..2 {
            let app = app.clone();
            let server = server.clone();
            let stop = stop.clone();
            std::thread::spawn(move || {
                crate::activity::lower_thread_priority();
                while !stop.load(Ordering::Acquire) {
                    match server.recv_timeout(Duration::from_secs(1)) {
                        Ok(Some(request)) if !stop.load(Ordering::Acquire) => {
                            serve(&app, request, &stop)
                        }
                        Ok(_) => {}
                        Err(_) => break,
                    }
                }
                stop.store(true, Ordering::Release);
                let mut runtime = RUNTIME.lock().unwrap();
                if runtime
                    .as_ref()
                    .is_some_and(|r| Arc::ptr_eq(&r.stop, &stop))
                {
                    runtime.take();
                    drop(runtime);
                    let _ = app.emit("phone_link", ());
                }
            });
        }
    }
    Ok(())
}
pub fn start(app: AppHandle) {
    let enabled = app
        .state::<crate::AppState>()
        .cfg
        .lock()
        .unwrap()
        .phone_link
        .enabled;
    if enabled {
        if let Err(error) = set_phone_link(app.clone(), true) {
            crate::applog(&format!("Phone Link: {error}"));
        }
    }
}
#[tauri::command]
pub fn remove_phone(app: AppHandle, device_id: String) -> Result<(), String> {
    if !auth::valid_device(&device_id) {
        return Err("设备 ID 无效".into());
    }
    // Removing metadata revokes immediately even if a vault deletion fails.
    let st = app.state::<crate::AppState>();
    let mut cfg = st.cfg.lock().unwrap();
    let mut next = cfg.clone();
    next.phone_link.devices.retain(|d| d.device_id != device_id);
    crate::config::save_checked(&next)?;
    *cfg = next;
    drop(cfg);
    let _ = crate::secrets::save_provider_secret(format!("phone-{device_id}"), String::new());
    let _ = app.emit("phone_link", ());
    Ok(())
}
fn error(kind: &str, now: u64) -> (u16, Value) {
    let status = match kind {
        "local-network-only" | "pairing-closed" => 403,
        "rate-limited" => 429,
        "unavailable" => 503,
        _ => 401,
    };
    (
        status,
        if kind == "clock-skew" {
            json!({"error":kind,"serverTime":now})
        } else {
            json!({"error":kind})
        },
    )
}
fn header(request: &tiny_http::Request, name: &str) -> String {
    request
        .headers()
        .iter()
        .find(|h| h.field.to_string().eq_ignore_ascii_case(name))
        .map(|h| h.value.to_string())
        .unwrap_or_default()
}
fn respond(request: tiny_http::Request, status: u16, body: Value) {
    let response = tiny_http::Response::from_string(body.to_string())
        .with_status_code(status)
        .with_header(tiny_http::Header::from_bytes("Content-Type", "application/json").unwrap())
        .with_header(tiny_http::Header::from_bytes("Cache-Control", "no-store").unwrap());
    let _ = request.respond(response);
}
fn encrypted(request: tiny_http::Request, body: Value, key: &[u8; 32], aad: &str) {
    match auth::seal(body.to_string().as_bytes(), key, aad) {
        Ok(body) => {
            let response = tiny_http::Response::from_string(body)
                .with_header(
                    tiny_http::Header::from_bytes("Content-Type", "application/codenotch-v3")
                        .unwrap(),
                )
                .with_header(tiny_http::Header::from_bytes("Cache-Control", "no-store").unwrap());
            let _ = request.respond(response);
        }
        Err(_) => respond(request, 503, json!({"error":"unavailable"})),
    }
}
#[tauri::command]
pub fn phone_pairing(open: bool) -> Result<(), String> {
    let mut runtime = RUNTIME.lock().unwrap();
    if let Some(r) = runtime.as_mut() {
        if open {
            r.pairing.open(now())?;
        } else {
            r.pairing.close(now());
        }
        Ok(())
    } else if open {
        Err("请先启用手机连接".into())
    } else {
        Ok(())
    }
}
fn serve(app: &AppHandle, mut request: tiny_http::Request, stop: &AtomicBool) {
    let Some(ip) = request.remote_addr().map(|a| a.ip()) else {
        respond(request, 403, json!({"error":"local-network-only"}));
        return;
    };
    let method = request.method().as_str().to_string();
    let uri = request.url().to_string();
    let path = uri.split('?').next().unwrap_or("").to_string();
    let now = now();
    let pairing = path == "/api/v3/pair";
    // Admission before reading the body or looking up a credential.
    let admission = RUNTIME
        .lock()
        .unwrap()
        .as_mut()
        .filter(|r| std::ptr::eq(Arc::as_ptr(&r.stop), stop))
        .map(|r| r.gate.rate(ip, pairing, now));
    if let Some(Err(e)) = admission {
        let (s, b) = error(e, now);
        respond(request, s, b);
        return;
    }
    if admission.is_none() {
        respond(request, 503, json!({"error":"unavailable"}));
        return;
    }
    if method == "GET" && path == "/health" {
        respond(
            request,
            200,
            json!({"ok":true,"app":"codenotch","api":3,"version":crate::BUILD}),
        );
        return;
    }
    let ts = header(&request, "X-CN-Timestamp");
    let nonce = header(&request, "X-CN-Nonce");
    let signature = header(&request, "X-CN-Signature");
    let device_id = header(&request, "X-CN-Device");
    if request.body_length().is_some_and(|n| n > 8192)
        || !header(&request, "Transfer-Encoding").is_empty()
    {
        respond(request, 413, json!({"error":"body-too-large"}));
        return;
    }
    let mut body = Vec::new();
    if request
        .as_reader()
        .take(8193)
        .read_to_end(&mut body)
        .is_err()
        || body.len() > 8192
    {
        respond(request, 400, json!({"error":"bad-body"}));
        return;
    }
    let signed = auth::Signed {
        ts: &ts,
        nonce: &nonce,
        signature: &signature,
        method: &method,
        uri: &uri,
        device: &device_id,
        body: &body,
    };
    let mut guard = RUNTIME.lock().unwrap();
    let Some(r) = guard
        .as_mut()
        .filter(|r| std::ptr::eq(Arc::as_ptr(&r.stop), stop))
    else {
        respond(request, 503, json!({"error":"unavailable"}));
        return;
    };
    if let Err(e) = r.gate.headers(ip, pairing, &signed, now) {
        let (s, b) = error(e, now);
        respond(request, s, b);
        return;
    }
    if pairing && method == "POST" {
        let keys = match r.pairing.authenticate(&signed, now) {
            Ok(k) => k,
            Err(e) => {
                let (s, b) = error(e, now);
                respond(request, s, b);
                return;
            }
        };
        let plain = match auth::open(&body, &keys.encryption, &auth::aad(&signed, true, false)) {
            Ok(p) => p,
            Err(_) => {
                respond(request, 401, json!({"error":"bad-code"}));
                return;
            }
        };
        let data: Value = match serde_json::from_slice(&plain) {
            Ok(v) => v,
            Err(_) => {
                respond(request, 400, json!({"error":"bad-body"}));
                return;
            }
        };
        let id = data["deviceId"].as_str().unwrap_or("");
        let platform = data["platform"].as_str().unwrap_or("");
        let phone_name = data["name"]
            .as_str()
            .unwrap_or("")
            .chars()
            .take(64)
            .collect::<String>();
        if id != device_id
            || !auth::valid_device(id)
            || !["ios", "android", "web"].contains(&platform)
            || phone_name.trim().is_empty()
        {
            respond(request, 400, json!({"error":"bad-device"}));
            return;
        }
        let st = app.state::<crate::AppState>();
        let mut cfg = st.cfg.lock().unwrap();
        let mut next = cfg.clone();
        if next.phone_link.devices.len() >= 64
            && !next.phone_link.devices.iter().any(|d| d.device_id == id)
        {
            respond(request, 409, json!({"error":"device-limit"}));
            return;
        }
        let secret = match auth::device_secret(r.pairing.code.as_deref().unwrap_or(""), id) {
            Ok(s) => s,
            Err(_) => {
                respond(request, 503, json!({"error":"unavailable"}));
                return;
            }
        };
        let vault_id = format!("phone-{id}");
        let previous = crate::secrets::read(&vault_id).ok();
        if crate::secrets::save_provider_secret(vault_id.clone(), secret).is_err() {
            respond(request, 503, json!({"error":"unavailable"}));
            return;
        }
        next.phone_link.devices.retain(|d| d.device_id != id);
        next.phone_link.devices.push(Device {
            device_id: id.into(),
            name: phone_name,
            platform: platform.into(),
            paired_at: now,
            last_seen_at: now,
            last_seen_ip: ip.to_string(),
        });
        if crate::config::save_checked(&next).is_err() {
            let _ = crate::secrets::save_provider_secret(vault_id, previous.unwrap_or_default());
            respond(request, 503, json!({"error":"unavailable"}));
            return;
        }
        // Consume only after both credential and metadata have been saved.
        r.pairing.close(now);
        r.pairing.state = "paired";
        *cfg = next;
        drop(cfg);
        drop(guard);
        let _ = app.emit("phone_link", ());
        let aad = auth::aad(&signed, true, true);
        encrypted(
            request,
            json!({"paired":true,"server":name(),"version":crate::BUILD,"api":3,"deviceId":id}),
            &keys.encryption,
            &aad,
        );
        return;
    }
    let known = auth::valid_device(&device_id)
        && app
            .state::<crate::AppState>()
            .cfg
            .lock()
            .unwrap()
            .phone_link
            .devices
            .iter()
            .any(|d| d.device_id == device_id);
    if !known {
        respond(request, 401, json!({"error":"unknown-device"}));
        return;
    }
    let secret = crate::secrets::read(&format!("phone-{device_id}"))
        .ok()
        .and_then(|s| auth::unhex(&s).ok());
    let Some(secret) = secret.filter(|s| s.len() == 32) else {
        respond(request, 401, json!({"error":"unknown-device"}));
        return;
    };
    let keys = auth::device_keys(&secret);
    if !auth::verify(&keys.signature, &signed)
        || (!body.is_empty()
            && auth::open(&body, &keys.encryption, &auth::aad(&signed, false, false)).is_err())
    {
        respond(request, 401, json!({"error":"bad-signature"}));
        return;
    }
    let aad = auth::aad(&signed, false, true);
    drop(guard);
    if stop.load(Ordering::Acquire) {
        respond(request, 503, json!({"error":"unavailable"}));
        return;
    }
    // Write activity at most once a minute per device, rather than on every phone refresh.
    {
        let st = app.state::<crate::AppState>();
        let mut cfg = st.cfg.lock().unwrap();
        let mut next = cfg.clone();
        if let Some(device) = next
            .phone_link
            .devices
            .iter_mut()
            .find(|d| d.device_id == device_id)
        {
            if now.saturating_sub(device.last_seen_at) >= 60 {
                device.last_seen_at = now;
                device.last_seen_ip = ip.to_string();
                if crate::config::save_checked(&next).is_ok() {
                    *cfg = next;
                }
            }
        }
    }
    match (method.as_str(), path.as_str()) {
        ("GET", "/api/v3/snapshot") => encrypted(request, snapshot(app), &keys.encryption, &aad),
        ("POST", "/api/v3/refresh") => {
            let pending = crate::refresh_all_tracked(app);
            crate::refresh::wait(&pending, stop);
            if stop.load(Ordering::Acquire) {
                respond(request, 503, json!({"error":"unavailable"}));
            } else {
                encrypted(request, snapshot(app), &keys.encryption, &aad);
            }
        }
        _ => respond(request, 404, json!({"error":"not-found"})),
    }
}
fn iso(ms: u64) -> Option<String> {
    chrono::DateTime::from_timestamp((ms / 1000).try_into().ok()?, 0)
        .map(|d| d.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
}
fn snapshot(app: &AppHandle) -> Value {
    let st = app.state::<crate::AppState>();
    let cfg = st.cfg.lock().unwrap().clone();
    let mut options = crate::get_tray_options(app.clone());
    options.sort_by_key(|o| {
        cfg.notch_slots
            .iter()
            .position(|s| s.provider == o.id)
            .unwrap_or(usize::MAX)
    });
    let providers: Vec<_> = options
        .into_iter()
        .filter(|o| {
            !matches!(o.id.as_str(), "ollama-local" | "lmstudio")
                && crate::providers::enabled(app, &o.id)
        })
        .map(|o| {
            let s = crate::snapshot_of(app, &o.id);
            let head = crate::ring_window(
                &o.id,
                &s.windows,
                &cfg.antigravity_limit,
                &cfg.antigravity_model,
            )
            .map(|w| w.id.as_str());
            provider_json(&o.id, &o.label, &s, head)
        })
        .collect();
    let sessions = st
        .store
        .lock()
        .unwrap()
        .snapshot(&cfg.lang, &crate::resolved_lang(&cfg.lang), true, false)
        .sessions;
    let mut sessions:Vec<_>=sessions.into_iter().map(|s|json!({"id":s.id,"name":s.title,"detail":s.last,"state":match s.state.as_str(){"running"=>"busy","attention"=>"waiting",_=>"idle"},"waitingFor":if s.attn.is_empty(){None}else{Some(s.attn)},"since":iso(s.started)})).collect();
    sessions.extend(st.activity.lock().unwrap().iter().map(activity_json));
    json!({"server":{"name":name(),"version":crate::BUILD,"generatedAt":iso(crate::now_ms()),"demo":false},"providers":providers,"sessions":sessions})
}

fn activity_json(s: &crate::activity::Activity) -> Value {
    // v3 has busy/waiting/idle only, including during the desktop success pulse.
    let state = match s.state.as_str() {
        "busy" => "busy",
        "waiting" => "waiting",
        _ => "idle",
    };
    json!({"id":s.id,"name":s.name,"detail":s.detail,"state":state,"waitingFor":s.waiting_for,"since":iso(s.since)})
}

/// Pure wire projection: no inferred denominators or plans, and explicit nulls as in v3.
fn provider_json(
    id: &str,
    label: &str,
    s: &crate::usage::UsageSnapshot,
    head: Option<&str>,
) -> Value {
    let status = match s.status.as_str() {
        "ok" => json!({"kind":"ok"}),
        "stale" => json!({"kind":"stale","since":iso(s.fetched_at)}),
        "backoff" if s.fetched_at > 0 => json!({"kind":"stale","since":iso(s.fetched_at)}),
        "needsAuth" | "absent" | "signedOutByOwner" => json!({"kind":"needsAuth"}),
        "accessDenied" => json!({"kind":"accessDenied"}),
        "unsupported" => json!({"kind":"unsupported","why":s.note}),
        _ => json!({"kind":"error","why":s.note}),
    };
    let windows: Vec<_> = s.windows.iter().map(|w| json!({
        "id": w.id, "label": w.label,
        "usedFraction": if w.count.is_none() && w.used.is_finite() { Some(w.used) } else { None },
        "remaining": w.remaining,
        "used": w.used_count.or_else(|| if w.remaining.is_none() { w.count } else { None }),
        "resetsAt": w.resets_at.and_then(iso)
    })).collect();
    let account = s
        .plan
        .as_deref()
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(|plan| json!({"plan":plan,"source":"Vela"}));
    json!({"id":id,"displayName":label,"fidelity":if s.windows.iter().any(|w|w.derived){"derived"}else{"official"},"status":status,"windows":windows,"headlineId":head,"block":null,"account":account})
}

#[cfg(test)]
mod snapshot_tests {
    use super::*;
    use crate::usage::{LimitWindow, UsageSnapshot};
    #[test]
    fn remaining_only_never_becomes_used_or_a_percentage() {
        let s = UsageSnapshot {
            status: "ok".into(),
            plan: Some("Pro".into()),
            windows: vec![
                LimitWindow {
                    id: "premium".into(),
                    count: Some(75),
                    remaining: Some(75),
                    ..Default::default()
                },
                LimitWindow {
                    id: "requests".into(),
                    count: Some(8),
                    ..Default::default()
                },
                LimitWindow {
                    id: "quota".into(),
                    used: 0.25,
                    used_count: Some(25),
                    remaining: Some(75),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        let v = provider_json("copilot", "GitHub Copilot", &s, Some("premium"));
        assert_eq!(v["account"]["plan"], "Pro");
        assert_eq!(v["headlineId"], "premium");
        assert!(v["windows"][0]["usedFraction"].is_null());
        assert!(v["windows"][0]["used"].is_null());
        assert_eq!(v["windows"][0]["remaining"], 75);
        assert_eq!(v["windows"][1]["used"], 8);
        assert_eq!(v["windows"][2]["usedFraction"], 0.25);
        assert_eq!(v["windows"][2]["used"], 25);
        assert!(v["windows"][2]["resetsAt"].is_null());
    }
    #[test]
    fn cached_backoff_uses_original_time_and_old_cache_remains_readable() {
        let mut s: UsageSnapshot = serde_json::from_value(
            json!({"status":"backoff","windows":[],"fetched_at":1000,"note":"rate limited"}),
        )
        .unwrap();
        let v = provider_json("kimi", "Kimi", &s, None);
        assert_eq!(
            v["status"],
            json!({"kind":"stale","since":"1970-01-01T00:00:01Z"})
        );
        assert!(v["account"].is_null());
        assert!(v["headlineId"].is_null());
        s.fetched_at = 0;
        assert_eq!(
            provider_json("kimi", "Kimi", &s, None)["status"]["kind"],
            "error"
        );
    }
}

#[cfg(test)]
mod activity_wire_tests {
    use super::*;
    #[test]
    fn waiting_reason_survives_and_success_uses_v3_idle() {
        let mut s = crate::activity::Activity {
            id: "antigravity-work:fixture".into(),
            provider: "antigravity-work".into(),
            state: "waiting".into(),
            name: "Antigravity".into(),
            detail: "Permission".into(),
            waiting_for: Some("Permission".into()),
            since: 1000,
        };
        let v = activity_json(&s);
        assert_eq!(v["waitingFor"], "Permission");
        assert_eq!(v["state"], "waiting");
        assert_eq!(v["id"], s.id);
        assert_eq!(v["since"], "1970-01-01T00:00:01Z");
        s.state = "success".into();
        s.detail = "Complete".into();
        s.waiting_for = None;
        let v = activity_json(&s);
        assert_eq!(v["state"], "idle");
        assert_eq!(v["detail"], "Complete");
        assert!(v["waitingFor"].is_null());
    }
}
