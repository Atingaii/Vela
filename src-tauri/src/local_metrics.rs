//! Only numeric metadata from local inference. Prompt, response and reasoning text never enter
//! this model, its snapshots, or the on-disk ledger.
use serde::{Deserialize, Serialize};
use chrono::{Local, TimeZone};

pub fn local_day_start(at_ms: u64) -> Option<i64> {
    let at = Local.timestamp_millis_opt(i64::try_from(at_ms).ok()?).single()?;
    let midnight = at.date_naive().and_hms_opt(0, 0, 0)?;
    Local.from_local_datetime(&midnight).earliest().map(|day| day.timestamp_millis())
}

fn retention_cutoff<T: TimeZone>(day_start: i64, zone: &T) -> Option<i64> {
    let day = zone.timestamp_millis_opt(day_start).single()?.date_naive();
    let previous = day.checked_sub_signed(chrono::Duration::days(60))?.and_hms_opt(0, 0, 0)?;
    zone.from_local_datetime(&previous).earliest().map(|at| at.timestamp_millis())
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Performance {
    pub output_tokens: u64,
    pub generation_seconds: f64,
    pub measured_at: u64,
    pub approximate: bool,
    pub speed_text: String,
    pub headline_text: String,
    pub band: String,
}

impl Performance {
    pub fn from_parts(output_tokens: u64, generation_seconds: f64, measured_at: u64, approximate: bool) -> Option<Self> {
        if output_tokens == 0 || output_tokens > i64::MAX as u64
            || !generation_seconds.is_finite() || generation_seconds <= 0.0
            || generation_seconds >= 1_000_000_000.0 { return None; }
        // Swift's seconds initializer converts through Int64 nanoseconds. A
        // positive sub-nanosecond duration truncates to zero and is invalid.
        let nanoseconds = (generation_seconds * 1_000_000_000.0).trunc() as i64;
        if nanoseconds <= 0 { return None; }
        Some(Self::valid(output_tokens, nanoseconds as f64 / 1_000_000_000.0,
            measured_at, approximate))
    }
    fn valid(output_tokens: u64, generation_seconds: f64, measured_at: u64, approximate: bool) -> Self {
        let speed = output_tokens as f64 / generation_seconds;
        let qualifier = if approximate { "~" } else { "" };
        let speed_text = if speed < 0.1 { format!("{qualifier}<0.1 tok/s") }
            else { format!("{qualifier}{} tok/s", fixed_trim(speed, 1)) };
        let headline_text = if speed < 1.0 { format!("{qualifier}<1 tok/s") }
            else if speed >= 1_000.0 {
                let (divisor, suffix) = if speed >= 1_000_000_000.0 { (1_000_000_000.0, "B") }
                    else if speed >= 1_000_000.0 { (1_000_000.0, "M") } else { (1_000.0, "K") };
                format!("{qualifier}{}{suffix} t/s", significant(speed / divisor, 2))
            } else { format!("{qualifier}{} tok/s", significant(speed, 3)) };
        let band = if speed < 10.0 { "verySlow" } else if speed < 20.0 { "slow" }
            else if speed < 40.0 { "smooth" } else { "veryFast" };
        Self { output_tokens, generation_seconds, measured_at, approximate,
            speed_text, headline_text, band: band.into() }
    }
    pub fn from_ollama(value: crate::ollama_stream::Performance) -> Option<Self> {
        if value.output_tokens == 0 || value.output_tokens > i64::MAX as u64
            || !value.generation_seconds.is_finite() || value.generation_seconds <= 0.0
            || value.generation_seconds * 1_000_000_000.0 > i64::MAX as f64 { return None; }
        Some(Self::valid(value.output_tokens, value.generation_seconds, value.measured_at, value.approximate))
    }
}

fn fixed_trim(value: f64, decimals: usize) -> String {
    let mut text = format!("{value:.decimals$}");
    if text.contains('.') { while text.ends_with('0') { text.pop(); } if text.ends_with('.') { text.pop(); } }
    text
}
fn significant(value: f64, digits: i32) -> String {
    let whole = (value.log10().floor() as i32 + 1).max(1);
    fixed_trim(value, (digits - whole).max(0) as usize)
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct LedgerTotals {
    pub requests: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub reasoning_tokens: u64,
    pub draft_tokens: u64,
    pub accepted_draft_tokens: u64,
}

impl LedgerTotals {
    fn add(&mut self, prediction: &LocalPrediction) {
        self.requests = self.requests.saturating_add(1);
        self.input_tokens = self.input_tokens.saturating_add(prediction.input_tokens.unwrap_or(0));
        self.output_tokens = self.output_tokens.saturating_add(prediction.output_tokens.unwrap_or(0));
        self.reasoning_tokens = self.reasoning_tokens.saturating_add(prediction.reasoning_tokens.unwrap_or(0));
        self.draft_tokens = self.draft_tokens.saturating_add(prediction.draft_tokens.unwrap_or(0));
        self.accepted_draft_tokens = self.accepted_draft_tokens.saturating_add(prediction.accepted_draft_tokens.unwrap_or(0));
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LocalPrediction {
    pub instance: String,
    pub at: u64,
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
    pub reasoning_tokens: Option<u64>,
    pub tokens_per_second: Option<f64>,
    pub time_to_first_token: Option<f64>,
    pub generation_seconds: Option<f64>,
    pub draft_tokens: Option<u64>,
    pub accepted_draft_tokens: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LedgerSummary {
    pub today: LedgerTotals,
    pub last: Option<LocalPrediction>,
}

impl LedgerSummary {
    pub fn context_fraction(&self, context_length: Option<u64>) -> Option<f64> {
        let input = self.last.as_ref()?.input_tokens?;
        let capacity = context_length.filter(|size| *size > 0)?;
        Some((input as f64 / capacity as f64).min(1.0))
    }
}

#[derive(Clone, Debug, Default)]
pub struct Ledger {
    /// Millisecond start of local day, per cell. The collector computes the key once on ingest.
    days: std::collections::BTreeMap<String, std::collections::BTreeMap<i64, LedgerTotals>>,
    last: std::collections::BTreeMap<String, LocalPrediction>,
}

impl Ledger {
    pub fn record(&mut self, cell: &str, day_start: i64, prediction: LocalPrediction) {
        self.days.entry(cell.into()).or_default().entry(day_start).or_default().add(&prediction);
        if self.last.get(cell).is_none_or(|previous| prediction.at >= previous.at) {
            self.last.insert(cell.into(), prediction);
        }
        let cutoff = retention_cutoff(day_start, &Local).unwrap_or(i64::MIN);
        for days in self.days.values_mut() { days.retain(|day, _| *day >= cutoff); }
    }

    pub fn summary(&self, cell: &str, day_start: i64) -> Option<LedgerSummary> {
        let today = self.days.get(cell).and_then(|days| days.get(&day_start)).cloned().unwrap_or_default();
        let last = self.last.get(cell).cloned();
        (today.requests > 0 || last.is_some()).then_some(LedgerSummary { today, last })
    }

    pub fn total_today(&self, day_start: i64) -> LedgerTotals {
        let mut total = LedgerTotals::default();
        for days in self.days.values() {
            if let Some(row) = days.get(&day_start) {
                total.requests = total.requests.saturating_add(row.requests);
                total.input_tokens = total.input_tokens.saturating_add(row.input_tokens);
                total.output_tokens = total.output_tokens.saturating_add(row.output_tokens);
                total.reasoning_tokens = total.reasoning_tokens.saturating_add(row.reasoning_tokens);
                total.draft_tokens = total.draft_tokens.saturating_add(row.draft_tokens);
                total.accepted_draft_tokens = total.accepted_draft_tokens.saturating_add(row.accepted_draft_tokens);
            }
        }
        total
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ledger_is_per_instance_and_local_day_and_keeps_only_numeric_metadata() {
        let prediction = LocalPrediction { instance: "one".into(), at: 100,
            input_tokens: Some(60), output_tokens: Some(20), reasoning_tokens: Some(5),
            tokens_per_second: Some(10.), time_to_first_token: None, generation_seconds: Some(2.),
            draft_tokens: None, accepted_draft_tokens: None };
        let mut ledger = Ledger::default();
        ledger.record("lmstudio:model:one", 0, prediction);
        let summary = ledger.summary("lmstudio:model:one", 0).unwrap();
        assert_eq!(summary.today.requests, 1);
        assert_eq!(summary.context_fraction(Some(100)), Some(0.6));
        assert!(ledger.summary("lmstudio:model:two", 0).is_none());
        assert_eq!(ledger.summary("lmstudio:model:one", 86_400_000).unwrap().today.requests, 0);
        assert_eq!(Performance::from_parts(20,2.,100,false).unwrap().band, "slow");
        for (tokens, seconds, expected) in [(10,1.,"10 tok/s"),(20,1.,"20 tok/s"),
            (999,1.,"999 tok/s"),(1_000,1.,"1K t/s"),(1_000_000,1.,"1M t/s")] {
            let reading = Performance::from_parts(tokens, seconds, 100, false).unwrap();
            assert_eq!(reading.headline_text, expected);
        }
        assert_eq!(Performance::from_parts(20,1.,100,false).unwrap().speed_text, "20 tok/s");
        assert!(Performance::from_ollama(crate::ollama_stream::Performance {
            output_tokens: 20, generation_seconds: u64::MAX as f64 / 1_000_000_000.0,
            measured_at: 100, approximate: false,
        }).is_none());
        assert!(Performance::from_parts(u64::MAX,1.,100,false).is_none());
        assert!(Performance::from_parts(1, 0.000_000_000_9, 100, false).is_none());
        assert!(Performance::from_parts(1, 0.000_000_001, 100, false).is_some());
        let zone = chrono_tz::America::New_York;
        let day = zone.with_ymd_and_hms(2026, 4, 10, 0, 0, 0).single().unwrap().timestamp_millis();
        let cutoff = retention_cutoff(day, &zone).unwrap();
        let expected = zone.with_ymd_and_hms(2026, 2, 9, 0, 0, 0).single().unwrap().timestamp_millis();
        assert_eq!(cutoff, expected); // March DST crossed: 60 calendar days, not 60 * 24 hours.
    }
}
