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
fn request(url: &str, token: Option<&str>, body: Option<Value>) -> Result<Value, Failure> {
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(15))
        .redirects(0)
        .build();
    let mut req = agent
        .request(if body.is_some() { "POST" } else { "GET" }, url)
        .set("Accept", "application/json")
        .set("User-Agent", "Velo/0.1")
        .set("X-GitHub-Api-Version", "2022-11-28")
        .set("Connect-Protocol-Version", "1");
    if let Some(token) = token {
        req = req.set("Authorization", &format!("Bearer {token}"));
    }
    let response = match if let Some(body) = body {
        req.send_json(body)
    } else {
        req.call()
    } {
        Ok(r) => r,
        Err(ureq::Error::Status(401, _)) => return Err(Failure::Auth),
        Err(ureq::Error::Status(403, _)) => return Err(Failure::Denied),
        Err(ureq::Error::Status(429, r)) => {
            let delay = r
                .header("Retry-After")
                .and_then(|s| s.parse().ok())
                .unwrap_or(60);
            return Err(Failure::Throttle(delay));
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
fn copilot_token() -> Option<String> {
    if let Some(v) = env(&["GH_TOKEN", "GITHUB_TOKEN"]) {
        return Some(v);
    }
    let root = std::env::var_os("GH_CONFIG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            if cfg!(windows) {
                dirs::config_dir().unwrap_or_default().join("GitHub CLI")
            } else {
                home().join(".config/gh")
            }
        });
    // hosts.yml has a small documented host -> oauth_token mapping. Never borrow another host's token.
    let text = read(root.join("hosts.yml"))?;
    let mut github = false;
    for line in text.lines() {
        if !line.starts_with(char::is_whitespace) {
            github = line.trim() == "github.com:";
        }
        if github {
            if let Some(t) = line.trim().strip_prefix("oauth_token:") {
                let t = t.trim().trim_matches(['\'', '"']);
                if !t.is_empty() {
                    return Some(t.into());
                }
            }
        }
    }
    None
}
fn devin_token() -> Option<String> {
    let root = if cfg!(target_os = "macos") {
        home().join("Library/Application Support")
    } else {
        dirs::config_dir().unwrap_or_default()
    };
    let path = root.join("Devin/User/globalStorage/state.vscdb");
    if let Ok(db) = rusqlite::Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) {
        let _ = db.busy_timeout(Duration::from_millis(100));
        if let Ok(text) = db.query_row(
            "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1",
            [],
            |r| r.get::<_, String>(0),
        ) {
            if let Ok(v) = serde_json::from_str::<Value>(&text) {
                if let Some(k) = key(&v, &["apiKey"]) {
                    return Some(k);
                }
            }
        }
    }
    let text = read(home().join(".local/share/devin/credentials.toml"))?;
    let doc = text.parse::<toml_edit::DocumentMut>().ok()?;
    doc.get("windsurf_api_key")?.as_str().map(str::to_owned)
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
                &request("https://opencode.ai/zen/go/v1/usage", Some(&token), None)?,
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
                &request(
                    "https://api.github.com/copilot_internal/user",
                    Some(&token),
                    None,
                )?,
            )
        }
        "devin" => {
            let token = devin_token().ok_or(Failure::Absent)?;
            parse::reading(id, &request("https://server.self-serve.windsurf.com/exa.seat_management_pb.SeatManagementService/GetUserStatus",None,Some(json!({"metadata":{"apiKey":token,"ideName":"windsurf","ideVersion":"1.108.2","extensionName":"windsurf","extensionVersion":"1.108.2","locale":"en"}})))?)
        }
        "commandcode" => {
            let token = env(&["COMMAND_CODE_API_KEY"])
                .or_else(|| key(&file(home().join(".commandcode/auth.json"))?, &["apiKey"]))
                .ok_or(Failure::Absent)?;
            let base = "https://api.commandcode.ai/alpha";
            let who = request(&format!("{base}/whoami"), Some(&token), None)?;
            let org = who["org"]["id"].as_str().ok_or(Failure::Invalid)?;
            let build = |path: &str, since: Option<&str>| -> Result<String, Failure> {
                let mut url =
                    tauri::Url::parse(&format!("{base}/{path}")).map_err(|_| Failure::Invalid)?;
                url.query_pairs_mut().append_pair("orgId", org);
                if let Some(since) = since {
                    url.query_pairs_mut().append_pair("since", since);
                }
                Ok(url.into())
            };
            let credits = request(&build("billing/credits", None)?, Some(&token), None)?;
            let subscription = request(&build("billing/subscriptions", None)?, Some(&token), None)?;
            let sub = subscription.get("data").unwrap_or(&subscription);
            let summary = request(
                &build("usage/summary", sub["currentPeriodStart"].as_str())?,
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
            .ok_or(Failure::Absent)?;
            let suffix = if china { "minimaxi.com" } else { "minimax.io" };
            for (host, path) in [
                ("api", "/v1/token_plan/remains"),
                ("www", "/v1/token_plan/remains"),
                ("www", "/v1/api/openplatform/coding_plan/remains"),
            ] {
                match request(
                    &format!("https://{host}.{suffix}{path}"),
                    Some(&token),
                    None,
                )
                .and_then(|v| parse::reading(id, &v))
                {
                    Err(Failure::Invalid) => continue,
                    result => return result,
                }
            }
            Err(Failure::Invalid)
        }
        "ollama-cloud" => {
            let token = env(&["OLLAMA_API_KEY"])
                .or_else(|| crate::secrets::read("ollama-cloud").ok())
                .ok_or(Failure::Absent)?;
            parse::reading(
                id,
                &request("https://ollama.com/api/usage", Some(&token), None)?,
            )
        }
        _ => Err(Failure::Absent),
    }
}
