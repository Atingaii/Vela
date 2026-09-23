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
    last_alerted_reset_date: Option<u64>,
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
        self.observe_with_block(provider, window, weekly, now, muted, false)
    }

    pub fn observe_with_block(
        &mut self,
        provider: &str,
        window: &LimitWindow,
        weekly: bool,
        now: u64,
        muted: bool,
        blocked: bool,
    ) -> Vec<Event> {
        let Some(fraction) = window.fraction() else {
            return Vec::new();
        };
        let exhausted = fraction >= 1.0 || (!weekly && blocked);
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
                    last_alerted_reset_date: window.resets_at,
                    exhausted,
                    threshold: level,
                },
            );
            // ThresholdNotifier starts at zero, unlike the reset and limit
            // watchers, whose first reading only seeds their state.
            return if !weekly && !muted {
                [80, 100]
                    .into_iter()
                    .filter(|threshold| *threshold <= level)
                    .map(|threshold| Event {
                        kind: Kind::Threshold,
                        provider: provider.into(),
                        label: window.label.clone(),
                        fraction: threshold as f64 / 100.0,
                    })
                    .collect()
            } else {
                Vec::new()
            };
        };
        let elapsed = old.resets_at.is_some_and(|t| t <= now);
        let advanced = matches!((old.resets_at, window.resets_at), (Some(a), Some(b)) if b > a);
        let dropped = fraction < old.fraction
            && (old.fraction - fraction >= 0.20 || (old.peak >= 0.30 && fraction <= 0.10));
        let date_rolled = elapsed
            && advanced
            && window
                .resets_at
                .is_some_and(|date| old.last_alerted_reset_date.map_or(true, |last| date > last));
        let reset =
            old.peak >= 0.15 && (date_rolled || (dropped && (old.resets_at.is_none() || elapsed)));
        let mut events = Vec::new();
        let mut emit = |kind| {
            events.push(Event {
                kind,
                provider: provider.into(),
                label: window.label.clone(),
                fraction,
            })
        };
        let delivered_reset = !weekly && reset && !muted;
        if delivered_reset {
            emit(Kind::Reset);
        }
        if advanced || fraction < 0.95 {
            old.exhausted = false;
        }
        if exhausted && !old.exhausted && !muted {
            emit(if weekly {
                Kind::WeeklyLimitReached
            } else {
                Kind::SessionLimitReached
            });
            old.exhausted = true;
        }
        if !weekly {
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
                }
            }
            // ThresholdNotifier updates this even while muted, and steps down
            // to 80 after a 100% reading so the next 100% is a new crossing.
            old.threshold = level;
        }
        old.fraction = fraction;
        old.peak = if delivered_reset {
            fraction
        } else {
            old.peak.max(fraction)
        };
        old.resets_at = window.resets_at;
        if delivered_reset {
            old.last_alerted_reset_date = window.resets_at;
        }
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
    fn threshold_first_frame_alerts_but_reset_ignores_countdown_drift() {
        let mut w = Watcher::default();
        let first = w.observe("a", &window(0.8, Some(1000)), false, 100, false);
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].kind, Kind::Threshold);
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
        let first = w.observe("b", &window(1.0, None), false, 0, false);
        assert_eq!(
            first.iter().filter(|e| e.kind == Kind::Threshold).count(),
            2
        );
        assert!(!first.iter().any(|e| e.kind == Kind::SessionLimitReached));
        w.observe("a", &window(0.1, None), false, 0, false);
        assert!(!w
            .observe("a", &window(1.0, None), false, 0, false)
            .is_empty());
    }
    #[test]
    fn muted_limit_replays_on_unmute_but_muted_threshold_does_not() {
        let mut w = Watcher::default();
        w.observe("a", &window(0.5, None), false, 0, false);
        assert!(w
            .observe("a", &window(1.0, None), false, 0, true)
            .is_empty());
        let unmuted = w.observe("a", &window(1.0, None), false, 0, false);
        assert_eq!(unmuted.len(), 1);
        assert_eq!(unmuted[0].kind, Kind::SessionLimitReached);
        assert!(w
            .observe("a", &window(f64::NAN, None), false, 0, false)
            .is_empty());
    }

    #[test]
    fn threshold_steps_back_from_hundred_to_eighty() {
        let mut watcher = Watcher::default();
        assert_eq!(
            watcher
                .observe("a", &window(1.0, None), false, 0, false)
                .len(),
            2
        );
        assert!(watcher
            .observe("a", &window(0.9, None), false, 0, false)
            .is_empty());
        let again = watcher.observe("a", &window(1.0, None), false, 0, false);
        assert_eq!(
            again
                .iter()
                .filter(|event| event.kind == Kind::Threshold)
                .count(),
            1
        );
        assert_eq!(
            again
                .iter()
                .find(|event| event.kind == Kind::Threshold)
                .unwrap()
                .fraction,
            1.0
        );
    }

    #[test]
    fn muted_reset_preserves_peak_until_a_later_deliverable_reset() {
        let mut watcher = Watcher::default();
        watcher.observe("a", &window(0.6, Some(100)), false, 0, true);
        assert!(watcher
            .observe("a", &window(0.1, Some(200)), false, 101, true)
            .is_empty());
        assert_eq!(watcher.previous[&("a".into(), false)].peak, 0.6);
        // The muted reset did not advance lastAlertedResetDate. A later
        // deadline and new date are still eligible even if usage stays low.
        let events = watcher.observe("a", &window(0.1, Some(300)), false, 201, false);
        assert!(events.iter().any(|event| event.kind == Kind::Reset));
        assert_eq!(watcher.previous[&("a".into(), false)].peak, 0.1);
    }

    #[test]
    fn measured_count_can_alert_but_unmetered_count_cannot() {
        let mut watcher = Watcher::default();
        let mut measured = window(0.8, None);
        measured.count = Some(80);
        measured.has_fraction = Some(true);
        watcher.observe("meter", &measured, false, 0, false);
        measured.used = 1.0;
        assert!(watcher
            .observe("meter", &measured, false, 0, false)
            .iter()
            .any(|event| event.kind == Kind::SessionLimitReached));

        let mut count_only = window(0.0, None);
        count_only.count = Some(100);
        count_only.has_fraction = Some(false);
        assert!(watcher
            .observe("count", &count_only, false, 0, false)
            .is_empty());
        count_only.count = Some(200);
        count_only.used = 1.0;
        assert!(watcher
            .observe("count", &count_only, false, 0, false)
            .is_empty());
    }

    #[test]
    fn provider_block_exhausts_a_measured_session_below_one_hundred_percent() {
        let mut watcher = Watcher::default();
        let session = window(0.5, None);
        watcher.observe("claude", &session, false, 0, false);
        let events = watcher.observe_with_block("claude", &session, false, 0, false, true);
        assert_eq!(
            events
                .iter()
                .filter(|event| event.kind == Kind::SessionLimitReached)
                .count(),
            1
        );
        assert!(watcher
            .observe_with_block("claude", &session, true, 0, false, true)
            .is_empty());
    }
}
