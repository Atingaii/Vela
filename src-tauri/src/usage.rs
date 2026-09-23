//! Claude usage adapter (official), implemented from the upstream Velo's documented behaviour.
//! Endpoint: GET https://api.anthropic.com/api/oauth/usage
//! Headers: Authorization: Bearer <token>; anthropic-beta: oauth-2025-04-20; 15 s timeout
//! Rules (upstream's discipline):
//!   - the credential comes from Claude Code's own store (Windows: ~/.claude/.credentials.json), read only
//!   - accounts, plural: ~/.claude and every ~/.claude-<slug> holding a credential. That layout is not invented
//!     here — it is what CLAUDE_CONFIG_DIR points a shell at, and what the Mac app already reads several accounts
//!     by. Each account's windows carry its name in `group`, so the card stacks them exactly as Antigravity's
//!     model families stack, and a machine with one account produces byte-for-byte the old reading
//!   - 401 → re-read the credential once and retry (Claude Code may have just refreshed the token) → still
//!     failing means needsAuth; 403 is access denied, not proof of lost authentication
//!   - 429 → back off 60 s × 2^n capped at 15 min, Retry-After only raises it, even past the cap; the deadline is persisted
//!   - an expired token is never sent: the endpoint answers it with 429 + Retry-After ≈ 3600, not 401, so sending it
//!     reads as "rate limited" for as long as the token stays stale (upstream's credentialExpired, no network)
//!   - the token is renewed by running the standalone `claude -p` with an empty stdin shortly before it expires
//!     (upstream's ClaudeTokenRefresher). Only that CLI writes ~/.claude/.credentials.json — Claude Code inside the
//!     desktop app renews its own copy elsewhere — so without this the file rots eight hours after the last CLI run
//!   - never invent a percentage on failure: keep the last reading marked stale, and the UI shows how old it is
//!
//! Reply (snake_case): { limits:[{kind,percent,resets_at}], five_hour:{utilization,resets_at}, seven_day:{...} }
//! limits is the forward-compatible main shape; five_hour/seven_day are merged in as a fallback (a window that just rolled over disappears from limits).

#[path = "claude_keychain.rs"]
mod claude_keychain;
#[path = "claude_sources.rs"]
mod claude_sources;
#[path = "process_output.rs"]
pub(crate) mod process_output;

use crate::AppState;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashMap};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

const ENDPOINT: &str = "https://api.anthropic.com/api/oauth/usage";
const POLL_ACTIVE_SECS: u64 = 60;
const POLL_IDLE_SECS: u64 = 300;
const BACKOFF_BASE_SECS: u64 = 60;
const BACKOFF_CAP_SECS: u64 = 900;
/// Renew when this close to expiry. Must stay under Claude Code's own five minutes: its start-up renews the token
/// only when now + 300 s >= expiresAt, so launching any earlier is a no-op that would be judged a failure
const RENEW_MARGIN_MS: u64 = 4 * 60 * 1000;
const RENEW_COOLDOWN_MS: u64 = 10 * 60 * 1000;
const RENEW_TIMEOUT_SECS: u64 = 30;
const EXPIRED_NOTE: &str = "Credential expired — run claude once in a terminal to renew it";
static RENEW_PID: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

#[derive(Default)]
struct DefaultRenewalState {
    epoch: u64,
    expiry: Option<u64>,
    needs_sign_in: bool,
}
static DEFAULT_RENEWAL: OnceLock<Mutex<DefaultRenewalState>> = OnceLock::new();
fn default_renewal() -> &'static Mutex<DefaultRenewalState> {
    DEFAULT_RENEWAL.get_or_init(|| Mutex::new(DefaultRenewalState::default()))
}

pub(crate) fn needs_sign_in_renewal(id: &str) -> bool {
    id == "claude" && default_renewal().lock().unwrap().needs_sign_in
}

pub(crate) fn renewal_pid() -> Option<u32> {
    match RENEW_PID.load(std::sync::atomic::Ordering::Acquire) {
        0 => None,
        pid => Some(pid),
    }
}

#[derive(Default)]
struct RefreshRequests {
    all: bool,
    profiles: BTreeSet<String>,
}
impl RefreshRequests {
    fn take_targets(&mut self) -> Option<BTreeSet<String>> {
        if self.all {
            self.all = false;
            self.profiles.clear();
            None
        } else if self.profiles.is_empty() {
            None
        } else {
            Some(std::mem::take(&mut self.profiles))
        }
    }
}
static REFRESH: OnceLock<Mutex<RefreshRequests>> = OnceLock::new();
fn refresh_requests() -> &'static Mutex<RefreshRequests> {
    REFRESH.get_or_init(|| Mutex::new(RefreshRequests::default()))
}

/// Immediate refresh from the tray or a command
pub fn request_refresh() {
    refresh_requests().lock().unwrap().all = true;
}

pub fn request_profile_refresh(id: &str) {
    refresh_requests()
        .lock()
        .unwrap()
        .profiles
        .insert(id.into());
}

pub(crate) fn cancel_profile_refresh(id: &str) {
    refresh_requests().lock().unwrap().profiles.remove(id);
}

/// None means the normal timer (or Refresh All); a set means one or more rings.
fn take_refresh_targets() -> Option<BTreeSet<String>> {
    refresh_requests().lock().unwrap().take_targets()
}

/// A single wait path for both the real worker and virtual-clock tests. Profile requests
/// interrupt immediately; otherwise the shared Swift-style busy/reset decision is sampled
/// at 60-second ticks, with the existing bounded backoff wait as an upper limit.
fn sleep_interruptible_with(
    total_secs: u64,
    last_attempt: u64,
    mut requested: impl FnMut() -> bool,
    mut due: impl FnMut(u64, u64) -> bool,
    mut now_ms: impl FnMut() -> u64,
    mut sleep_one: impl FnMut(),
) {
    let tick_ms = POLL_ACTIVE_SECS * 1_000;
    let mut tick = last_attempt.saturating_add(tick_ms);
    for _ in 0..total_secs {
        if requested() {
            return;
        }
        let now = now_ms();
        if now >= tick {
            if due(last_attempt, now) {
                return;
            }
            tick = tick.saturating_add(((now - tick) / tick_ms + 1) * tick_ms);
        }
        sleep_one();
    }
}

fn sleep_interruptible(app: &AppHandle, total_secs: u64, last_attempt: u64) {
    sleep_interruptible_with(
        total_secs,
        last_attempt,
        || {
            let requests = refresh_requests().lock().unwrap();
            requests.all || !requests.profiles.is_empty()
        },
        |last, now| crate::providers::remote_refresh_due(app, last, now),
        now_ms,
        || std::thread::sleep(Duration::from_secs(1)),
    );
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

const CRED_NAMES: [&str; 2] = [".credentials.json", "credentials.json"];

/// One Claude Code account, as its config directory. `slug` is None for the default ~/.claude and
/// Some("work") for ~/.claude-work.
#[derive(Debug, Clone, PartialEq)]
struct Profile {
    dir: PathBuf,
    slug: Option<String>,
}

impl Profile {
    fn name(&self) -> String {
        self.slug.clone().unwrap_or_else(|| "default".into())
    }

    /// The heading the card files this account's windows under. The plan is what tells two accounts
    /// apart at a glance ("max" against "pro"); the slug is what stays unique when both plans match.
    fn group(&self, plan: Option<&str>) -> String {
        match plan {
            Some(p) if !p.is_empty() => format!("{} · {p}", self.name()),
            _ => self.name(),
        }
    }
}

/// Every account on the machine: the default first, then ~/.claude-<slug> in name order. A secondary
/// directory must carry a Claude first-run marker and its own credential.
fn profiles() -> Vec<Profile> {
    let Some(home) = dirs::home_dir() else {
        return Vec::new();
    };
    let mut out = vec![Profile {
        dir: home.join(".claude"),
        slug: None,
    }];
    out.extend(
        crate::providers::claude_named_profiles()
            .into_iter()
            .map(|(slug, dir)| Profile {
                dir,
                slug: Some(slug),
            }),
    );
    out
}

fn claude_marker(dir: &Path) -> bool {
    [
        "sessions",
        "projects",
        "settings.json",
        "history.jsonl",
        ".claude.json",
    ]
    .into_iter()
    .any(|name| dir.join(name).exists())
}

pub(crate) fn discover_named_profiles(home: &Path) -> Vec<(String, PathBuf)> {
    discover_named_profiles_with(home, |slug, dir| {
        let profile = Profile {
            dir: dir.to_owned(),
            slug: Some(slug.into()),
        };
        claude_keychain::has_credential(&profile)
    })
}

fn discover_named_profiles_with(
    home: &Path,
    has_credential: impl Fn(&str, &Path) -> bool,
) -> Vec<(String, PathBuf)> {
    let mut profiles: Vec<_> = std::fs::read_dir(home)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().to_string();
            let slug = name.strip_prefix(".claude-")?.to_string();
            if slug.is_empty() || !entry.file_type().ok()?.is_dir() {
                return None;
            }
            let dir = entry.path();
            if !claude_marker(&dir) {
                // Windows also retained file-only credential profiles in
                // older Velo builds; keep those readable during migration.
                #[cfg(not(target_os = "windows"))]
                return None;
                #[cfg(target_os = "windows")]
                if !CRED_NAMES.iter().any(|name| dir.join(name).is_file()) {
                    return None;
                }
            }
            has_credential(&slug, &dir).then_some((slug, dir))
        })
        .collect();
    profiles.sort_by(|a, b| a.0.cmp(&b.0));
    profiles
}

/// Every account directory, for anything that watches a profile's files (the session watcher)
pub fn profile_dirs() -> Vec<PathBuf> {
    profiles().into_iter().map(|p| p.dir).collect()
}

/// Resolve only a Claude Code profile identifier, never a caller-supplied path.
/// A named profile may not have a credential yet when Sign in is clicked.
pub(crate) fn profile_directory_for_id(id: &str) -> Option<Option<PathBuf>> {
    if id == "claude" {
        return Some(None);
    }
    let slug = id.strip_prefix("claude-")?;
    if slug.is_empty() || slug.contains(['/', '\\', '\0']) {
        return None;
    }
    Some(Some(dirs::home_dir()?.join(format!(".claude-{slug}"))))
}

pub(crate) fn account_label(id: &str) -> Option<String> {
    let dir = match profile_directory_for_id(id)? {
        Some(dir) => dir,
        None => dirs::home_dir()?.join(".claude"),
    };
    let slug = id.strip_prefix("claude-").map(str::to_owned);
    claude_sources::account_address(&Profile { dir, slug })
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct LimitWindow {
    pub id: String,
    pub label: String,
    /// 0.0–1.0 (fraction used)
    pub used: f64,
    /// `false` distinguishes an unmetered count/detail from a measured 0%.
    /// None keeps archived readings compatible with older versions.
    #[serde(default)]
    pub has_fraction: Option<bool>,
    /// Reset time, ms epoch (None = unknown)
    pub resets_at: Option<u64>,
    /// Reported quota duration in seconds; absent means pace cannot be inferred.
    #[serde(default)]
    pub duration: Option<f64>,
    /// Pure count window (no published denominator, e.g. Antigravity's requests today) — the cell shows ~N and the ring draws only its track
    #[serde(default)]
    pub count: Option<i64>,
    /// Provider-reported counts can coexist with a fraction; unknown stays absent.
    #[serde(default)]
    pub remaining: Option<i64>,
    #[serde(default)]
    pub used_count: Option<i64>,
    /// The number is ours, not the vendor's (upstream fidelity=.derived) — the card adds a ~ prefix
    #[serde(default)]
    pub derived: bool,
    /// The heading the window sits under on the card, for a provider that reports the same windows
    /// for several things (Antigravity: a 5-hour and a weekly lane per model family). None = ungrouped
    #[serde(default)]
    pub group: Option<String>,
    /// Provider-reported balance components; the fraction remains a separate field.
    #[serde(default)]
    pub money: Option<MoneyBreakdown>,
    /// Detail-only text for a window with no ring fraction.
    #[serde(default)]
    pub detail: Option<String>,
    /// Provider's formatted unit, used by custom endpoints for money/tokens.
    #[serde(default)]
    pub used_text: Option<String>,
    #[serde(default)]
    pub prefers_used_text: bool,
    #[serde(default)]
    pub band_override: Option<UsageBand>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum UsageBand {
    Ample,
    Watch,
    Critical,
    Exhausted,
}

impl UsageBand {
    pub fn from_used_fraction(fraction: f64) -> Self {
        if fraction < 0.5 {
            Self::Ample
        } else if fraction < 0.7 {
            Self::Watch
        } else if fraction < 1.0 {
            Self::Critical
        } else {
            Self::Exhausted
        }
    }
}

impl LimitWindow {
    /// A count or a remaining balance alone does not establish a denominator.
    /// Older archives lack `has_fraction`; preserve their measured positive
    /// readings while keeping new explicit zero and pure-count rows distinct.
    pub fn fraction(&self) -> Option<f64> {
        let legacy = self.used > 0.0
            || (self.count.is_none()
                && self.remaining.is_none()
                && self.used_count.is_none()
                && self.detail.is_none());
        (self.has_fraction.unwrap_or(legacy) && self.used.is_finite() && self.used >= 0.0)
            .then_some(self.used)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct MoneyBreakdown {
    pub currency: String,
    pub spent: f64,
    pub remaining: f64,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Fidelity {
    #[default]
    Official,
    Derived,
    Manual,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UsageBlock {
    pub reason: String,
    #[serde(default)]
    pub resets_at: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CodexTokenSummary {
    pub lifetime_tokens: Option<i64>,
    pub peak_daily_tokens: Option<i64>,
    pub longest_running_turn_seconds: Option<f64>,
    pub current_streak_days: Option<i64>,
    pub longest_streak_days: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CodexDailyBucket {
    pub start_date: String,
    pub tokens: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CodexTokenUsage {
    pub summary: Option<CodexTokenSummary>,
    #[serde(default)]
    pub daily_usage_buckets: Vec<CodexDailyBucket>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CodexResetCredit {
    pub id: String,
    pub status: String,
    #[serde(default)]
    pub expires_at: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CodexResetCredits {
    pub available_count: i64,
    #[serde(default)]
    pub credits: Vec<CodexResetCredit>,
}

impl CodexResetCredits {
    pub fn next_expiry(&self) -> Option<u64> {
        self.credits
            .iter()
            .filter(|credit| credit.status == "available")
            .filter_map(|credit| credit.expires_at)
            .min()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UsageSnapshot {
    /// ok | stale | needsAuth | backoff | error
    pub status: String,
    pub windows: Vec<LimitWindow>,
    pub fetched_at: u64,
    pub note: String,
    #[serde(default)]
    pub backoff_until: u64,
    #[serde(default)]
    pub plan: Option<String>,
    #[serde(default)]
    pub fidelity: Fidelity,
    #[serde(default)]
    pub block: Option<UsageBlock>,
    #[serde(default)]
    pub token_usage: Option<CodexTokenUsage>,
    #[serde(default)]
    pub reset_credits: Option<CodexResetCredits>,
    #[serde(default)]
    pub usage_detail: Option<crate::web_usage_detail::ProviderUsageDetail>,
    #[serde(default)]
    pub local_model: Option<crate::local_runtime::Model>,
    #[serde(default)]
    pub source_provider_id: Option<String>,
    #[serde(default)]
    pub local_runtime_measures_speed: bool,
    #[serde(default)]
    pub local_performance: Option<crate::local_metrics::Performance>,
    #[serde(default)]
    pub local_ledger: Option<crate::local_metrics::LedgerSummary>,
    #[serde(default)]
    pub local_context_fraction: Option<f64>,
    #[serde(default)]
    pub shows_local_performance: bool,
}

fn store_path() -> std::path::PathBuf {
    crate::config::config_path().with_file_name("usage.json")
}

pub fn load_persisted() -> UsageSnapshot {
    std::fs::read_to_string(store_path())
        .ok()
        .and_then(|t| serde_json::from_str::<UsageSnapshot>(&t).ok())
        .map(rehydrate_archive)
        .unwrap_or_default()
}

fn rehydrate_archive(mut snapshot: UsageSnapshot) -> UsageSnapshot {
    // An archive is remembered evidence, not a fresh response from this
    // process. Keep the original timestamp so the UI reports its real age.
    snapshot.status = "stale".into();
    snapshot
}

fn persist(s: &UsageSnapshot) {
    if let Ok(t) = serde_json::to_string_pretty(s) {
        let _ = std::fs::write(store_path(), t);
    }
}

#[derive(Clone, Default)]
struct Credential {
    token: String,
    /// ms epoch (None = the file names no expiry)
    expires_at: Option<u64>,
    /// "max" | "pro" | … as the credential names it, for the card's account heading
    plan: Option<String>,
}

impl Credential {
    fn expired(&self, now: u64) -> bool {
        self.expires_at.map(|e| e <= now).unwrap_or(false)
    }
}

/// Reads Claude Code's OAuth credential.
fn read_credentials(dir: &Path) -> Option<Credential> {
    for name in CRED_NAMES {
        let p = dir.join(name);
        let Ok(text) = std::fs::read_to_string(&p) else {
            continue;
        };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else {
            continue;
        };
        let oauth = v.get("claudeAiOauth").unwrap_or(&v);
        if let Some(tok) = oauth.get("accessToken").and_then(|x| x.as_str()) {
            // An empty token is signed out, not expired: fall through to the next
            // candidate file rather than report a credential that cannot be used.
            if tok.trim().is_empty() {
                continue;
            }
            let expires_at = oauth
                .get("expiresAt")
                .and_then(|x| x.as_f64())
                .map(|ms| ms as u64);
            let plan = oauth
                .get("subscriptionType")
                .and_then(|x| x.as_str())
                .map(String::from);
            return Some(Credential {
                token: tok.to_string(),
                expires_at,
                plan,
            });
        }
    }
    #[cfg(target_os = "macos")]
    if dirs::home_dir().is_some_and(|h| dir == h.join(".claude")) {
        if let Some(text) = crate::platform::claude_keychain() {
            if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&text) {
                let oauth = v.get("claudeAiOauth").unwrap_or(&v);
                if let Some(token) = oauth["accessToken"]
                    .as_str()
                    .filter(|s| !s.trim().is_empty())
                {
                    return Some(Credential {
                        token: token.into(),
                        expires_at: oauth["expiresAt"].as_u64(),
                        plan: oauth["subscriptionType"].as_str().map(String::from),
                    });
                }
            }
        }
    }
    None
}

/// For doctor: credential probe report (prints no secret values)
pub fn probe_credentials() -> String {
    let cli = match find_cli() {
        Some(p) => format!("renews via {}", p.display()),
        None => "no standalone claude CLI found to renew it".into(),
    };
    let list = profiles();
    if list.is_empty() {
        return format!("credential: no home directory to read ~/.claude from; {cli}");
    }
    let lines: Vec<String> = list
        .iter()
        .map(|p| match read_credentials(&p.dir) {
            Some(c) => format!(
                "credential[{}]: found (token {} chars, {}, plan {})",
                p.name(),
                c.token.len(),
                if c.expired(now_ms()) { "expired" } else { "valid" },
                c.plan.as_deref().unwrap_or("?")
            ),
            None => format!(
                "credential[{}]: {} not found (needsAuth; the desktop app may use another store — signing in once with the Claude Code CLI creates it)",
                p.name(),
                p.dir.join(CRED_NAMES[0]).display()
            ),
        })
        .collect();
    format!(
        "{}; {cli}",
        lines.join(
            "
  "
        )
    )
}

// ---------------- token renewal (upstream's ClaudeTokenRefresher) ----------------

/// Anything under these belongs to the desktop app: its bundled Claude Code keeps its token in the desktop app's
/// own store and never writes ~/.claude/.credentials.json, so renewing with it would change nothing here
fn is_desktop_owned(p: &std::path::Path) -> bool {
    let s = p.to_string_lossy().to_ascii_lowercase().replace('/', "\\");
    s.contains("\\anthropicclaude\\")
        || s.contains("\\claude\\claude-code\\")
        || s.contains("\\windowsapps\\")
}

/// The standalone Claude Code command: its own installer's location first, then global npm/pnpm/Volta, then PATH
pub(crate) fn find_cli() -> Option<std::path::PathBuf> {
    let mut v = Vec::new();
    #[cfg(unix)]
    {
        if let Some(h) = dirs::home_dir() {
            v.push(h.join(".local/bin/claude"));
            v.push(h.join(".claude/local/claude"));
            v.push(h.join(".bun/bin/claude"));
            v.push(h.join(".volta/bin/claude"));
            v.push(h.join("Library/pnpm/claude"));
            v.push(h.join(".npm-global/bin/claude"));
            if let Ok(entries) = std::fs::read_dir(h.join(".nvm/versions/node")) {
                let mut node_versions: Vec<_> =
                    entries.flatten().map(|entry| entry.path()).collect();
                node_versions.sort_by(|a, b| {
                    let parts = |path: &PathBuf| {
                        path.file_name()
                            .unwrap_or_default()
                            .to_string_lossy()
                            .trim_start_matches('v')
                            .split('.')
                            .filter_map(|part| part.parse::<u32>().ok())
                            .collect::<Vec<_>>()
                    };
                    parts(b).cmp(&parts(a))
                });
                v.extend(
                    node_versions
                        .into_iter()
                        .map(|path| path.join("bin/claude")),
                );
            }
        }
        v.push("/opt/homebrew/bin/claude".into());
        v.push("/usr/local/bin/claude".into());
    }
    if let Some(h) = dirs::home_dir() {
        v.push(h.join(".local").join("bin").join("claude.exe"));
    }
    if let Some(d) = dirs::config_dir() {
        v.push(d.join("npm").join("claude.cmd"));
    }
    if let Some(d) = dirs::data_local_dir() {
        v.push(d.join("pnpm").join("claude.cmd"));
    }
    if let Some(h) = dirs::home_dir() {
        v.push(h.join(".volta").join("bin").join("claude.exe"));
    }
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            #[cfg(unix)]
            if dir.is_absolute() {
                v.push(dir.join("claude"));
            }
            v.push(dir.join("claude.exe"));
            v.push(dir.join("claude.cmd"));
        }
    }
    v.into_iter().find(|p| {
        if !p.is_file() || is_desktop_owned(p) {
            return false;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            p.metadata()
                .is_ok_and(|m| m.permissions().mode() & 0o111 != 0)
        }
        #[cfg(not(unix))]
        {
            true
        }
    })
}

/// Whether a launch is worth making. Pure, so every branch is testable without a clock or a subprocess
fn should_renew(
    expires_at: Option<u64>,
    now: u64,
    attempted_for: Option<u64>,
    last_attempt: Option<u64>,
) -> bool {
    // Nothing read yet: never launch on a guess
    let Some(exp) = expires_at else { return false };
    // Plenty of time left — also where launching would do nothing, because the CLI's own gate has not opened
    if exp >= now.saturating_add(RENEW_MARGIN_MS) {
        return false;
    }
    // Swift spends exactly one attempt on an expiry; a failed CLI startup must
    // not launch repeatedly against the same saved token.
    if attempted_for == Some(exp) {
        return false;
    }
    last_attempt.is_none_or(|at| now.saturating_sub(at) >= RENEW_COOLDOWN_MS)
}

/// `claude -p` with a null stdin starts up (which is where it renews an aged token), then exits non-zero for want
/// of a prompt: no conversation, no transcript. Output goes nowhere — a token could in principle be echoed into it.
fn run_renewal(cli: &std::path::Path, dir: &Path) -> std::io::Result<()> {
    use std::process::{Command, Stdio};
    let mut cmd = Command::new(cli);
    cmd.arg("-p")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // Launched from inside a Claude Code session, the child would take the host's auth and leave the file alone
    for (k, _) in std::env::vars_os() {
        let k = k.to_string_lossy();
        if k == "CLAUDECODE" || k.starts_with("CLAUDE_CODE_") {
            cmd.env_remove(k.as_ref());
        }
    }
    // Which account gets renewed is said here, never inherited: CLAUDE_CONFIG_DIR is not CLAUDE_CODE_*, so it
    // survives the loop above, and a Velo started from a shell pointed at another account used to renew
    // that one while the account on screen stayed expired.
    cmd.env("CLAUDE_CONFIG_DIR", dir);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    let mut child = cmd.spawn()?;
    struct RenewalPidGuard;
    impl Drop for RenewalPidGuard {
        fn drop(&mut self) {
            RENEW_PID.store(0, std::sync::atomic::Ordering::Release);
        }
    }
    RENEW_PID.store(child.id(), std::sync::atomic::Ordering::Release);
    let _pid_guard = RenewalPidGuard;
    let deadline = std::time::Instant::now() + Duration::from_secs(RENEW_TIMEOUT_SECS);
    while child.try_wait()?.is_none() {
        if std::time::Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    Ok(())
}

#[derive(Default)]
struct Renewer {
    attempted_for: Option<u64>,
    last_attempt: Option<u64>,
}

impl Renewer {
    /// Some(true) means the expiry moved, regardless of the CLI exit status.
    fn maybe_renew_with(
        &mut self,
        profile: &Profile,
        expiry: Option<u64>,
        cli: Option<&Path>,
        launch: impl FnOnce(&Path, &Path) -> std::io::Result<()>,
        reload_expiry: impl FnOnce() -> Option<u64>,
    ) -> Option<bool> {
        // The upstream AppDelegate installs one refresher for the default
        // Claude profile only. Named profiles age until their own CLI runs.
        if profile.slug.is_some() {
            return None;
        }
        let _auth = crate::claude_auth::try_acquire()?;
        let now = now_ms();
        if !should_renew(expiry, now, self.attempted_for, self.last_attempt) {
            return None;
        }
        self.last_attempt = Some(now);
        self.attempted_for = expiry;
        let Some(cli) = cli else {
            crate::applog(&format!(
                "claude[default]: token about to expire and no standalone claude CLI found to renew it"
            ));
            return Some(false);
        };
        if let Err(e) = launch(cli, &profile.dir) {
            crate::applog(&format!(
                "claude[default]: token renewal could not start ({}): {e}",
                cli.display()
            ));
            return Some(false);
        }
        let after = reload_expiry();
        let renewed = matches!((after, expiry), (Some(a), Some(b)) if a > b);
        crate::applog(&if renewed {
            format!("claude[default]: token renewed via {}", cli.display())
        } else {
            format!(
                "claude[default]: ran {} but the token expiry did not move",
                cli.display()
            )
        });
        Some(renewed)
    }
}

fn parse_reset(v: &serde_json::Value) -> Option<u64> {
    v.as_str()
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .map(|d| d.timestamp_millis().max(0) as u64)
}

fn label_for(kind: &str) -> String {
    match kind {
        "session" => "Current session".into(),
        "seven_day" | "weekly_all" => "Weekly (all models)".into(),
        "seven_day_opus" | "weekly_opus" => "Weekly (Opus)".into(),
        "weekly_scoped" => "Weekly (model-scoped)".into(),
        other => {
            // Forward compatibility: an unknown kind gets a readable label
            let mut s = other.replace('_', " ");
            if let Some(c) = s.get_mut(0..1) {
                c.make_ascii_uppercase();
            }
            s
        }
    }
}

fn parse_response(v: &serde_json::Value) -> Vec<LimitWindow> {
    let mut out: Vec<LimitWindow> = Vec::new();
    if let Some(arr) = v.get("limits").and_then(|x| x.as_array()) {
        for l in arr {
            let Some(kind) = l.get("kind").and_then(|x| x.as_str()) else {
                continue;
            };
            let Some(pct) = l.get("percent").and_then(|x| x.as_f64()) else {
                continue;
            };
            let resets = l.get("resets_at").and_then(parse_reset);
            if resets.is_none() {
                continue; // upstream rule: a window without a reset time is not shown
            }
            out.push(LimitWindow {
                id: kind.to_string(),
                label: label_for(kind),
                used: (pct / 100.0).clamp(0.0, 1.0),
                has_fraction: Some(true),
                resets_at: resets,
                duration: claude_duration(kind),
                ..Default::default()
            });
        }
    }
    // Fallback merge: a window that just rolled over disappears from limits while the named field remains.
    // In practice the kinds in limits are weekly_all/weekly_scoped, not seven_day — deduplicating by id
    // alone would add the seven_day fallback a second time (the card showed "Weekly all" and
    // "Weekly (all models)" as twins). Three dedupe rules: id alias / same resets_at and percentage / same label.
    let aliases: [(&str, &str, &[&str]); 2] = [
        ("five_hour", "session", &["session", "five_hour"]),
        (
            "seven_day",
            "seven_day",
            &["seven_day", "weekly_all", "weekly"],
        ),
    ];
    for (field, id, alias) in aliases {
        let Some(w) = v.get(field) else { continue };
        let Some(u) = w.get("utilization").and_then(|x| x.as_f64()) else {
            continue;
        };
        let used = (u / 100.0).clamp(0.0, 1.0);
        let resets_at = w.get("resets_at").and_then(parse_reset);
        let label = label_for(id);
        let dup = out.iter().any(|x| {
            alias.contains(&x.id.as_str())
                || x.label == label
                || (resets_at.is_some()
                    && x.resets_at.map(|r| r / 1000) == resets_at.map(|r| r / 1000)
                    && (x.used - used).abs() < 0.005)
        });
        if dup {
            continue;
        }
        out.push(LimitWindow {
            id: id.into(),
            label,
            used,
            has_fraction: Some(true),
            resets_at,
            duration: claude_duration(id),
            ..Default::default()
        });
    }
    // session always comes first (upstream display order)
    out.sort_by_key(|w| if w.id == "session" { 0 } else { 1 });
    out
}

fn claude_duration(kind: &str) -> Option<f64> {
    if kind == "session" {
        Some(5.0 * 3600.0)
    } else if kind.starts_with("weekly_") || kind.starts_with("seven_day") {
        Some(7.0 * 86400.0)
    } else {
        None
    }
}

enum FetchErr {
    NeedsAuth,
    RateLimited(u64), // suggested wait in seconds (the Retry-After before the floor is applied)
    Other(String),
}

fn fetch_once(token: &str) -> Result<Vec<LimitWindow>, FetchErr> {
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(15))
        .redirects(0)
        .build();
    let resp = agent
        .get(ENDPOINT)
        .set("Authorization", &format!("Bearer {token}"))
        .set("anthropic-beta", "oauth-2025-04-20")
        .call();
    match resp {
        Ok(r) => {
            let mut body = Vec::new();
            r.into_reader()
                .take(2 * 1024 * 1024 + 1)
                .read_to_end(&mut body)
                .map_err(|_| FetchErr::Other("Claude response read failed".into()))?;
            if body.len() > 2 * 1024 * 1024 {
                return Err(FetchErr::Other("Claude response exceeded limit".into()));
            }
            let v: serde_json::Value = serde_json::from_slice(&body)
                .map_err(|_| FetchErr::Other("Claude response was invalid JSON".into()))?;
            let windows = parse_response(&v);
            if windows.is_empty() {
                return Err(FetchErr::Other(
                    "Claude answered, but listed no usage limits for this account".into(),
                ));
            }
            Ok(windows)
        }
        Err(ureq::Error::Status(401, _)) => Err(FetchErr::NeedsAuth),
        Err(ureq::Error::Status(403, _)) => Err(FetchErr::NeedsAuth),
        Err(ureq::Error::Status(429, r)) => {
            let ra = r
                .header("retry-after")
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(0);
            Err(FetchErr::RateLimited(ra))
        }
        Err(ureq::Error::Status(code, _)) => Err(FetchErr::Other(format!("HTTP {code}"))),
        Err(e) => Err(FetchErr::Other(format!("{e}"))),
    }
}

fn backoff_secs(consecutive: u32, retry_after_floor: u64) -> u64 {
    let exp = BACKOFF_BASE_SECS.saturating_mul(1u64 << consecutive.min(4));
    // The server's Retry-After is honoured in full: with expired tokens no longer
    // sent, a long one is a real rate limit, and retrying early only earns another.
    exp.clamp(BACKOFF_BASE_SECS, BACKOFF_CAP_SECS)
        .max(retry_after_floor)
}

fn set_and_broadcast(app: &AppHandle, mutate: impl FnOnce(&mut UsageSnapshot)) {
    let st = app.state::<AppState>();
    let snap = {
        let mut u = st.usage.lock().unwrap();
        mutate(&mut u);
        u.clone()
    };
    persist(&snap);
    let _ = app.emit("usage", &snap);
    crate::refresh::complete("claude");
}

/// What one account contributes to the shared reading. Kept across ticks so a refresh that fails for
/// one account keeps showing that account's last good windows, and never blanks the other one.
#[derive(Default)]
struct Account {
    generation: u64,
    credential_expiry: Option<u64>,
    consecutive_429: u32,
    backoff_until: u64,
    windows: Vec<LimitWindow>,
    status: String,
    note: String,
    fetched_at: u64,
    plan: Option<String>,
    last_desktop_miss: Option<u64>,
    last_cli_attempt: Option<u64>,
    cli_cache: Option<(Vec<LimitWindow>, u64, Option<String>)>,
}

fn key(p: &Profile) -> String {
    p.dir.to_string_lossy().to_string()
}

fn profile_id(p: &Profile) -> String {
    p.slug
        .as_ref()
        .map(|slug| format!("claude-{slug}"))
        .unwrap_or_else(|| "claude".into())
}

pub(crate) fn was_refused_claude_access(id: &str) -> bool {
    profile_directory_for_id(id).is_some() && claude_keychain::was_refused(id)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum BorrowedKeychainError {
    Denied,
    Transient,
}

#[cfg(target_os = "macos")]
pub(crate) fn read_borrowed_keychain(
    service: &str,
    account: &str,
    interactive: bool,
) -> Result<Option<Vec<u8>>, BorrowedKeychainError> {
    claude_keychain::borrowed_secret(service, account, interactive).map_err(|error| match error {
        claude_keychain::ReadError::Denied => BorrowedKeychainError::Denied,
        _ => BorrowedKeychainError::Transient,
    })
}

#[cfg(target_os = "macos")]
pub(crate) fn has_borrowed_keychain(service: &str, account: &str) -> bool {
    claude_keychain::has_borrowed_secret(service, account)
}

#[tauri::command]
pub fn allow_claude_keychain_access(app: AppHandle, id: String) -> Result<(), String> {
    if profile_directory_for_id(&id).is_none() || !crate::providers::enabled(&app, &id) {
        return Err("Claude profile is unavailable".into());
    }
    claude_keychain::grant(&id);
    request_profile_refresh(&id);
    Ok(())
}

fn credential_for(
    p: &Profile,
    interactive: bool,
) -> Result<Credential, claude_keychain::ReadError> {
    #[cfg(target_os = "macos")]
    {
        claude_keychain::read(p, interactive)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = interactive;
        read_credentials(&p.dir).ok_or(claude_keychain::ReadError::NeedsAuth)
    }
}

/// Called while the connection gate is held. Rebuild the shared legacy reading
/// from the still-connected profile snapshots, not from a removed account's
/// in-memory aggregate or credential.
pub(crate) fn forget_profile(app: &AppHandle, id: &str) {
    cancel_profile_refresh(id);
    if id == "claude" {
        let mut renewal = default_renewal().lock().unwrap();
        renewal.expiry = None;
        renewal.needs_sign_in = false;
    }
    let active: Vec<Profile> = profiles()
        .into_iter()
        .filter(|p| crate::providers::enabled(app, &profile_id(p)))
        .collect();
    let accounts: HashMap<String, Account> = active
        .iter()
        .filter_map(|p| {
            let snap = crate::providers::snapshot(&profile_id(p));
            (snap.status != "absent").then(|| {
                (
                    key(p),
                    Account {
                        windows: decorate(snap.windows, p, None),
                        status: snap.status,
                        note: snap.note,
                        fetched_at: snap.fetched_at,
                        backoff_until: snap.backoff_until,
                        ..Default::default()
                    },
                )
            })
        })
        .collect();
    let snap = aggregate(&active, &accounts);
    *app.state::<AppState>().usage.lock().unwrap() = snap.clone();
    persist(&snap);
    let _ = app.emit("usage", &snap);
}

/// The account's windows as they go on the card: its name in `group`, and for a secondary account an
/// id suffixed with the slug -- which is what keeps `by_id("session")` in the notch meaning the default
/// account's session and not whichever account answered first.
fn decorate(mut windows: Vec<LimitWindow>, p: &Profile, group: Option<&str>) -> Vec<LimitWindow> {
    for w in &mut windows {
        if let Some(g) = group {
            w.group = Some(g.to_string());
        }
        if let Some(slug) = &p.slug {
            w.id = format!("{}@{slug}", w.id);
        }
    }
    windows
}

/// Hands each account back the windows it contributed before the restart: a secondary account's ids
/// carry `@slug`, so both accounts come back from disk instead of only the default one.
fn split_persisted(snap: &UsageSnapshot, order: &[Profile]) -> HashMap<String, Vec<LimitWindow>> {
    let mut out: HashMap<String, Vec<LimitWindow>> = HashMap::new();
    for w in &snap.windows {
        let owner = order.iter().find(|p| match &p.slug {
            Some(sl) => w.id.ends_with(&format!("@{sl}")),
            None => !w.id.contains('@'),
        });
        if let Some(p) = owner {
            out.entry(key(p)).or_default().push(w.clone());
        }
    }
    out
}

/// One reading out of every account's, in profile order. The status is the best news any account has:
/// a second account that needs signing in must not dim a first one that just answered.
fn aggregate(order: &[Profile], accounts: &HashMap<String, Account>) -> UsageSnapshot {
    if order.is_empty() {
        return UsageSnapshot::default();
    }
    let rank = |s: &str| match s {
        "ok" => 0,
        "stale" => 1,
        "error" => 2,
        _ => 3, // needsAuth, and anything not set yet
    };
    let multi = order.len() > 1;
    let mut snap = UsageSnapshot::default();
    let mut notes: Vec<String> = Vec::new();
    let mut best = 4;
    for p in order {
        let Some(a) = accounts.get(&key(p)) else {
            continue;
        };
        snap.windows.extend(a.windows.iter().cloned());
        snap.fetched_at = snap.fetched_at.max(a.fetched_at);
        if !a.status.is_empty() && rank(a.status.as_str()) < best {
            best = rank(a.status.as_str());
            snap.status = a.status.clone();
        }
        if !a.note.is_empty() {
            notes.push(if multi {
                format!("{}: {}", p.name(), a.note)
            } else {
                a.note.clone()
            });
        }
        // The soonest deadline is the one worth waking for
        if a.backoff_until > 0 && (snap.backoff_until == 0 || a.backoff_until < snap.backoff_until)
        {
            snap.backoff_until = a.backoff_until;
        }
    }
    if snap.status.is_empty() {
        snap.status = "needsAuth".into();
    }
    snap.note = notes.join(" · ");
    snap
}

/// One account's reading; the default account's token renewal has its own timer.
fn accepted_windows(
    p: &Profile,
    acc: &mut Account,
    windows: Vec<LimitWindow>,
    plan: Option<String>,
    multi: bool,
) {
    let group = multi.then(|| p.group(plan.as_deref()));
    acc.windows = decorate(windows, p, group.as_deref());
    acc.plan = plan;
    acc.status = "ok".into();
    acc.fetched_at = now_ms();
    acc.note.clear();
    acc.backoff_until = 0;
}

fn poll_account(p: &Profile, acc: &mut Account, multi: bool) {
    let id = profile_id(p);
    let now = now_ms();
    if claude_keychain::was_refused(&id) {
        acc.status = "accessDenied".into();
        acc.note = "Claude Keychain access was denied".into();
        acc.windows.clear();
        return;
    }
    let asking_again = claude_keychain::asking_again(&id);
    // An organization ID is mandatory: Desktop is signed into one account,
    // while Claude Code may have several profile rings.
    if !asking_again
        && acc
            .last_desktop_miss
            .is_none_or(|at| now.saturating_sub(at) >= 300_000)
    {
        if let Some(windows) = claude_sources::desktop_windows(p, now) {
            acc.last_desktop_miss = None;
            accepted_windows(p, acc, windows, None, multi);
            return;
        }
        acc.last_desktop_miss = Some(now);
    }
    let reusable_cli = acc
        .cli_cache
        .as_ref()
        .filter(|(windows, at, _)| {
            now.saturating_sub(*at) < 300_000
                && !windows
                    .iter()
                    .any(|w| w.resets_at.is_some_and(|reset| reset <= now))
        })
        .map(|(windows, _, plan)| (windows.clone(), plan.clone()));
    if !asking_again {
        if let Some((windows, plan)) = reusable_cli {
            accepted_windows(p, acc, windows, plan, multi);
            return;
        }
    }
    if !asking_again
        && acc
            .last_cli_attempt
            .is_none_or(|at| now.saturating_sub(at) >= 300_000)
    {
        acc.last_cli_attempt = Some(now);
        if let Some(reading) = find_cli().and_then(|cli| claude_sources::run_cli(&cli, p, now)) {
            acc.cli_cache = Some((reading.0.clone(), now, reading.1.clone()));
            accepted_windows(p, acc, reading.0, reading.1, multi);
            return;
        }
    }
    // No requests inside this account's back-off window
    if acc.backoff_until > now_ms() && !asking_again {
        return;
    }
    let credential = credential_for(p, asking_again);
    if p.slug.is_none() {
        if let Ok(ref credential) = credential {
            acc.credential_expiry = credential.expires_at;
        }
    }
    match credential {
        Err(claude_keychain::ReadError::NeedsAuth) => {
            acc.status = "needsAuth".into();
            acc.note = "No Claude Code credential found".into();
        }
        Err(claude_keychain::ReadError::SignedOut) => {
            acc.status = "signedOutByOwner".into();
            acc.windows.clear();
            acc.note = "Claude Code signed out".into();
        }
        Err(claude_keychain::ReadError::Denied) => {
            acc.status = "accessDenied".into();
            acc.windows.clear();
            acc.note = "Claude Keychain access denied".into();
        }
        Err(claude_keychain::ReadError::Transient) => {
            acc.status = if acc.windows.is_empty() {
                "needsAuth"
            } else {
                "stale"
            }
            .into();
            acc.note = "Claude Keychain temporarily unavailable".into();
        }
        // Expired is not signed out: keep the last reading, dimmed and dated, and send nothing
        Ok(cred) if cred.expired(now_ms()) => {
            acc.status = if acc.windows.is_empty() {
                "needsAuth"
            } else {
                "stale"
            }
            .into();
            acc.note = EXPIRED_NOTE.into();
        }
        Ok(cred) => {
            let token = cred.token;
            // On 401 re-read the credential and retry once (Claude Code may have just refreshed it)
            let result = match fetch_once(&token) {
                Err(FetchErr::NeedsAuth) => {
                    claude_keychain::forget_cached(&id);
                    match credential_for(p, false) {
                        Ok(c2) if c2.token != token => fetch_once(&c2.token),
                        _ => Err(FetchErr::NeedsAuth),
                    }
                }
                other => other,
            };
            match result {
                Ok(windows) => {
                    crate::claude_auth::usage_succeeded();
                    acc.consecutive_429 = 0;
                    accepted_windows(p, acc, windows, cred.plan, multi);
                }
                Err(FetchErr::NeedsAuth) => {
                    acc.status = "needsAuth".into();
                    acc.note = "Credential rejected (switched accounts?)".into();
                }
                Err(FetchErr::RateLimited(ra)) => {
                    acc.consecutive_429 += 1;
                    let wait = backoff_secs(acc.consecutive_429 - 1, ra);
                    // The status is left alone: a refused refresh says nothing about the reading we are
                    // holding, which is exactly as old as it was a moment ago. Marking it stale here
                    // dimmed the ring on the first 429, which on Windows is often the first minute of a
                    // rate limit. Age decides, as it does on the Mac (`UsageStore` keeps the previous
                    // status until `staleAfter`), and the note says why it is not moving.
                    acc.note = format!("Rate limited, retrying in {wait}s");
                    acc.backoff_until = now_ms() + wait * 1000;
                }
                Err(FetchErr::Other(msg)) => {
                    // No reading at all is an error worth showing; a reading we could not refresh is
                    // just a reading, and its own age is what makes it stale.
                    if acc.windows.is_empty() {
                        acc.status = "error".into();
                    }
                    acc.note = msg;
                }
            }
        }
    }
}

fn start_default_renewer(app: AppHandle) {
    std::thread::spawn(move || {
        crate::activity::lower_thread_priority();
        let Some(home) = dirs::home_dir() else { return };
        let profile = Profile {
            dir: home.join(".claude"),
            slug: None,
        };
        let cli = find_cli();
        let mut renewer = Renewer::default();
        loop {
            // Swift starts the refresher's 60-second timer without an eager
            // launch. It only runs after this process has learned an expiry.
            std::thread::sleep(Duration::from_secs(60));
            if !crate::providers::enabled(&app, "claude") {
                continue;
            }
            let epoch = crate::providers::generation("claude");
            let expiry = {
                let state = default_renewal().lock().unwrap();
                (state.epoch == epoch).then_some(state.expiry).flatten()
            };
            if expiry.is_none() {
                continue;
            }
            let mut after = None;
            let result =
                renewer.maybe_renew_with(&profile, expiry, cli.as_deref(), run_renewal, || {
                    #[cfg(target_os = "macos")]
                    {
                        claude_keychain::forget_cached("claude");
                        after = credential_for(&profile, false)
                            .ok()
                            .and_then(|fresh| fresh.expires_at);
                    }
                    #[cfg(not(target_os = "macos"))]
                    {
                        after = read_credentials(&profile.dir).and_then(|fresh| fresh.expires_at);
                    }
                    after
                });
            if let Some(succeeded) = result {
                crate::providers::with_current(&app, "claude", epoch, || {
                    let mut state = default_renewal().lock().unwrap();
                    if succeeded {
                        state.expiry = after;
                    } else {
                        state.needs_sign_in = true;
                    }
                });
                if succeeded {
                    request_profile_refresh("claude");
                }
                let _ = app.emit("providers", crate::providers::get_providers(app.clone()));
            }
        }
    });
}

pub fn start(app: AppHandle) {
    start_default_renewer(app.clone());
    std::thread::spawn(move || {
        // The aggregate cache predates per-profile switches. Filter it before
        // the first event, so a disabled secondary account never flashes back.
        let discovered = profiles();
        let persisted = crate::providers::with_lifecycle(|_| {
            let st = app.state::<AppState>();
            let mut snap = st.usage.lock().unwrap().clone();
            let active: Vec<Profile> = discovered
                .iter()
                .filter(|p| crate::providers::enabled(&app, &profile_id(p)))
                .cloned()
                .collect();
            let original_windows = snap.windows.len();
            snap.windows.retain(|w| {
                active.iter().any(|p| match &p.slug {
                    Some(slug) => w.id.ends_with(&format!("@{slug}")),
                    None => !w.id.contains('@'),
                })
            });
            if snap.windows.is_empty() {
                snap = UsageSnapshot::default();
            } else if snap.windows.len() != original_windows {
                snap.status = "stale".into();
                snap.note.clear();
                snap.plan = None;
                snap.fetched_at = active
                    .iter()
                    .map(|p| crate::providers::snapshot(&profile_id(p)).fetched_at)
                    .max()
                    .unwrap_or(0);
                snap.backoff_until = 0;
            }
            *st.usage.lock().unwrap() = snap.clone();
            persist(&snap);
            let _ = app.emit("usage", &snap);
            snap
        });
        let mut accounts: HashMap<String, Account> = HashMap::new();
        for (k, windows) in split_persisted(&persisted, &discovered) {
            accounts.entry(k).or_default().windows = windows;
        }
        loop {
            // A sign-in the user started owns the credential until it finishes. Polling through it
            // reads a file being rewritten and reports a signed-out account mid-login.
            if crate::claude_auth::state().busy {
                std::thread::sleep(Duration::from_secs(2));
                continue;
            }
            let attempted_at = now_ms();
            let targeted = take_refresh_targets();
            // Re-read the list each tick: an account signed into or removed while this runs needs no restart
            let order = profiles();
            let multi = order.len() > 1;
            for p in &order {
                let id = profile_id(p);
                if !crate::providers::enabled(&app, &id) {
                    continue;
                }
                if targeted.as_ref().is_some_and(|ids| !ids.contains(&id)) {
                    continue;
                }
                let epoch = crate::providers::generation(&id);
                let acc = accounts.entry(key(p)).or_default();
                if acc.generation != epoch {
                    *acc = Account {
                        generation: epoch,
                        ..Default::default()
                    };
                }
                if acc.fetched_at == 0 {
                    let old = crate::providers::snapshot(&id);
                    if old.fetched_at > 0 {
                        acc.fetched_at = old.fetched_at;
                        acc.backoff_until = old.backoff_until;
                        acc.status = "stale".into();
                    }
                }
                poll_account(p, acc, multi);
                if id == "claude" {
                    crate::providers::with_current(&app, &id, epoch, || {
                        let mut renewal = default_renewal().lock().unwrap();
                        if renewal.epoch != epoch {
                            renewal.expiry = None;
                        }
                        renewal.epoch = epoch;
                        if let Some(expiry) = acc.credential_expiry {
                            renewal.expiry = Some(expiry);
                        }
                        if acc.status == "ok" {
                            renewal.needs_sign_in = false;
                        }
                    });
                }
                if crate::providers::enabled(&app, &id) {
                    let mut windows = acc.windows.clone();
                    for w in &mut windows {
                        w.id = w.id.split('@').next().unwrap_or(&w.id).to_string();
                    }
                    crate::providers::publish_profile_if_current(
                        &app,
                        &id,
                        epoch,
                        UsageSnapshot {
                            plan: acc.plan.clone(),
                            status: acc.status.clone(),
                            windows,
                            fetched_at: acc.fetched_at,
                            note: acc.note.clone(),
                            backoff_until: acc.backoff_until,
                            ..Default::default()
                        },
                    );
                }
            }
            let backoff_until = crate::providers::with_lifecycle(|epochs| {
                let active: Vec<Profile> = order
                    .iter()
                    .filter(|p| crate::providers::enabled(&app, &profile_id(p)))
                    .cloned()
                    .collect();
                accounts.retain(|k, a| {
                    active.iter().any(|p| {
                        key(p) == *k
                            && a.generation == epochs.get(&profile_id(p)).copied().unwrap_or(0)
                    })
                });
                let snap = aggregate(&active, &accounts);
                let backoff_until = snap.backoff_until;
                set_and_broadcast(&app, |u| *u = snap);
                backoff_until
            });
            // The global activity/reset decision is checked at each 60-second tick. A
            // Claude-only session count would miss a busy Codex/Kimi session and would treat
            // idle or completed Claude sessions as busy. Keep the account backoff wake-up.
            let now = now_ms();
            let secs = if backoff_until > now {
                ((backoff_until - now) / 1000).clamp(1, 30)
            } else {
                POLL_IDLE_SECS
            };
            sleep_interruptible(&app, secs, attempted_at);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    const EXP: u64 = 1_000_000_000;

    #[test]
    fn claude_worker_wait_follows_global_busy_reset_ticks_and_profile_requests() {
        let clock = Cell::new(0_u64);
        let checked = Cell::new(0_u32);
        sleep_interruptible_with(
            POLL_IDLE_SECS,
            0,
            || false,
            |last, now| {
                checked.set(checked.get() + 1);
                crate::providers::remote_due(last, now, now >= 120_000, false)
            },
            || clock.get(),
            || clock.set(clock.get() + 1_000),
        );
        assert_eq!(clock.get(), 120_000, "other-provider activity wakes Claude at a tick");
        assert_eq!(checked.get(), 2);

        clock.set(0);
        sleep_interruptible_with(
            POLL_IDLE_SECS,
            0,
            || false,
            |last, now| crate::providers::remote_due(last, now, false, now >= 60_000),
            || clock.get(),
            || clock.set(clock.get() + 1_000),
        );
        assert_eq!(clock.get(), 60_000, "a reset wakes Claude without a busy session");

        clock.set(0);
        sleep_interruptible_with(
            POLL_IDLE_SECS,
            0,
            || clock.get() >= 10_000,
            |_, _| panic!("targeted profile request must interrupt before the first tick"),
            || clock.get(),
            || clock.set(clock.get() + 1_000),
        );
        assert_eq!(clock.get(), 10_000);

        clock.set(0);
        sleep_interruptible_with(
            30,
            0,
            || false,
            |_, _| panic!("backoff's short wake remains bounded before the first tick"),
            || clock.get(),
            || clock.set(clock.get() + 1_000),
        );
        assert_eq!(clock.get(), 30_000);

        clock.set(0);
        sleep_interruptible_with(
            POLL_IDLE_SECS,
            0,
            || false,
            |last, now| crate::providers::remote_due(last, now, false, false),
            || clock.get(),
            || clock.set(clock.get() + 1_000),
        );
        assert_eq!(clock.get(), 300_000, "idle cadence remains five minutes");
    }

    #[test]
    fn archived_claude_reading_is_stale_without_changing_its_age() {
        let old = UsageSnapshot {
            status: "ok".into(),
            fetched_at: 1234,
            windows: vec![LimitWindow {
                id: "session".into(),
                used: 0.42,
                has_fraction: Some(true),
                ..Default::default()
            }],
            ..Default::default()
        };
        let restored = rehydrate_archive(old);
        assert_eq!(restored.status, "stale");
        assert_eq!(restored.fetched_at, 1234);
        assert_eq!(restored.windows[0].fraction(), Some(0.42));
    }

    #[test]
    fn named_profile_discovery_requires_marker_and_own_credential() {
        let home = tempfile::tempdir().unwrap();
        for (name, marker) in [
            (".claude-work", "sessions"),
            (".claude-expired", "history.jsonl"),
            (".claude-日本語", "projects"),
            (".claude-mem", "settings.json"),
            (".claude-unused", ""),
        ] {
            let dir = home.path().join(name);
            std::fs::create_dir_all(&dir).unwrap();
            match marker {
                "sessions" | "projects" => std::fs::create_dir_all(dir.join(marker)).unwrap(),
                "" => (),
                _ => std::fs::write(dir.join(marker), "{}").unwrap(),
            }
        }
        let rows = discover_named_profiles_with(home.path(), |slug, _| slug != "mem");
        let slugs: Vec<_> = rows.iter().map(|(slug, _)| slug.as_str()).collect();
        assert_eq!(slugs, ["expired", "work", "日本語"]);
    }

    #[test]
    fn one_claude_ring_does_not_turn_into_an_all_account_refresh() {
        let mut requests = RefreshRequests::default();
        requests.profiles.insert("claude-work".into());
        let targets = requests.take_targets().expect("one targeted refresh");
        assert!(targets.contains("claude-work"));
        assert!(!targets.contains("claude"));
        assert!(!targets.contains("claude-personal"));
        requests.profiles.insert("claude-work".into());
        requests.all = true;
        assert!(
            requests.take_targets().is_none(),
            "Refresh All overrides rings"
        );
        assert!(requests.profiles.is_empty());
    }

    #[test]
    fn renews_only_inside_the_margin() {
        assert!(
            !should_renew(None, EXP, None, None),
            "never launch on a guess"
        );
        assert!(
            !should_renew(Some(EXP), EXP - RENEW_MARGIN_MS - 1, None, None),
            "plenty of time left"
        );
        assert!(should_renew(
            Some(EXP),
            EXP - RENEW_MARGIN_MS + 1,
            None,
            None
        ));
        assert!(
            should_renew(Some(EXP), EXP + 3_600_000, None, None),
            "already expired still renews"
        );
    }

    #[test]
    fn a_new_token_waits_out_the_cooldown() {
        let now = EXP + 1;
        assert!(
            !should_renew(Some(EXP + 5), now, Some(EXP), Some(now - 1000)),
            "cooldown holds a new token back"
        );
        assert!(should_renew(
            Some(EXP + 5),
            now,
            Some(EXP),
            Some(now - RENEW_COOLDOWN_MS)
        ));
    }

    #[test]
    fn one_failed_expiry_is_never_relaunched_until_the_token_changes() {
        let now = EXP + 1;
        assert!(!should_renew(
            Some(EXP),
            now,
            Some(EXP),
            Some(now - 24 * 60 * 60 * 1000)
        ));
        assert!(should_renew(
            Some(EXP + 1),
            now,
            Some(EXP),
            Some(now - RENEW_COOLDOWN_MS)
        ));
    }

    #[test]
    fn refresher_launches_only_for_default_profile_with_fake_cli() {
        let expiry = now_ms().saturating_add(1_000);
        let mut launches = 0;
        let cli = Path::new("/fixture/claude");
        let mut renewer = Renewer::default();
        let result = renewer.maybe_renew_with(
            &prof(Some("work")),
            Some(expiry),
            Some(cli),
            |_, _| {
                launches += 1;
                Ok(())
            },
            || Some(expiry + 60_000),
        );
        assert_eq!(result, None);
        assert_eq!(launches, 0);
        let result = renewer.maybe_renew_with(
            &prof(None),
            Some(expiry),
            Some(cli),
            |_, _| {
                launches += 1;
                Ok(())
            },
            || Some(expiry + 60_000),
        );
        assert_eq!(result, Some(true));
        assert_eq!(launches, 1);
    }

    #[test]
    fn retry_after_never_exceeds_the_cap() {
        assert_eq!(backoff_secs(0, 3600), 3600);
        assert_eq!(backoff_secs(0, 0), BACKOFF_BASE_SECS);
        assert_eq!(backoff_secs(1, 300), 300);
        assert_eq!(backoff_secs(9, 0), BACKOFF_CAP_SECS);
    }

    #[test]
    fn desktop_bundled_cli_is_refused() {
        use std::path::Path;
        assert!(is_desktop_owned(Path::new(
            r"C:\Users\u\AppData\Local\AnthropicClaude\app-1.2.3\claude.exe"
        )));
        assert!(is_desktop_owned(Path::new(
            r"C:\Users\u\AppData\Roaming\Claude\claude-code\2.1.0\claude.exe"
        )));
        assert!(!is_desktop_owned(Path::new(
            r"C:\Users\u\.local\bin\claude.exe"
        )));
        assert!(!is_desktop_owned(Path::new(
            r"C:\Users\u\AppData\Roaming\npm\claude.cmd"
        )));
    }

    #[test]
    #[ignore = "Runs the installed standalone claude CLI; opt in for integration verification"]
    fn live_renewal_runs_the_standalone_cli() {
        let cli = find_cli().expect("a standalone claude CLI");
        assert!(!is_desktop_owned(&cli));
        let p = profiles().into_iter().next().expect("a profile");
        let before = read_credentials(&p.dir).and_then(|c| c.expires_at);
        let t = std::time::Instant::now();
        run_renewal(&cli, &p.dir).expect("spawned");
        assert!(
            t.elapsed() < Duration::from_secs(RENEW_TIMEOUT_SECS),
            "returned before the timeout"
        );
        let after = read_credentials(&p.dir).and_then(|c| c.expires_at);
        assert!(after >= before, "the expiry never moves backwards");
        eprintln!("cli: {}", cli.display());
    }

    fn prof(slug: Option<&str>) -> Profile {
        Profile {
            dir: PathBuf::from(match slug {
                Some(s) => format!("/home/u/.claude-{s}"),
                None => "/home/u/.claude".to_string(),
            }),
            slug: slug.map(String::from),
        }
    }

    fn win(id: &str) -> LimitWindow {
        LimitWindow {
            id: id.into(),
            label: "Current session".into(),
            used: 0.5,
            ..Default::default()
        }
    }

    #[test]
    fn one_account_reads_exactly_as_before() {
        let w = decorate(vec![win("session")], &prof(None), None);
        assert_eq!(w[0].id, "session", "the only account keeps its ids");
        assert_eq!(
            w[0].group, None,
            "and stays ungrouped, so its card is the card that shipped"
        );
    }

    #[test]
    fn a_second_account_is_suffixed_and_grouped() {
        let w = decorate(
            vec![win("session")],
            &prof(Some("work")),
            Some("work · pro"),
        );
        assert_eq!(
            w[0].id, "session@work",
            "so by_id(\"session\") still means the default account"
        );
        assert_eq!(w[0].group.as_deref(), Some("work · pro"));
    }

    #[test]
    fn the_group_pairs_the_name_with_the_plan() {
        assert_eq!(prof(None).group(Some("max")), "default · max");
        assert_eq!(prof(Some("work")).group(None), "work");
        assert_eq!(
            prof(Some("work")).group(Some("")),
            "work",
            "an empty plan adds no separator"
        );
    }

    #[test]
    fn persisted_windows_go_back_to_the_account_that_made_them() {
        let order = vec![prof(None), prof(Some("work"))];
        let snap = UsageSnapshot {
            windows: vec![win("session"), win("session@work"), win("weekly@gone")],
            ..Default::default()
        };
        let split = split_persisted(&snap, &order);
        assert_eq!(split[&key(&order[0])].len(), 1);
        assert_eq!(split[&key(&order[1])][0].id, "session@work");
        assert_eq!(
            split.len(),
            2,
            "windows from an account that is gone are dropped"
        );
    }

    #[test]
    fn status_is_the_best_news_any_account_has() {
        let order = vec![prof(None), prof(Some("work"))];
        let mut accounts: HashMap<String, Account> = HashMap::new();
        accounts.insert(
            key(&order[0]),
            Account {
                status: "ok".into(),
                windows: vec![win("session")],
                fetched_at: 10,
                ..Default::default()
            },
        );
        accounts.insert(
            key(&order[1]),
            Account {
                status: "needsAuth".into(),
                note: "No Claude Code credential found".into(),
                ..Default::default()
            },
        );
        let snap = aggregate(&order, &accounts);
        assert_eq!(
            snap.status, "ok",
            "a signed-out second account must not dim the first"
        );
        assert_eq!(snap.windows.len(), 1);
        assert_eq!(snap.fetched_at, 10);
        assert!(
            snap.note.starts_with("work: "),
            "the note names the account: {}",
            snap.note
        );
    }

    #[test]
    fn the_soonest_back_off_is_the_one_waited_out() {
        let order = vec![prof(None), prof(Some("work"))];
        let mut accounts: HashMap<String, Account> = HashMap::new();
        accounts.insert(
            key(&order[0]),
            Account {
                backoff_until: 900,
                ..Default::default()
            },
        );
        accounts.insert(
            key(&order[1]),
            Account {
                backoff_until: 300,
                ..Default::default()
            },
        );
        assert_eq!(aggregate(&order, &accounts).backoff_until, 300);
    }

    #[test]
    fn the_default_account_is_first_and_always_listed() {
        // Discovery reads the real home, so this asserts only what holds on any machine
        let list = profiles();
        assert!(
            !list.is_empty(),
            "the default account is listed even with no credential"
        );
        assert_eq!(list[0].slug, None, "and comes first, so it owns the notch");
        let slugs: Vec<Option<String>> = list.iter().skip(1).map(|p| p.slug.clone()).collect();
        let mut sorted = slugs.clone();
        sorted.sort();
        assert_eq!(slugs, sorted, "secondary accounts are listed in name order");
        assert!(
            list.iter().skip(1).all(|p| p.slug.is_some()),
            "only the default account has no slug"
        );
    }

    #[test]
    fn expired_is_judged_against_now() {
        let c = Credential {
            token: "t".into(),
            expires_at: Some(EXP),
            ..Default::default()
        };
        assert!(c.expired(EXP));
        assert!(!c.expired(EXP - 1));
        assert!(!Credential {
            token: "t".into(),
            expires_at: None,
            ..Default::default()
        }
        .expired(EXP));
    }
}
