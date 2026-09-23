//! Four-state machine: attention > running > done > idle (ordered by attention cost).
//! done persists: it is cleared only by a new UserPromptSubmit for that session, the user's ✕, or the > 24 h stale sweep.

use serde::Serialize;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::time::{SystemTime, UNIX_EPOCH};

pub const ST_RUNNING: &str = "running";
pub const ST_ATTENTION: &str = "attention";
pub const ST_DONE: &str = "done";
pub const ST_IDLE: &str = "idle";

const RUNNING_STALE_MS: u64 = 30 * 60 * 1000; // running with no event for 30 min is treated as an abnormal exit
const DONE_STALE_MS: u64 = 24 * 3600 * 1000; // stale done entries are removed after 24 h
const IDLE_DROP_MS: u64 = 10 * 60 * 1000; // idle entries leave the list after 10 min
/// A session that crashed while waiting on you never sends another event, and attention was never
/// swept, so its card stayed up for good (#165). A day is longer than anyone leaves a real question.
const ATTENTION_STALE_MS: u64 = 24 * 3600 * 1000;
/// Sessions kept at once. Far above any real number of open terminals; it only bounds what a
/// misbehaving or hostile local sender could make the store hold.
const MAX_SESSIONS: usize = 200;
/// A working directory longer than this is not a real one; it is only kept for the card's title.
const MAX_CWD_CHARS: usize = 1024;

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Session {
    pub id: String,
    pub provider: String,
    pub title: String,
    pub state: String,
    /// Start of the current activity (ms epoch)
    pub started: u64,
    /// Total elapsed time frozen at done (ms)
    pub total: u64,
    pub last: String,
    /// What attention is about (permission request / question summary)
    pub attn: String,
    /// The user's latest input (card subtitle: "you: …" — show what you said rather than the agent's action)
    pub prompt: String,
    /// The model the session actually uses (message.model of a transcript assistant entry)
    pub model: String,
    #[serde(skip)]
    pub ppid: u32,
    #[serde(skip)]
    pub last_event: u64,
    #[serde(skip)]
    pub cwd: String,
    /// Time of the last real hook event; watcher inference is ignored while hook data is fresh
    #[serde(skip)]
    pub last_hook: u64,
}

/// Hook data is considered fresh within this window, and watcher inference yields to it
const HOOK_FRESH_MS: u64 = 5 * 60 * 1000;

#[derive(Debug, Clone, Serialize)]
pub struct Snapshot {
    pub sessions: Vec<Session>,
    pub agg: String,
    pub counts: HashMap<String, usize>,
    /// The language the user chose (may be "auto"; used to highlight the menu item)
    pub lang: String,
    /// The actual language resolved on the Rust side (WebView2's navigator.language is unreliable)
    pub lang_resolved: String,
    /// Whether reset times use a 24-hour clock, from the Windows region settings
    pub clock_24h: bool,
    /// Whether dragging / wheel resizing is allowed (the page enables the gestures from it)
    pub drag: bool,
}

#[derive(Default)]
pub struct Store {
    map: HashMap<String, Session>,
    registry: HashMap<String, Session>,
    registry_provider: HashMap<String, String>,
    registry_session_ids: HashSet<String>,
    registry_seen_ids: HashMap<String, u64>,
}

pub struct HookEvent {
    pub e: String,
    pub session_id: String,
    pub ppid: u32,
    pub cwd: String,
    pub prompt: String,
    pub message: String,
    pub tool_name: String,
    pub tool_cmd: String,
    pub model: String,
    /// "hook" (a real event) or "watch" (transcript inference, the desktop app's fallback)
    pub src: &'static str,
}

fn truncate(s: &str, n: usize) -> String {
    let mut out: String = s.chars().take(n).collect();
    if s.chars().count() > n {
        out.push('…');
    }
    out
}

fn title_of(cwd: &str, id: &str) -> String {
    let base = cwd
        .replace('\\', "/")
        .rsplit('/')
        .find(|p| !p.is_empty())
        .unwrap_or("claude")
        .to_string();
    let short: String = id.chars().take(4).collect();
    format!("{base} · {short}")
}

impl Store {
    /// The process registry is authoritative while a PID is live. Its session ID
    /// suppresses the matching hook/transcript row, so one Claude turn is not
    /// drawn twice. A dead process disappears at the next monitor tick.
    pub fn replace_registry(
        &mut self,
        rows: Vec<crate::claude_session_monitor::LiveSession>,
    ) -> bool {
        let now = now_ms();
        let mut registry = HashMap::new();
        let mut provider = HashMap::new();
        let mut ids = HashSet::new();
        for row in rows {
            provider.insert(row.id.clone(), row.provider.clone());
            if let Some(id) = row.session_id.as_ref() {
                ids.insert(id.clone());
            }
            let state = match row.state {
                "busy" => ST_RUNNING,
                "waiting" => ST_ATTENTION,
                _ => ST_IDLE,
            };
            registry.insert(
                row.id.clone(),
                Session {
                    id: row.id,
                    provider: row.provider,
                    title: row.name,
                    state: state.into(),
                    started: row.since,
                    total: 0,
                    last: row.detail,
                    attn: row.waiting_for.unwrap_or_default(),
                    prompt: String::new(),
                    model: String::new(),
                    ppid: row.pid,
                    last_event: now,
                    cwd: row.cwd,
                    last_hook: 0,
                },
            );
        }
        // last_event is internal bookkeeping, not a UI change.
        let visible = |map: &HashMap<String, Session>| {
            map.iter()
                .map(|(id, s)| {
                    (
                        id.clone(),
                        (
                            s.title.clone(),
                            s.provider.clone(),
                            s.state.clone(),
                            s.started,
                            s.last.clone(),
                            s.attn.clone(),
                            s.ppid,
                        ),
                    )
                })
                .collect::<HashMap<_, _>>()
        };
        let changed =
            visible(&self.registry) != visible(&registry) || self.registry_session_ids != ids;
        for id in &ids {
            self.map.remove(id);
        }
        self.registry_seen_ids
            .retain(|_, seen| now.saturating_sub(*seen) <= 10 * 60 * 1000);
        for id in &ids {
            self.registry_seen_ids.insert(id.clone(), now);
        }
        self.registry = registry;
        self.registry_provider = provider;
        self.registry_session_ids = ids;
        changed
    }
    pub fn clear_provider_sessions(&mut self, provider: &str) -> bool {
        let ids: Vec<String> = self
            .registry_provider
            .iter()
            .filter(|(_, p)| p.as_str() == provider)
            .map(|(id, _)| id.clone())
            .collect();
        let mut changed = false;
        for id in ids {
            changed |= self.registry.remove(&id).is_some();
            self.registry_provider.remove(&id);
        }
        if provider == "claude" {
            changed |= !self.map.is_empty();
            self.map.clear();
        }
        changed
    }
    pub fn apply(&mut self, ev: HookEvent) -> bool {
        let now = now_ms();
        // A registry-backed turn ends with its process. A delayed watcher tail
        // must not resurrect a 24-hour done/attention row after the PID exits.
        if ev.src == "watch" && self.registry_seen_ids.contains_key(&ev.session_id) {
            return false;
        }
        if self.registry_session_ids.contains(&ev.session_id) {
            return false;
        }
        if ev.e == "session_end" {
            return self.map.remove(&ev.session_id).is_some();
        }
        let cwd: String = ev.cwd.chars().take(MAX_CWD_CHARS).collect();
        if !self.map.contains_key(&ev.session_id) && self.map.len() >= MAX_SESSIONS {
            // Full: the session heard from longest ago makes room.
            if let Some(oldest) = self
                .map
                .iter()
                .min_by_key(|(_, s)| s.last_event)
                .map(|(k, _)| k.clone())
            {
                self.map.remove(&oldest);
            }
        }
        let s = self
            .map
            .entry(ev.session_id.clone())
            .or_insert_with(|| Session {
                id: ev.session_id.clone(),
                provider: "claude".into(),
                title: title_of(&cwd, &ev.session_id),
                state: ST_IDLE.into(),
                started: now,
                total: 0,
                last: String::new(),
                attn: String::new(),
                prompt: String::new(),
                model: String::new(),
                ppid: 0,
                last_event: now,
                cwd: cwd.clone(),
                last_hook: 0,
            });
        // Source arbitration: a session with fresh hook data does not accept watcher inference
        if ev.src == "watch" && s.last_hook > 0 && now.saturating_sub(s.last_hook) < HOOK_FRESH_MS {
            return false;
        }
        if ev.src == "hook" {
            s.last_hook = now;
        }
        let before = (
            s.state.clone(),
            s.last.clone(),
            s.attn.clone(),
            s.prompt.clone(),
            s.model.clone(),
        );
        s.last_event = now;
        if ev.ppid != 0 {
            s.ppid = ev.ppid;
        }
        if !ev.model.is_empty() {
            s.model = ev.model.clone();
        }
        if !cwd.is_empty() && s.cwd.is_empty() {
            s.cwd = cwd.clone();
            s.title = title_of(&cwd, &s.id);
        }
        match ev.e.as_str() {
            "session_start" => {
                if s.state != ST_RUNNING {
                    s.state = ST_IDLE.into();
                }
            }
            "running" => {
                if s.state != ST_RUNNING {
                    s.started = now;
                }
                s.state = ST_RUNNING.into();
                s.attn.clear();
                if !ev.prompt.is_empty() {
                    s.prompt = truncate(&ev.prompt, 120);
                }
                if !ev.tool_name.is_empty() {
                    s.last = if ev.tool_cmd.is_empty() {
                        format!("🔧 {}", ev.tool_name)
                    } else {
                        format!("🔧 {}: {}", ev.tool_name, truncate(&ev.tool_cmd, 60))
                    };
                }
            }
            "attention" => {
                s.state = ST_ATTENTION.into();
                if !ev.message.is_empty() {
                    s.attn = truncate(&ev.message, 200);
                }
            }
            "done" => {
                if s.state != ST_DONE {
                    s.total = now.saturating_sub(s.started);
                }
                s.state = ST_DONE.into();
                s.attn.clear();
            }
            _ => {}
        }
        // Broadcast only on a visible change, so the watcher's rapid appends cannot cause a storm
        (
            s.state.clone(),
            s.last.clone(),
            s.attn.clone(),
            s.prompt.clone(),
            s.model.clone(),
        ) != before
    }

    pub fn dismiss(&mut self, id: &str) -> bool {
        self.map.remove(id).is_some() || self.registry.remove(id).is_some()
    }

    pub fn has_done(&self) -> bool {
        self.map.values().any(|s| s.state == ST_DONE)
    }

    /// Seen-clears-it: done sessions matching the predicate become idle (and the sweep removes them later)
    pub fn ack_done<F: Fn(&Session) -> bool>(&mut self, f: F) -> bool {
        let now = now_ms();
        let mut changed = false;
        for s in self.map.values_mut() {
            if s.state == ST_DONE && f(s) {
                s.state = ST_IDLE.into();
                s.last_event = now;
                changed = true;
            }
        }
        changed
    }

    /// Stale sweep; returns whether anything changed
    pub fn sweep(&mut self) -> bool {
        let now = now_ms();
        let mut changed = false;
        for s in self.map.values_mut() {
            if s.state == ST_RUNNING && now.saturating_sub(s.last_event) > RUNNING_STALE_MS {
                s.state = ST_IDLE.into();
                changed = true;
            }
        }
        let before = self.map.len();
        self.map.retain(|_, s| {
            !(s.state == ST_IDLE && now.saturating_sub(s.last_event) > IDLE_DROP_MS
                || s.state == ST_DONE && now.saturating_sub(s.last_event) > DONE_STALE_MS
                || s.state == ST_ATTENTION && now.saturating_sub(s.last_event) > ATTENTION_STALE_MS)
        });
        changed || self.map.len() != before
    }

    pub fn ppid_of(&self, id: &str) -> Option<u32> {
        self.map
            .get(id)
            .or_else(|| self.registry.get(id))
            .map(|s| s.ppid)
            .filter(|p| *p != 0)
    }

    pub fn snapshot(
        &self,
        lang: &str,
        lang_resolved: &str,
        clock_24h: bool,
        drag: bool,
    ) -> Snapshot {
        self.snapshot_filtered(lang, lang_resolved, clock_24h, drag, &BTreeSet::new())
    }

    pub fn snapshot_filtered(
        &self,
        lang: &str,
        lang_resolved: &str,
        clock_24h: bool,
        drag: bool,
        disabled: &BTreeSet<String>,
    ) -> Snapshot {
        let mut sessions: Vec<Session> = self
            .map
            .iter()
            .filter(|(id, s)| {
                !disabled.contains(&s.provider) && !self.registry_session_ids.contains(*id)
            })
            .map(|(_, s)| s.clone())
            .chain(
                self.registry
                    .iter()
                    .filter(|(_, s)| !disabled.contains(&s.provider))
                    .map(|(_, s)| s.clone()),
            )
            .collect();
        let rank = |st: &str| match st {
            ST_ATTENTION => 0,
            ST_RUNNING => 1,
            ST_DONE => 2,
            _ => 3,
        };
        sessions.sort_by(|a, b| {
            rank(&a.state)
                .cmp(&rank(&b.state))
                .then(b.started.cmp(&a.started))
        });
        let mut counts = HashMap::new();
        for k in [ST_ATTENTION, ST_RUNNING, ST_DONE] {
            counts.insert(
                k.to_string(),
                sessions.iter().filter(|s| s.state == k).count(),
            );
        }
        let agg = [ST_ATTENTION, ST_RUNNING, ST_DONE]
            .iter()
            .find(|k| counts.get(**k).copied().unwrap_or(0) > 0)
            .map(|k| k.to_string())
            .unwrap_or_else(|| ST_IDLE.to_string());
        Snapshot {
            sessions,
            agg,
            counts,
            lang: lang.to_string(),
            lang_resolved: lang_resolved.to_string(),
            clock_24h,
            drag,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn live_registry_replaces_same_transcript_and_death_does_not_restore_it() {
        let mut store = Store::default();
        store.apply(event("running", "session-a", "/tmp/work"));
        assert!(
            store.replace_registry(vec![crate::claude_session_monitor::LiveSession {
                id: "claude.42".into(),
                session_id: Some("session-a".into()),
                provider: "claude".into(),
                name: "work".into(),
                detail: "Terminal · work".into(),
                state: "waiting",
                waiting_for: Some("permission".into()),
                since: 1234,
                pid: 42,
                cwd: "/tmp/work".into(),
            }])
        );
        let snapshot = store.snapshot("en", "en", true, false);
        assert_eq!(snapshot.sessions.len(), 1);
        assert_eq!(snapshot.sessions[0].id, "claude.42");
        assert_eq!(snapshot.sessions[0].state, ST_ATTENTION);
        assert_eq!(store.ppid_of("claude.42"), Some(42));
        let disabled = ["claude".to_string()].into_iter().collect();
        assert!(store
            .snapshot_filtered("en", "en", true, false, &disabled)
            .sessions
            .is_empty());
        assert!(store.replace_registry(Vec::new()));
        let mut delayed = event("done", "session-a", "/tmp/work");
        delayed.src = "watch";
        assert!(!store.apply(delayed));
        assert!(store.snapshot("en", "en", true, false).sessions.is_empty());
    }

    #[test]
    fn disconnect_removes_registry_before_the_next_monitor_tick() {
        let mut store = Store::default();
        store.replace_registry(vec![crate::claude_session_monitor::LiveSession {
            id: "claude-work.77".into(),
            session_id: Some("work-session".into()),
            provider: "claude-work".into(),
            name: "work".into(),
            detail: "Terminal · work".into(),
            state: "busy",
            waiting_for: None,
            since: 100,
            pid: 77,
            cwd: "/tmp/work".into(),
        }]);
        assert!(store.clear_provider_sessions("claude-work"));
        assert!(store.snapshot("en", "en", true, false).sessions.is_empty());
    }

    fn event(e: &str, id: &str, cwd: &str) -> HookEvent {
        HookEvent {
            e: e.into(),
            session_id: id.into(),
            ppid: 0,
            cwd: cwd.into(),
            prompt: String::new(),
            message: String::new(),
            tool_name: String::new(),
            tool_cmd: String::new(),
            model: String::new(),
            src: "hook",
        }
    }

    #[test]
    fn the_store_never_holds_more_than_its_cap() {
        let mut store = Store::default();
        for n in 0..(MAX_SESSIONS + 50) {
            store.apply(event("session_start", &format!("s{n}"), "C:/work"));
        }
        assert_eq!(store.map.len(), MAX_SESSIONS);
        assert!(
            store.map.contains_key(&format!("s{}", MAX_SESSIONS + 49)),
            "the newest session must be kept"
        );
    }

    #[test]
    fn a_working_directory_is_capped() {
        let mut store = Store::default();
        let long = "x".repeat(MAX_CWD_CHARS * 4);
        store.apply(event("session_start", "s", &long));
        assert_eq!(store.map["s"].cwd.chars().count(), MAX_CWD_CHARS);
    }

    #[test]
    fn an_abandoned_attention_card_is_swept() {
        let mut store = Store::default();
        store.apply(event("session_start", "s", "C:/work"));
        let s = store.map.get_mut("s").unwrap();
        s.state = ST_ATTENTION.into();
        s.last_event = now_ms().saturating_sub(ATTENTION_STALE_MS + 1000);
        assert!(store.sweep());
        assert!(!store.map.contains_key("s"));
    }

    #[test]
    fn a_fresh_attention_card_stays() {
        let mut store = Store::default();
        store.apply(event("session_start", "s", "C:/work"));
        store.map.get_mut("s").unwrap().state = ST_ATTENTION.into();
        store.sweep();
        assert!(store.map.contains_key("s"));
    }
}
