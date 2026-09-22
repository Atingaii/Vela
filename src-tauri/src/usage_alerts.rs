//! Pure ports of Swift UsageResetWatcher / UsageLimitWatcher. No network or timers.
use crate::usage::LimitWindow;
use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Reset,
    SessionLimitReached,
    WeeklyLimitReached,
    Threshold,
}
#[derive(Clone, Debug, serde::Serialize)]
pub struct Event {
    pub kind: Kind,
    pub provider: String,
    pub label: String,
    pub fraction: f64,
}
#[derive(Default)]
struct Previous {
    fraction: f64,
    peak: f64,
    resets_at: Option<u64>,
    exhausted: bool,
    threshold: u32,
}
#[derive(Default)]
pub struct Watcher {
    previous: HashMap<(String, bool), Previous>,
}
impl Watcher {
    pub fn observe(
        &mut self,
        provider: &str,
        window: &LimitWindow,
        weekly: bool,
        now: u64,
        muted: bool,
    ) -> Vec<Event> {
        if window.count.is_some() || !window.used.is_finite() || window.used < 0.0 {
            return Vec::new();
        }
        let fraction = window.used;
        let level = if fraction >= 1.0 {
            100
        } else if fraction >= 0.8 {
            80
        } else {
            0
        };
        let Some(old) = self.previous.get_mut(&(provider.into(), weekly)) else {
            self.previous.insert(
                (provider.into(), weekly),
                Previous {
                    fraction,
                    peak: fraction,
                    resets_at: window.resets_at,
                    exhausted: fraction >= 1.0,
                    threshold: level,
                },
            );
            return Vec::new();
        };
        let elapsed = old.resets_at.is_some_and(|t| t <= now);
        let advanced = matches!((old.resets_at, window.resets_at), (Some(a), Some(b)) if b > a);
        let dropped = fraction < old.fraction
            && (old.fraction - fraction >= 0.20 || (old.peak >= 0.30 && fraction <= 0.10));
        let reset = old.peak >= 0.15
            && ((elapsed && advanced) || (dropped && (old.resets_at.is_none() || elapsed)));
        let mut events = Vec::new();
        let mut emit = |kind| {
            events.push(Event {
                kind,
                provider: provider.into(),
                label: window.label.clone(),
                fraction,
            })
        };
        if !weekly && reset && !muted {
            emit(Kind::Reset);
        }
        if advanced || fraction < 0.95 {
            old.exhausted = false;
        }
        if fraction >= 1.0 && !old.exhausted && !muted {
            emit(if weekly {
                Kind::WeeklyLimitReached
            } else {
                Kind::SessionLimitReached
            });
        }
        // Consume muted crossings too: unmuting should not replay old alerts.
        old.exhausted = fraction >= 1.0 || old.exhausted;
        if !weekly {
            if level < 80 {
                old.threshold = 0;
            }
            for threshold in [80, 100] {
                if level >= threshold && old.threshold < threshold {
                    if !muted {
                        events.push(Event {
                            kind: Kind::Threshold,
                            provider: provider.into(),
                            label: window.label.clone(),
                            fraction: threshold as f64 / 100.,
                        });
                    }
                    old.threshold = threshold;
                }
            }
        }
        old.fraction = fraction;
        old.peak = if reset {
            fraction
        } else {
            old.peak.max(fraction)
        };
        old.resets_at = window.resets_at;
        events
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn window(used: f64, reset: Option<u64>) -> LimitWindow {
        LimitWindow {
            id: "session".into(),
            used,
            resets_at: reset,
            ..Default::default()
        }
    }
    #[test]
    fn startup_and_countdown_drift_do_not_alert() {
        let mut w = Watcher::default();
        assert!(w
            .observe("a", &window(0.8, Some(1000)), false, 100, false)
            .is_empty());
        assert!(w
            .observe("a", &window(0.4, Some(1010)), false, 200, false)
            .is_empty());
        let e = w.observe("a", &window(0.1, Some(2000)), false, 1100, false);
        assert_eq!(e.len(), 1);
        assert_eq!(e[0].kind, Kind::Reset);
    }
    #[test]
    fn crossings_are_once_per_window_and_accounts_do_not_share_state() {
        let mut w = Watcher::default();
        w.observe("a", &window(0.7, None), false, 0, false);
        let e = w.observe("a", &window(1.0, None), false, 0, false);
        assert!(e.iter().any(|e| e.kind == Kind::SessionLimitReached));
        assert!(w
            .observe("a", &window(1.0, None), false, 0, false)
            .is_empty());
        assert!(w
            .observe("b", &window(1.0, None), false, 0, false)
            .is_empty());
        w.observe("a", &window(0.1, None), false, 0, false);
        assert!(!w
            .observe("a", &window(1.0, None), false, 0, false)
            .is_empty());
    }
    #[test]
    fn muted_or_unknown_readings_do_not_later_replay_a_crossing() {
        let mut w = Watcher::default();
        w.observe("a", &window(0.5, None), false, 0, false);
        assert!(w
            .observe("a", &window(1.0, None), false, 0, true)
            .is_empty());
        assert!(w
            .observe("a", &window(1.0, None), false, 0, false)
            .is_empty());
        assert!(w
            .observe("a", &window(f64::NAN, None), false, 0, false)
            .is_empty());
    }
}
