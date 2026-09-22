//! Pinned Swift DailyPace / UsagePace arithmetic. All timestamps here are milliseconds.
use crate::usage::{LimitWindow, UsageSnapshot};

const DAY: u64 = 86_400_000;
pub const DAILY_ID: &str = "daily_pace";

pub fn claude(id: &str) -> bool {
    id == "claude" || id.starts_with("claude-") || id.starts_with("claude@")
}

pub fn daily(weekly: &LimitWindow, now: u64) -> Option<LimitWindow> {
    if weekly.count.is_some() || !weekly.used.is_finite() || weekly.used < 0.0 {
        return None;
    }
    let reset = weekly.resets_at?;
    // Use a signed difference so even an early-epoch fixture behaves like Swift Date.
    let start = i128::from(reset) - i128::from(7 * DAY);
    let elapsed = (i128::from(now) - start).clamp(0, i128::from(7 * DAY));
    let day = (elapsed / i128::from(DAY)).min(6);
    let end = if day == 6 {
        i128::from(reset)
    } else {
        start + (day + 1) * i128::from(DAY)
    };
    Some(LimitWindow {
        id: DAILY_ID.into(),
        label: "Daily pace".into(),
        used: weekly.used / ((day + 1) as f64 / 7.0),
        resets_at: Some(end.try_into().ok()?),
        // It is a synthetic allowance, not a timed quota. No pace-of-a-pace line.
        ..Default::default()
    })
}

pub fn apply(id: &str, mut snapshot: UsageSnapshot, enabled: bool, now: u64) -> UsageSnapshot {
    if enabled && claude(id) && !snapshot.windows.iter().any(|w| w.id == DAILY_ID) {
        if let Some(window) = snapshot
            .windows
            .iter()
            .find(|w| matches!(w.id.as_str(), "weekly_all" | "seven_day" | "weekly"))
            .and_then(|w| daily(w, now))
        {
            snapshot.windows.insert(0, window);
        }
    }
    snapshot
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn daily_matches_swift_day_boundaries_overage_and_clock_skew() {
        let start = 1_800_000_000_000 - 7 * DAY;
        let weekly = LimitWindow {
            id: "weekly_all".into(),
            used: 0.1,
            resets_at: Some(start + 7 * DAY),
            ..Default::default()
        };
        let first = daily(&weekly, start + DAY / 2).unwrap();
        assert!((first.used - 0.7).abs() < 1e-9);
        assert_eq!(first.resets_at, Some(start + DAY));
        assert_eq!(first.duration, None);
        let heavy = LimitWindow {
            used: 0.5,
            ..weekly.clone()
        };
        assert!((daily(&heavy, start + 2 * DAY).unwrap().used - 0.5 / (3.0 / 7.0)).abs() < 1e-9);
        assert_eq!(
            daily(&weekly, start - 1).unwrap().resets_at,
            Some(start + DAY)
        );
        assert_eq!(
            daily(&weekly, start + 8 * DAY).unwrap().resets_at,
            weekly.resets_at
        );
        assert!(daily(
            &LimitWindow {
                resets_at: None,
                ..weekly.clone()
            },
            start
        )
        .is_none());
        assert!(daily(
            &LimitWindow {
                used: f64::NAN,
                ..weekly
            },
            start
        )
        .is_none());
    }
    #[test]
    fn all_claude_accounts_only_and_never_stack_synthetic_windows() {
        let original = UsageSnapshot {
            windows: vec![LimitWindow {
                id: "weekly_all".into(),
                used: 0.3,
                resets_at: Some(1_800_000_000_000),
                ..Default::default()
            }],
            ..Default::default()
        };
        for id in ["claude", "claude-work", "claude@work"] {
            let once = apply(id, original.clone(), true, 1_799_700_000_000);
            assert_eq!(once.windows[0].id, DAILY_ID);
            assert_eq!(apply(id, once, true, 1_799_700_000_000).windows.len(), 2);
        }
        assert_eq!(apply("codex", original.clone(), true, 0).windows.len(), 1);
        assert_eq!(apply("claude", original, false, 0).windows.len(), 1);
    }
}
