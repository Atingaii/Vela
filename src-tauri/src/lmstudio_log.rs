//! LM Studio server-log reader. Only `usage` and `stats` numeric blocks are retained while a
//! prediction is parsed; prompt, response, reasoning and conversation fields are discarded.
use crate::local_metrics::LocalPrediction;
use chrono::{Local, NaiveDateTime, TimeZone};
use serde_json::Value;
use std::{fs::{self, File}, io::{Read, Seek, SeekFrom}, path::{Path, PathBuf}, sync::{Arc, atomic::{AtomicBool, Ordering}}};

const MAX_LINE: usize = 4 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, serde::Serialize)]
pub enum Event {
    RequestStarted { instance: String, at: u64 },
    PromptProcessed { instance: String, at: u64 },
    Prediction(LocalPrediction),
}

#[derive(Clone, Debug)]
struct Capture {
    instance: String,
    at: u64,
    usage: String,
    stats: String,
    block: Option<Block>,
}
#[derive(Clone, Copy, Debug)]
enum Block { Usage, Stats }

#[derive(Default)]
pub struct Parser {
    pending: Vec<u8>,
    capture: Option<Capture>,
}

impl Parser {
    pub fn append(&mut self, bytes: &[u8]) -> Vec<Event> {
        let mut events = Vec::new();
        for byte in bytes {
            if *byte == b'\n' {
                let line = std::mem::take(&mut self.pending);
                events.extend(self.consume(&line));
            } else if self.pending.len() < MAX_LINE {
                self.pending.push(*byte);
            } else {
                self.pending.clear();
                self.capture = None;
            }
        }
        events
    }

    pub fn finish(&mut self) -> Vec<Event> {
        let line = std::mem::take(&mut self.pending);
        let mut events = if line.is_empty() { Vec::new() } else { self.consume(&line) };
        if let Some(capture) = self.capture.take() {
            if let Some(prediction) = prediction(capture) { events.push(Event::Prediction(prediction)); }
        }
        events
    }

    fn consume(&mut self, raw: &[u8]) -> Vec<Event> {
        let line = raw.strip_suffix(b"\r").unwrap_or(raw);
        if let Some((at, instance, message)) = header(line) {
            let mut completed: Vec<Event> = self.capture.take().and_then(prediction).map(Event::Prediction).into_iter().collect();
            if message.starts_with("Generated prediction: {") {
                self.capture = Some(Capture { instance, at, usage: String::new(), stats: String::new(), block: None });
            } else if message.starts_with("Running ") && message.contains("completion") {
                completed.push(Event::RequestStarted { instance, at });
            } else if message.starts_with("Prompt processing progress: 100") {
                completed.push(Event::PromptProcessed { instance, at });
            }
            return completed;
        }
        if is_header_shaped(line) {
            return self.capture.take().and_then(prediction).map(Event::Prediction).into_iter().collect();
        }
        let Some(capture) = self.capture.as_mut() else { return Vec::new(); };
        if line == b"}" {
            return self.capture.take().and_then(prediction).map(Event::Prediction).into_iter().collect();
        }
        if let Some(block) = capture.block {
            if line.starts_with(b"  }") {
                capture.block = None;
            } else if let Ok(text) = std::str::from_utf8(line) {
                let buffer = match block { Block::Usage => &mut capture.usage, Block::Stats => &mut capture.stats };
                if buffer.len().saturating_add(text.len()) < MAX_LINE {
                    buffer.push_str(text);
                    buffer.push('\n');
                } else { self.capture = None; }
            }
        } else if line.starts_with(b"  \"usage\": {") && !line.windows(2).any(|window| window == b"{}") {
            capture.block = Some(Block::Usage);
        } else if line.starts_with(b"  \"stats\": {") && !line.windows(2).any(|window| window == b"{}") {
            capture.block = Some(Block::Stats);
        }
        Vec::new()
    }
}

fn header(line: &[u8]) -> Option<(u64, String, String)> {
    if !is_header_shaped(line) { return None; }
    let stamp = std::str::from_utf8(line.get(1..20)?).ok()?;
    let rest = line.get(21..)?;
    let rest = rest.strip_prefix(b"[")?;
    let level_end = rest.iter().position(|byte| *byte == b']')?;
    let rest = rest.get(level_end + 1..)?;
    let (instance, message) = if let Some(tag) = rest.strip_prefix(b"[") {
        let end = tag.iter().position(|byte| *byte == b']')?;
        (String::from_utf8_lossy(&tag[..end]).into_owned(), tag.get(end + 1..)?)
    } else { (String::new(), rest) };
    let message = message.iter().position(|byte| *byte != b' ').and_then(|start| message.get(start..))?;
    if !matches!(message[0], b'R' | b'P' | b'G') { return None; }
    let message = String::from_utf8_lossy(message).to_string();
    if !message.starts_with("Running ") && !message.starts_with("Prompt processing progress: 100")
        && !message.starts_with("Generated prediction: {") { return None; }
    let parsed = NaiveDateTime::parse_from_str(stamp, "%Y-%m-%d %H:%M:%S").ok()?;
    let at = Local.from_local_datetime(&parsed).earliest()?.timestamp_millis();
    Some((u64::try_from(at).ok()?, instance, message))
}

fn is_header_shaped(line: &[u8]) -> bool {
    line.len() >= 25 && line.first() == Some(&b'[') && line.get(20) == Some(&b']')
        && line.get(5) == Some(&b'-') && line.get(8) == Some(&b'-')
        && line.get(11) == Some(&b' ') && line.get(14) == Some(&b':')
        && line.get(17) == Some(&b':')
}

fn integer(value: &Value) -> Option<u64> {
    // JSON true/false never enter Number. Swift asks Int(exactly: number.doubleValue),
    // which also accepts 7.0 while rejecting fractions and Int64 overflow.
    let number = value.as_number()?.as_f64()?;
    (number.is_finite() && number >= 0.0 && number < 9_223_372_036_854_775_808.0
        && number.fract() == 0.0).then(|| number as u64)
}
fn positive(value: &Value) -> Option<f64> { value.as_f64().filter(|n| n.is_finite() && *n > 0.0) }
fn object(text: &str) -> Value {
    serde_json::from_str(&format!("{{{text}}}")).unwrap_or(Value::Null)
}
fn prediction(capture: Capture) -> Option<LocalPrediction> {
    let usage = object(&capture.usage);
    let stats = object(&capture.stats);
    let input = integer(&usage["prompt_tokens"]).or_else(|| integer(&stats["input_tokens"]));
    let output = integer(&usage["completion_tokens"]).or_else(|| integer(&stats["total_output_tokens"]));
    if input.is_none() && output.is_none() { return None; }
    Some(LocalPrediction {
        instance: capture.instance, at: capture.at, input_tokens: input, output_tokens: output,
        reasoning_tokens: integer(&usage["completion_tokens_details"]["reasoning_tokens"])
            .or_else(|| integer(&stats["reasoning_output_tokens"])),
        tokens_per_second: positive(&stats["tokens_per_second"]),
        time_to_first_token: positive(&stats["time_to_first_token"])
            .or_else(|| positive(&stats["time_to_first_token_seconds"])),
        generation_seconds: positive(&stats["generation_time"]),
        draft_tokens: integer(&usage["total_draft_tokens_count"])
            .or_else(|| integer(&stats["total_draft_tokens_count"])),
        accepted_draft_tokens: integer(&usage["accepted_draft_tokens_count"])
            .or_else(|| integer(&stats["accepted_draft_tokens_count"])),
    })
}

/// Old files stream oldest first; the newest parser keeps a half-written line for the next poll.
pub struct Tail {
    root: PathBuf,
    current: Option<PathBuf>,
    offset: u64,
    parser: Parser,
    cancel: Option<Arc<AtomicBool>>,
}
impl Tail {
    pub fn new(root: PathBuf) -> Self {
        Self { root, current: None, offset: 0, parser: Parser::default(), cancel: None }
    }
    pub fn with_cancel(root: PathBuf, cancel: Arc<AtomicBool>) -> Self {
        Self { cancel: Some(cancel), ..Self::new(root) }
    }

    fn files(&self) -> Vec<PathBuf> {
        let mut months: Vec<_> = fs::read_dir(&self.root).ok().into_iter().flatten()
            .filter_map(Result::ok).filter(|entry| entry.file_type().ok().is_some_and(|kind| kind.is_dir()))
            .map(|entry| entry.path()).collect();
        months.sort();
        let mut files = Vec::new();
        for month in months {
            let mut day_files: Vec<_> = fs::read_dir(&month).ok().into_iter().flatten()
                .filter_map(Result::ok)
                .filter(|entry| entry.file_type().ok().is_some_and(|kind| kind.is_file())
                    && entry.file_name().to_string_lossy().ends_with(".log"))
                .map(|entry| entry.path()).collect();
            day_files.sort_by(|a,b| log_order(a).cmp(&log_order(b)));
            files.extend(day_files);
        }
        files
    }

    pub fn load_history(&mut self, mut absorb: impl FnMut(Event)) {
        let files = self.files();
        for (index, path) in files.iter().enumerate() {
            if self.cancel.as_ref().is_some_and(|cancel| cancel.load(Ordering::Acquire)) { break; }
            let mut parser = Parser::default();
            let bytes = read_from(path, 0, &mut parser, &mut absorb, &self.cancel);
            if index + 1 == files.len() {
                self.parser = parser;
                self.current = Some(path.clone());
                self.offset = bytes;
            } else { for event in parser.finish() { absorb(event); } }
        }
    }

    pub fn poll(&mut self, mut absorb: impl FnMut(Event)) {
        let Some(newest) = self.files().pop() else { return; };
        if self.current.as_ref() != Some(&newest) {
            for event in self.parser.finish() { absorb(event); }
            self.parser = Parser::default();
            self.current = Some(newest.clone());
            self.offset = 0;
        }
        let size = fs::metadata(&newest).map(|meta| meta.len()).unwrap_or(0);
        if size < self.offset { self.offset = 0; self.parser = Parser::default(); }
        if size > self.offset {
            self.offset += read_from(&newest, self.offset, &mut self.parser, &mut absorb, &self.cancel);
        }
    }
}

fn log_order(path: &Path) -> (String, u32) {
    let name = path.file_name().and_then(|name| name.to_str()).unwrap_or_default().trim_end_matches(".log");
    let mut parts = name.splitn(2, '.');
    let day = parts.next().unwrap_or_default().to_owned();
    let index = parts.next().and_then(|index| index.parse().ok()).unwrap_or(0);
    (day, index)
}

fn read_from(path: &Path, offset: u64, parser: &mut Parser, absorb: &mut impl FnMut(Event), cancel: &Option<Arc<AtomicBool>>) -> u64 {
    let Ok(mut file) = File::open(path) else { return 0; };
    if file.seek(SeekFrom::Start(offset)).is_err() { return 0; }
    let mut total = 0;
    let mut buffer = vec![0; 4 * 1024 * 1024];
    loop {
        if cancel.as_ref().is_some_and(|cancel| cancel.load(Ordering::Acquire)) { break; }
        let Ok(size) = file.read(&mut buffer) else { break; };
        if size == 0 { break; }
        total += size as u64;
        for event in parser.append(&buffer[..size]) { absorb(event); }
    }
    total
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn split_log_discards_prompt_and_reply_and_keeps_numeric_stats() {
        let log = b"[2026-09-10 00:35:56][INFO][qwen] Generated prediction: {\n  \"id\": \"private-reply\",\n  \"usage\": {\n    \"prompt_tokens\": 66,\n    \"completion_tokens\": 300,\n    \"completion_tokens_details\": {\"reasoning_tokens\": 12}\n  },\n  \"stats\": {\n    \"tokens_per_second\": 17.9,\n    \"generation_time\": 17.8\n  },\n  \"messages\": \"private-prompt\"\n}\n";
        let mut parser = Parser::default();
        let mut events = parser.append(&log[..90]);
        events.extend(parser.append(&log[90..]));
        assert_eq!(events.len(), 1);
        let Event::Prediction(prediction) = &events[0] else { panic!("expected prediction") };
        assert_eq!(prediction.input_tokens, Some(66));
        assert_eq!(prediction.output_tokens, Some(300));
        assert_eq!(prediction.reasoning_tokens, Some(12));
        let serialized = serde_json::to_string(&events).unwrap();
        assert!(!serialized.contains("private-prompt") && !serialized.contains("private-reply"));
    }

    #[test]
    fn request_and_prompt_phases_are_events_without_parsing_chatter_dates() {
        let mut parser = Parser::default();
        let events = parser.append(b"[bad-date-xx xx:xx:xx][INFO][server] Routine log\n[2026-09-10 00:35:38][INFO][qwen] Running chat completion on conversation with 1 messages.\n[2026-09-10 00:35:39][INFO][qwen] Prompt processing progress: 100.0%\n");
        assert_eq!(events.len(), 2);
        assert!(matches!(&events[0], Event::RequestStarted{instance,..} if instance == "qwen"));
        assert!(matches!(&events[1], Event::PromptProcessed{instance,..} if instance == "qwen"));
    }
    #[test]
    fn integer_matches_swift_exact_double_conversion() {
        assert_eq!(integer(&serde_json::json!(7.0)), Some(7));
        assert_eq!(integer(&serde_json::json!(0)), Some(0));
        assert_eq!(integer(&serde_json::json!(7.5)), None);
        assert_eq!(integer(&serde_json::json!(true)), None);
        assert_eq!(integer(&serde_json::json!(u64::MAX)), None);
    }
    #[test]
    fn tail_orders_numeric_rotations_and_reads_only_new_bytes() {
        let root = tempfile::tempdir().unwrap();
        let month = root.path().join("2026-09");
        fs::create_dir_all(&month).unwrap();
        let old = month.join("2026-09-10.9.log");
        let newest = month.join("2026-09-10.10.log");
        fs::write(&old, "[2026-09-10 00:00:00][INFO][first] Running chat completion\n").unwrap();
        fs::write(&newest, "[2026-09-10 00:00:01][INFO][second] Running chat completion\n").unwrap();
        let mut tail = Tail::new(root.path().into());
        let mut events = Vec::new();
        tail.load_history(|event| events.push(event));
        assert!(matches!(&events[0], Event::RequestStarted{instance,..} if instance == "first"));
        assert!(matches!(&events[1], Event::RequestStarted{instance,..} if instance == "second"));
        use std::io::Write;
        File::options().append(true).open(&newest).unwrap()
            .write_all(b"[2026-09-10 00:00:02][INFO][second] Prompt processing progress: 100.0%\n").unwrap();
        tail.poll(|event| events.push(event));
        assert_eq!(events.len(), 3);
        tail.poll(|event| events.push(event));
        assert_eq!(events.len(), 3);
    }
}
