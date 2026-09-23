//! Antigravity usage adapter.
//!
//! Preferred path: when official Antigravity CLI (`agy.exe`) is installed
//! (`%LOCALAPPDATA%\agy\bin\agy.exe` or `PATH`), executes standalone `agy --print /usage`
//! via native Windows ConPTY inside a bounded JobObject without running the full IDE.
//! Refreshes at startup and explicit/hover requests with a 5-minute TTL cache.
//!
//! Fallback path, when the CLI is absent (as upstream, most honest first):
//!   1. Local bridge: find the `language_server*` process (its command line carries
//!      `--csrf_token <t>`; the port is `--https_server_port 0`, i.e. random at runtime, and can
//!      only be found in the listening table; it opens two ports and only one answers this RPC,
//!      so both are tried),
//!      POST `https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`
//!      with header `x-codeium-csrf-token: <t>` (Antigravity sits on the Codeium stack; the header
//!      name never changed) and body `{"forceRefresh":true}` (otherwise the server answers from
//!      QuotaSummaryCache). Self-signed certificate → verification is relaxed for 127.0.0.1 only.
//!      Reply `{response:{groups:[{displayName, buckets:[{bucketId, displayName, remainingFraction, resetTime}]}]}}`
//!      — it reports what **remains**, so used = 1 - remainingFraction; the label is
//!      group.displayName (buckets only ever say "Weekly Limit Remaining").
//!   2. Bridge answered before and does not now = Antigravity is closed (the port changes on every
//!      launch): keep the last percentage marked stale rather than switching to a count.
//!   3. Credential path (when a Google token exists): Windows Credential Manager target
//!      `gemini:antigravity` (Go keyring: service:user), value JSON
//!      `{auth_method, token:{access_token, expiry (RFC3339 with offset)}}`; on macOS it carries a
//!      `go-keyring-base64:` prefix, and both forms are accepted. POST `:loadCodeAssist`
//!      (`{"metadata":{"pluginType":"GEMINI"}}`, not ANTIGRAVITY) for the tier name; then try
//!      `:retrieveUserQuotaSummary` (empty body `{}`), which is 200 only for licensed accounts, and
//!      parse it defensively (no positive limit, or used > 1.5×limit → discard).
//!   4. Fallback: count today's `source=="MODEL"` steps in every install's
//!      `~/.gemini/antigravity*/brain/*/.system_generated/logs/transcript.jsonl` (created_at is UTC,
//!      compared by local day). This is a **count, not a percentage** — there is no published
//!      denominator, so the ring draws only its track.
//!
//! Read only; token values are never cached and never appear in any log.

use crate::usage::{LimitWindow, UsageSnapshot};
use crate::AppState;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

const POLL_SECS: u64 = 300;
const CLI_TTL: Duration = Duration::from_secs(300);
const QUOTA_SUMMARY: &str =
    "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary";
const LS_SERVICE: &str = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary";
const CSRF_HEADER: &str = "x-codeium-csrf-token";
const MAX_QUOTA_BODY: u64 = 2 * 1024 * 1024;

mod quota;

fn bounded_json(response: ureq::Response) -> Option<serde_json::Value> {
    let mut body = Vec::new();
    response
        .into_reader()
        .take(MAX_QUOTA_BODY + 1)
        .read_to_end(&mut body)
        .ok()?;
    (body.len() as u64 <= MAX_QUOTA_BODY)
        .then(|| serde_json::from_slice(&body).ok())
        .flatten()
}

static REFRESH_CLI: Mutex<Option<std::sync::mpsc::SyncSender<()>>> = Mutex::new(None);
static REFRESH_LEGACY: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
#[derive(Default)]
struct PromptPermission {
    owed_until: Option<u64>,
}

impl PromptPermission {
    fn grant(&mut self, now: u64) {
        self.owed_until = Some(now.saturating_add(60_000));
    }

    fn take(&mut self, now: u64) -> bool {
        self.owed_until
            .take()
            .is_some_and(|deadline| now < deadline)
    }
}

static KEYCHAIN_PROMPT: OnceLock<Mutex<PromptPermission>> = OnceLock::new();

fn keychain_prompt() -> &'static Mutex<PromptPermission> {
    KEYCHAIN_PROMPT.get_or_init(|| Mutex::new(PromptPermission::default()))
}

fn grant_keychain_prompt(now: u64) {
    keychain_prompt().lock().unwrap().grant(now);
}

fn take_keychain_prompt(now: u64) -> bool {
    keychain_prompt().lock().unwrap().take(now)
}

pub fn request_refresh() {
    if let Some(sender) = REFRESH_CLI.lock().unwrap().as_ref() {
        let _ = sender.try_send(());
    } else {
        REFRESH_LEGACY.store(true, std::sync::atomic::Ordering::Relaxed);
    }
}

pub fn request_hover_refresh() {
    // Hover must not wake the legacy adapter's periodic poller.
    if let Some(sender) = REFRESH_CLI.lock().unwrap().as_ref() {
        let _ = sender.try_send(());
    }
}

#[tauri::command]
pub fn allow_antigravity_keychain_access(app: AppHandle, id: String) -> Result<(), String> {
    if id != "gemini" || !crate::providers::enabled(&app, &id) {
        return Err("Antigravity Keychain account is unavailable".into());
    }
    grant_keychain_prompt(now_ms());
    request_refresh();
    Ok(())
}

#[cfg(test)]
#[test]
fn hover_does_not_request_legacy_refresh() {
    assert!(REFRESH_CLI.lock().unwrap().is_none());
    request_hover_refresh();
    assert!(!REFRESH_LEGACY.load(std::sync::atomic::Ordering::Relaxed));
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Every install's state directory — `antigravity`, `antigravity-ide`, `antigravity-cli`, … — not
/// just the first that exists: switching flavour leaves the old directory behind, so the first can
/// be empty while the transcripts sit in the next (#84 hit this on macOS).
pub(crate) fn state_roots() -> Vec<PathBuf> {
    dirs::home_dir()
        .map(|h| state_roots_in(&h))
        .unwrap_or_default()
}

fn state_roots_in(home: &Path) -> Vec<PathBuf> {
    let Ok(rd) = std::fs::read_dir(home.join(".gemini")) else {
        return vec![];
    };
    let mut out: Vec<PathBuf> = rd
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with("antigravity"))
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    out.sort();
    out
}

fn store_path() -> PathBuf {
    crate::config::config_path().with_file_name("antigravity.json")
}

pub fn load_persisted() -> UsageSnapshot {
    if crate::agy_cli::find_agy().is_some() {
        let mut snap = std::fs::read_to_string(store_path())
            .ok()
            .and_then(|s| serde_json::from_str::<UsageSnapshot>(&s).ok())
            .unwrap_or_default();
        if !snap.note.starts_with("via Antigravity CLI") {
            snap = UsageSnapshot::default();
        }
        snap.status = if snap.windows.is_empty() {
            "error"
        } else if now_ms().saturating_sub(snap.fetched_at) < CLI_TTL.as_millis() as u64 {
            "ok"
        } else {
            "stale"
        }
        .into();
        if snap.windows.is_empty() {
            snap.note = "Waiting for Antigravity CLI quota".into();
        }
        snap
    } else {
        std::fs::read_to_string(store_path())
            .ok()
            .and_then(|t| serde_json::from_str::<UsageSnapshot>(&t).ok())
            .map(|mut s| {
                if !s.windows.is_empty() {
                    s.status = "stale".into();
                }
                s
            })
            .unwrap_or_default()
    }
}

fn persist(s: &UsageSnapshot) {
    let _ = crate::agy_cli::save_persisted_to(&store_path(), s);
}

/// Is Antigravity installed: the official CLI is available, or any state
/// directory exists, or Credential Manager holds its token
pub fn present() -> bool {
    crate::agy_cli::find_agy().is_some() || legacy_present()
}

/// Every `~/.gemini/antigravity*` install counts, not only the first one found.
fn legacy_present() -> bool {
    let home = dirs::home_dir().unwrap_or_default();
    !state_roots().is_empty()
        || keychain_present()
        || home.join(".omp/agent/agent.db").is_file()
        || home.join(".gemini/oauth_creds.json").is_file()
}

#[cfg(target_os = "macos")]
fn keychain_present() -> bool {
    crate::usage::has_borrowed_keychain("gemini", "antigravity")
}

#[cfg(not(target_os = "macos"))]
fn keychain_present() -> bool {
    read_credential_raw(false).is_some()
}

// ---------------- 1. Local bridge ----------------

#[derive(Clone, Debug, PartialEq)]
struct Endpoint {
    ports: Vec<u16>,
    csrf: String,
}

fn run_hidden(program: &str, args: &[&str]) -> String {
    let mut cmd = std::process::Command::new(program);
    cmd.args(args)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    cmd.output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

/// The process table is the only source of truth: the token is on the command line and the port is written nowhere
#[cfg(windows)]
fn discover() -> Option<Endpoint> {
    // PowerShell CIM query: one "pid<TAB>commandline" per line
    let table = run_hidden(
        "powershell",
        &[
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "Get-CimInstance Win32_Process -Filter \"Name LIKE '%language_server%'\" | ForEach-Object { \"$($_.ProcessId)`t$($_.CommandLine)\" }",
        ],
    );
    let line = table.lines().find(|l| l.contains("--csrf_token"))?;
    let (pid_s, cmdline) = line.split_once('\t')?;
    let pid: u32 = pid_s.trim().parse().ok()?;
    let csrf = flag_value(cmdline, "--csrf_token")?;
    let ports = listening_ports(pid);
    if ports.is_empty() {
        return None;
    }
    Some(Endpoint { ports, csrf })
}
#[cfg(not(windows))]
fn discover() -> Option<Endpoint> {
    let table = run_hidden("ps", &["-Ao", "pid,command"]);
    let line = table
        .lines()
        .find(|l| l.contains("language_server") && l.contains("--csrf_token"))?;
    let pid: u32 = line.trim().split_whitespace().next()?.parse().ok()?;
    let csrf = flag_value(line, "--csrf_token")?;
    let out = run_hidden(
        "lsof",
        &["-nP", "-a", "-p", &pid.to_string(), "-iTCP", "-sTCP:LISTEN"],
    );
    let ports: Vec<u16> = out
        .lines()
        .filter_map(|l| l.split_whitespace().rev().find(|w| w.contains(':')))
        .filter_map(|a| a.rsplit(':').next()?.parse().ok())
        .collect();
    if ports.is_empty() {
        return None;
    }
    Some(Endpoint { ports, csrf })
}

fn flag_value(line: &str, flag: &str) -> Option<String> {
    let parts: Vec<&str> = line.split_whitespace().collect();
    let i = parts.iter().position(|p| *p == flag)?;
    parts.get(i + 1).map(|s| s.trim_matches('"').to_string())
}

/// netstat -ano: `TCP 127.0.0.1:PORT 0.0.0.0:0 LISTENING PID`
#[cfg(windows)]
fn listening_ports(pid: u32) -> Vec<u16> {
    let out = run_hidden("netstat", &["-ano", "-p", "TCP"]);
    let pid_s = pid.to_string();
    let mut ports: Vec<u16> = out
        .lines()
        .filter(|l| l.contains("LISTENING"))
        .filter_map(|l| {
            let cols: Vec<&str> = l.split_whitespace().collect();
            if cols.len() < 5 || cols[4] != pid_s {
                return None;
            }
            cols[1].rsplit(':').next()?.parse::<u16>().ok()
        })
        .collect();
    ports.sort_unstable();
    ports.dedup();
    ports
}

/// Loopback only: the self-signed certificate is accepted for 127.0.0.1 alone (never used for any public request)
fn local_agent() -> Option<ureq::Agent> {
    let tls = native_tls::TlsConnector::builder()
        .danger_accept_invalid_certs(true)
        .danger_accept_invalid_hostnames(true)
        .build()
        .ok()?;
    Some(
        ureq::AgentBuilder::new()
            .tls_connector(Arc::new(tls))
            .timeout(Duration::from_secs(10))
            .redirects(0)
            .build(),
    )
}

fn bridge_quota(ep: &Endpoint) -> Result<Vec<LimitWindow>, String> {
    let agent = local_agent().ok_or("TLS setup failed")?;
    let mut last = String::from("no port answered");
    for port in &ep.ports {
        let url = format!("https://127.0.0.1:{port}{LS_SERVICE}");
        match agent
            .post(&url)
            .set("Content-Type", "application/json")
            .set(CSRF_HEADER, &ep.csrf)
            .send_string(r#"{"forceRefresh":true}"#)
        {
            Ok(r) => match bounded_json(r) {
                Some(v) => {
                    let w = windows_from_bridge(&v);
                    if !w.is_empty() {
                        return Ok(w);
                    }
                    last = format!("port {port}: no recognisable groups");
                }
                None => last = format!("port {port}: invalid response"),
            },
            Err(ureq::Error::Status(code, _)) => last = format!("port {port}: HTTP {code}"),
            Err(e) => last = format!("port {port}: {e}"),
        }
    }
    Err(last)
}

pub fn windows_from_bridge(v: &serde_json::Value) -> Vec<LimitWindow> {
    quota::parse(v, now_ms())
}

/// "5-hour Limit" or "Weekly Limit", as the Mac card names Antigravity's lanes, from the language
/// server's `gemini-5h` ids or the CLI's "Gemini Models Five Hour Limit" ones
pub(crate) fn lane_name(id: &str) -> Option<&'static str> {
    let id = id.to_lowercase();
    if id.contains("weekly") {
        Some("Weekly Limit")
    } else if ["5h", "five hour", "hourly"].iter().any(|k| id.contains(k)) {
        Some("5-hour Limit")
    } else {
        None
    }
}

/// The Mac card's order: groups as the source lists them, and in each the 5-hour lane before the
/// weekly one. The language server and the CLI both send weekly first.
pub(crate) fn order_lanes(windows: &mut [LimitWindow]) {
    let mut groups: Vec<Option<String>> = Vec::new();
    for w in windows.iter() {
        if !groups.contains(&w.group) {
            groups.push(w.group.clone());
        }
    }
    let rank = |w: &LimitWindow| match lane_name(&w.id) {
        Some("5-hour Limit") => 0,
        Some(_) => 1,
        None => 2,
    };
    windows.sort_by_key(|w| (groups.iter().position(|g| *g == w.group), rank(w)));
}

// ---------------- 3. Credential path ----------------

struct Creds {
    access_token: String,
    expired: bool,
    auth_method: String,
    project_id: Option<String>,
    email: Option<String>,
}

/// Windows Credential Manager: generic credential with target = "gemini:antigravity" (Go keyring's service:user naming)
#[cfg(windows)]
fn read_credential_raw(_interactive: bool) -> Option<Vec<u8>> {
    use windows::core::PCWSTR;
    use windows::Win32::Security::Credentials::{
        CredFree, CredReadW, CREDENTIALW, CRED_TYPE_GENERIC,
    };
    let target: Vec<u16> = "gemini:antigravity"
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let mut pcred: *mut CREDENTIALW = std::ptr::null_mut();
    unsafe {
        if CredReadW(PCWSTR(target.as_ptr()), CRED_TYPE_GENERIC, 0, &mut pcred).is_err()
            || pcred.is_null()
        {
            return None;
        }
        let c = &*pcred;
        let blob = if c.CredentialBlobSize > 0 && !c.CredentialBlob.is_null() {
            std::slice::from_raw_parts(c.CredentialBlob, c.CredentialBlobSize as usize).to_vec()
        } else {
            Vec::new()
        };
        CredFree(pcred as *const core::ffi::c_void);
        if blob.is_empty() {
            None
        } else {
            Some(blob)
        }
    }
}
#[cfg(not(any(windows, target_os = "macos")))]
fn read_credential_raw(_interactive: bool) -> Option<Vec<u8>> {
    None
}

#[cfg(target_os = "macos")]
fn read_credential_raw(interactive: bool) -> Option<Vec<u8>> {
    crate::usage::read_borrowed_keychain("gemini", "antigravity", interactive)
        .ok()
        .flatten()
}

/// Raw JSON, or base64 with a `go-keyring-base64:` prefix (UTF-16 storage is accepted too)
fn decode_credential(raw: &[u8]) -> Option<Creds> {
    let mut text = String::from_utf8(raw.to_vec()).unwrap_or_else(|_| {
        // Some writers store the blob as UTF-16LE
        let u16s: Vec<u16> = raw
            .as_chunks::<2>()
            .0
            .iter()
            .map(|c| u16::from_le_bytes(*c))
            .collect();
        String::from_utf16_lossy(&u16s)
    });
    text = text.trim_matches('\0').trim().to_string();
    if let Some(rest) = text.strip_prefix("go-keyring-base64:") {
        let bytes = b64_decode(rest.trim())?;
        text = String::from_utf8(bytes).ok()?;
    }
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    let access = v.pointer("/token/access_token")?.as_str()?.to_string();
    let expiry = v
        .pointer("/token/expiry")
        .and_then(|x| x.as_str())
        .unwrap_or("");
    let expired = chrono::DateTime::parse_from_rfc3339(expiry)
        .map(|d| (d.timestamp_millis().max(0) as u64) <= now_ms())
        .unwrap_or(false);
    let auth_method = v
        .get("auth_method")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    Some(Creds {
        access_token: access,
        expired,
        auth_method,
        project_id: None,
        email: None,
    })
}

fn decode_file_credential(raw: &[u8], omp: bool) -> Option<Creds> {
    let value: serde_json::Value = serde_json::from_slice(raw).ok()?;
    let token = value
        .get(if omp { "access" } else { "access_token" })?
        .as_str()?
        .trim();
    if token.is_empty() {
        return None;
    }
    let expiry = value
        .get(if omp { "expires" } else { "expiry_date" })
        .and_then(serde_json::Value::as_f64)
        .filter(|millis| millis.is_finite() && *millis >= 0.0);
    Some(Creds {
        access_token: token.into(),
        expired: expiry.is_some_and(|millis| millis <= now_ms() as f64),
        auth_method: "consumer".into(),
        project_id: value
            .get("projectId")
            .or_else(|| value.get("project_id"))
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
        email: value
            .get("email")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
    })
}

fn read_json_credentials(path: &Path) -> Option<Creds> {
    let meta = std::fs::metadata(path).ok()?;
    if meta.len() > 64 * 1024 {
        return None;
    }
    decode_file_credential(&std::fs::read(path).ok()?, false)
}

fn read_omp_credentials(path: &Path) -> Option<Creds> {
    use rusqlite::OpenFlags;
    let db = rusqlite::Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;
    db.busy_timeout(Duration::from_millis(100)).ok()?;
    db.execute_batch("PRAGMA query_only=ON;").ok()?;
    let raw: String = db
        .query_row(
            "SELECT data FROM auth_credentials WHERE provider = 'google-antigravity' ORDER BY updated_at DESC LIMIT 1",
            [],
            |row| row.get(0),
        )
        .ok()?;
    (raw.len() <= 64 * 1024).then(|| decode_file_credential(raw.as_bytes(), true))?
}

fn omp_usage_windows(path: &Path, email: Option<&str>) -> Vec<LimitWindow> {
    use rusqlite::{params, OpenFlags};
    let Ok(db) = rusqlite::Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
    else {
        return Vec::new();
    };
    let _ = db.busy_timeout(Duration::from_millis(100));
    let _ = db.execute_batch("PRAGMA query_only=ON;");
    let latest_email = email.map(str::to_owned).or_else(|| {
        db.query_row(
            "SELECT email FROM usage_history WHERE provider = 'google-antigravity' AND email IS NOT NULL AND email != '' ORDER BY recorded_at DESC, id DESC LIMIT 1",
            [],
            |row| row.get::<_, String>(0),
        )
        .ok()
    });
    let sql = if latest_email
        .as_deref()
        .is_some_and(|email| !email.is_empty())
    {
        "SELECT limit_id, label, window_label, used_fraction, resets_at FROM usage_history WHERE provider = 'google-antigravity' AND email = ?1 ORDER BY recorded_at DESC, id DESC LIMIT 10"
    } else {
        "SELECT limit_id, label, window_label, used_fraction, resets_at FROM usage_history WHERE provider = 'google-antigravity' ORDER BY recorded_at DESC, id DESC LIMIT 10"
    };
    let Ok(mut statement) = db.prepare(sql) else {
        return Vec::new();
    };
    let mut newest = std::collections::HashMap::new();
    let collect =
        |row: &rusqlite::Row<'_>| -> rusqlite::Result<(String, String, String, f64, Option<f64>)> {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
            ))
        };
    let rows = if let Some(email) = latest_email.as_deref().filter(|email| !email.is_empty()) {
        statement.query_map(params![email], collect)
    } else {
        statement.query_map([], collect)
    };
    let Ok(rows) = rows else { return Vec::new() };
    for row in rows.flatten() {
        let (limit_id, raw_label, window_label, used, reset) = row;
        let gemini = limit_id.contains(":google:") || raw_label.contains("Google");
        let weekly = window_label.to_lowercase().contains("weekly");
        let id = match (gemini, weekly) {
            (true, true) => "gemini-weekly",
            (true, false) => "gemini-hourly",
            (false, true) => "3p-weekly",
            (false, false) => "3p-hourly",
        };
        newest
            .entry(id)
            .or_insert((used, reset.filter(|ms| *ms > 0.).map(|ms| ms as u64)));
    }
    [
        ("gemini-hourly", "Gemini Models", "5-hour Limit", false),
        ("gemini-weekly", "Gemini Models", "Weekly Limit", true),
        ("3p-hourly", "Claude and GPT models", "5-hour Limit", false),
        ("3p-weekly", "Claude and GPT models", "Weekly Limit", true),
    ]
    .into_iter()
    .map(|(id, group, label, weekly)| {
        let (used, reset) = newest.get(id).copied().unwrap_or((0., None));
        LimitWindow {
            id: id.into(),
            group: Some(group.into()),
            label: label.into(),
            used,
            has_fraction: Some(true),
            resets_at: reset,
            duration: weekly.then_some(7. * 86400.),
            ..Default::default()
        }
    })
    .collect()
}

/// Dependency-free base64 (standard alphabet, tolerant of URL-safe characters and missing padding)
pub(crate) fn b64_decode(s: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let mut buf = 0u32;
    let mut bits = 0u8;
    for c in s.bytes() {
        let sextet: u8 = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            b'=' | b'\n' | b'\r' | b' ' => continue,
            _ => return None,
        };
        let v = sextet as u32;
        buf = (buf << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((buf >> bits) & 0xFF) as u8);
        }
    }
    Some(out)
}

#[derive(Clone, Copy)]
enum CredentialSource {
    Keychain,
    Omp,
    Json,
}

fn choose_default_credentials(
    mut read: impl FnMut(CredentialSource) -> Option<Creds>,
) -> Option<Creds> {
    let mut expired = None;
    for source in [
        CredentialSource::Keychain,
        CredentialSource::Omp,
        CredentialSource::Json,
    ] {
        if let Some(credentials) = read(source) {
            if !credentials.expired {
                return Some(credentials);
            }
            if expired.is_none() {
                expired = Some(credentials);
            }
        }
    }
    expired
}

fn read_credentials(interactive: bool) -> Option<Creds> {
    let home = dirs::home_dir().unwrap_or_default();
    choose_default_credentials(|source| match source {
        CredentialSource::Keychain => {
            read_credential_raw(interactive).and_then(|raw| decode_credential(&raw))
        }
        CredentialSource::Omp => read_omp_credentials(&home.join(".omp/agent/agent.db")),
        CredentialSource::Json => read_json_credentials(&home.join(".gemini/oauth_creds.json")),
    })
}

/// A personal account may answer 403; that is an honest missing quota, not
/// a signed-out claim. Credentials never follow a redirect to another host.
fn direct_quota_at(endpoint: &str, token: &str, project: Option<&str>) -> Option<Vec<LimitWindow>> {
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(15))
        .redirects(0)
        .build();
    let body = project.filter(|project| !project.is_empty()).map_or_else(
        || serde_json::json!({}),
        |project| serde_json::json!({"project": project}),
    );
    let r = agent
        .post(endpoint)
        .set("Authorization", &format!("Bearer {token}"))
        .set("Content-Type", "application/json")
        .set(
            "User-Agent",
            "antigravity/hub/2.8.0 (aidev_client; os_type=darwin; arch=arm64; cl=963137146)",
        )
        .set(
            "Client-Metadata",
            "ideType=IDE_UNSPECIFIED,platform=PLATFORM_UNSPECIFIED,pluginType=GEMINI",
        )
        .send_json(body)
        .ok()?;
    let v = bounded_json(r)?;
    let windows = quota::parse(&v, now_ms());
    (!windows.is_empty()).then_some(windows)
}

fn direct_quota(token: &str, project: Option<&str>) -> Option<Vec<LimitWindow>> {
    direct_quota_at(QUOTA_SUMMARY, token, project)
}

// ---------------- 4. Fallback count ----------------

/// Today's MODEL steps across every install (UTC timestamps compared by local day)
pub fn requests_today() -> (u64, Option<u64>) {
    requests_in(&state_roots(), chrono::Local::now().date_naive())
}

fn requests_in(roots: &[PathBuf], today: chrono::NaiveDate) -> (u64, Option<u64>) {
    use chrono::{Local, TimeZone};
    let mut count = 0u64;
    let mut latest: Option<u64> = None;
    for e in roots
        .iter()
        .filter_map(|r| std::fs::read_dir(r.join("brain")).ok())
        .flat_map(|rd| rd.flatten())
    {
        let p = e
            .path()
            .join(".system_generated")
            .join("logs")
            .join("transcript.jsonl");
        let Ok(text) = std::fs::read_to_string(&p) else {
            continue;
        };
        for line in text.lines() {
            if !line.contains("\"MODEL\"") {
                continue;
            }
            let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
                continue;
            };
            if v.get("source").and_then(|x| x.as_str()) != Some("MODEL") {
                continue;
            }
            let Some(ts) = v.get("created_at").and_then(|x| x.as_str()) else {
                continue;
            };
            let Ok(dt) = chrono::DateTime::parse_from_rfc3339(ts) else {
                continue;
            };
            let ms = dt.timestamp_millis().max(0) as u64;
            latest = Some(latest.map_or(ms, |l| l.max(ms)));
            let local = Local.timestamp_millis_opt(ms as i64).single();
            if let Some(l) = local {
                if l.date_naive() == today {
                    count += 1;
                }
            }
        }
    }
    (count, latest)
}

// ---------------- Putting it together ----------------

struct Runtime {
    endpoint: Option<Endpoint>,
    ever_bridged: bool,
}

fn read_once(rt: &mut Runtime, prev: &UsageSnapshot) -> UsageSnapshot {
    let mut snap = UsageSnapshot::default();
    // 1. Local bridge (the cached endpoint first; the port changes on every launch, so a miss is normal)
    let mut bridge_err = String::new();
    let mut tried = false;
    if let Some(ep) = rt.endpoint.clone() {
        tried = true;
        match bridge_quota(&ep) {
            Ok(w) => {
                rt.ever_bridged = true;
                snap.status = "ok".into();
                snap.windows = w;
                snap.fetched_at = now_ms();
                snap.note = "via Antigravity".into();
                return snap;
            }
            Err(e) => {
                bridge_err = e;
                rt.endpoint = None;
            }
        }
    }
    if let Some(ep) = discover() {
        tried = true;
        match bridge_quota(&ep) {
            Ok(w) => {
                rt.endpoint = Some(ep);
                rt.ever_bridged = true;
                snap.status = "ok".into();
                snap.windows = w;
                snap.fetched_at = now_ms();
                snap.note = "via Antigravity".into();
                return snap;
            }
            Err(e) => bridge_err = e,
        }
    }
    if tried && !bridge_err.is_empty() {
        crate::applog(&format!("antigravity: local bridge failed ({bridge_err})"));
    }
    // A valid borrowed credential can still answer while the IDE is closed.
    let mut tier: Option<String> = None;
    let credentials = read_credentials(take_keychain_prompt(now_ms()));
    if let Some(c) = &credentials {
        tier = Some(if c.auth_method == "consumer" {
            "Personal".into()
        } else {
            c.auth_method.clone()
        });
        if !c.expired {
            if let Some(windows) = direct_quota(&c.access_token, c.project_id.as_deref()) {
                snap.status = "ok".into();
                snap.windows = windows;
                snap.fetched_at = now_ms();
                snap.note = "via Google".into();
                return snap;
            }
        }
    }
    let home = dirs::home_dir().unwrap_or_default();
    let omp = omp_usage_windows(
        &home.join(".omp/agent/agent.db"),
        credentials.as_ref().and_then(|cred| cred.email.as_deref()),
    );
    if !omp.is_empty() {
        snap.status = "ok".into();
        snap.windows = omp;
        snap.fetched_at = now_ms();
        snap.note = "via OMP".into();
        return snap;
    }
    // Once a bridge supplied a percentage, a failed refresh cannot replace it
    // with an unrelated request count.
    if rt.ever_bridged && !prev.windows.is_empty() {
        snap = prev.clone();
        snap.status = "stale".into();
        snap.note = "Antigravity is closed — last reading kept".into();
        return snap;
    }
    // Count fallback (derived: the card gets a ~ prefix and no percentage arc).
    let (n, latest) = requests_today();
    snap.status = "ok".into();
    snap.fetched_at = latest.unwrap_or_else(now_ms);
    snap.windows = vec![LimitWindow {
        id: "requests".into(),
        label: "Requests today · no limit published".into(),
        used: 0.0,
        resets_at: None,
        count: Some(n as i64),
        has_fraction: Some(false),
        derived: true,
        ..Default::default()
    }];
    snap.fidelity = crate::usage::Fidelity::Derived;
    snap.note = match tier {
        Some(t) => format!("{t} · Google publishes no quota for this account"),
        None => "Open Antigravity to read its quota".into(),
    };
    snap
}

fn broadcast(app: &AppHandle, epoch: u64, snap: UsageSnapshot) {
    crate::providers::with_current(app, "gemini", epoch, || {
        let st = app.state::<AppState>();
        *st.antigravity.lock().unwrap() = snap.clone();
        persist(&snap);
        let _ = app.emit("antigravity", &snap);
        crate::refresh::complete("gemini");
    });
}

pub(crate) fn forget(app: &AppHandle) {
    REFRESH_LEGACY.store(false, std::sync::atomic::Ordering::Relaxed);
    *app.state::<AppState>().antigravity.lock().unwrap() = UsageSnapshot::default();
    let _ = std::fs::remove_file(store_path());
    let _ = app.emit("antigravity", UsageSnapshot::default());
}

fn sleep_interruptible(secs: u64) {
    for _ in 0..secs {
        if REFRESH_LEGACY.swap(false, std::sync::atomic::Ordering::Relaxed) {
            return;
        }
        std::thread::sleep(Duration::from_secs(1));
    }
}

pub fn start(app: AppHandle) {
    if crate::agy_cli::find_agy().is_some() {
        start_cli(app);
    } else {
        start_legacy(app);
    }
}

fn start_cli(app: AppHandle) {
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    *REFRESH_CLI.lock().unwrap() = Some(sender);

    std::thread::spawn(move || {
        {
            let st = app.state::<AppState>();
            let snap = st.antigravity.lock().unwrap().clone();
            let _ = app.emit("antigravity", &snap);
        }

        let mut last_attempt: Option<Instant> = None;
        let mut last_epoch = crate::providers::generation("gemini");

        while receiver.recv().is_ok() {
            if !crate::providers::enabled(&app, "gemini") {
                continue;
            }
            let epoch = crate::providers::generation("gemini");
            if epoch != last_epoch {
                last_attempt = None;
                last_epoch = epoch;
            }
            if last_attempt.is_some_and(|last| last.elapsed() < CLI_TTL) {
                crate::refresh::complete("gemini");
                continue;
            }
            let st = app.state::<AppState>();
            let previous = st.antigravity.lock().unwrap().clone();
            if !previous.windows.is_empty()
                && now_ms().saturating_sub(previous.fetched_at) < CLI_TTL.as_millis() as u64
            {
                crate::refresh::complete("gemini");
                continue;
            }
            last_attempt = Some(Instant::now());

            let snap = match crate::agy_cli::read_quota() {
                Ok(windows) => UsageSnapshot {
                    status: "ok".into(),
                    windows,
                    fetched_at: now_ms(),
                    note: "via Antigravity CLI".into(),
                    ..Default::default()
                },
                Err(error) => UsageSnapshot {
                    status: if previous.windows.is_empty() {
                        "error".into()
                    } else {
                        "stale".into()
                    },
                    note: format!(
                        "via Antigravity CLI — {error}.{}",
                        if previous.windows.is_empty() {
                            ""
                        } else {
                            " Last reading kept."
                        }
                    ),
                    ..previous
                },
            };

            broadcast(&app, epoch, snap);
        }
    });

    request_refresh();
}

fn start_legacy(app: AppHandle) {
    std::thread::spawn(move || {
        {
            let st = app.state::<AppState>();
            let snap = st.antigravity.lock().unwrap().clone();
            let _ = app.emit("antigravity", &snap);
        }
        if !legacy_present() {
            broadcast(
                &app,
                crate::providers::generation("gemini"),
                UsageSnapshot {
                    status: "absent".into(),
                    ..Default::default()
                },
            );
            loop {
                if !crate::providers::enabled(&app, "gemini") {
                    std::thread::sleep(Duration::from_secs(1));
                    continue;
                }
                sleep_interruptible(600);
                if legacy_present() {
                    break;
                }
            }
        }
        let mut rt = Runtime {
            endpoint: None,
            ever_bridged: false,
        };
        loop {
            if !crate::providers::enabled(&app, "gemini") {
                std::thread::sleep(Duration::from_secs(1));
                continue;
            }
            let prev = {
                let st = app.state::<AppState>();
                let s = st.antigravity.lock().unwrap().clone();
                s
            };
            let epoch = crate::providers::generation("gemini");
            let snap = read_once(&mut rt, &prev);
            broadcast(&app, epoch, snap);
            sleep_interruptible(POLL_SECS);
        }
    });
}

/// For doctor: contains no secrets
pub fn probe() -> String {
    if let Some(agy) = crate::agy_cli::find_agy() {
        format!("Antigravity: official CLI installed at {}", agy.display())
    } else {
        legacy_probe()
    }
}

fn legacy_probe() -> String {
    let roots = state_roots();
    let cred = read_credentials(false);
    let ep = discover();
    format!(
        "Antigravity: state dirs {} | Credential Manager gemini:antigravity {} | language_server {}",
        if roots.is_empty() {
            "none under ~/.gemini".to_string()
        } else {
            roots.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join(", ")
        },
        match cred {
            Some(c) => format!("found ({}, {})", c.auth_method, if c.expired { "expired" } else { "valid" }),
            None => "not found".into(),
        },
        match ep {
            Some(e) => format!("running, ports {:?}", e.ports),
            None => "not running".into(),
        }
    )
}

#[cfg(test)]
mod tests {
    use super::{
        choose_default_credentials, decode_file_credential, read_json_credentials,
        read_omp_credentials, requests_in, state_roots_in, CredentialSource, Creds,
        PromptPermission,
    };
    use std::path::{Path, PathBuf};

    #[test]
    fn keychain_prompt_is_single_use_and_expires() {
        let mut permission = PromptPermission::default();
        permission.grant(100);
        assert!(permission.take(60_099));
        assert!(!permission.take(101));
        permission.grant(100);
        assert!(!permission.take(60_100));
    }

    #[test]
    fn default_credentials_try_keychain_then_omp_then_json_without_reading_later_sources() {
        let credential = |name: &str, expired| Creds {
            access_token: name.into(),
            expired,
            auth_method: "consumer".into(),
            project_id: None,
            email: None,
        };
        let mut visited = Vec::new();
        let chosen = choose_default_credentials(|source| {
            visited.push(match source {
                CredentialSource::Keychain => "keychain",
                CredentialSource::Omp => "omp",
                CredentialSource::Json => "json",
            });
            match source {
                CredentialSource::Keychain => Some(credential("old-keychain", true)),
                CredentialSource::Omp => Some(credential("live-omp", false)),
                CredentialSource::Json => panic!("a valid OMP credential must stop reads"),
            }
        })
        .unwrap();
        assert_eq!(chosen.access_token, "live-omp");
        assert_eq!(visited, ["keychain", "omp"]);
        let expired = choose_default_credentials(|source| match source {
            CredentialSource::Keychain => Some(credential("first-expired", true)),
            CredentialSource::Omp => Some(credential("second-expired", true)),
            CredentialSource::Json => None,
        })
        .unwrap();
        assert_eq!(expired.access_token, "first-expired");
    }

    #[test]
    fn named_file_credentials_use_json_before_agent_db_and_never_default_keychain() {
        let temp = tempfile::tempdir().unwrap();
        let json = temp.path().join("oauth_creds.json");
        let db_path = temp.path().join("agent.db");
        let db = rusqlite::Connection::open(&db_path).unwrap();
        db.execute_batch(
            "CREATE TABLE auth_credentials(provider TEXT, data TEXT, updated_at INTEGER);",
        )
        .unwrap();
        db.execute(
            "INSERT INTO auth_credentials VALUES ('google-antigravity', ?1, 1)",
            [r#"{"access":"omp-fixture","projectId":"project","email":"omp@example.test"}"#],
        )
        .unwrap();
        drop(db);
        std::fs::write(
            &json,
            br#"{"access_token":"json-fixture","project_id":"project","email":"json@example.test"}"#,
        )
        .unwrap();
        let chosen = read_json_credentials(&json)
            .or_else(|| read_omp_credentials(&db_path))
            .unwrap();
        assert_eq!(chosen.access_token, "json-fixture");
        std::fs::remove_file(&json).unwrap();
        let omp = read_json_credentials(&json)
            .or_else(|| read_omp_credentials(&db_path))
            .unwrap();
        assert_eq!(omp.access_token, "omp-fixture");
        assert_eq!(omp.email.as_deref(), Some("omp@example.test"));
        assert!(decode_file_credential(br#"{"access":""}"#, true).is_none());
    }

    #[test]
    fn borrowed_quota_request_never_redirects_a_token() {
        use tiny_http::{Header, Response, Server};
        let first = Server::http("127.0.0.1:0").unwrap();
        let target = Server::http("127.0.0.1:0").unwrap();
        let url = format!("http://{}/quota", first.server_addr());
        let target_url = format!("http://{}/borrowed", target.server_addr());
        let worker = std::thread::spawn(move || {
            let request = first.recv().unwrap();
            assert!(request.headers().iter().any(|header| {
                header.field.equiv("Authorization")
                    && header.value.as_str() == "Bearer fixture-secret"
            }));
            let header = Header::from_bytes("Location", target_url.as_bytes()).unwrap();
            request
                .respond(Response::empty(302).with_header(header))
                .unwrap();
        });
        assert!(super::direct_quota_at(&url, "fixture-secret", Some("fixture-project")).is_none());
        worker.join().unwrap();
        assert!(target
            .recv_timeout(std::time::Duration::from_millis(300))
            .unwrap()
            .is_none());
    }

    #[test]
    fn borrowed_quota_response_is_bounded_before_json_parse() {
        use tiny_http::{Response, Server};
        let server = Server::http("127.0.0.1:0").unwrap();
        let url = format!("http://{}/quota", server.server_addr());
        let worker = std::thread::spawn(move || {
            let request = server.recv().unwrap();
            request
                .respond(Response::from_data(vec![
                    b' ';
                    super::MAX_QUOTA_BODY as usize + 1
                ]))
                .unwrap();
        });
        assert!(super::direct_quota_at(&url, "fixture-secret", None).is_none());
        worker.join().unwrap();
    }

    struct Home(PathBuf);
    impl Home {
        fn new(name: &str) -> Self {
            let p = std::env::temp_dir().join(format!("vela-ag-{}-{name}", std::process::id()));
            let _ = std::fs::remove_dir_all(&p);
            std::fs::create_dir_all(p.join(".gemini")).unwrap();
            Home(p)
        }
        fn flavour(&self, name: &str) -> PathBuf {
            let d = self.0.join(".gemini").join(name);
            std::fs::create_dir_all(&d).unwrap();
            d
        }
    }
    impl Drop for Home {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn names(roots: &[PathBuf]) -> Vec<String> {
        roots
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect()
    }

    fn trajectory(root: &Path, id: &str, lines: &[String]) {
        let logs = root
            .join("brain")
            .join(id)
            .join(".system_generated")
            .join("logs");
        std::fs::create_dir_all(&logs).unwrap();
        std::fs::write(logs.join("transcript.jsonl"), lines.join("\n")).unwrap();
    }

    fn step(source: &str, at: chrono::DateTime<chrono::Utc>) -> String {
        format!(
            r#"{{"source":"{source}","created_at":"{}"}}"#,
            at.to_rfc3339()
        )
    }

    fn today() -> chrono::NaiveDate {
        chrono::Local::now().date_naive()
    }

    #[test]
    fn no_gemini_directory_means_no_roots() {
        let missing = std::env::temp_dir().join(format!("vela-ag-{}-missing", std::process::id()));
        assert!(state_roots_in(&missing).is_empty());
    }

    #[test]
    fn an_ide_only_install_is_found() {
        let h = Home::new("ide");
        h.flavour("antigravity-ide");
        h.flavour("config");
        assert_eq!(names(&state_roots_in(&h.0)), ["antigravity-ide"]);
    }

    #[test]
    fn the_legacy_layout_still_works() {
        let h = Home::new("legacy");
        h.flavour("antigravity");
        assert_eq!(names(&state_roots_in(&h.0)), ["antigravity"]);
    }

    #[test]
    fn every_flavour_is_found_and_nothing_else() {
        let h = Home::new("all");
        for f in [
            "antigravity-cli",
            "antigravity",
            "antigravity-ide",
            "antigravity-backup",
            "config",
        ] {
            h.flavour(f);
        }
        std::fs::write(h.0.join(".gemini").join("antigravity-notes.txt"), "").unwrap();
        assert_eq!(
            names(&state_roots_in(&h.0)),
            [
                "antigravity",
                "antigravity-backup",
                "antigravity-cli",
                "antigravity-ide"
            ]
        );
    }

    #[test]
    fn requests_are_summed_across_installs() {
        let h = Home::new("sum");
        let now = chrono::Utc::now();
        let old = now - chrono::TimeDelta::days(3);
        trajectory(
            &h.flavour("antigravity-ide"),
            "a",
            &[step("MODEL", now), step("USER", now), step("MODEL", old)],
        );
        trajectory(
            &h.flavour("antigravity-cli"),
            "b",
            &[step("MODEL", now), step("MODEL", now)],
        );
        let (count, latest) = requests_in(&state_roots_in(&h.0), today());
        assert_eq!(count, 3);
        assert_eq!(latest, Some(now.timestamp_millis() as u64));
    }

    #[test]
    fn an_empty_first_install_does_not_hide_the_next() {
        // #84's trap: antigravity-ide/brain existed and was empty while the transcripts sat in
        // antigravity-cli, so "the first that exists" read zero.
        let h = Home::new("trap");
        std::fs::create_dir_all(h.flavour("antigravity-ide").join("brain")).unwrap();
        trajectory(
            &h.flavour("antigravity-cli"),
            "c",
            &[step("MODEL", chrono::Utc::now())],
        );
        assert_eq!(requests_in(&state_roots_in(&h.0), today()).0, 1);
    }

    #[test]
    fn lanes_are_grouped_by_model_and_named_five_hour_first() {
        // The shape the language server answered with on a real machine
        let reply = serde_json::json!({ "response": { "groups": [
            { "displayName": "Gemini Models", "buckets": [
                { "bucketId": "gemini-weekly", "displayName": "Weekly Limit Remaining", "remainingFraction": 0.97 },
                { "bucketId": "gemini-5h", "displayName": "5-hour Limit Remaining", "remainingFraction": 1.0 } ] },
            { "displayName": "Claude and GPT models", "buckets": [
                { "bucketId": "3p-weekly", "displayName": "Weekly Limit Remaining", "remainingFraction": 1.0 },
                { "bucketId": "3p-5h", "displayName": "5-hour Limit Remaining", "remainingFraction": 1.0 } ] } ] } });
        let lanes: Vec<String> = super::windows_from_bridge(&reply)
            .into_iter()
            .map(|w| format!("{} › {} ({})", w.group.unwrap_or_default(), w.label, w.id))
            .collect();
        assert_eq!(
            lanes,
            [
                "Gemini Models › 5-hour Limit (gemini-5h)",
                "Gemini Models › Weekly Limit (gemini-weekly)",
                "Claude and GPT models › 5-hour Limit (3p-5h)",
                "Claude and GPT models › Weekly Limit (3p-weekly)",
            ]
        );
    }
}

pub fn read_profile(home: &std::path::Path, _previous: UsageSnapshot) -> UsageSnapshot {
    let cred = read_json_credentials(&home.join("oauth_creds.json"))
        .or_else(|| read_omp_credentials(&home.join("agent.db")));
    if let Some(cred) = cred {
        if let Some(windows) = direct_quota(&cred.access_token, cred.project_id.as_deref()) {
            return UsageSnapshot {
                status: "ok".into(),
                windows,
                fetched_at: now_ms(),
                note: "via Google".into(),
                ..Default::default()
            };
        }
    }
    let (count, latest) = requests_in(&[home.to_path_buf()], chrono::Local::now().date_naive());
    UsageSnapshot {
        status: "ok".into(),
        windows: vec![LimitWindow {
            id: "requests".into(),
            label: "Requests today · no limit published".into(),
            count: Some(count as i64),
            has_fraction: Some(false),
            derived: true,
            ..Default::default()
        }],
        fidelity: crate::usage::Fidelity::Derived,
        fetched_at: latest.unwrap_or_else(now_ms),
        note: "Open Antigravity to read its quota".into(),
        ..Default::default()
    }
}
