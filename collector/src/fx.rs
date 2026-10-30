use crate::pricing::Pricing;
use crate::scan::Row;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
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
fn generations(path: &Path) -> Vec<Generation> {
    let Ok(text) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut best: HashMap<String, Generation> = HashMap::new();
    for line in text.lines() {
        let Ok(obj) = serde_json::from_str::<Line>(line) else {
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
