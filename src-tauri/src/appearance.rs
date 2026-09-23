//! Presentation preferences restored from the pinned Swift baseline.
use serde::{Deserialize, Serialize};
use chrono::{DateTime, Datelike, Duration, Timelike, Utc};
use tauri::{AppHandle, Emitter, Manager};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Preferences {
    pub accent_color: String,
    pub app_presence: String,
    /// Swift NotchScreenScope raw value: one panel or one independent panel per display.
    pub notch_scope: String,
    /// Stored choice; its effective native rendering depends on macOS and accessibility settings.
    pub surface_style: String,
    pub shows_limits_in_menu_bar: bool,
    pub shows_weekly_limit_in_menu_bar: bool,
    /// None means the Swift default provider selection; [] means explicitly none.
    pub menu_bar_providers: Option<Vec<String>>,
    pub deepseek_pricing_enabled: bool,
    #[serde(default, deserialize_with = "deserialize_schedule")]
    pub deepseek_pricing_schedule: DeepSeekPricingSchedule,
    pub reset_time: String,
    pub show_codex_extra: bool,
    pub show_usage_pace: bool,
    pub claude_daily_pace: bool,
    pub weekly_dashed: bool,
    pub folds_for_fullscreen: bool,
    pub custom_scale: Option<f64>,
    /// Swift keeps the custom slider even while a preset is active.
    pub saved_custom_scale: f64,
    pub watch: f64,
    pub critical: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct DeepSeekPricingSchedule {
    /// Foundation Gregorian weekdays: Sunday=1 through Saturday=7, interpreted in UTC.
    pub peak_weekdays: Vec<i64>,
    pub windows: Vec<PricingWindow>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PricingWindow {
    pub start_minute: i64,
    pub end_minute: i64,
}

fn deserialize_schedule<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<DeepSeekPricingSchedule, D::Error> {
    let raw = serde_json::Value::deserialize(deserializer)?;
    Ok(serde_json::from_value(raw).unwrap_or_default())
}

impl Default for DeepSeekPricingSchedule {
    fn default() -> Self {
        Self { peak_weekdays: vec![2, 3, 4, 5, 6],
            windows: vec![PricingWindow { start_minute: 60, end_minute: 240 },
                PricingWindow { start_minute: 360, end_minute: 600 }] }
    }
}
impl DeepSeekPricingSchedule {
    pub(crate) fn normalize(&mut self) {
        self.peak_weekdays.retain(|day| (1..=7).contains(day));
        self.peak_weekdays.sort_unstable();
        self.peak_weekdays.dedup();
        self.windows.iter_mut().for_each(|w| {
            w.start_minute = w.start_minute.clamp(0, 1440);
            w.end_minute = w.end_minute.clamp(0, 1440);
        });
        self.windows.retain(|w| w.start_minute < w.end_minute);
        if self.windows.is_empty() {
            self.windows.push(PricingWindow { start_minute: 60, end_minute: 240 });
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct DeepSeekPricingState {
    pub phase: &'static str,
    pub next_phase: &'static str,
    pub next_at: i64,
}

fn pricing_phase(schedule: &DeepSeekPricingSchedule, at: DateTime<Utc>) -> &'static str {
    let day = at.weekday().number_from_sunday() as i64;
    let minute = (at.hour() * 60 + at.minute()) as i64;
    if schedule.peak_weekdays.contains(&day) && schedule.windows.iter().any(|w| {
        w.start_minute <= minute && minute < w.end_minute
    }) { "peak" } else { "offPeak" }
}

fn pricing_state(schedule: &DeepSeekPricingSchedule, now: DateTime<Utc>) -> DeepSeekPricingState {
    let phase = pricing_phase(schedule, now);
    let midnight = now.date_naive().and_hms_opt(0, 0, 0).unwrap().and_utc();
    let boundaries: std::collections::BTreeSet<i64> = schedule.windows.iter()
        .flat_map(|w| [w.start_minute, w.end_minute]).collect();
    for day in 0..=8 {
        for minute in &boundaries {
            let candidate = midnight + Duration::days(day) + Duration::minutes(*minute);
            if candidate <= now { continue; }
            let next_phase = pricing_phase(schedule, candidate);
            if next_phase != pricing_phase(schedule, candidate - Duration::seconds(1)) {
                return DeepSeekPricingState { phase, next_phase, next_at: candidate.timestamp_millis() };
            }
        }
    }
    DeepSeekPricingState { phase, next_phase: "offPeak", next_at: (now + Duration::days(8)).timestamp_millis() }
}

#[tauri::command]
pub fn get_deepseek_pricing_state(app: AppHandle) -> DeepSeekPricingState {
    let schedule = app.state::<crate::AppState>().cfg.lock().unwrap()
        .appearance.deepseek_pricing_schedule.clone();
    pricing_state(&schedule, Utc::now())
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            accent_color: "system".into(),
            app_presence: "dock".into(),
            notch_scope: "mainDisplay".into(),
            surface_style: "glass".into(),
            shows_limits_in_menu_bar: false,
            shows_weekly_limit_in_menu_bar: false,
            menu_bar_providers: None,
            deepseek_pricing_enabled: true,
            deepseek_pricing_schedule: DeepSeekPricingSchedule::default(),
            reset_time: "automatic".into(),
            show_codex_extra: true,
            show_usage_pace: false,
            claude_daily_pace: false,
            weekly_dashed: false,
            folds_for_fullscreen: true,
            custom_scale: None,
            saved_custom_scale: 1.0,
            watch: 0.5,
            critical: 0.7,
        }
    }
}
impl Preferences {
    fn validate(&self) -> Result<(), String> {
        if ![
            "system", "ff33e1", "eb4236", "eb8436", "ffd400", "00ff88", "00e5cc", "36a8eb",
            "6c5ce7", "b026ff", "f7f6f5",
        ]
        .contains(&self.accent_color.as_str())
            || !matches!(self.app_presence.as_str(), "dock" | "menuBar" | "hidden")
            || !matches!(self.notch_scope.as_str(), "mainDisplay" | "allDisplays")
            || !matches!(self.surface_style.as_str(), "glass" | "darkGlass" | "solid")
            || self.menu_bar_providers.as_ref().is_some_and(|ids| {
                ids.len() > 32
                    || ids.iter().any(|id| {
                        id.len() > 512
                            || id.is_empty()
                            || id.chars().any(char::is_control)
                    })
            })
            || !matches!(self.reset_time.as_str(), "automatic" | "remaining")
            || !self.watch.is_finite()
            || !self.critical.is_finite()
            || self.watch < 0.01
            || self.critical > 1.0
            || self.critical - self.watch < 0.009999
            || self
                .custom_scale
                .is_some_and(|n| !n.is_finite() || !(0.75..=1.5).contains(&n))
            || !self.saved_custom_scale.is_finite()
            || !(0.75..=1.5).contains(&self.saved_custom_scale)
        {
            return Err("外观设置的阈值或尺寸无效".into());
        }
        Ok(())
    }
    pub fn effective_scale(&self, preset: f64) -> f64 {
        self.custom_scale
            .filter(|n| n.is_finite() && (0.75..=1.5).contains(n))
            .unwrap_or_else(|| crate::config::snap_scale(preset))
    }
}
#[tauri::command]
pub fn get_appearance(app: AppHandle) -> Preferences {
    app.state::<crate::AppState>()
        .cfg
        .lock()
        .unwrap()
        .appearance
        .clone()
}
#[tauri::command]
pub fn set_appearance(app: AppHandle, mut prefs: Preferences) -> Result<Preferences, String> {
    prefs.deepseek_pricing_schedule.normalize();
    if let Some(scale) = prefs.custom_scale { prefs.saved_custom_scale = scale; }
    prefs.validate()?;
    let st = app.state::<crate::AppState>();
    let mut cfg = st.cfg.lock().unwrap();
    let previous_scale = cfg.appearance.effective_scale(cfg.scale);
    let codex_extra_changed = cfg.appearance.show_codex_extra != prefs.show_codex_extra;
    let mut next = cfg.clone();
    next.appearance = prefs.clone();
    let scale_changed = (next.appearance.effective_scale(next.scale) - previous_scale).abs() > f64::EPSILON;
    crate::config::save_checked(&next)?;
    *cfg = next;
    drop(cfg);
    if codex_extra_changed {
        for id in crate::providers::codex_profile_ids() {
            let _ = crate::refresh_provider(&app, &id);
        }
    }
    crate::place_notch(&app);
    if scale_changed { crate::peek_notch_for_size(&app); }
    crate::native_notch::apply_preferences(&app);
    crate::settings_window::apply_presence(&app);
    crate::tray::refresh_menu(&app);
    let _ = app.emit("appearance", &prefs);
    Ok(prefs)
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preset_and_custom_slider_keep_independent_values() {
        let mut prefs = Preferences { custom_scale: Some(1.17), saved_custom_scale: 1.17, ..Default::default() };
        assert_eq!(prefs.effective_scale(0.8), 1.17);
        prefs.custom_scale = None;
        assert_eq!(prefs.effective_scale(0.8), 0.8);
        assert_eq!(prefs.saved_custom_scale, 1.17);
        prefs.custom_scale = Some(prefs.saved_custom_scale);
        assert_eq!(prefs.effective_scale(1.25), 1.17);
        prefs.saved_custom_scale = 2.0;
        assert!(prefs.validate().is_err());
    }
    #[test]
    fn deepseek_schedule_preserves_explicit_days_and_normalizes_bad_windows() {
        let mut schedule = DeepSeekPricingSchedule {
            peak_weekdays: vec![6, 2, 9, 2],
            windows: vec![PricingWindow { start_minute: 600, end_minute: 600 },
                PricingWindow { start_minute: 360, end_minute: 1600 }],
        };
        schedule.normalize();
        assert_eq!(schedule.peak_weekdays, vec![2, 6]);
        assert_eq!(schedule.windows, vec![PricingWindow { start_minute: 360, end_minute: 1440 }]);
        let json = serde_json::to_string(&schedule).unwrap();
        assert_eq!(serde_json::from_str::<DeepSeekPricingSchedule>(&json).unwrap(), schedule);
        schedule.windows.clear();
        schedule.normalize();
        assert_eq!(schedule.windows, vec![PricingWindow { start_minute: 60, end_minute: 240 }]);
        let prefs: Preferences = serde_json::from_str(r#"{"accent_color":"ff33e1","deepseek_pricing_schedule":{"windows":"corrupt"}}"#).unwrap();
        assert_eq!(prefs.accent_color, "ff33e1");
        assert_eq!(prefs.deepseek_pricing_schedule, DeepSeekPricingSchedule::default());
    }
    #[test]
    fn deepseek_utc_transition_skips_weekend_and_uses_half_open_windows() {
        use chrono::TimeZone;
        let schedule = DeepSeekPricingSchedule::default();
        let friday_end = Utc.with_ymd_and_hms(2026, 9, 25, 10, 0, 0).single().unwrap();
        assert_eq!(pricing_phase(&schedule, friday_end), "offPeak");
        let state = pricing_state(&schedule, friday_end);
        assert_eq!(state.next_phase, "peak");
        assert_eq!(state.next_at, Utc.with_ymd_and_hms(2026, 9, 28, 1, 0, 0)
            .single().unwrap().timestamp_millis());
        let inside = Utc.with_ymd_and_hms(2026, 9, 28, 1, 0, 0).single().unwrap();
        assert_eq!(pricing_phase(&schedule, inside), "peak");
    }
    #[test]
    fn only_the_pinned_accent_palette_can_be_saved() {
        let mut p = Preferences::default();
        assert_eq!(p.accent_color, "system");
        for color in [
            "system", "ff33e1", "eb4236", "eb8436", "ffd400", "00ff88", "00e5cc", "36a8eb",
            "6c5ce7", "b026ff", "f7f6f5",
        ] {
            p.accent_color = color.into();
            assert!(p.validate().is_ok());
        }
        for color in ["ffffff", "#ff33e1", "red;display:none"] {
            p.accent_color = color.into();
            assert!(p.validate().is_err());
        }
    }
    #[test]
    fn app_presence_defaults_to_dock_and_rejects_unknown_modes() {
        let mut p: Preferences = serde_json::from_str("{}").unwrap();
        assert_eq!(p.app_presence, "dock");
        for mode in ["dock", "menuBar", "hidden"] {
            p.app_presence = mode.into();
            assert!(p.validate().is_ok());
        }
        p.app_presence = "typo".into();
        assert!(p.validate().is_err());
    }
    #[test]
    fn custom_size_survives_and_invalid_thresholds_are_refused() {
        let mut p = Preferences {
            custom_scale: Some(1.17),
            ..Default::default()
        };
        assert_eq!(p.effective_scale(0.8), 1.17);
        assert!(p.validate().is_ok());
        p.watch = p.critical;
        assert!(p.validate().is_err());
        p.watch = 0.5;
        p.custom_scale = Some(f64::NAN);
        assert!(p.validate().is_err());
        assert_eq!(p.effective_scale(0.8), 0.8);
    }
    #[test]
    fn native_preferences_preserve_unset_menu_selection_and_validate_raw_values() {
        let mut p: Preferences = serde_json::from_str("{}").unwrap();
        assert_eq!(p.notch_scope, "mainDisplay");
        assert_eq!(p.surface_style, "glass");
        assert_eq!(p.menu_bar_providers, None);
        p.notch_scope = "allDisplays".into();
        p.surface_style = "darkGlass".into();
        p.menu_bar_providers = Some(vec![]);
        assert!(p.validate().is_ok());
        p.menu_bar_providers = Some(vec!["claude-工作 甲".into()]);
        assert!(p.validate().is_ok());
        p.menu_bar_providers = Some(vec!["bad\nname".into()]);
        assert!(p.validate().is_err());
        p.menu_bar_providers = Some(vec![]);
        assert_eq!(
            serde_json::to_value(&p).unwrap()["menu_bar_providers"],
            serde_json::json!([])
        );
        p.notch_scope = "oneArbitraryDisplay".into();
        assert!(p.validate().is_err());
        p.notch_scope = "mainDisplay".into();
        p.surface_style = "cssBlur".into();
        assert!(p.validate().is_err());
    }
}
