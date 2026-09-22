//! Completion generations for a bounded Phone Link refresh. A failed read still
//! completes; unchanged cached JSON must not make the phone wait for the timeout.
use std::{
    collections::BTreeMap,
    sync::{
        atomic::{AtomicBool, Ordering},
        Condvar, Mutex, OnceLock,
    },
    time::{Duration, Instant},
};

#[derive(Default)]
struct Completions {
    generations: Mutex<BTreeMap<String, u64>>,
    changed: Condvar,
}
impl Completions {
    fn generation(&self, id: &str) -> u64 {
        self.generations
            .lock()
            .unwrap()
            .get(id)
            .copied()
            .unwrap_or(0)
    }
    fn complete(&self, id: &str) {
        let mut generations = self.generations.lock().unwrap();
        let generation = generations.entry(id.into()).or_default();
        *generation = generation.wrapping_add(1);
        self.changed.notify_all();
    }
    fn wait(&self, pending: &[(String, u64)], stop: &AtomicBool, timeout: Duration) {
        let deadline = Instant::now() + timeout;
        let mut generations = self.generations.lock().unwrap();
        while !stop.load(Ordering::Acquire)
            && pending
                .iter()
                .any(|(id, generation)| generations.get(id).copied().unwrap_or(0) == *generation)
        {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            generations = self
                .changed
                .wait_timeout(generations, remaining.min(Duration::from_millis(250)))
                .unwrap()
                .0;
        }
    }
}
fn store() -> &'static Completions {
    static STORE: OnceLock<Completions> = OnceLock::new();
    STORE.get_or_init(Completions::default)
}
pub fn generation(id: &str) -> u64 {
    store().generation(id)
}
pub fn complete(id: &str) {
    store().complete(id);
}
pub fn wait(pending: &[(String, u64)], stop: &AtomicBool) {
    store().wait(pending, stop, Duration::from_secs(20));
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn waits_for_all_requested_accounts_even_when_their_readings_are_unchanged() {
        let store = Completions::default();
        let pending = vec![
            ("claude".into(), store.generation("claude")),
            ("codex-work".into(), store.generation("codex-work")),
        ];
        let stop = AtomicBool::new(false);
        std::thread::scope(|scope| {
            scope.spawn(|| {
                store.complete("claude");
                store.complete("codex-other");
                std::thread::sleep(Duration::from_millis(10));
                store.complete("codex-work");
            });
            store.wait(&pending, &stop, Duration::from_secs(1));
            assert_ne!(store.generation("codex-work"), pending[1].1);
        });
    }
    #[test]
    fn cancellation_empty_targets_and_deadline_do_not_require_a_provider_update() {
        let store = Completions::default();
        let stop = AtomicBool::new(true);
        store.wait(&[("absent".into(), 0)], &stop, Duration::from_secs(20));
        stop.store(false, Ordering::Release);
        store.wait(&[], &stop, Duration::from_secs(20));
        let started = Instant::now();
        store.wait(&[("absent".into(), 0)], &stop, Duration::from_millis(5));
        assert!(started.elapsed() >= Duration::from_millis(5));
        assert_eq!(store.generation("absent"), 0);
    }
}
