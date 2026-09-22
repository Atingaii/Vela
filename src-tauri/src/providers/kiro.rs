use super::{parse, Failure};
use crate::usage::LimitWindow;
use chrono::{Datelike, Local, TimeZone};
use regex::Regex;
use std::{path::PathBuf, time::Duration};
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
pub(super) fn parse_cli(input: &str) -> Result<Vec<LimitWindow>, Failure> {
    let text = crate::agy_cli::sanitize_terminal_output(input);
    let lower = text.to_lowercase();
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
    let mut out = Vec::new();
    let pair = r"\((\d+\.?\d*)\s+of\s+(\d+)\s+covered";
    let used = number(&text, r"█+\s*(\d+)%", 1)
        .map(|n| n / 100.)
        .or_else(|| Some(number(&text, pair, 1)? / number(&text, pair, 2).filter(|n| *n > 0.)?));
    if let Some(used) = used {
        let reset =
            capture(&text, r"resets on (\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2})", 1).and_then(|stamp| {
                let now = Local::now();
                let date = if stamp.contains('-') {
                    chrono::NaiveDate::parse_from_str(&stamp, "%Y-%m-%d").ok()?
                } else {
                    let (month, day) = stamp.split_once('/')?;
                    let month = month.parse().ok()?;
                    let day = day.parse().ok()?;
                    let d = chrono::NaiveDate::from_ymd_opt(now.year(), month, day)?;
                    if d < now.date_naive() {
                        chrono::NaiveDate::from_ymd_opt(now.year() + 1, month, day)?
                    } else {
                        d
                    }
                };
                Local
                    .from_local_datetime(&date.and_hms_opt(0, 0, 0)?)
                    .earliest()
                    .map(|d| d.timestamp_millis().max(0) as u64)
            });
        out.push(LimitWindow {
            id: "credits".into(),
            label: "Credits".into(),
            used,
            resets_at: reset,
            ..Default::default()
        });
    }
    let bonus = r"Bonus credits:\s*(\d+\.?\d*)/(\d+)";
    if let (Some(used), Some(total)) = (
        number(&text, bonus, 1),
        number(&text, bonus, 2).filter(|n| *n > 0.),
    ) {
        let reset = number(&text, r"expires in (\d+) days?", 1)
            .map(|n| crate::now_ms().saturating_add((n * 86400000.) as u64));
        out.push(LimitWindow {
            id: "bonus".into(),
            label: "Bonus credits".into(),
            used: used / total,
            resets_at: reset,
            ..Default::default()
        });
    }
    if out.is_empty() {
        Err(Failure::Invalid)
    } else {
        Ok(out)
    }
}
fn executable() -> Option<PathBuf> {
    let mut dirs = Vec::new();
    if let Some(home) = dirs::home_dir() {
        dirs.push(home.join(".local/bin"));
        dirs.push(home.join(".kiro/bin"));
    }
    dirs.push("/opt/homebrew/bin".into());
    dirs.push("/usr/local/bin".into());
    if let Some(path) = std::env::var_os("PATH") {
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
        .find(|p| p.is_file())
}
pub(super) fn read() -> Result<Vec<LimitWindow>, Failure> {
    let exe = executable().ok_or(Failure::Absent)?;
    let output = crate::agy_cli::run_cmd_conpty(
        &exe,
        &["chat", "--no-interactive", "/usage"],
        None,
        Duration::from_secs(20),
    )
    .map_err(|_| Failure::Network)?;
    let mut windows = parse_cli(&output)?;
    // API enrichment is best effort; it cannot erase the independent CLI bonus pool.
    if let Ok(v) = limits() {
        apply_limits(&mut windows, &v);
    }
    Ok(windows)
}
fn limits() -> Result<serde_json::Value, Failure> {
    let dir = std::env::var_os("KIRO_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| dirs::data_local_dir().unwrap_or_default().join("kiro-cli"));
    let db = rusqlite::Connection::open_with_flags(
        dir.join("data.sqlite3"),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .map_err(|_| Failure::Absent)?;
    let _ = db.busy_timeout(Duration::from_millis(100));
    let token: String = db
        .query_row(
            "SELECT value FROM auth_kv WHERE key='kirocli:odic:token' LIMIT 1",
            [],
            |r| r.get(0),
        )
        .map_err(|_| Failure::Absent)?;
    let profile: String = db
        .query_row(
            "SELECT value FROM state WHERE key='api.codewhisperer.profile' LIMIT 1",
            [],
            |r| r.get(0),
        )
        .map_err(|_| Failure::Absent)?;
    let token: serde_json::Value = serde_json::from_str(&token).map_err(|_| Failure::Invalid)?;
    let profile: serde_json::Value =
        serde_json::from_str(&profile).map_err(|_| Failure::Invalid)?;
    let token = token["access_token"]
        .as_str()
        .or_else(|| token["accessToken"].as_str())
        .ok_or(Failure::Auth)?;
    let arn = profile["arn"].as_str().ok_or(Failure::Invalid)?;
    let region = capture(
        arn,
        r"^arn:aws:codewhisperer:([a-z0-9-]+):[0-9]+:profile/[^\s]+$",
        1,
    )
    .ok_or(Failure::Invalid)?;
    let host = match region.as_str() {
        "us-east-1" => "https://codewhisperer.us-east-1.amazonaws.com/",
        "eu-central-1" => "https://q.eu-central-1.amazonaws.com/",
        _ => return Err(Failure::Invalid),
    };
    let response = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(10))
        .redirects(0)
        .build()
        .post(host)
        .set("Content-Type", "application/x-amz-json-1.0")
        .set("X-Amz-Target", "AmazonCodeWhispererService.GetUsageLimits")
        .set("Authorization", &format!("Bearer {token}"))
        .send_json(serde_json::json!({"profileArn":arn}))
        .map_err(|_| Failure::Network)?;
    use std::io::Read;
    let mut body = Vec::new();
    response
        .into_reader()
        .take(2 * 1024 * 1024 + 1)
        .read_to_end(&mut body)
        .map_err(|_| Failure::Network)?;
    if body.len() > 2 * 1024 * 1024 {
        return Err(Failure::Invalid);
    }
    serde_json::from_slice(&body).map_err(|_| Failure::Invalid)
}
fn apply_limits(windows: &mut Vec<LimitWindow>, v: &serde_json::Value) {
    let Some(list) = v["usageBreakdownList"].as_array() else {
        return;
    };
    let rows: Vec<_> = list
        .iter()
        .filter(|v| v["resourceType"] == "CREDIT")
        .collect();
    if rows.len() != 1 {
        return;
    }
    let row = rows[0];
    let Some(limit) = parse::number(&row["usageLimitWithPrecision"])
        .or_else(|| parse::number(&row["usageLimit"]))
        .filter(|n| *n > 0.)
    else {
        return;
    };
    let Some(total) = parse::number(&row["currentUsageWithPrecision"])
        .or_else(|| parse::number(&row["currentUsage"]))
        .filter(|n| *n >= 0.)
    else {
        return;
    };
    let overage = parse::number(&row["currentOveragesWithPrecision"])
        .or_else(|| parse::number(&row["currentOverages"]))
        .unwrap_or(0.);
    if overage < 0. || total < overage {
        return;
    }
    let reset = parse::date(&row["nextDateReset"]).or_else(|| parse::date(&v["nextDateReset"]));
    if !windows.iter().any(|w| w.id == "bonus") && total - overage <= limit {
        if let Some(w) = windows.iter_mut().find(|w| w.id == "credits") {
            w.used = (total - overage) / limit;
            if reset.is_some() {
                w.resets_at = reset;
            }
        }
    }
    if v["overageConfiguration"]["overageStatus"] == "ENABLED" {
        if let Some(cap) = parse::number(&row["overageCap"]).filter(|n| *n > 0.) {
            windows.push(LimitWindow {
                id: "overage".into(),
                label: "Overage credits".into(),
                used: overage / cap,
                resets_at: reset,
                ..Default::default()
            });
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn percent_wins_bonus_is_independent_and_plan_is_not_a_zero() {
        let w = parse_cli("\x1b[32m██ 25%\x1b[0m (80 of 100 covered in plan)\nBonus credits: 5/20")
            .unwrap();
        assert_eq!(w[0].used, 0.25);
        assert_eq!(w[1].used, 0.25);
        assert!(parse_cli("Plan: KIRO PRO").is_err());
        assert!(matches!(
            parse_cli("Run kiro-cli login"),
            Err(Failure::Auth)
        ));
        let mut w = w;
        apply_limits(
            &mut w,
            &serde_json::json!({"usageBreakdownList":[{"resourceType":"CREDIT","usageLimit":100,"currentUsage":90}]}),
        );
        assert_eq!(w[0].used, 0.25);
    }
}
