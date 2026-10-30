use crate::pricing::Pricing;
use crate::scan::Row;
use serde::Deserialize;
use std::fs;
use std::path::{Path, PathBuf};
use time::format_description::well_known::Rfc3339;
use time::{OffsetDateTime, UtcOffset};

fn local_day(ts: &str) -> Option<String> {
    let parsed = OffsetDateTime::parse(ts, &Rfc3339).ok()?;
    let offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    Some(parsed.to_offset(offset).date().to_string())
}

#[derive(Deserialize)]
struct Usage {
    input_tokens: Option<f64>,
    cached_input_tokens: Option<f64>,
    output_tokens: Option<f64>,
}

#[derive(Deserialize)]
struct Info {
    total_token_usage: Option<Usage>,
}

#[derive(Deserialize)]
struct Payload {
    #[serde(rename = "type")]
    kind: Option<String>,
    cwd: Option<String>,
    model: Option<String>,
    info: Option<Info>,
}

#[derive(Deserialize)]
struct Line {
    #[serde(rename = "type")]
    kind: Option<String>,
    timestamp: Option<String>,
    payload: Option<Payload>,
}

struct Event {
    at_ms: i64,
    day: String,
    input: f64,
    cached: f64,
    output: f64,
    model: String,
}

struct Day {
    day: String,
    input: f64,
    cached: f64,
    output: f64,
    model: Option<String>,
}

/// Codex counters are session-wide running totals, so each day's cost is the
/// growth over the previous day's maximum. Resumed threads append to the file
/// created on their first day, which is why the whole file is parsed and only
/// the day bucket is filtered later.
pub fn scan(
    host: &str,
    roots: &[PathBuf],
    since_ms: i64,
    since_day: &str,
    pricing: &Pricing,
) -> Vec<Row> {
    let mut files = Vec::new();
    for root in roots {
        walk(root, &mut files);
    }
    let mut rows = Vec::new();
    for file in files {
        if let Ok(meta) = fs::metadata(&file) {
            if let Ok(modified) = meta.modified() {
                if let Ok(since) = modified.duration_since(std::time::UNIX_EPOCH) {
                    if (since.as_millis() as i64) < since_ms {
                        continue;
                    }
                }
            }
        }
        rows.extend(file_rows(host, &file, since_day, pricing));
    }
    rows
}

fn file_rows(host: &str, path: &Path, since_day: &str, pricing: &Pricing) -> Vec<Row> {
    let Ok(text) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut events: Vec<Event> = Vec::new();
    let mut project = String::new();
    let mut current_model = String::new();

    for line in text.lines() {
        let Ok(obj) = serde_json::from_str::<Line>(line) else {
            continue;
        };
        match obj.kind.as_deref() {
            Some("session_meta") => {
                if let Some(cwd) = obj.payload.as_ref().and_then(|p| p.cwd.clone()) {
                    project = cwd;
                }
            }
            Some("turn_context") => {
                if let Some(payload) = &obj.payload {
                    if let Some(model) = &payload.model {
                        current_model = model.clone();
                    }
                    if project.is_empty() {
                        if let Some(cwd) = &payload.cwd {
                            project = cwd.clone();
                        }
                    }
                }
            }
            Some("event_msg") => {
                let Some(payload) = &obj.payload else {
                    continue;
                };
                if payload.kind.as_deref() != Some("token_count") {
                    continue;
                }
                let Some(info) = &payload.info else { continue };
                let Some(usage) = &info.total_token_usage else {
                    continue;
                };
                let Some(timestamp) = obj.timestamp.as_deref() else {
                    continue;
                };
                let Some(day) = local_day(timestamp) else {
                    continue;
                };
                let Some(at_ms) = OffsetDateTime::parse(timestamp, &Rfc3339)
                    .ok()
                    .map(|time| (time.unix_timestamp_nanos() / 1_000_000) as i64)
                else {
                    continue;
                };
                events.push(Event {
                    at_ms,
                    day,
                    input: usage.input_tokens.unwrap_or(0.0),
                    cached: usage.cached_input_tokens.unwrap_or(0.0),
                    output: usage.output_tokens.unwrap_or(0.0),
                    model: current_model.clone(),
                });
            }
            _ => {}
        }
    }
    if events.is_empty() {
        return Vec::new();
    }
    // Resumed threads can interleave, so order by timestamp before bucketing.
    events.sort_by_key(|event| event.at_ms);

    let mut days: Vec<Day> = Vec::new();
    for event in &events {
        match days.last_mut() {
            Some(day) if day.day == event.day => {
                day.input = day.input.max(event.input);
                day.cached = day.cached.max(event.cached);
                day.output = day.output.max(event.output);
                if !event.model.is_empty() && pricing.cost(&event.model, None).is_some() {
                    day.model = Some(event.model.clone());
                }
            }
            _ => days.push(Day {
                day: event.day.clone(),
                input: event.input,
                cached: event.cached,
                output: event.output,
                model: if event.model.is_empty() {
                    None
                } else {
                    Some(event.model.clone())
                },
            }),
        }
    }

    let mut rows = Vec::new();
    let mut before = (-1.0_f64, -1.0_f64, -1.0_f64);
    for day in days {
        let previous = before;
        before.0 = before.0.max(day.input);
        before.1 = before.1.max(day.cached);
        before.2 = before.2.max(day.output);
        if day.day.as_str() < since_day {
            continue;
        }
        // Subagent labels carry no price and the counters are session-wide, so
        // the day is billed to the last model that has a rate.
        let Some(model) = day
            .model
            .as_deref()
            .filter(|model| pricing.cost(model, None).is_some())
        else {
            continue;
        };
        let Some(cost) = pricing.cost(model, None) else {
            continue;
        };
        let input = (day.input - previous.0.max(0.0)).max(0.0);
        let cached = (day.cached - previous.1.max(0.0)).max(0.0);
        let output = (day.output - previous.2.max(0.0)).max(0.0);
        let spent = pricing.codex(cost, input, cached, output);
        let tokens = (input + output) as i64;
        if spent > 0.0 || tokens > 0 {
            rows.push(Row {
                host: host.to_string(),
                day: day.day.clone(),
                provider: "codex".to_string(),
                project: project.clone(),
                model: model.to_string(),
                spent,
                tokens,
                source: "estimated".to_string(),
            });
        }
    }
    rows
}

fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            walk(&path, out);
        } else if path.extension().and_then(|ext| ext.to_str()) == Some("jsonl") {
            out.push(path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn day_growth_is_billed_once() {
        let dir = std::env::temp_dir().join(format!("meter-codex-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let file = dir.join("rollout.jsonl");
        let lines = [
            r#"{"type":"session_meta","payload":{"cwd":"/tmp/app"}}"#,
            r#"{"type":"turn_context","payload":{"model":"gpt-5.2"}}"#,
            r#"{"type":"event_msg","timestamp":"2026-01-02T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":0}}}}"#,
            r#"{"type":"event_msg","timestamp":"2026-01-03T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000000,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        ];
        fs::write(&file, lines.join("\n")).unwrap();
        let pricing = Pricing::with_rate("gpt-5.2", crate::pricing::Cost::default());
        let rows = file_rows("mac", &file, "2026-01-01", &pricing);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].tokens, 1_000_000);
        assert_eq!(rows[1].tokens, 1_000_000);
        let _ = fs::remove_dir_all(&dir);
    }
}
