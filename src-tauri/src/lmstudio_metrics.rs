//! LM Studio metrics from its own SDK state and server log. This reads only connected local
//! runtimes, never sends inference traffic, and stores numeric metadata only.
use crate::{lmstudio_link::{Instance, Link, Processing}, lmstudio_log::{Event, Tail}, local_metrics::{Ledger, LedgerSummary, Performance}};
use serde::Serialize;
use serde_json::{json, Value};
use std::{collections::BTreeMap, sync::{Arc, Mutex, OnceLock, atomic::{AtomicBool, AtomicU64, Ordering}}, time::Duration};

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Activity { pub phase: String, pub queued: u32, pub since: u64 }
#[derive(Clone, Debug, Serialize)]
pub struct Status {
    pub status: String,
    pub linked: bool,
    pub history_loaded: bool,
    pub activities: BTreeMap<String, Activity>,
    pub performances: BTreeMap<String, Performance>,
    pub today: crate::local_metrics::LedgerTotals,
    pub model_count: usize,
}
impl Default for Status {
    fn default() -> Self {
        Self { status: "Off".into(), linked: false, history_loaded: false,
            activities: BTreeMap::new(), performances: BTreeMap::new(),
            today: Default::default(), model_count: 0 }
    }
}
#[derive(Default)]
struct State {
    public: Status,
    ledger: Ledger,
    generating: BTreeMap<String, u64>,
    finished: BTreeMap<String, (u64, u64)>,
}
#[derive(Default)]
struct Controller {
    endpoint: String,
    worker: Option<tauri::async_runtime::JoinHandle<()>>,
    cancel: Option<Arc<AtomicBool>>,
}
static CONTROLLER: OnceLock<Mutex<Controller>> = OnceLock::new();
static STATE: OnceLock<Mutex<State>> = OnceLock::new();
static GENERATION: AtomicU64 = AtomicU64::new(1);
fn controller() -> &'static Mutex<Controller> { CONTROLLER.get_or_init(|| Mutex::new(Controller::default())) }
fn state() -> &'static Mutex<State> { STATE.get_or_init(|| Mutex::new(State::default())) }
fn with_current(generation: u64, f: impl FnOnce(&mut State)) {
    let mut state = state().lock().unwrap();
    if GENERATION.load(Ordering::Acquire) == generation { f(&mut state); }
}
pub fn status() -> Status {
    let state = state().lock().unwrap();
    let mut public = state.public.clone();
    if let Some(today) = crate::local_metrics::local_day_start(crate::now_ms()) {
        public.today = state.ledger.total_today(today);
    }
    public
}
pub fn is_busy() -> bool { !state().lock().unwrap().public.activities.is_empty() }
pub fn performance(cell: &str) -> Option<Performance> { state().lock().unwrap().public.performances.get(cell).cloned() }
pub fn ledger_summary(cell: &str, now: u64) -> Option<LedgerSummary> {
    let day = crate::local_metrics::local_day_start(now)?;
    state().lock().unwrap().ledger.summary(cell, day)
}

pub fn configure(enabled: bool, endpoint: &str) {
    let mut control = controller().lock().unwrap();
    if enabled && control.endpoint == endpoint
        && control.worker.as_ref().is_some_and(|worker| !worker.inner().is_finished()) { return; }
    if let Some(cancel) = control.cancel.take() { cancel.store(true, Ordering::Release); }
    if let Some(worker) = control.worker.take() { worker.abort(); }
    let generation = {
        let mut state = state().lock().unwrap();
        let generation = GENERATION.fetch_add(1, Ordering::AcqRel) + 1;
        *state = State::default();
        state.public.status = if enabled { "Connecting…".into() } else { "Off".into() };
        generation
    };
    control.endpoint.clear();
    if !enabled { return; }
    if crate::local_runtime::endpoint(endpoint).is_err() {
        state().lock().unwrap().public.status = "Invalid LM Studio address".into();
        return;
    }
    control.endpoint = endpoint.into();
    let endpoint = endpoint.to_owned();
    let cancel = Arc::new(AtomicBool::new(false));
    control.cancel = Some(cancel.clone());
    control.worker = Some(tauri::async_runtime::spawn(async move {
        let log = log_loop(generation, cancel.clone());
        let socket = socket_loop(generation, endpoint);
        tokio::join!(log, socket);
    }));
}

async fn socket_loop(generation: u64, endpoint: String) {
    let Ok(mut link) = Link::new(&endpoint) else { return; };
    let mut known: Option<(u64, Vec<Instance>)> = None;
    let mut retry_after = 0;
    let mut timer = tokio::time::interval(Duration::from_millis(400));
    timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        timer.tick().await;
        if GENERATION.load(Ordering::Acquire) != generation { break; }
        let now = crate::now_ms();
        if now < retry_after { continue; }
        let response: Result<(Vec<Instance>, BTreeMap<String, Processing>), String> = async {
            let instances = if let Some((at, list)) = &known {
                if now.saturating_sub(*at) < 5_000 { list.clone() }
                else { parse_instances(&mut link).await? }
            } else { parse_instances(&mut link).await? };
            if known.as_ref().is_none_or(|(at,_)| now.saturating_sub(*at) >= 5_000) {
                known = Some((now, instances.clone()));
            }
            let mut states = BTreeMap::new();
            for instance in &instances {
                let result = link.call("getInstanceProcessingState", Some(json!({
                    "specifier":{"type":"instanceReference","instanceReference":instance.reference},
                    "throwIfNotFound":true
                }))).await?;
                if let Some(state) = crate::lmstudio_link::parse_processing(&result) {
                    states.insert(instance.identifier.clone(), state);
                }
            }
            Ok((instances, states))
        }.await;
        match response {
            Ok((instances, states)) => with_current(generation, |current| observe(current, &instances, &states, now)),
            Err(error) => {
                link.close();
                known = None;
                retry_after = now.saturating_add(2_000);
                with_current(generation, |current| {
                    current.public.linked = false;
                    current.public.status = error;
                    current.public.activities.clear();
                    current.generating.clear();
                    current.finished.clear();
                });
            }
        }
    }
}

async fn parse_instances(link: &mut Link) -> Result<Vec<Instance>, String> {
    let result = link.call("listLoaded", None).await?;
    if !result.is_array() { return Err("LM Studio model inventory is invalid".into()); }
    Ok(crate::lmstudio_link::parse_instances(&result))
}

fn observe(current: &mut State, instances: &[Instance], states: &BTreeMap<String, Processing>, now: u64) {
    let mut activity = BTreeMap::new();
    let mut loaded = std::collections::BTreeSet::new();
    for instance in instances {
        loaded.insert(instance.identifier.clone());
        let Some(state) = states.get(&instance.identifier) else { continue; };
        let cell = format!("lmstudio:model:{}", instance.identifier);
        if let Some(phase) = state.phase {
            let since = current.public.activities.get(&cell)
                .filter(|old| old.phase == phase).map(|old| old.since).unwrap_or(now);
            activity.insert(cell, Activity { phase: phase.into(), queued: state.queued, since });
        }
        if state.generating {
            current.generating.entry(instance.identifier.clone()).or_insert(now);
        } else if let Some(start) = current.generating.remove(&instance.identifier) {
            current.finished.insert(instance.identifier.clone(), (start, now));
        }
    }
    current.generating.retain(|id,_| loaded.contains(id));
    current.public.activities = activity;
    current.public.linked = true;
    current.public.model_count = instances.len();
    current.public.status = format!("Connected · {} loaded", instances.len());
}

async fn log_loop(generation: u64, cancel: Arc<AtomicBool>) {
    let root = dirs::home_dir().unwrap_or_default().join(".lmstudio/server-logs");
    let history = tokio::task::spawn_blocking(move || {
        let mut tail = Tail::with_cancel(root, cancel);
        let mut historical = State::default();
        tail.load_history(|event| absorb(&mut historical, event, false, crate::now_ms()));
        (tail, historical)
    }).await;
    let Ok((mut tail, historical)) = history else { return; };
    with_current(generation, |state| {
        state.ledger = historical.ledger;
        state.public.performances = historical.public.performances;
        let today = crate::local_metrics::local_day_start(crate::now_ms()).unwrap_or_default();
        state.public.today = state.ledger.total_today(today);
        state.public.history_loaded = true;
    });
    let mut timer = tokio::time::interval(Duration::from_secs(1));
    timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        timer.tick().await;
        if GENERATION.load(Ordering::Acquire) != generation { break; }
        let result = tokio::task::spawn_blocking(move || {
            let mut events = Vec::new();
            tail.poll(|event| events.push(event));
            (tail, events)
        }).await;
        let Ok((next_tail, events)) = result else { break; };
        tail = next_tail;
        with_current(generation, |state| {
            let now = crate::now_ms();
            for event in events { absorb(state, event, true, now); }
        });
    }
}

fn absorb(state: &mut State, event: Event, live: bool, now: u64) {
    if let Event::Prediction(prediction) = event {
        let cell = format!("lmstudio:model:{}", prediction.instance);
        if let Some(day) = crate::local_metrics::local_day_start(prediction.at) {
            state.ledger.record(&cell, day, prediction.clone());
        }
        let Some(output) = prediction.output_tokens else { return; };
        let at = if live { now } else { prediction.at };
        let measurement = if let Some(rate) = prediction.tokens_per_second {
            Performance::from_parts(output, output as f64 / rate, at, false)
        } else if let Some(seconds) = prediction.generation_seconds {
            Performance::from_parts(output, seconds, at, false)
        } else if live {
            state.finished.remove(&prediction.instance).and_then(|(start,end)| {
                (now.saturating_sub(end) < 5_000 && end > start)
                    .then(|| Performance::from_parts(output,(end-start) as f64 / 1000.,at,true)).flatten()
            })
        } else { None };
        if let Some(measurement) = measurement {
            if state.public.performances.get(&cell).is_none_or(|old| old.measured_at <= measurement.measured_at) {
                state.public.performances.insert(cell, measurement);
            }
        }
        if live {
            let today = crate::local_metrics::local_day_start(now).unwrap_or_default();
            state.public.today = state.ledger.total_today(today);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn polling_preserves_phase_start_and_finalizes_generation_for_fallback_speed() {
        let instance = Instance { identifier:"one".into(), reference:"ref".into() };
        let mut state = State::default();
        let active = BTreeMap::from([("one".into(), Processing { phase:Some("generating"), queued:2, generating:true })]);
        observe(&mut state, &[instance.clone()], &active, 100);
        observe(&mut state, &[instance.clone()], &active, 500);
        assert_eq!(state.public.activities["lmstudio:model:one"].since, 100);
        observe(&mut state, &[instance], &BTreeMap::from([("one".into(), Processing { phase:None, queued:0, generating:false })]), 2_100);
        assert_eq!(state.finished["one"], (100,2_100));
        assert!(state.public.activities.is_empty());
    }
}
