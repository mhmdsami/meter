use crate::pricing::Pricing;
use crate::scan::Row;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::Path;
use time::OffsetDateTime;
use time::UtcOffset;

#[derive(Deserialize)]
struct Fact {
    id: Option<String>,
    created_at_ms: Option<f64>,
    input_tokens: Option<f64>,
    cache_read_tokens: Option<f64>,
    output_tokens: Option<f64>,
    total_cost: Option<f64>,
    model: Option<String>,
}

#[derive(Deserialize)]
struct Line {
    kind: Option<String>,
    fact: Option<Fact>,
}

struct Generation {
    day: String,
    cost: f64,
    input: f64,
    read: f64,
    output: f64,
    model: String,
    tokens: f64,
}

/// `pending` and final lines share an id, so keep the most complete one.
/// fx keeps cumulative token snapshots in its v2 session logs, so Grok usage
/// does not appear in `usage.jsonl` (that file only holds gateway-billed
/// generations). Each `set usage` is a running total; the delta between two
/// snapshots is what one turn cost.
pub fn v2_sessions(host: &str, root: &Path, since_ms: i64, pricing: &Pricing) -> Vec<Row> {
    let mut workspaces: HashMap<String, String> = HashMap::new();
    if let Ok(handle) = fs::File::open(root.join("index.jsonl")) {
        for line in BufReader::new(handle).lines().map_while(Result::ok) {
            let Ok(value) = serde_json::from_str::<serde_json::Value>(&line) else {
                continue;
            };
            if value.get("op").and_then(|v| v.as_str()) != Some("put") {
                continue;
            }
            let (Some(id), Some(workspace)) = (
                value.get("id").and_then(|v| v.as_str()),
                value.get("workspace").and_then(|v| v.as_str()),
            ) else {
                continue;
            };
            workspaces
                .entry(id.to_string())
                .or_insert_with(|| workspace.to_string());
        }
    }

    let mut rows = Vec::new();
    let Ok(entries) = fs::read_dir(root) else {
        return rows;
    };
    for entry in entries.flatten() {
        let dir = entry.path();
        if !dir.is_dir() {
            continue;
        }
        let Some(id) = dir.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        let Ok(handle) = fs::File::open(dir.join("log.jsonl")) else {
            continue;
        };
        let project = workspaces.get(id).cloned().unwrap_or_default();
        let mut model: Option<String> = None;
        let mut provider: Option<String> = None;
        let mut last = (0i64, 0i64, 0i64, 0i64, 0i64);

        for line in BufReader::new(handle).lines().map_while(Result::ok) {
            let Ok(value) = serde_json::from_str::<serde_json::Value>(&line) else {
                continue;
            };
            if value.get("kind").and_then(|v| v.as_str()) != Some("set") {
                continue;
            }
            let Some(key) = value.get("key").and_then(|v| v.as_str()) else {
                continue;
            };
            let Some(payload) = value.get("value") else {
                continue;
            };
            match key {
                "prefs" => {
                    provider = payload
                        .get("provider")
                        .and_then(|v| v.as_str())
                        .map(str::to_string);
                    model = payload
                        .get("model")
                        .and_then(|v| v.as_str())
                        .map(str::to_string);
                }
                "usage" => {
                    let field =
                        |name: &str| payload.get(name).and_then(|v| v.as_i64()).unwrap_or(0);
                    let now = (
                        field("input_tokens"),
                        field("output_tokens"),
                        field("cache_read_tokens"),
                        field("cache_write_tokens"),
                        field("reasoning_tokens"),
                    );
                    let delta = (
                        (now.0 - last.0).max(0),
                        (now.1 - last.1).max(0),
                        (now.2 - last.2).max(0),
                        (now.3 - last.3).max(0),
                        (now.4 - last.4).max(0),
                    );
                    last = now;
                    if provider.as_deref() != Some("grok") {
                        continue;
                    }
                    let Some(model_name) = model.as_deref() else {
                        continue;
                    };
                    let Some(ts) = value.get("ts").and_then(|v| v.as_i64()) else {
                        continue;
                    };
                    if ts < since_ms {
                        continue;
                    }
                    let Some(day) = local_day_ms(ts) else {
                        continue;
                    };
                    let Some(cost) = pricing.cost(model_name, None) else {
                        continue;
                    };
                    let spent = pricing.claude(
                        cost,
                        delta.0 as f64,
                        delta.2 as f64,
                        delta.3 as f64,
                        (delta.1 + delta.4) as f64,
                    );
                    let tokens = delta.0 + delta.1 + delta.2 + delta.3 + delta.4;
                    if spent <= 0.004 && tokens == 0 {
                        continue;
                    }
                    rows.push(Row {
                        host: host.to_string(),
                        day,
                        provider: "grok".to_string(),
                        project: project.clone(),
                        model: model_name.to_string(),
                        spent,
                        tokens,
                        source: "estimated".to_string(),
                    });
                }
                _ => {}
            }
        }
    }
    rows
}

fn local_day_ms(ms: i64) -> Option<String> {
    let offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    OffsetDateTime::from_unix_timestamp_nanos(ms as i128 * 1_000_000)
        .ok()
        .map(|time| time.to_offset(offset).date().to_string())
}

fn generations(path: &Path) -> Vec<Generation> {
    let Ok(handle) = fs::File::open(path) else {
        return Vec::new();
    };
    let mut best: HashMap<String, Generation> = HashMap::new();
    for line in BufReader::new(handle).lines() {
        let Ok(line) = line else { continue };
        let Ok(obj) = serde_json::from_str::<Line>(&line) else {
            continue;
        };
        if obj.kind.as_deref() != Some("generation") {
            continue;
        }
        let Some(fact) = obj.fact else { continue };
        let Some(id) = fact.id else { continue };
        let Some(ms) = fact.created_at_ms else {
            continue;
        };
        let input = fact.input_tokens.unwrap_or(0.0);
        let read = fact.cache_read_tokens.unwrap_or(0.0);
        let output = fact.output_tokens.unwrap_or(0.0);
        let offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
        let day = OffsetDateTime::from_unix_timestamp_nanos((ms * 1e6) as i128)
            .map(|time| time.to_offset(offset).date().to_string())
            .unwrap_or_default();
        let generation = Generation {
            day,
            cost: fact.total_cost.unwrap_or(0.0),
            input,
            read,
            output,
            model: fact.model.unwrap_or_default(),
            tokens: input + read + output,
        };
        match best.get(&id) {
            Some(previous) if previous.cost > generation.cost => {}
            Some(previous)
                if previous.cost == generation.cost && previous.tokens > generation.tokens => {}
            _ => {
                best.insert(id, generation);
            }
        }
    }
    best.into_values().collect()
}

/// What the gateway actually charged, and Codex usage it bills at $0 because
/// the subscription covers it (priced here from the logged tokens).
pub fn rows(host: &str, path: &Path, since_day: &str, pricing: &Pricing) -> Vec<Row> {
    let mut out = Vec::new();
    for generation in generations(path) {
        if generation.day.is_empty() || generation.day.as_str() < since_day {
            continue;
        }
        if generation.cost > 0.0 {
            out.push(Row {
                host: host.to_string(),
                day: generation.day.clone(),
                provider: "vercel".to_string(),
                project: String::new(),
                model: generation.model.clone(),
                spent: generation.cost,
                tokens: (generation.input + generation.read + generation.output) as i64,
                source: "reported".to_string(),
            });
            continue;
        }
        let Some(bare) = generation.model.strip_prefix("codex/") else {
            continue;
        };
        let Some(cost) = pricing.cost(bare, None) else {
            continue;
        };
        let spent = pricing.codex(cost, generation.input, generation.read, generation.output);
        let tokens = (generation.input + generation.output) as i64;
        if spent > 0.0 || tokens > 0 {
            out.push(Row {
                host: host.to_string(),
                day: generation.day.clone(),
                provider: "codex".to_string(),
                project: String::new(),
                model: bare.to_string(),
                spent,
                tokens,
                source: "estimated".to_string(),
            });
        }
    }
    out
}
