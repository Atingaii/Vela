use super::{parse, Failure};
use crate::usage::UsageSnapshot;
use serde_json::{json, Value};
use std::{
    io::Read,
    path::{Path, PathBuf},
    time::Duration,
};

const MAX_BODY: u64 = 2 * 1024 * 1024;
fn read(path: impl AsRef<Path>) -> Option<String> {
    let file = std::fs::File::open(path).ok()?;
    if file.metadata().ok()?.len() > MAX_BODY {
        return None;
    }
    let mut text = String::new();
    file.take(MAX_BODY).read_to_string(&mut text).ok()?;
    Some(text)
}
fn file(path: impl AsRef<Path>) -> Option<Value> {
    serde_json::from_str(&read(path)?).ok()
}
fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_default()
}
fn env(names: &[&str]) -> Option<String> {
    names
        .iter()
        .find_map(|n| std::env::var(n).ok().filter(|s| !s.trim().is_empty()))
}
fn key(v: &Value, keys: &[&str]) -> Option<String> {
    v.as_str()
        .or_else(|| keys.iter().find_map(|k| v[*k].as_str()))
        .filter(|s| !s.trim().is_empty())
        .map(str::to_owned)
}

fn coding_plan_token(raw: String) -> Option<String> {
    let trimmed = raw.trim();
    let token = if trimmed
        .get(..7)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("bearer "))
    {
        &trimmed[7..]
    } else {
        trimmed
    }
    .trim();
    (!token.is_empty() && !token.to_ascii_lowercase().starts_with("sk-api-"))
        .then(|| token.to_owned())
}

fn cookie_store_path(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    [
        "cookies.sqlite",
        "cookies.binarycookies",
        "/chrome/",
        "/chromium/",
        "/safari/",
        "/cookies/",
    ]
    .iter()
    .any(|part| lower.contains(part))
        || lower.ends_with("/cookies")
}

fn cookie_pair(value: &str) -> Option<String> {
    let value = value.trim();
    (value.contains('=') && !value.chars().any(char::is_control) && !cookie_store_path(value))
        .then(|| value.to_owned())
}

fn cookie_header(value: &str) -> Option<String> {
    let value = value.trim();
    value
        .get(..7)
        .filter(|head| head.eq_ignore_ascii_case("cookie:"))
        .and_then(|_| cookie_pair(&value[7..]))
}

fn shell_tokens(raw: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut quote = None;
    for ch in raw.chars() {
        match (quote, ch) {
            (Some(mark), ch) if ch == mark => quote = None,
            (Some(_), ch) => current.push(ch),
            (None, '\'' | '"') => quote = Some(ch),
            (None, ch) if ch.is_whitespace() => {
                if !current.is_empty() {
                    tokens.push(std::mem::take(&mut current));
                }
            }
            _ => current.push(ch),
        }
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    tokens
}

fn normalized_cookie(raw: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.is_empty() || raw.chars().any(|ch| ch == '\r' || ch == '\0') {
        return None;
    }
    for line in raw.lines() {
        if let Some(value) = cookie_header(line) {
            return Some(value);
        }
    }
    let tokens = shell_tokens(raw);
    if tokens.first().is_some_and(|first| first == "curl")
        || tokens
            .iter()
            .any(|part| matches!(part.as_str(), "-H" | "--header" | "-b" | "--cookie"))
    {
        for (i, token) in tokens.iter().enumerate() {
            let value = tokens.get(i + 1).map(String::as_str);
            let found = match token.as_str() {
                "-H" | "--header" => value.and_then(cookie_header),
                "-b" | "--cookie" => value.and_then(cookie_pair),
                _ => token
                    .strip_prefix("--header=")
                    .and_then(cookie_header)
                    .or_else(|| token.strip_prefix("--cookie=").and_then(cookie_pair)),
            };
            if found.is_some() {
                return found;
            }
        }
        return None;
    }
    cookie_pair(raw)
}

fn minimax_cookie() -> Option<String> {
    ["MINIMAX_COOKIE", "MINIMAX_COOKIE_HEADER"]
        .iter()
        .filter_map(|key| std::env::var(key).ok())
        .find_map(|raw| normalized_cookie(&raw))
        .or_else(|| {
            crate::secrets::read("minimax-cookie")
                .ok()
                .and_then(|raw| normalized_cookie(&raw))
        })
}

fn minimax_envelope_code(value: &Value) -> Option<i64> {
    [
        &value["status_code"],
        &value["code"],
        &value["base_resp"]["status_code"],
        &value["base_resp"]["code"],
        &value["data"]["base_resp"]["status_code"],
        &value["data"]["base_resp"]["code"],
    ]
    .iter()
    .find_map(|item| {
        item.as_i64()
            .or_else(|| item.as_str().and_then(|text| text.parse().ok()))
    })
}

fn minimax_key_region(
    suffix: &str,
    token: &str,
    mut get: impl FnMut(&str, &str) -> Result<Value, Failure>,
) -> Result<UsageSnapshot, Failure> {
    let mut missing = false;
    let mut empty = false;
    for (host, path) in [
        ("api", "/v1/token_plan/remains"),
        ("www", "/v1/token_plan/remains"),
        ("www", "/v1/api/openplatform/coding_plan/remains"),
    ] {
        let url = format!("https://{host}.{suffix}{path}");
        match get(&url, token) {
            Ok(body) => match minimax_envelope_code(&body) {
                Some(429 | 2045) => return Err(Failure::MiniMaxThrottle(None)),
                Some(401 | 403) => return Err(Failure::Auth),
                Some(1004) => {
                    missing = true;
                    continue;
                }
                _ => match parse::reading("minimax", &body) {
                    Ok(reading) => return Ok(reading),
                    Err(Failure::Invalid | Failure::Unsupported(_)) => {
                        empty = true;
                        continue;
                    }
                    Err(error) => return Err(error),
                },
            },
            Err(Failure::MissingEndpoint) => {
                missing = true;
                continue;
            }
            Err(error) => return Err(error),
        }
    }
    if empty {
        Err(Failure::Unsupported("MiniMax reported no usage windows"))
    } else if missing {
        Err(Failure::MissingEndpoint)
    } else {
        Err(Failure::Invalid)
    }
}

fn minimax_key_with(
    token: &str,
    china: bool,
    mut get: impl FnMut(&str, &str) -> Result<Value, Failure>,
) -> Result<UsageSnapshot, Failure> {
    let suffix = if china { "minimaxi.com" } else { "minimax.io" };
    match minimax_key_region(suffix, token, &mut get) {
        Err(Failure::Auth) if !china => minimax_key_region("minimaxi.com", token, get),
        outcome => outcome,
    }
}
fn request(url: &str, token: Option<&str>, body: Option<Value>) -> Result<Value, Failure> {
    request_with_policy(url, token, None, body, RequestPolicy::Standard)
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum RequestPolicy {
    Standard,
    OpenCode,
    Copilot,
    CommandCode,
    OllamaCloud,
    MiniMax,
}

fn request_for(
    policy: RequestPolicy,
    url: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> Result<Value, Failure> {
    request_with_policy(url, token, None, body, policy)
}

fn request_with_policy(
    url: &str,
    token: Option<&str>,
    cookie: Option<&str>,
    body: Option<Value>,
    policy: RequestPolicy,
) -> Result<Value, Failure> {
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(15))
        .redirects(0)
        .build();
    let mut req = agent
        .request(if body.is_some() { "POST" } else { "GET" }, url)
        .set("Accept", "application/json")
        .set(
            "User-Agent",
            if policy == RequestPolicy::CommandCode {
                "command-code-desktop"
            } else {
                "Velo/0.1"
            },
        )
        .set("X-GitHub-Api-Version", "2022-11-28")
        .set("Connect-Protocol-Version", "1");
    if policy == RequestPolicy::CommandCode {
        req = req.set("x-command-code-version", "desktop");
    }
    if let Some(token) = token {
        req = req.set("Authorization", &format!("Bearer {token}"));
    }
    if let Some(cookie) = cookie {
        req = req.set("Cookie", cookie);
    }
    let response = match if let Some(body) = body {
        req.send_json(body)
    } else {
        req.call()
    } {
        Ok(r) => r,
        Err(ureq::Error::Status(401, _)) => return Err(Failure::Auth),
        Err(ureq::Error::Status(403, _)) => {
            return Err(match policy {
                RequestPolicy::OpenCode => {
                    Failure::Unsupported("No OpenCode Go subscription on this key")
                }
                RequestPolicy::Copilot
                | RequestPolicy::CommandCode
                | RequestPolicy::OllamaCloud
                | RequestPolicy::MiniMax => Failure::Auth,
                RequestPolicy::Standard => Failure::Denied,
            })
        }
        Err(ureq::Error::Status(429, r)) => {
            let hint = r.header("Retry-After").and_then(retry_after_secs);
            return Err(match policy {
                RequestPolicy::OpenCode => Failure::OpenCodeThrottle(hint),
                RequestPolicy::MiniMax => Failure::MiniMaxThrottle(hint),
                _ => Failure::Throttle(hint.unwrap_or(60)),
            });
        }
        Err(ureq::Error::Status(404 | 405, _)) if policy == RequestPolicy::MiniMax => {
            return Err(Failure::MissingEndpoint)
        }
        Err(ureq::Error::Status(_, _)) => return Err(Failure::Invalid),
        Err(_) => return Err(Failure::Network),
    };
    if !(200..300).contains(&response.status()) {
        return Err(Failure::Invalid);
    }
    let mut bytes = Vec::new();
    response
        .into_reader()
        .take(MAX_BODY + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Failure::Network)?;
    if bytes.len() as u64 > MAX_BODY {
        return Err(Failure::Invalid);
    }
    serde_json::from_slice(&bytes).map_err(|_| Failure::Invalid)
}

fn retry_after_secs(value: &str) -> Option<u64> {
    let value = value.trim();
    if let Ok(seconds) = value.parse::<f64>() {
        return seconds.is_finite().then(|| seconds.max(0.0).ceil() as u64);
    }
    let date = chrono::DateTime::parse_from_rfc2822(value).ok()?;
    Some((date.timestamp() - chrono::Utc::now().timestamp()).max(0) as u64)
}

fn commandcode_since(value: &Value) -> Option<String> {
    use chrono::{SecondsFormat, TimeZone};
    let date = if let Some(text) = value.as_str() {
        chrono::DateTime::parse_from_rfc3339(text)
            .ok()?
            .with_timezone(&chrono::Utc)
    } else {
        let number = value
            .as_f64()
            .filter(|number| number.is_finite() && *number > 0.0)?;
        let millis = if number > 1_000_000_000_000.0 {
            number
        } else {
            number * 1000.0
        };
        chrono::Utc
            .timestamp_millis_opt(millis.round() as i64)
            .single()?
    };
    Some(date.to_rfc3339_opts(SecondsFormat::Millis, true))
}

fn commandcode_url(
    base: &str,
    path: &str,
    org: Option<&str>,
    since: Option<&str>,
) -> Result<String, Failure> {
    let mut url = tauri::Url::parse(&format!("{base}/{path}")).map_err(|_| Failure::Invalid)?;
    if let Some(org) = org {
        url.query_pairs_mut().append_pair("orgId", org);
    }
    if let Some(since) = since {
        url.query_pairs_mut().append_pair("since", since);
    }
    Ok(url.into())
}
fn copilot_hosts_path() -> PathBuf {
    let root = std::env::var_os("GH_CONFIG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            if cfg!(windows) {
                dirs::config_dir().unwrap_or_default().join("GitHub CLI")
            } else {
                home().join(".config/gh")
            }
        });
    root.join("hosts.yml")
}

fn copilot_hosts(text: Option<&str>) -> (Option<String>, Option<String>) {
    let Some(text) = text else {
        return (None, None);
    };
    let mut github = false;
    let mut user = None;
    let mut token = None;
    for line in text.lines() {
        if !line.starts_with(char::is_whitespace) {
            github = line.trim() == "github.com:";
        }
        if github {
            for (key, target) in [("user:", &mut user), ("oauth_token:", &mut token)] {
                if let Some(value) = line.trim().strip_prefix(key) {
                    let value = value.trim().trim_matches(['\'', '"']);
                    if !value.is_empty() {
                        *target = Some(value.to_owned());
                    }
                }
            }
        }
    }
    (user, token)
}

fn copilot_credentials(
    environment_token: Option<String>,
    hosts: Option<&str>,
    command: impl FnOnce() -> Option<String>,
) -> Option<(String, Option<String>)> {
    let (user, stored) = copilot_hosts(hosts);
    let token = environment_token.or(stored).or_else(command)?;
    Some((token, user))
}

fn gh_token() -> Option<String> {
    let executable = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        .into_iter()
        .find(|path| Path::new(path).is_file())?;
    gh_token_at(Path::new(executable))
}

fn gh_token_at(executable: &Path) -> Option<String> {
    let mut command = std::process::Command::new(executable);
    command.args(["auth", "token", "--hostname", "github.com"]);
    let output = crate::usage::process_output::output(command, 4096, Duration::from_secs(5))?;
    String::from_utf8(output).ok().and_then(|text| {
        let token = text.trim();
        (!token.is_empty()).then(|| token.to_owned())
    })
}

fn copilot_token() -> Option<String> {
    let hosts = read(copilot_hosts_path());
    copilot_credentials(
        env(&["GH_TOKEN", "GITHUB_TOKEN"]),
        hosts.as_deref(),
        gh_token,
    )
    .map(|(token, _)| token)
}

pub(super) fn copilot_account() -> Option<String> {
    let hosts = read(copilot_hosts_path());
    copilot_hosts(hosts.as_deref()).0
}

pub(super) fn commandcode_account() -> Option<Option<String>> {
    if env(&["COMMAND_CODE_API_KEY"]).is_some() {
        return Some(None);
    }
    let stored = file(home().join(".commandcode/auth.json"))?;
    key(&stored["apiKey"], &[])?;
    Some(
        stored["userName"]
            .as_str()
            .filter(|name| !name.is_empty())
            .map(str::to_owned),
    )
}
struct DevinAuth {
    api_key: String,
    email: Option<String>,
    source: &'static str,
}
fn devin_paths() -> (PathBuf, PathBuf) {
    let root = if cfg!(target_os = "macos") {
        home().join("Library/Application Support")
    } else {
        dirs::config_dir().unwrap_or_default()
    };
    (
        root.join("Devin/User/globalStorage/state.vscdb"),
        home().join(".local/share/devin/credentials.toml"),
    )
}
fn devin_desktop(path: &Path) -> Option<(String, Option<String>)> {
    let db = rusqlite::Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()?;
    let _ = db.busy_timeout(Duration::from_millis(100));
    let text: String = db
        .query_row(
            "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1",
            [],
            |r| r.get(0),
        )
        .ok()?;
    let root: Value = serde_json::from_str(&text).ok()?;
    let api_key = root["apiKey"].as_str()?.trim();
    if api_key.is_empty() {
        return None;
    }
    let email = root["email"]
        .as_str()
        .filter(|s| !s.is_empty())
        .map(str::to_owned);
    Some((api_key.to_owned(), email))
}
fn devin_auth_at(desktop: &Path, cli: &Path) -> Option<DevinAuth> {
    let source = if desktop.is_file() {
        "Devin Desktop"
    } else {
        "Devin CLI"
    };
    if let Some((api_key, email)) = devin_desktop(desktop) {
        return Some(DevinAuth {
            api_key,
            email,
            source,
        });
    }
    let text = read(cli)?;
    let doc = text.parse::<toml_edit::DocumentMut>().ok()?;
    let api_key = doc.get("windsurf_api_key")?.as_str()?.trim();
    (!api_key.is_empty()).then(|| DevinAuth {
        api_key: api_key.to_owned(),
        email: None,
        source,
    })
}
fn devin_auth() -> Option<DevinAuth> {
    let (desktop, cli) = devin_paths();
    devin_auth_at(&desktop, &cli)
}
pub(super) fn devin_account() -> Option<super::AccountSummary> {
    let auth = devin_auth()?;
    Some(super::AccountSummary {
        label: auth.email,
        plan: None,
        source: auth.source.into(),
        manage_url: Some("https://app.devin.ai".into()),
    })
}
pub(super) fn fetch(id: &str, china: bool) -> Result<UsageSnapshot, Failure> {
    match id {
        "opencode" => {
            let root = std::env::var_os("XDG_DATA_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| home().join(".local/share"));
            let v = file(root.join("opencode/auth.json")).ok_or(Failure::Absent)?;
            let token = key(
                &v["opencode-go"],
                &["key", "apiKey", "api_key", "token", "accessToken"],
            )
            .ok_or(Failure::Absent)?;
            parse::reading(
                id,
                &request_for(
                    RequestPolicy::OpenCode,
                    "https://opencode.ai/zen/go/v1/usage",
                    Some(&token),
                    None,
                )?,
            )
        }
        "kimi" => {
            let root = std::env::var_os("KIMI_CODE_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| home().join(".kimi-code"));
            let v = file(root.join("credentials/kimi-code.json")).ok_or(Failure::Absent)?;
            let token = key(&v, &["access_token"]).ok_or(Failure::Absent)?;
            if parse::number(&v["expires_at"]).is_none_or(|t| t * 1000. <= crate::now_ms() as f64) {
                return Err(Failure::Expired);
            }
            parse::reading(
                id,
                &request("https://api.kimi.com/coding/v1/usages", Some(&token), None)?,
            )
        }
        "copilot" => {
            let token = copilot_token().ok_or(Failure::Absent)?;
            parse::reading(
                id,
                &request_for(
                    RequestPolicy::Copilot,
                    "https://api.github.com/copilot_internal/user",
                    Some(&token),
                    None,
                )?,
            )
        }
        "devin" => {
            let token = devin_auth().ok_or(Failure::Absent)?.api_key;
            parse::reading(id, &request("https://server.self-serve.windsurf.com/exa.seat_management_pb.SeatManagementService/GetUserStatus",None,Some(json!({"metadata":{"apiKey":token,"ideName":"windsurf","ideVersion":"1.108.2","extensionName":"windsurf","extensionVersion":"1.108.2","locale":"en"}})))?)
        }
        "commandcode" => {
            let token = env(&["COMMAND_CODE_API_KEY"])
                .or_else(|| key(&file(home().join(".commandcode/auth.json"))?, &["apiKey"]))
                .ok_or(Failure::Absent)?;
            let base = "https://api.commandcode.ai/alpha";
            let who = request_for(
                RequestPolicy::CommandCode,
                &format!("{base}/whoami"),
                Some(&token),
                None,
            )?;
            let org = who["org"]["id"].as_str();
            let build = |path: &str, since: Option<&str>| commandcode_url(base, path, org, since);
            let credits = request_for(
                RequestPolicy::CommandCode,
                &build("billing/credits", None)?,
                Some(&token),
                None,
            )?;
            let subscription = request_for(
                RequestPolicy::CommandCode,
                &build("billing/subscriptions", None)?,
                Some(&token),
                None,
            )?;
            let sub = subscription.get("data").unwrap_or(&subscription);
            let since = commandcode_since(&sub["currentPeriodStart"]);
            let summary = request_for(
                RequestPolicy::CommandCode,
                &build("usage/summary", since.as_deref())?,
                Some(&token),
                None,
            )?;
            let plan = sub["planId"]
                .as_str()
                .filter(|s| !s.trim().is_empty())
                .map(|s| {
                    if s.to_lowercase().contains("goat") {
                        "GOAT".into()
                    } else {
                        s.into()
                    }
                });
            Ok(UsageSnapshot {
                windows: parse::commandcode(&summary, &credits, &subscription)?,
                plan,
                ..Default::default()
            })
        }
        "minimax" => {
            let token = env(&[
                "MiniMax_CODING_API_KEY",
                "MINIMAX_CODING_API_KEY",
                "MINIMAX_API_KEY",
            ])
            .or_else(|| crate::secrets::read("minimax").ok())
            .and_then(coding_plan_token);
            if let Some(token) = token {
                return minimax_key_with(&token, china, |url, token| {
                    request_for(RequestPolicy::MiniMax, url, Some(token), None)
                });
            }
            let suffix = if china { "minimaxi.com" } else { "minimax.io" };
            let cookie = minimax_cookie().ok_or(Failure::Absent)?;
            let url = format!("https://www.{suffix}/v1/api/openplatform/coding_plan/remains");
            let body =
                request_with_policy(&url, None, Some(&cookie), None, RequestPolicy::MiniMax)?;
            match minimax_envelope_code(&body) {
                Some(429 | 2045) => return Err(Failure::MiniMaxThrottle(None)),
                Some(401 | 403 | 1004) => return Err(Failure::Auth),
                _ => {}
            }
            parse::reading(id, &body).map(|mut snapshot| {
                snapshot.fidelity = crate::usage::Fidelity::Derived;
                snapshot
            })
        }
        "ollama-cloud" => {
            let token = env(&["OLLAMA_API_KEY"])
                .or_else(|| crate::secrets::read("ollama-cloud").ok())
                .ok_or(Failure::Absent)?;
            parse::reading(
                id,
                &request_for(
                    RequestPolicy::OllamaCloud,
                    "https://ollama.com/api/usage",
                    Some(&token),
                    None,
                )?,
            )
        }
        _ => Err(Failure::Absent),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn devin_desktop_identity_precedes_cli_and_blank_cli_key_is_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let desktop = dir.path().join("state.vscdb");
        let cli = dir.path().join("credentials.toml");
        std::fs::write(&cli, "windsurf_api_key = \"  cli-fixture  \"\n").unwrap();
        let cli_auth = devin_auth_at(&desktop, &cli).unwrap();
        assert_eq!(cli_auth.api_key, "cli-fixture");
        assert_eq!(cli_auth.email, None);
        assert_eq!(cli_auth.source, "Devin CLI");
        {
            let db = rusqlite::Connection::open(&desktop).unwrap();
            db.execute_batch("CREATE TABLE ItemTable(key TEXT,value TEXT); INSERT INTO ItemTable VALUES('windsurfAuthStatus','{\"apiKey\":\"desktop-fixture\",\"email\":\"devin@example.test\"}');").unwrap();
        }
        let auth = devin_auth_at(&desktop, &cli).unwrap();
        assert_eq!(auth.api_key, "desktop-fixture");
        assert_eq!(auth.email.as_deref(), Some("devin@example.test"));
        assert_eq!(auth.source, "Devin Desktop");
        std::fs::write(&cli, "windsurf_api_key = \"  \"\n").unwrap();
        std::fs::remove_file(&desktop).unwrap();
        assert!(devin_auth_at(&desktop, &cli).is_none());
    }

    #[test]
    fn devin_request_keeps_access_denied_and_minute_floor() {
        let (url, server) = serve_once(403, "");
        assert!(matches!(
            request_for(RequestPolicy::Standard, &url, None, None),
            Err(Failure::Denied)
        ));
        let headers = server.join().unwrap().to_ascii_lowercase();
        assert!(headers.contains("connect-protocol-version: 1\r\n"));
        let (url, server) = serve_once(429, "Retry-After: 5\r\n");
        assert!(matches!(
            request_for(RequestPolicy::Standard, &url, None, None),
            Err(Failure::Throttle(5))
        ));
        server.join().unwrap();
        // The shared publisher enforces Swift's 60-second minimum.
        assert_eq!(
            super::super::failure(UsageSnapshot::default(), Failure::Throttle(5), 1_000)
                .backoff_until,
            61_000
        );
    }

    fn serve_once(status: u16, extra: &str) -> (String, std::thread::JoinHandle<String>) {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/fixture", listener.local_addr().unwrap());
        let extra = extra.to_owned();
        let task = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut header = Vec::new();
            let mut byte = [0u8; 1];
            while header.len() < 8192 && !header.ends_with(b"\r\n\r\n") {
                stream.read_exact(&mut byte).unwrap();
                header.push(byte[0]);
            }
            assert!(header.ends_with(b"\r\n\r\n"));
            let reply = format!("HTTP/1.1 {status} Fixture\r\nContent-Length: 2\r\nConnection: close\r\n{extra}\r\n{{}}");
            stream.write_all(reply.as_bytes()).unwrap();
            String::from_utf8(header).unwrap()
        });
        (url, task)
    }

    #[test]
    fn minimax_cookie_only_accepts_an_explicit_cookie_value() {
        assert_eq!(
            normalized_cookie("Cookie: a=b; c=d"),
            Some("a=b; c=d".into())
        );
        assert_eq!(
            normalized_cookie(
                "curl 'https://www.minimax.io' -H 'Accept: */*' -H 'Cookie: a=b' --compressed"
            ),
            Some("a=b".into())
        );
        assert_eq!(
            normalized_cookie("curl -b 'a=b' https://www.minimax.io"),
            Some("a=b".into())
        );
        assert_eq!(
            normalized_cookie("curl -b '/Users/me/Chrome/Cookies' https://www.minimax.io"),
            None
        );
        assert_eq!(
            normalized_cookie("curl -H 'Accept: */*' https://www.minimax.io"),
            None
        );
        assert_eq!(normalized_cookie("Cookie: \r\nAuthorization: x"), None);
    }

    #[test]
    fn pay_as_you_go_key_does_not_shadow_minimax_cookie_or_web() {
        assert_eq!(
            coding_plan_token("Bearer sk-cp-plan".into()).as_deref(),
            Some("sk-cp-plan")
        );
        assert!(coding_plan_token("sk-api-metered".into()).is_none());
        assert_eq!(
            minimax_envelope_code(
                &serde_json::json!({"data":{"base_resp":{"status_code":"2045"}}})
            ),
            Some(2045)
        );
    }

    #[test]
    fn copilot_uses_env_then_github_hosts_then_bounded_cli_fallback() {
        let hosts = "github.enterprise.local:\n    oauth_token: other\ngithub.com:\n    user: octocat\n    oauth_token: github-fixture\n";
        let mut called = false;
        let (token, user) = copilot_credentials(Some("env-fixture".into()), Some(hosts), || {
            called = true;
            None
        })
        .unwrap();
        assert_eq!(token, "env-fixture");
        assert_eq!(user.as_deref(), Some("octocat"));
        assert!(!called);
        let (token, _) =
            copilot_credentials(None, Some(hosts), || panic!("hosts should win")).unwrap();
        assert_eq!(token, "github-fixture");
        let (token, user) =
            copilot_credentials(None, Some("github.com:\n    user: octocat"), || {
                Some("cli-fixture".into())
            })
            .unwrap();
        assert_eq!(token, "cli-fixture");
        assert_eq!(user.as_deref(), Some("octocat"));
    }

    #[cfg(unix)]
    #[test]
    fn copilot_cli_invocation_is_bounded_and_host_specific() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("gh");
        std::fs::write(&script, "#!/bin/sh\n[ \"$1 $2 $3 $4\" = 'auth token --hostname github.com' ] || exit 3\nprintf fixture-cli-token\n").unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(gh_token_at(&script).as_deref(), Some("fixture-cli-token"));
    }

    #[test]
    fn commandcode_since_accepts_iso_seconds_and_milliseconds() {
        assert_eq!(
            commandcode_since(&serde_json::json!("2026-09-23T12:34:56Z")).as_deref(),
            Some("2026-09-23T12:34:56.000Z")
        );
        assert_eq!(
            commandcode_since(&serde_json::json!(1790166896)).as_deref(),
            Some("2026-09-23T12:34:56.000Z")
        );
        assert_eq!(
            commandcode_since(&serde_json::json!(1790166896000u64)).as_deref(),
            Some("2026-09-23T12:34:56.000Z")
        );
        assert!(commandcode_since(&serde_json::json!(0)).is_none());
    }

    #[test]
    fn retry_after_accepts_seconds_and_http_date() {
        assert_eq!(retry_after_secs(" 90 "), Some(90));
        assert!(retry_after_secs("Wed, 21 Oct 2015 07:28:00 GMT").is_some());
        assert_eq!(retry_after_secs("invalid"), None);
    }

    #[test]
    fn provider_specific_http_statuses_and_commandcode_headers_match_source() {
        for (policy, expected) in [
            (RequestPolicy::OpenCode, "unsupported"),
            (RequestPolicy::Copilot, "auth"),
            (RequestPolicy::CommandCode, "auth"),
            (RequestPolicy::OllamaCloud, "auth"),
            (RequestPolicy::Standard, "denied"),
        ] {
            let (url, server) = serve_once(403, "");
            let result = request_for(policy, &url, Some("fixture-token"), None);
            let correct = match expected {
                "unsupported" => matches!(result, Err(Failure::Unsupported(_))),
                "auth" => matches!(result, Err(Failure::Auth)),
                _ => matches!(result, Err(Failure::Denied)),
            };
            assert!(correct, "wrong 403 mapping for {expected}");
            let header = server.join().unwrap().to_ascii_lowercase();
            if policy == RequestPolicy::CommandCode {
                assert!(header.contains("user-agent: command-code-desktop\r\n"));
                assert!(header.contains("x-command-code-version: desktop\r\n"));
            }
        }
        let (url, server) = serve_once(429, "Retry-After: 120\r\n");
        assert!(matches!(
            request_for(RequestPolicy::OpenCode, &url, Some("fixture"), None),
            Err(Failure::OpenCodeThrottle(Some(120)))
        ));
        server.join().unwrap();
    }

    #[test]
    fn commandcode_without_org_does_not_add_query() {
        assert_eq!(
            commandcode_url(
                "https://api.commandcode.ai/alpha",
                "billing/credits",
                None,
                None
            )
            .unwrap(),
            "https://api.commandcode.ai/alpha/billing/credits"
        );
        assert!(commandcode_url(
            "https://api.commandcode.ai/alpha",
            "usage/summary",
            Some("org"),
            Some("2026-09-23T12:34:56.000Z")
        )
        .unwrap()
        .contains("orgId=org&since=2026-09-23T12%3A34%3A56.000Z"));
    }

    #[test]
    fn minimax_retries_china_only_after_international_key_auth_failure() {
        let mut urls = Vec::new();
        let reading = minimax_key_with("fixture", false, |url, _| {
            urls.push(url.to_owned());
            if url.contains("minimax.io") {
                Err(Failure::Auth)
            } else {
                Ok(
                    serde_json::json!({"data":{"model_remains":[{"model_name":"general","current_interval_remaining_percent":75}]}}),
                )
            }
        });
        assert!(!urls.is_empty());
        assert!(urls.first().unwrap().contains("minimax.io"));
        assert!(urls.iter().any(|url| url.contains("minimaxi.com")));
        assert!(reading.is_ok());

        urls.clear();
        let _ = minimax_key_with("fixture", false, |url, _| {
            urls.push(url.to_owned());
            Err(Failure::MiniMaxThrottle(Some(120)))
        });
        assert_eq!(urls.len(), 1);
        assert!(!urls[0].contains("minimaxi.com"));
    }
}
