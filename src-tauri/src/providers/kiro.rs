use super::{parse, Failure};
use crate::usage::{LimitWindow, UsageSnapshot};
use chrono::{Datelike, Local, TimeZone};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::{
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::Duration,
};

#[derive(Debug, Clone)]
pub(super) struct Reading {
    plan: Option<String>,
    windows: Vec<LimitWindow>,
    has_usage_metrics: bool,
    bonus_used: Option<f64>,
    bonus_total: Option<f64>,
    overage_enabled: Option<bool>,
    overage_used_cli: Option<f64>,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
struct EnrichmentState {
    retry_after_ms: u64,
    attempts: u32,
}
static ENRICHMENT: OnceLock<Mutex<EnrichmentState>> = OnceLock::new();
fn enrichment() -> &'static Mutex<EnrichmentState> {
    ENRICHMENT.get_or_init(|| {
        let saved = std::fs::read(enrichment_path())
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        Mutex::new(saved)
    })
}
fn enrichment_path() -> PathBuf {
    crate::config::config_path().with_file_name("kiro-enrichment.json")
}
fn save_enrichment(state: EnrichmentState) {
    if let Ok(bytes) = serde_json::to_vec(&state) {
        let _ = super::persist(&enrichment_path(), &bytes);
    }
}
pub(super) fn forget() {
    *enrichment().lock().unwrap() = EnrichmentState::default();
    *last_plan().lock().unwrap() = None;
    let _ = std::fs::remove_file(enrichment_path());
}

static LAST_PLAN: OnceLock<Mutex<Option<String>>> = OnceLock::new();

fn last_plan() -> &'static Mutex<Option<String>> {
    LAST_PLAN.get_or_init(|| Mutex::new(None))
}

pub(super) fn account(plan: Option<String>) -> Option<super::AccountSummary> {
    (executable().is_some() || load_access_token(&database_path()).is_some()).then(|| {
        super::AccountSummary {
            label: None,
            plan: plan.or_else(|| last_plan().lock().unwrap().clone()),
            source: "Kiro CLI".into(),
            manage_url: Some("https://app.kiro.dev/account/usage".into()),
        }
    })
}
fn capture(text: &str, pattern: &str, index: usize) -> Option<String> {
    Regex::new(pattern)
        .ok()?
        .captures(text)?
        .get(index)
        .map(|m| m.as_str().into())
}
fn number(text: &str, pattern: &str, index: usize) -> Option<f64> {
    capture(text, pattern, index)?.parse().ok()
}
fn title_plan(raw: &str) -> String {
    let compact = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    if !compact.to_ascii_lowercase().contains("kiro") {
        return compact;
    }
    compact
        .split_whitespace()
        .map(|word| {
            if word.eq_ignore_ascii_case("kiro") {
                "Kiro".to_string()
            } else {
                let mut chars = word.chars();
                match chars.next() {
                    Some(first) => {
                        format!("{}{}", first.to_uppercase(), chars.as_str().to_lowercase())
                    }
                    None => String::new(),
                }
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn plan_name(text: &str) -> Option<String> {
    [
        r"Plan:[ \t]*([^|\r\n]+?)[ \t]*\|[ \t]*[0-9]+[ \t]+usage breakdowns?",
        r"Estimated Usage[ \t]*\|[^\n|]*\|[ \t]*([A-Z][A-Z0-9+ ]+)",
        r"\|[ \t]*(KIRO(?:[ \t]+[A-Za-z0-9+]+)+)",
        r"Plan:[ \t]*([^|\r\n]+)",
    ]
    .into_iter()
    .find_map(|pattern| capture(text, pattern, 1).filter(|value| !value.trim().is_empty()))
    .map(|name| title_plan(&name))
}

fn reset_date(text: &str, now: chrono::DateTime<Local>) -> Option<u64> {
    let stamp = capture(text, r"resets on (\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2})", 1)?;
    let date = if stamp.contains('-') {
        chrono::NaiveDate::parse_from_str(&stamp, "%Y-%m-%d").ok()?
    } else {
        let (month, day) = stamp.split_once('/')?;
        let month = month.parse().ok()?;
        let day = day.parse().ok()?;
        let mut date = chrono::NaiveDate::from_ymd_opt(now.year(), month, day)?;
        if date < now.date_naive() {
            date = chrono::NaiveDate::from_ymd_opt(now.year() + 1, month, day)?;
        }
        date
    };
    Local
        .from_local_datetime(&date.and_hms_opt(0, 0, 0)?)
        .earliest()
        .map(|date| date.timestamp_millis().max(0) as u64)
}

fn parse_cli_at(input: &str, now: chrono::DateTime<Local>) -> Result<Reading, Failure> {
    let text = crate::agy_cli::sanitize_terminal_output(input);
    let lower = text.to_ascii_lowercase();
    if [
        "not logged in",
        "login required",
        "failed to initialize auth portal",
        "kiro-cli login",
        "oauth error",
    ]
    .iter()
    .any(|s| lower.contains(s))
    {
        return Err(Failure::Auth);
    }
    let plan = plan_name(&text);
    let mut windows = Vec::new();
    let pair = r"\((\d+\.?\d*)\s+of\s+(\d+)\s+covered";
    let used = number(&text, r"█+\s*(\d+)%", 1)
        .map(|n| n / 100.)
        .or_else(|| Some(number(&text, pair, 1)? / number(&text, pair, 2).filter(|n| *n > 0.)?));
    let reset = reset_date(&text, now);
    if let Some(used) = used {
        windows.push(LimitWindow {
            id: "credits".into(),
            label: "Credits".into(),
            used,
            has_fraction: Some(true),
            resets_at: reset,
            duration: (reset.is_some() || lower.contains("monthly")).then_some(30. * 86400.),
            ..Default::default()
        });
    }
    let bonus = r"Bonus credits:\s*(\d+\.?\d*)/(\d+)";
    let bonus_used = number(&text, bonus, 1);
    let bonus_total = number(&text, bonus, 2);
    if let (Some(used), Some(total)) = (bonus_used, bonus_total.filter(|n| *n > 0.)) {
        let reset = number(&text, r"expires in (\d+) days?", 1)
            .and_then(|days| now.checked_add_days(chrono::Days::new(days as u64)))
            .map(|date| date.timestamp_millis().max(0) as u64);
        windows.push(LimitWindow {
            id: "bonus".into(),
            group: Some("Bonus".into()),
            label: "Credits".into(),
            used: used / total,
            has_fraction: Some(true),
            remaining: (total - used >= 0.).then_some((total - used).round() as i64),
            resets_at: reset,
            ..Default::default()
        });
    }
    if plan.is_none() && windows.is_empty() {
        return Err(Failure::Unsupported("Kiro CLI reported no usage"));
    }
    let overage_enabled = capture(&text, r"(?i)Overages:\s*([^\n]+)", 1).and_then(|status| {
        let lower = status.to_ascii_lowercase();
        if lower.starts_with("enabled") {
            Some(true)
        } else if lower.starts_with("disabled") {
            Some(false)
        } else {
            None
        }
    });
    let overage_used_cli = number(&text, r"(?i)Credits used:\s*(\d+\.?\d*)", 1);
    Ok(Reading {
        plan,
        has_usage_metrics: used.is_some(),
        windows,
        bonus_used,
        bonus_total,
        overage_enabled,
        overage_used_cli,
    })
}

pub(super) fn parse_cli(input: &str) -> Result<Reading, Failure> {
    parse_cli_at(input, Local::now())
}
fn executable_in(
    home: &Path,
    path: Option<&std::ffi::OsStr>,
    override_path: Option<&std::ffi::OsStr>,
) -> Option<PathBuf> {
    fn runnable(path: &Path) -> bool {
        if !path.is_absolute() || !path.is_file() {
            return false;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            return path
                .metadata()
                .is_ok_and(|m| m.permissions().mode() & 0o111 != 0);
        }
        #[cfg(not(unix))]
        {
            true
        }
    }
    if let Some(path) = override_path
        .and_then(|p| p.to_str())
        .map(str::trim)
        .filter(|p| !p.is_empty())
    {
        let expanded = if let Some(rest) = path.strip_prefix("~/") {
            home.join(rest)
        } else {
            PathBuf::from(path)
        };
        // An explicit invalid override must not silently choose another binary.
        return runnable(&expanded).then_some(expanded);
    }
    let mut dirs = Vec::new();
    dirs.push(home.join(".local/bin"));
    dirs.push("/opt/homebrew/bin".into());
    dirs.push("/usr/local/bin".into());
    if let Some(path) = path {
        dirs.extend(std::env::split_paths(&path).filter(|p| p.is_absolute()));
    }
    dirs.into_iter()
        .map(|p| {
            p.join(if cfg!(windows) {
                "kiro-cli.exe"
            } else {
                "kiro-cli"
            })
        })
        .find(|p| runnable(p))
}
fn executable() -> Option<PathBuf> {
    let home = dirs::home_dir()?;
    executable_in(
        &home,
        std::env::var_os("PATH").as_deref(),
        std::env::var_os("KIRO_CLI_PATH").as_deref(),
    )
}
fn run_cli(exe: &Path) -> Result<String, Failure> {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let mut command = std::process::Command::new(exe);
        command
            .args(["chat", "--no-interactive", "/usage"])
            .env("TERM", "dumb")
            .env("KIRO_CHAT_UI", "classic")
            .current_dir(std::env::temp_dir());
        // The CLI can print the entire card to stderr; merge both bounded
        // pipes before the shared process-group runner starts reading.
        unsafe {
            command.pre_exec(|| {
                if libc::dup2(1, 2) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let bytes =
            crate::usage::process_output::output(command, 256 * 1024, Duration::from_secs(20))
                .ok_or(Failure::Network)?;
        return String::from_utf8(bytes).map_err(|_| Failure::Invalid);
    }
    #[cfg(windows)]
    {
        crate::agy_cli::run_cmd_conpty(
            exe,
            &["chat", "--no-interactive", "/usage"],
            Some(&std::env::temp_dir()),
            Duration::from_secs(20),
        )
        .map_err(|_| Failure::Network)
    }
}
pub(super) fn read(app: &tauri::AppHandle, epoch: u64) -> Result<UsageSnapshot, Failure> {
    let exe = executable().ok_or(Failure::Unsupported("Kiro CLI is not installed"))?;
    let output = run_cli(&exe)?;
    let mut reading = parse_cli(&output)?;
    // API enrichment is best effort; it cannot erase the independent CLI bonus pool.
    if let Some(limits) = limits(app, epoch) {
        apply_limits(&mut reading, &limits);
    }
    let plan = reading.plan.clone();
    super::with_current(app, "kiro", epoch, || {
        *last_plan().lock().unwrap() = plan;
    });
    Ok(UsageSnapshot {
        plan: reading.plan,
        windows: reading.windows,
        ..Default::default()
    })
}
fn database_path() -> PathBuf {
    std::env::var_os("KIRO_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| dirs::data_local_dir().unwrap_or_default().join("kiro-cli"))
        .join("data.sqlite3")
}
fn load_access_token(path: &Path) -> Option<String> {
    let db =
        rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .ok()?;
    let raw: String = db
        .query_row(
            "SELECT value FROM auth_kv WHERE key='kirocli:odic:token' LIMIT 1",
            [],
            |r| r.get(0),
        )
        .ok()?;
    let value: serde_json::Value = serde_json::from_str(&raw).ok()?;
    value["access_token"]
        .as_str()
        .or_else(|| value["accessToken"].as_str())
        .map(str::to_owned)
}
#[derive(Debug, Clone, PartialEq)]
struct CreditLimits {
    plan_used: f64,
    plan_limit: f64,
    overage_used: f64,
    overage_cap: Option<f64>,
    reset_at: Option<u64>,
    has_unseparated_bonus: bool,
}
fn valid_number(value: Option<f64>) -> Result<f64, Failure> {
    value
        .filter(|v| v.is_finite() && *v >= 0.)
        .ok_or(Failure::Invalid)
}
fn first_number(row: &serde_json::Value, precise: &str, fallback: &str) -> Option<f64> {
    parse::number(&row[precise]).or_else(|| parse::number(&row[fallback]))
}
fn parse_limits(value: &serde_json::Value) -> Result<CreditLimits, Failure> {
    let list = value["usageBreakdownList"]
        .as_array()
        .ok_or(Failure::Invalid)?;
    let credits: Vec<_> = list
        .iter()
        .filter(|v| v["resourceType"] == "CREDIT")
        .collect();
    if credits.len() != 1 {
        return Err(Failure::Invalid);
    }
    let row = credits[0];
    let plan_limit = valid_number(first_number(row, "usageLimitWithPrecision", "usageLimit"))?;
    let total = valid_number(first_number(
        row,
        "currentUsageWithPrecision",
        "currentUsage",
    ))?;
    let overage_used = valid_number(Some(
        first_number(row, "currentOveragesWithPrecision", "currentOverages").unwrap_or(0.),
    ))?;
    if total < overage_used {
        return Err(Failure::Invalid);
    }
    let plan_used = total - overage_used;
    let has_unseparated_bonus = row["bonuses"].as_array().is_some_and(|v| !v.is_empty());
    if !has_unseparated_bonus && plan_used > plan_limit {
        return Err(Failure::Invalid);
    }
    let enabled = value["overageConfiguration"]["overageStatus"] == "ENABLED";
    let overage_cap = if enabled {
        first_number(row, "overageCapWithPrecision", "overageCap")
            .map(|n| valid_number(Some(n)))
            .transpose()?
    } else {
        None
    };
    let reset_seconds =
        parse::number(&row["nextDateReset"]).or_else(|| parse::number(&value["nextDateReset"]));
    let reset_at = reset_seconds
        .filter(|n| (1_000_000_000. ..=4_102_444_800.).contains(n))
        .map(|n| (n * 1000.) as u64);
    Ok(CreditLimits {
        plan_used,
        plan_limit,
        overage_used,
        overage_cap,
        reset_at,
        has_unseparated_bonus,
    })
}
fn apply_limits(reading: &mut Reading, limits: &CreditLimits) {
    if limits.plan_limit > 0. && !limits.has_unseparated_bonus {
        let index = reading.windows.iter().position(|w| w.id == "credits");
        let existing = index.and_then(|i| reading.windows.get(i));
        let reset = limits
            .reset_at
            .or_else(|| existing.and_then(|w| w.resets_at));
        let credits = LimitWindow {
            id: "credits".into(),
            label: existing
                .map(|w| w.label.clone())
                .unwrap_or_else(|| "Credits".into()),
            used: limits.plan_used / limits.plan_limit,
            has_fraction: Some(true),
            used_count: Some(limits.plan_used.round() as i64),
            resets_at: reset,
            duration: existing
                .and_then(|w| w.duration)
                .or_else(|| reset.map(|_| 30. * 86400.)),
            ..Default::default()
        };
        if let Some(i) = index {
            reading.windows[i] = credits;
        } else {
            reading.windows.insert(0, credits);
        }
        reading.has_usage_metrics = true;
    }
    if let Some(cap) = limits.overage_cap.filter(|cap| *cap > 0.) {
        let overage = LimitWindow {
            id: "overage".into(),
            label: "Overage".into(),
            used: limits.overage_used / cap,
            has_fraction: Some(true),
            used_count: Some(limits.overage_used.round() as i64),
            resets_at: limits.reset_at,
            ..Default::default()
        };
        if let Some(i) = reading.windows.iter().position(|w| w.id == "overage") {
            reading.windows[i] = overage;
        } else {
            reading.windows.push(overage);
        }
    }
}
fn profile_arn(path: &Path) -> Option<String> {
    let db =
        rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .ok()?;
    let raw: String = db
        .query_row(
            "SELECT value FROM state WHERE key='api.codewhisperer.profile' LIMIT 1",
            [],
            |r| r.get(0),
        )
        .ok()?;
    let value: serde_json::Value = serde_json::from_str(&raw).ok()?;
    value["arn"]
        .as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}
fn endpoint(arn: &str) -> Option<&'static str> {
    let parts: Vec<_> = arn.splitn(6, ':').collect();
    if parts.len() != 6
        || parts[0] != "arn"
        || parts[1] != "aws"
        || parts[2] != "codewhisperer"
        || parts[4].is_empty()
        || !parts[5].starts_with("profile/")
        || parts[5] == "profile/"
        || arn.chars().any(char::is_whitespace)
    {
        return None;
    }
    match parts[3] {
        "us-east-1" => Some("https://codewhisperer.us-east-1.amazonaws.com/"),
        "eu-central-1" => Some("https://q.eu-central-1.amazonaws.com/"),
        _ => None,
    }
}
fn retry_after_ms(response: &ureq::Response, now_ms: u64) -> Option<u64> {
    let value = response.header("Retry-After")?.trim();
    if let Ok(seconds) = value.parse::<f64>() {
        return Some((seconds.max(0.) * 1000.) as u64);
    }
    let date = chrono::DateTime::parse_from_rfc2822(value).ok()?;
    Some((date.timestamp_millis().max(0) as u64).saturating_sub(now_ms))
}
fn backoff_ms(attempt: u32, hint_ms: Option<u64>) -> u64 {
    60_000u64
        .saturating_mul(1u64 << attempt.min(4))
        .max(hint_ms.unwrap_or(0))
        .min(900_000)
}
enum LimitReply {
    Data(serde_json::Value),
    RateLimited(Option<u64>),
    Other,
}
fn request_limits(url: &str, token: &str, arn: &str, now_ms: u64) -> LimitReply {
    let request = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(10))
        .redirects(0)
        .build()
        .post(url)
        .set("Content-Type", "application/x-amz-json-1.0")
        .set("X-Amz-Target", "AmazonCodeWhispererService.GetUsageLimits")
        .set("Authorization", &format!("Bearer {token}"));
    let response = match request.send_json(serde_json::json!({"profileArn": arn})) {
        Ok(response) => response,
        Err(ureq::Error::Status(429, response)) => {
            return LimitReply::RateLimited(retry_after_ms(&response, now_ms))
        }
        Err(_) => return LimitReply::Other,
    };
    use std::io::Read;
    let mut bytes = Vec::new();
    if response
        .into_reader()
        .take(2 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .is_err()
        || bytes.len() > 2 * 1024 * 1024
    {
        return LimitReply::Other;
    }
    match serde_json::from_slice(&bytes) {
        Ok(value) => LimitReply::Data(value),
        Err(_) => LimitReply::Other,
    }
}
fn limits(app: &tauri::AppHandle, epoch: u64) -> Option<CreditLimits> {
    let now = crate::now_ms();
    if enrichment().lock().unwrap().retry_after_ms > now {
        return None;
    }
    let database = database_path();
    let token = load_access_token(&database)?;
    let arn = profile_arn(&database)?;
    let url = endpoint(&arn)?;
    match request_limits(url, &token, &arn, now) {
        LimitReply::Data(value) => {
            let _ = super::with_current(app, "kiro", epoch, || {
                let mut state = enrichment().lock().unwrap();
                *state = EnrichmentState::default();
                save_enrichment(*state);
            });
            parse_limits(&value).ok()
        }
        LimitReply::RateLimited(hint) => {
            let _ = super::with_current(app, "kiro", epoch, || {
                let mut state = enrichment().lock().unwrap();
                let wait = backoff_ms(state.attempts, hint);
                state.attempts = state.attempts.saturating_add(1);
                state.retry_after_ms = crate::now_ms().saturating_add(wait);
                save_enrichment(*state);
            });
            None
        }
        LimitReply::Other => None,
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn read_request(stream: &mut std::net::TcpStream) -> String {
        use std::io::Read;
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut bytes = Vec::new();
        let mut buffer = [0u8; 512];
        loop {
            let n = stream.read(&mut buffer).unwrap();
            if n == 0 {
                break;
            }
            bytes.extend_from_slice(&buffer[..n]);
            if let Some(header_end) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                let header_end = header_end + 4;
                let head = String::from_utf8_lossy(&bytes[..header_end]);
                let len = head
                    .lines()
                    .find_map(|line| {
                        line.to_ascii_lowercase()
                            .strip_prefix("content-length:")
                            .and_then(|n| n.trim().parse::<usize>().ok())
                    })
                    .unwrap_or(0);
                if bytes.len() >= header_end + len {
                    break;
                }
            }
            assert!(bytes.len() < 8192);
        }
        String::from_utf8_lossy(&bytes).into_owned()
    }
    #[test]
    fn percent_wins_bonus_is_independent_and_plan_is_not_a_zero() {
        let w = parse_cli("\x1b[32m██ 25%\x1b[0m (80 of 100 covered in plan)\nBonus credits: 5/20")
            .unwrap();
        assert_eq!(w.windows[0].used, 0.25);
        assert_eq!(w.windows[1].used, 0.25);
        assert_eq!(
            parse_cli("Plan: KIRO PRO").unwrap().plan.as_deref(),
            Some("Kiro Pro")
        );
        assert!(matches!(
            parse_cli("Run kiro-cli login"),
            Err(Failure::Auth)
        ));
        let mut w = w;
        let limits = parse_limits(&serde_json::json!({"usageBreakdownList":[{"resourceType":"CREDIT","usageLimit":100,"currentUsage":90,"bonuses":[{}]}]})).unwrap();
        apply_limits(&mut w, &limits);
        assert_eq!(w.windows[0].used, 0.25);
    }

    #[test]
    fn limits_split_plan_overage_and_preserve_cli_bonus() {
        let value = serde_json::json!({
            "nextDateReset": 1_788_220_800.0,
            "overageConfiguration": {"overageStatus":"ENABLED"},
            "usageBreakdownList":[{
                "resourceType":"CREDIT", "currentUsageWithPrecision":13603.49,
                "currentOveragesWithPrecision":3603.49, "usageLimitWithPrecision":10000,
                "overageCapWithPrecision":10000, "bonuses":[]
            }]
        });
        let limits = parse_limits(&value).unwrap();
        assert_eq!(limits.plan_used, 10000.);
        assert_eq!(limits.overage_used, 3603.49);
        let mut cli = parse_cli("| KIRO PRO |\n████ 80%\nBonus credits: 5/10").unwrap();
        apply_limits(&mut cli, &limits);
        assert_eq!(
            cli.windows
                .iter()
                .map(|w| w.id.as_str())
                .collect::<Vec<_>>(),
            vec!["credits", "bonus", "overage"]
        );
        assert_eq!(cli.windows[0].used, 1.);
        assert_eq!(cli.windows[0].used_count, Some(10000));
        assert_eq!(cli.windows[1].used, 0.5);
        assert!((cli.windows[2].used - 0.360349).abs() < 0.000001);
        assert_eq!(cli.windows[2].used_count, Some(3603));
    }

    #[test]
    fn api_bonus_flag_not_cli_wallet_decides_credit_rewrite() {
        let with_bonus = serde_json::json!({"usageBreakdownList":[{"resourceType":"CREDIT","currentUsage":130,"usageLimit":100,"bonuses":[{}]}]});
        let limits = parse_limits(&with_bonus).unwrap();
        let mut cli = parse_cli("| KIRO PRO |\n████ 80%\nBonus credits: 5/10").unwrap();
        apply_limits(&mut cli, &limits);
        assert_eq!(cli.windows[0].used, 0.8);
        let without_bonus = serde_json::json!({"usageBreakdownList":[{"resourceType":"CREDIT","currentUsage":30,"usageLimit":100,"bonuses":[]}]});
        let limits = parse_limits(&without_bonus).unwrap();
        apply_limits(&mut cli, &limits);
        assert_eq!(cli.windows[0].used, 0.3);
        assert_eq!(cli.windows[1].id, "bonus");
        assert!(parse_limits(&serde_json::json!({"usageBreakdownList":[{"resourceType":"CREDIT","currentUsage":130,"usageLimit":100,"bonuses":[]}]})).is_err());
    }

    #[test]
    fn plan_only_is_enriched_and_invalid_dates_do_not_become_resets() {
        let mut cli = parse_cli("Plan: KIRO PRO").unwrap();
        assert!(cli.windows.is_empty());
        let limits = parse_limits(&serde_json::json!({"nextDateReset":1788220800000.0,"usageBreakdownList":[{"resourceType":"CREDIT","currentUsage":25,"usageLimit":100}]})).unwrap();
        assert_eq!(limits.reset_at, None);
        apply_limits(&mut cli, &limits);
        assert_eq!(cli.windows.len(), 1);
        assert_eq!(cli.windows[0].used, 0.25);
        assert_eq!(cli.windows[0].resets_at, None);
    }

    #[test]
    fn enrichment_backoff_only_delays_api() {
        assert_eq!(backoff_ms(0, None), 60_000);
        assert_eq!(backoff_ms(1, None), 120_000);
        assert_eq!(backoff_ms(9, None), 900_000);
        assert_eq!(backoff_ms(0, Some(180_000)), 180_000);
        assert_eq!(backoff_ms(0, Some(3_600_000)), 900_000);
    }

    #[test]
    fn sqlite_credentials_are_read_only_and_never_refresh() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("data.sqlite3");
        {
            let db = rusqlite::Connection::open(&path).unwrap();
            db.execute_batch("CREATE TABLE auth_kv(key TEXT,value TEXT); CREATE TABLE state(key TEXT,value TEXT); INSERT INTO auth_kv VALUES('kirocli:odic:token','{\"access_token\":\"synthetic\",\"refresh_token\":\"never-used\",\"expires_at\":\"2020-01-01\"}'); INSERT INTO state VALUES('api.codewhisperer.profile','{\"arn\":\"arn:aws:codewhisperer:us-east-1:123:profile/test\"}');").unwrap();
        }
        let before = std::fs::read(&path).unwrap();
        assert_eq!(load_access_token(&path).as_deref(), Some("synthetic"));
        assert_eq!(
            profile_arn(&path).as_deref(),
            Some("arn:aws:codewhisperer:us-east-1:123:profile/test")
        );
        assert_eq!(std::fs::read(&path).unwrap(), before);
        assert_eq!(
            endpoint("arn:aws:codewhisperer:us-east-1:123:profile/test"),
            Some("https://codewhisperer.us-east-1.amazonaws.com/")
        );
        assert_eq!(
            endpoint("arn:aws:codewhisperer:ap-southeast-1:123:profile/test"),
            None
        );
    }

    #[test]
    fn enrichment_http_429_and_redirect_never_forward_borrowed_token() {
        use std::io::Write;
        use std::net::TcpListener;
        let destination = TcpListener::bind("127.0.0.1:0").unwrap();
        destination.set_nonblocking(true).unwrap();
        let redirect_target = format!("http://{}", destination.local_addr().unwrap());
        let server = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", server.local_addr().unwrap());
        let worker = std::thread::spawn(move || {
            let (mut stream, _) = server.accept().unwrap();
            assert!(read_request(&mut stream).contains("Bearer synthetic-token"));
            write!(stream, "HTTP/1.1 302 Found\r\nLocation: {redirect_target}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
        });
        assert!(matches!(
            request_limits(&url, "synthetic-token", "arn", 0),
            LimitReply::Other
        ));
        worker.join().unwrap();
        assert!(destination.accept().is_err());

        let server = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", server.local_addr().unwrap());
        let worker = std::thread::spawn(move || {
            let (mut stream, _) = server.accept().unwrap();
            assert!(read_request(&mut stream).contains("Bearer synthetic-token"));
            stream.write_all(b"HTTP/1.1 429 Too Many Requests\r\nRetry-After: 180\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
        });
        assert!(matches!(
            request_limits(&url, "synthetic-token", "arn", 0),
            LimitReply::RateLimited(Some(180_000))
        ));
        worker.join().unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn explicit_bad_binary_does_not_fall_back_and_stderr_card_is_read() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join(".local/bin/kiro-cli");
        std::fs::create_dir_all(bin.parent().unwrap()).unwrap();
        std::fs::write(&bin, "#!/bin/sh\nprintf 'Plan: KIRO PRO\\n' >&2\nprintf 'Estimated Usage\\n' >&2\nprintf '████ 25%%\\n' >&2\n").unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(executable_in(dir.path(), None, None), Some(bin.clone()));
        assert_eq!(
            executable_in(
                dir.path(),
                None,
                Some(std::ffi::OsStr::new("/missing/kiro-cli"))
            ),
            None
        );
        let output = run_cli(&bin).unwrap();
        assert!(output.contains("Estimated Usage"));
        assert_eq!(
            parse_cli(&output).unwrap().plan.as_deref(),
            Some("Kiro Pro")
        );
    }
}
