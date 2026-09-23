//! Metadata-only observer for Ollama's NDJSON and OpenAI-compatible SSE responses.
//! Prompt and answer bytes are never retained beyond the current bounded line.
use serde::Serialize;
use serde_json::Value;

const MAX_LINE: usize = 1_048_576;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Performance {
    pub output_tokens: u64,
    pub generation_seconds: f64,
    pub measured_at: u64,
    pub approximate: bool,
}

impl Performance {
    pub fn tokens_per_second(&self) -> f64 {
        self.output_tokens as f64 / self.generation_seconds
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Transition {
    pub model: String,
    pub thinking: bool,
}

pub struct Observer {
    pending: Vec<u8>,
    pub model: String,
    thinking: bool,
    observing: bool,
    sse: bool,
    native: bool,
    streaming: bool,
    performance: Option<Performance>,
}

impl Observer {
    pub fn new(path: &str, body: &[u8]) -> Self {
        let request: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
        let model = request["model"].as_str().unwrap_or_default().to_owned();
        let sse = path == "/v1/chat/completions";
        let native = matches!(path, "/api/chat" | "/api/generate");
        let streaming = if sse {
            request["stream"] == true
        } else {
            request["stream"] != false
        };
        let observing = !model.is_empty() && (native || (sse && streaming));
        Self {
            pending: Vec::new(), model, thinking: false, observing, sse, native, streaming,
            performance: None,
        }
    }

    pub fn model_key(name: &str) -> String {
        let name = name.trim();
        if name.rsplit('/').next().unwrap_or_default().contains(':') {
            name.to_owned()
        } else {
            format!("{name}:latest")
        }
    }

    pub fn append(&mut self, bytes: &[u8], now_ms: u64) -> Vec<Transition> {
        if !self.observing { return Vec::new(); }
        if !self.streaming {
            if self.pending.len().saturating_add(bytes.len()) > MAX_LINE {
                self.observing = false;
                self.pending.clear();
            } else {
                self.pending.extend_from_slice(bytes);
            }
            return Vec::new();
        }
        let mut changes = Vec::new();
        for byte in bytes {
            if *byte == b'\n' {
                let old_model = self.model.clone();
                let old = self.thinking;
                let line = std::mem::take(&mut self.pending);
                self.consume(&line, now_ms);
                if old && old_model != self.model {
                    changes.push(Transition { model: old_model.clone(), thinking: false });
                }
                if old != self.thinking || (old_model != self.model && self.thinking) {
                    changes.push(Transition { model: self.model.clone(), thinking: self.thinking });
                }
            } else if self.pending.len() < MAX_LINE {
                self.pending.push(*byte);
            } else {
                self.observing = false;
                self.pending.clear();
                if self.thinking {
                    changes.push(Transition { model: self.model.clone(), thinking: false });
                }
                self.thinking = false;
                break;
            }
        }
        changes
    }

    pub fn finish(&mut self, now_ms: u64) {
        if self.observing && !self.pending.is_empty() {
            let line = std::mem::take(&mut self.pending);
            self.consume(&line, now_ms);
        }
        self.pending.clear();
        self.thinking = false;
        self.observing = false;
    }

    pub fn take_performance(&mut self) -> Option<Performance> {
        self.performance.take()
    }

    fn consume(&mut self, line: &[u8], now_ms: u64) {
        let data = if self.sse {
            let Ok(text) = std::str::from_utf8(line) else { return; };
            let Some(payload) = text.strip_prefix("data:") else { return; };
            let payload = payload.trim();
            if payload == "[DONE]" {
                self.thinking = false;
                self.observing = false;
                return;
            }
            payload.as_bytes()
        } else { line };
        if data.is_empty() { return; }
        let Ok(item) = serde_json::from_slice::<Value>(data) else {
            self.thinking = false;
            self.observing = false;
            return;
        };
        if let Some(name) = item["model"].as_str().filter(|s| !s.is_empty()) {
            self.model = name.to_owned();
        }
        if item["done"] == true || !item["error"].is_null() {
            if self.native && item["done"] == true && item["error"].is_null() {
                let count = item["eval_count"].as_u64().filter(|n| *n > 0);
                let duration = item["eval_duration"].as_u64().filter(|n| *n > 0);
                if let (Some(output_tokens), Some(nanos)) = (count, duration) {
                    self.performance = Some(Performance {
                        output_tokens,
                        generation_seconds: nanos as f64 / 1_000_000_000.,
                        measured_at: now_ms,
                        approximate: false,
                    });
                }
            }
            self.thinking = false;
            self.observing = false;
            return;
        }
        if !self.streaming { return; }
        let msg = &item["message"];
        let mut thinking = nonempty(&item["thinking"]) || nonempty(&msg["thinking"]);
        let mut answer = nonempty(&item["response"]) || nonempty(&msg["content"]);
        let mut tool = nonempty_array(&msg["tool_calls"]);
        if self.sse {
            if let Some(choices) = item["choices"].as_array() {
                for choice in choices {
                    if !choice["finish_reason"].is_null() {
                        self.thinking = false;
                        self.observing = false;
                        return;
                    }
                    let delta = &choice["delta"];
                    thinking |= nonempty(&delta["reasoning"]) || nonempty(&delta["reasoning_content"]);
                    answer |= nonempty(&delta["content"]);
                    tool |= nonempty_array(&delta["tool_calls"]);
                }
            }
        }
        if answer || tool { self.thinking = false; }
        else if thinking { self.thinking = true; }
    }
}

fn nonempty(value: &Value) -> bool { value.as_str().is_some_and(|s| !s.is_empty()) }
fn nonempty_array(value: &Value) -> bool { value.as_array().is_some_and(|v| !v.is_empty()) }

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_stream_tracks_phase_and_uses_only_final_numeric_stats() {
        let mut o = Observer::new("/api/chat", br#"{"model":"qwen","messages":[{"content":"private"}]}"#);
        assert_eq!(o.append(b"{\"message\":{\"thinking\":\"secret reasoning\"}}\n{\"message\":{\"content\":\"private answer\"}}\n", 1), vec![
            Transition {model:"qwen".into(), thinking:true},
            Transition {model:"qwen".into(), thinking:false},
        ]);
        o.append(br#"{"done":true,"eval_count":40,"eval_duration":2000000000}"#, 200);
        o.finish(200);
        let perf = o.take_performance().unwrap();
        assert_eq!(perf.tokens_per_second(), 20.);
        assert_eq!(perf.measured_at, 200);
        assert_eq!(o.take_performance(), None);
    }
    #[test]
    fn sse_and_invalid_stats_do_not_claim_performance() {
        let mut o = Observer::new("/v1/chat/completions", br#"{"model":"m","stream":true}"#);
        assert_eq!(o.append(b"data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"x\"}}]}\n", 1).len(), 1);
        assert_eq!(o.append(b"data: [DONE]\n", 2).len(), 1);
        assert!(o.take_performance().is_none());
        let mut native = Observer::new("/api/generate", br#"{"model":"m"}"#);
        native.append(b"{\"done\":true,\"eval_count\":1.5,\"eval_duration\":9}\n", 3);
        assert!(native.take_performance().is_none());
    }
    #[test]
    fn oversized_line_stops_observation_and_slash_tag_key_is_stable() {
        let mut o = Observer::new("/api/chat", br#"{"model":"library/model"}"#);
        assert!(o.append(&vec![b'x'; MAX_LINE + 1], 1).is_empty());
        assert!(o.append(b"{\"message\":{\"thinking\":\"x\"}}\n", 2).is_empty());
        assert_eq!(Observer::model_key(" library/model "), "library/model:latest");
        assert_eq!(Observer::model_key("library/model:v2"), "library/model:v2");
    }
}
