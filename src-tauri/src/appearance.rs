//! Presentation preferences restored from the pinned Swift baseline.
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Preferences {
    pub reset_time: String,
    pub show_codex_extra: bool,
    pub show_usage_pace: bool,
    pub claude_daily_pace: bool,
    pub weekly_dashed: bool,
    pub custom_scale: Option<f64>,
    pub watch: f64,
    pub critical: f64,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            reset_time: "automatic".into(),
            show_codex_extra: true,
            show_usage_pace: false,
            claude_daily_pace: false,
            weekly_dashed: false,
            custom_scale: None,
            watch: 0.5,
            critical: 0.7,
        }
    }
}
impl Preferences {
    fn validate(&self) -> Result<(), String> {
        if !matches!(self.reset_time.as_str(), "automatic" | "remaining")
            || !self.watch.is_finite()
            || !self.critical.is_finite()
            || self.watch < 0.01
            || self.critical > 1.0
            || self.critical - self.watch < 0.009999
            || self
                .custom_scale
                .is_some_and(|n| !n.is_finite() || !(0.75..=1.5).contains(&n))
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
pub fn set_appearance(app: AppHandle, prefs: Preferences) -> Result<Preferences, String> {
    prefs.validate()?;
    let st = app.state::<crate::AppState>();
    let mut cfg = st.cfg.lock().unwrap();
    let mut next = cfg.clone();
    next.appearance = prefs.clone();
    crate::config::save_checked(&next)?;
    *cfg = next;
    drop(cfg);
    crate::place_notch(&app);
    let _ = app.emit("appearance", &prefs);
    Ok(prefs)
}
#[cfg(test)]
mod tests {
    use super::*;
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
}
