//! Claude Desktop's bounded HTTP cache and Claude Code's `/usage` output.
//! These sources do not borrow a different profile's identity or write CLI data.

use super::{claude_duration, label_for, parse_response, LimitWindow, Profile};
use chrono::{Datelike, Local, NaiveDate, TimeZone, Utc};
use regex::Regex;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

const MAX_CACHE_ENTRY: u64 = 512 * 1024;
const MAX_CACHE_KEY: usize = 8 * 1024;
const MAX_CACHE_BODY: usize = 256 * 1024;
const MAX_CACHE_SCAN: usize = 400;
const MAX_CLI_OUTPUT: u64 = 256 * 1024;
const CACHE_FRESH_MS: u64 = 30 * 60 * 1000;
const HEADER_BYTES: usize = 24;
const SIMPLE_MAGIC: u64 = 0xfcfb_6d1b_a772_5c30;

fn organization_in_key(key: &str) -> Option<&str> {
    if !(key.contains("claude.ai") || key.contains("anthropic.com")) {
        return None;
    }
    let suffix = key.split("/api/organizations/").nth(1)?;
    let path = suffix.split(['?', '#']).next()?;
    let (org, rest) = path.split_once('/')?;
    (!org.is_empty() && rest == "usage").then_some(org)
}

fn cache_key(bytes: &[u8]) -> Option<&str> {
    if bytes.len() < HEADER_BYTES
        || u64::from_le_bytes(bytes[0..8].try_into().ok()?) != SIMPLE_MAGIC
    {
        return None;
    }
    let len = u32::from_le_bytes(bytes[12..16].try_into().ok()?) as usize;
    if len == 0 || len > MAX_CACHE_KEY || HEADER_BYTES + len > bytes.len() {
        return None;
    }
    std::str::from_utf8(&bytes[HEADER_BYTES..HEADER_BYTES + len]).ok()
}

fn trailer_date(trailer: &[u8]) -> Option<u64> {
    for part in trailer.split(|byte| *byte == 0) {
        let Ok(text) = std::str::from_utf8(part) else {
            continue;
        };
        let Some(value) = text
            .get(..5)
            .filter(|head| head.eq_ignore_ascii_case("date:"))
        else {
            continue;
        };
        let _ = value;
        let date = chrono::DateTime::parse_from_rfc2822(text[5..].trim()).ok()?;
        return Some(date.timestamp_millis().max(0) as u64);
    }
    None
}

fn decode_entry(
    bytes: &[u8],
    organization: &str,
    modified: u64,
) -> Option<(Vec<LimitWindow>, u64)> {
    let key = cache_key(bytes)?;
    if organization_in_key(key)? != organization {
        return None;
    }
    let start = HEADER_BYTES + key.len();
    if bytes.get(start..start + 4)? != [0x28, 0xb5, 0x2f, 0xfd] {
        return None;
    }
    let frame_len = zstd::zstd_safe::find_frame_compressed_size(&bytes[start..]).ok()?;
    let end = start.checked_add(frame_len)?;
    let frame = bytes.get(start..end)?;
    let mut body = vec![0; MAX_CACHE_BODY];
    let written = zstd::bulk::decompress_to_buffer(frame, &mut body).ok()?;
    body.truncate(written);
    let json: serde_json::Value = serde_json::from_slice(&body).ok()?;
    let windows = parse_response(&json);
    if windows.is_empty() {
        return None;
    }
    Some((windows, trailer_date(&bytes[end..]).unwrap_or(modified)))
}

fn account_file(profile: &Profile) -> PathBuf {
    if profile.slug.is_some() {
        profile.dir.join(".claude.json")
    } else {
        profile
            .dir
            .parent()
            .unwrap_or(&profile.dir)
            .join(".claude.json")
    }
}

pub(super) fn account_address(profile: &Profile) -> Option<String> {
    let file = std::fs::File::open(account_file(profile)).ok()?;
    if file.metadata().ok()?.len() > MAX_CACHE_ENTRY {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(MAX_CACHE_ENTRY + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    let value: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    value
        .pointer("/oauthAccount/emailAddress")
        .and_then(|value| value.as_str())
        .filter(|address| !address.is_empty())
        .map(str::to_owned)
}

fn organization(profile: &Profile) -> Option<String> {
    let path = account_file(profile);
    let file = std::fs::File::open(path).ok()?;
    if file.metadata().ok()?.len() > MAX_CACHE_ENTRY {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(MAX_CACHE_ENTRY + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    let value: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    value
        .pointer("/oauthAccount/organizationUuid")
        .and_then(|v| v.as_str())
        .filter(|org| !org.is_empty())
        .map(str::to_owned)
}

fn recent_entries(directory: &Path) -> Vec<(PathBuf, u64)> {
    let mut files: Vec<_> = std::fs::read_dir(directory)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            if !path.file_name()?.to_str()?.ends_with("_0") {
                return None;
            }
            let meta = entry.metadata().ok()?;
            if !meta.is_file() || meta.len() <= HEADER_BYTES as u64 || meta.len() > MAX_CACHE_ENTRY
            {
                return None;
            }
            let modified = meta
                .modified()
                .ok()?
                .duration_since(UNIX_EPOCH)
                .ok()?
                .as_millis() as u64;
            Some((path, modified))
        })
        .collect();
    files.sort_by_key(|(_, modified)| std::cmp::Reverse(*modified));
    files.truncate(MAX_CACHE_SCAN);
    files
}

pub(super) fn desktop_windows(profile: &Profile, now: u64) -> Option<Vec<LimitWindow>> {
    let org = organization(profile)?;
    let home = profile.dir.parent()?;
    let directory = home.join("Library/Application Support/Claude/Cache/Cache_Data");
    for (path, _) in recent_entries(&directory) {
        let Ok(mut file) = std::fs::File::open(path) else {
            continue;
        };
        let mut head = vec![0; HEADER_BYTES + MAX_CACHE_KEY];
        let Ok(size) = file.read(&mut head) else {
            continue;
        };
        let Some(key) = cache_key(&head[..size]) else {
            continue;
        };
        if organization_in_key(key) != Some(org.as_str()) {
            continue;
        }
        if file.seek(SeekFrom::Start(0)).is_err() {
            continue;
        }
        let mut bytes = Vec::new();
        if Read::take(&mut file, MAX_CACHE_ENTRY + 1)
            .read_to_end(&mut bytes)
            .is_err()
            || bytes.len() as u64 > MAX_CACHE_ENTRY
        {
            continue;
        }
        let modified = file
            .metadata()
            .ok()
            .and_then(|meta| meta.modified().ok())
            .and_then(|when| when.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_millis() as u64)
            .unwrap_or(now);
        let Some((windows, captured)) = decode_entry(&bytes, &org, modified) else {
            continue;
        };
        if now.abs_diff(captured) >= CACHE_FRESH_MS {
            // The newest decodable reading is authoritative. An older entry
            // cannot revive quota after this one has gone stale.
            return None;
        }
        if windows
            .iter()
            .any(|window| window.resets_at.is_some_and(|at| at <= now))
        {
            return None;
        }
        return Some(windows);
    }
    None
}

fn reset_date(text: &str, now_ms: u64) -> Option<u64> {
    let pattern = Regex::new(
        r"(?i)^([A-Za-z]{3}) (\d{1,2}) at (\d{1,2})(?::(\d{2}))?(am|pm)(?: \(([^)]+)\))?$",
    )
    .ok()?;
    let captures = pattern.captures(text.trim())?;
    let month_name = captures.get(1)?.as_str().to_ascii_lowercase();
    let month = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ]
    .iter()
    .position(|m| *m == month_name)? as u32
        + 1;
    let day: u32 = captures.get(2)?.as_str().parse().ok()?;
    let mut hour: u32 = captures.get(3)?.as_str().parse().ok()?;
    if !(1..=12).contains(&hour) {
        return None;
    }
    hour %= 12;
    if captures.get(5)?.as_str().eq_ignore_ascii_case("pm") {
        hour += 12;
    }
    let minute: u32 = captures.get(4).map_or("0", |m| m.as_str()).parse().ok()?;
    let now = chrono::DateTime::<Utc>::from_timestamp_millis(now_ms as i64)?;
    let zone = captures
        .get(6)
        .and_then(|m| m.as_str().parse::<chrono_tz::Tz>().ok());
    let this_year = zone
        .map(|tz| now.with_timezone(&tz).year())
        .unwrap_or_else(|| now.with_timezone(&Local).year());
    [this_year - 1, this_year, this_year + 1]
        .into_iter()
        .filter_map(|year| {
            let naive = NaiveDate::from_ymd_opt(year, month, day)?.and_hms_opt(hour, minute, 0)?;
            let value = if let Some(tz) = zone {
                tz.from_local_datetime(&naive)
                    .earliest()?
                    .timestamp_millis()
            } else {
                Local
                    .from_local_datetime(&naive)
                    .earliest()?
                    .timestamp_millis()
            };
            (value >= 0).then_some(value as u64)
        })
        .min_by_key(|candidate| candidate.abs_diff(now_ms))
}

pub(super) fn parse_cli(text: &str, now_ms: u64) -> Option<(Vec<LimitWindow>, Option<String>)> {
    let pattern = Regex::new(r"(?m)^Current (?:(session)|week \(([^)]+)\)):\s*(\d+)%\s*used(?:\s*·\s*resets\s*(.+?))?\s*$").ok()?;
    let mut windows = Vec::new();
    for captures in pattern.captures_iter(text) {
        let id = if captures.get(1).is_some() {
            "session".to_owned()
        } else {
            let kind = captures
                .get(2)?
                .as_str()
                .to_ascii_lowercase()
                .replace(' ', "_");
            format!(
                "weekly_{}",
                if kind == "all_models" { "all" } else { &kind }
            )
        };
        if windows.iter().any(|window: &LimitWindow| window.id == id) {
            continue;
        }
        let percent: f64 = captures.get(3)?.as_str().parse().ok()?;
        let label = match id.as_str() {
            "weekly_all" => "All models".to_owned(),
            "weekly_opus" => "Opus".to_owned(),
            _ => label_for(&id),
        };
        windows.push(LimitWindow {
            id: id.clone(),
            label,
            used: percent / 100.0,
            has_fraction: Some(true),
            resets_at: captures.get(4).and_then(|m| reset_date(m.as_str(), now_ms)),
            duration: claude_duration(&id),
            ..Default::default()
        });
    }
    if !windows.iter().any(|window| window.id == "session") {
        return None;
    }
    windows.sort_by_key(|window| if window.id == "session" { 0 } else { 1 });
    let head = text
        .lines()
        .take(4)
        .collect::<Vec<_>>()
        .join("\n")
        .to_ascii_lowercase();
    let plan = ["Max 20x", "Max 5x", "extra usage", "Max", "Pro", "Team"]
        .iter()
        .find(|phrase| head.contains(&phrase.to_ascii_lowercase()))
        .map(|s| (*s).to_owned());
    Some((windows, plan))
}

fn scratch_directory() -> Option<PathBuf> {
    let path = crate::config::config_path().parent()?.join("usage-scratch");
    std::fs::create_dir_all(&path).ok()?;
    Some(path)
}

pub(super) fn run_cli(
    binary: &Path,
    profile: &Profile,
    now: u64,
) -> Option<(Vec<LimitWindow>, Option<String>)> {
    run_cli_at(
        binary,
        profile,
        now,
        &scratch_directory()?,
        Duration::from_secs(20),
    )
}

fn run_cli_at(
    binary: &Path,
    profile: &Profile,
    now: u64,
    scratch: &Path,
    timeout: Duration,
) -> Option<(Vec<LimitWindow>, Option<String>)> {
    use std::process::Command;
    let mut command = Command::new(binary);
    command
        .args([
            "--print",
            "--no-session-persistence",
            "--strict-mcp-config",
            "/usage",
        ])
        .current_dir(scratch)
        .env("PWD", scratch);
    if profile.slug.is_some() {
        command.env("CLAUDE_CONFIG_DIR", &profile.dir);
    } else {
        command.env_remove("CLAUDE_CONFIG_DIR");
    }
    for (key, _) in std::env::vars_os() {
        let key = key.to_string_lossy();
        if key == "CLAUDECODE" || key.starts_with("CLAUDE_CODE_") {
            command.env_remove(key.as_ref());
        }
    }
    let bytes = super::process_output::output(command, MAX_CLI_OUTPUT as usize, timeout)?;
    parse_cli(std::str::from_utf8(&bytes).ok()?, now)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cli_windows_keep_zone_and_counted_reset_year() {
        let now = 1_788_760_800_000;
        let text = "Current session: 38% used · resets Sep 7 at 2:59pm (Asia/Jakarta)\nCurrent week (all models): 4% used · resets Sep 14 at 5:59am (Asia/Jakarta)";
        let (windows, _) = parse_cli(text, now).unwrap();
        assert_eq!(
            windows.iter().map(|w| w.id.as_str()).collect::<Vec<_>>(),
            vec!["session", "weekly_all"]
        );
        assert_eq!(windows[0].used, 0.38);
        assert_eq!(windows[0].resets_at, Some(1_788_767_940_000));
        assert_eq!(
            reset_date("Jan 2 at 3am (UTC)", 1_798_718_400_000),
            Some(1_798_858_800_000)
        );
    }
    #[test]
    fn oversized_or_wrong_account_cache_frame_is_never_read_as_usage() {
        let key = b"1/0/https://claude.ai/api/organizations/work/usage";
        let mut entry = vec![0; HEADER_BYTES];
        entry[0..8].copy_from_slice(&SIMPLE_MAGIC.to_le_bytes());
        entry[12..16].copy_from_slice(&(key.len() as u32).to_le_bytes());
        entry.extend_from_slice(key);
        entry.extend_from_slice(
            &zstd::bulk::compress(
                br#"{"five_hour":{"utilization":38,"resets_at":"2026-09-07T07:59:00Z"}}"#,
                0,
            )
            .unwrap(),
        );
        assert!(decode_entry(&entry, "personal", 0).is_none());
        assert_eq!(decode_entry(&entry, "work", 0).unwrap().0[0].used, 0.38);
        let mut bomb = entry[..HEADER_BYTES + key.len()].to_vec();
        bomb.extend_from_slice(&zstd::bulk::compress(&vec![b'x'; MAX_CACHE_BODY + 1], 0).unwrap());
        assert!(decode_entry(&bomb, "work", 0).is_none());
    }

    #[test]
    fn newest_decodable_desktop_entry_cannot_fall_back_to_older_quota() {
        let temp = tempfile::tempdir().unwrap();
        let profile = Profile {
            dir: temp.path().join(".claude"),
            slug: None,
        };
        std::fs::write(
            temp.path().join(".claude.json"),
            br#"{"oauthAccount":{"organizationUuid":"work"}}"#,
        )
        .unwrap();
        let cache = temp
            .path()
            .join("Library/Application Support/Claude/Cache/Cache_Data");
        std::fs::create_dir_all(&cache).unwrap();
        let now = chrono::DateTime::parse_from_rfc3339("2026-09-23T12:00:00Z")
            .unwrap()
            .timestamp_millis() as u64;
        let key = b"1/0/https://claude.ai/api/organizations/work/usage";
        for (name, reset, age_ms) in [
            ("older_0", "2026-09-24T12:00:00Z", 2_000),
            ("newer_0", "2026-09-22T12:00:00Z", 1_000),
        ] {
            let mut entry = vec![0; HEADER_BYTES];
            entry[0..8].copy_from_slice(&SIMPLE_MAGIC.to_le_bytes());
            entry[12..16].copy_from_slice(&(key.len() as u32).to_le_bytes());
            entry.extend_from_slice(key);
            entry.extend_from_slice(
                &zstd::bulk::compress(
                    format!(r#"{{"five_hour":{{"utilization":38,"resets_at":"{reset}"}}}}"#)
                        .as_bytes(),
                    0,
                )
                .unwrap(),
            );
            let file = std::fs::File::create(cache.join(name)).unwrap();
            use std::io::Write;
            (&file).write_all(&entry).unwrap();
            file.set_modified(UNIX_EPOCH + Duration::from_millis(now - age_ms))
                .unwrap();
        }
        assert!(desktop_windows(&profile, now).is_none());
    }

    #[cfg(unix)]
    #[test]
    fn cli_that_closes_stdout_but_keeps_running_is_killed_on_timeout() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let script = temp.path().join("claude");
        std::fs::write(&script, b"#!/bin/sh\nexec 1>&-\nwhile :; do :; done\n").unwrap();
        let mut mode = std::fs::metadata(&script).unwrap().permissions();
        mode.set_mode(0o700);
        std::fs::set_permissions(&script, mode).unwrap();
        let profile = Profile {
            dir: temp.path().join(".claude"),
            slug: None,
        };
        let started = std::time::Instant::now();
        assert!(run_cli_at(
            &script,
            &profile,
            0,
            temp.path(),
            Duration::from_millis(250)
        )
        .is_none());
        assert!(started.elapsed() < Duration::from_secs(2));
    }
}
