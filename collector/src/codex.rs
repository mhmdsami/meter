use crate::pricing::Pricing;
use crate::scan::Row;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};
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
    parent_thread_id: Option<String>,
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

/// One day of a session, already net of the previous day's running total.
struct Day {
    day: String,
    input: f64,
    cached: f64,
    output: f64,
    model: Option<String>,
}

struct Session {
    project: String,
    parent: Option<String>,
    days: Vec<Day>,
}

/// Codex reviews approvals in a child thread running `codex-auto-review`, a
/// hidden model with no published rate. Such a thread is billed at the rate of
/// the thread that spawned it instead of disappearing from the ledger.
struct Parents {
    files: HashMap<String, PathBuf>,
    models: HashMap<String, Option<String>>,
}

impl Parents {
    fn new(files: &[PathBuf]) -> Parents {
        let mut index = HashMap::new();
        for file in files {
            let Some(stem) = file.file_stem().and_then(|name| name.to_str()) else {
                continue;
            };
            let Some(id) = stem.get(stem.len().saturating_sub(36)..) else {
                continue;
            };
            if id.len() == 36 {
                index.entry(id.to_string()).or_insert_with(|| file.clone());
            }
        }
        Parents {
            files: index,
            models: HashMap::new(),
        }
    }

    fn model(&mut self, id: &str, pricing: &Pricing) -> Option<String> {
        if !self.models.contains_key(id) {
            let model = self
                .files
                .get(id)
                .and_then(|path| first_priced_model(path, pricing));
            self.models.insert(id.to_string(), model);
        }
        self.models.get(id).cloned().flatten()
    }
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
    files.retain(|file| {
        fs::metadata(file)
            .ok()
            .and_then(|meta| meta.modified().ok())
            .and_then(|modified| modified.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|since| (since.as_millis() as i64) >= since_ms)
            .unwrap_or(true)
    });
    let mut parents = Parents::new(&files);
    let mut rows = Vec::new();
    for file in &files {
        rows.extend(file_rows(host, file, since_day, pricing, &mut parents));
    }
    rows
}

fn file_rows(
    host: &str,
    path: &Path,
    since_day: &str,
    pricing: &Pricing,
    parents: &mut Parents,
) -> Vec<Row> {
    let Some(session) = read_session(path, pricing) else {
        return Vec::new();
    };
    let mut rows = Vec::new();
    for day in session.days {
        let model = day.model.or_else(|| {
            session
                .parent
                .as_deref()
                .and_then(|id| parents.model(id, pricing))
        });
        let Some(model) = model else { continue };
        let Some(cost) = pricing.cost(&model, None) else {
            continue;
        };
        if day.day.as_str() < since_day {
            continue;
        }
        let spent = pricing.codex(cost, day.input, day.cached, day.output);
        let tokens = (day.input + day.output) as i64;
        if spent > 0.0 || tokens > 0 {
            rows.push(Row {
                host: host.to_string(),
                day: day.day,
                provider: "codex".to_string(),
                project: session.project.clone(),
                model,
                spent,
                tokens,
                source: "estimated".to_string(),
            });
        }
    }
    rows
}

fn read_session(path: &Path, pricing: &Pricing) -> Option<Session> {
    let handle = fs::File::open(path).ok()?;
    let mut events: Vec<Event> = Vec::new();
    let mut project = String::new();
    let mut parent: Option<String> = None;
    let mut current_model = String::new();

    for line in BufReader::new(handle).lines().map_while(Result::ok) {
        let Ok(obj) = serde_json::from_str::<Line>(&line) else {
            continue;
        };
        match obj.kind.as_deref() {
            Some("session_meta") => {
                if let Some(payload) = &obj.payload {
                    if let Some(cwd) = &payload.cwd {
                        project = cwd.clone();
                    }
                    if let Some(id) = &payload.parent_thread_id {
                        parent = Some(id.clone());
                    }
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
        return None;
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
                // A subagent label can open the day and carries no rate; billing
                // it to an unpriced model would drop the whole day.
                model: if event.model.is_empty() || pricing.cost(&event.model, None).is_none() {
                    None
                } else {
                    Some(event.model.clone())
                },
            }),
        }
    }

    let mut before = (0.0_f64, 0.0_f64, 0.0_f64);
    for day in &mut days {
        let previous = before;
        before.0 = before.0.max(day.input);
        before.1 = before.1.max(day.cached);
        before.2 = before.2.max(day.output);
        day.input = (day.input - previous.0).max(0.0);
        day.cached = (day.cached - previous.1).max(0.0);
        day.output = (day.output - previous.2).max(0.0);
    }
    Some(Session {
        project,
        parent,
        days,
    })
}

fn first_priced_model(path: &Path, pricing: &Pricing) -> Option<String> {
    let handle = fs::File::open(path).ok()?;
    for line in BufReader::new(handle).lines().map_while(Result::ok) {
        let Ok(obj) = serde_json::from_str::<Line>(&line) else {
            continue;
        };
        if obj.kind.as_deref() != Some("turn_context") {
            continue;
        }
        if let Some(model) = obj.payload.and_then(|payload| payload.model) {
            if pricing.cost(&model, None).is_some() {
                return Some(model);
            }
        }
    }
    None
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

    const PARENT: &str = "01111111-2222-3333-4444-555555555555";
    const CHILD: &str = "02222222-3333-4444-5555-666666666666";

    fn fixture(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("meter-codex-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn rollout(dir: &Path, id: &str) -> PathBuf {
        dir.join(format!("rollout-2026-01-02T10-00-00-{id}.jsonl"))
    }

    #[test]
    fn day_growth_is_billed_once() {
        let root = fixture("growth");
        let file = rollout(&root, "03333333-4444-5555-6666-777777777777");
        let lines = [
            r#"{"type":"session_meta","payload":{"cwd":"/tmp/app"}}"#,
            r#"{"type":"turn_context","payload":{"model":"gpt-5.2"}}"#,
            r#"{"type":"event_msg","timestamp":"2026-01-02T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":0}}}}"#,
            r#"{"type":"event_msg","timestamp":"2026-01-03T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000000,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        ];
        fs::write(&file, lines.join("\n")).unwrap();
        let pricing = Pricing::with_rate("gpt-5.2", crate::pricing::Cost::default());
        let rows = scan(
            "mac",
            std::slice::from_ref(&root),
            0,
            "2026-01-01",
            &pricing,
        );
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].tokens, 1_000_000);
        assert_eq!(rows[1].tokens, 1_000_000);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn guardian_thread_inherits_the_parent_rate() {
        let root = fixture("guardian");
        let parent = rollout(&root, PARENT);
        let child = rollout(&root, CHILD);
        fs::write(
            &parent,
            [
                r#"{"type":"session_meta","payload":{"cwd":"/tmp/parent"}}"#,
                r#"{"type":"turn_context","payload":{"model":"gpt-5.2"}}"#,
                r#"{"type":"event_msg","timestamp":"2026-01-02T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":0}}}}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        let child_lines = [
            format!(
                r#"{{"type":"session_meta","payload":{{"cwd":"/tmp/child","parent_thread_id":"{PARENT}"}}}}"#
            ),
            r#"{"type":"turn_context","payload":{"model":"codex-auto-review"}}"#.to_string(),
            r#"{"type":"event_msg","timestamp":"2026-01-02T10:05:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":700,"cached_input_tokens":0,"output_tokens":0}}}}"#.to_string(),
        ];
        fs::write(&child, child_lines.join("\n")).unwrap();
        let pricing = Pricing::with_rate("gpt-5.2", crate::pricing::Cost::default());
        let rows = scan(
            "mac",
            std::slice::from_ref(&root),
            0,
            "2026-01-01",
            &pricing,
        );
        let review = rows
            .iter()
            .find(|row| row.project == "/tmp/child")
            .expect("guardian tokens are billed");
        assert_eq!(review.model, "gpt-5.2");
        assert_eq!(review.tokens, 700);
        let _ = fs::remove_dir_all(&root);
    }
}
