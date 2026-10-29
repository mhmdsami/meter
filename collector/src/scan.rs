use crate::pricing::Pricing;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use time::format_description::well_known::Rfc3339;
use time::{OffsetDateTime, UtcOffset};

#[derive(serde::Serialize, Clone)]
pub struct Row {
    pub host: String,
    pub day: String,
    pub provider: String,
    pub project: String,
    pub model: String,
    pub spent: f64,
    pub tokens: i64,
    pub source: String,
}

fn local_day(ts: &str) -> Option<String> {
    let parsed = OffsetDateTime::parse(ts, &Rfc3339).ok()?;
    let offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    Some(parsed.to_offset(offset).date().to_string())
}

fn bare_model(model: &str) -> String {
    let base = model.rsplit('/').next().unwrap_or(model);
    if let Some(idx) = base.rfind("-thinking-") {
        base[..idx].to_string()
    } else {
        base.to_string()
    }
}

fn pi_provider(provider: &str) -> &'static str {
    match provider {
        "straitly" => "straitly",
        "openai-codex" | "openai" => "codex",
        "opencode-go" | "opencode" => "opencode",
        "openrouter" => "openrouter",
        "anthropic" => "claude",
        "google" | "google-vertex" | "gemini" => "antigravity",
        _ => "other",
    }
}

fn opencode_provider(provider: &str) -> &'static str {
    match provider {
        "opencode-go" | "opencode" => "opencode",
        _ => "other",
    }
}

// MARK: - opencode

#[derive(Deserialize)]
struct OcRow {
    day: String,
    cwd: Option<String>,
    provider: Option<String>,
    model: Option<String>,
    total: Option<f64>,
    input: Option<f64>,
    output: Option<f64>,
    reasoning: Option<f64>,
    cache_read: Option<f64>,
    cache_write: Option<f64>,
}

const OPENCODE_QUERY: &str = r#"
import sqlite3, json, sys
path, since = sys.argv[1], int(sys.argv[2])
con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
sql = """
SELECT date(m.time_created/1000,'unixepoch','localtime') AS day,
       s.directory AS cwd,
       json_extract(m.data,'$.model.providerID') AS provider,
       json_extract(m.data,'$.model.id') AS model,
       SUM(json_extract(m.data,'$.cost')) AS total,
       SUM(COALESCE(json_extract(m.data,'$.tokens.input'),0)) AS input,
       SUM(COALESCE(json_extract(m.data,'$.tokens.output'),0)) AS output,
       SUM(COALESCE(json_extract(m.data,'$.tokens.reasoning'),0)) AS reasoning,
       SUM(COALESCE(json_extract(m.data,'$.tokens.cache.read'),0)) AS cache_read,
       SUM(COALESCE(json_extract(m.data,'$.tokens.cache.write'),0)) AS cache_write
FROM session_message m JOIN session_v2 s ON s.id = m.session_id
WHERE m.type='assistant' AND m.time_created >= ?
GROUP BY day, cwd, provider, model
"""
cur = con.execute(sql, (since,))
cols = [d[0] for d in cur.description]
print(json.dumps([dict(zip(cols, r)) for r in cur.fetchall()]))
"#;

pub fn opencode(host: &str, path: &Path, since_ms: i64, pricing: &Pricing) -> Vec<Row> {
    if !path.exists() {
        return Vec::new();
    }
    let output = Command::new("/usr/bin/python3")
        .args(["-c", OPENCODE_QUERY])
        .arg(path)
        .arg(since_ms.to_string())
        .output();
    let Ok(output) = output else {
        return Vec::new();
    };
    if !output.status.success() {
        eprintln!("opencode: {}", String::from_utf8_lossy(&output.stderr));
        return Vec::new();
    }
    let rows: Vec<OcRow> = serde_json::from_slice(&output.stdout).unwrap_or_default();
    rows.into_iter()
        .filter_map(|row| {
            let model = row.model.unwrap_or_default();
            let provider_id = row.provider.unwrap_or_default();
            let input = row.input.unwrap_or(0.0);
            let output = row.output.unwrap_or(0.0);
            let reasoning = row.reasoning.unwrap_or(0.0);
            let cache_read = row.cache_read.unwrap_or(0.0);
            let cache_write = row.cache_write.unwrap_or(0.0);
            let reported = row.total.unwrap_or(0.0);
            let estimated = reported <= 0.0;
            let spent = if estimated {
                pricing
                    .cost(&model, Some(&provider_id))
                    .map(|cost| {
                        pricing.claude(cost, input, cache_read, cache_write, output + reasoning)
                    })
                    .unwrap_or(0.0)
            } else {
                reported
            };
            let tokens = (input + output + reasoning + cache_read + cache_write) as i64;
            if spent <= 0.004 && tokens == 0 {
                return None;
            }
            Some(Row {
                host: host.to_string(),
                day: row.day,
                provider: opencode_provider(&provider_id).to_string(),
                project: row.cwd.unwrap_or_default(),
                model,
                spent,
                tokens,
                source: if estimated { "estimated" } else { "reported" }.to_string(),
            })
        })
        .collect()
}

// MARK: - pi / OMP sessions

#[derive(Deserialize)]
struct PiLine {
    #[serde(rename = "type")]
    kind: Option<String>,
    id: Option<String>,
    cwd: Option<String>,
    timestamp: Option<String>,
    message: Option<PiMessage>,
}

#[derive(Deserialize)]
struct PiMessage {
    id: Option<String>,
    role: Option<String>,
    model: Option<String>,
    provider: Option<String>,
    usage: Option<PiUsage>,
}

#[derive(Deserialize, Default, Clone, Copy)]
struct PiUsage {
    input: Option<f64>,
    output: Option<f64>,
    #[serde(rename = "cacheRead")]
    cache_read: Option<f64>,
    #[serde(rename = "cacheWrite")]
    cache_write: Option<f64>,
}

struct PiMsg {
    day: String,
    project: String,
    provider: String,
    model: String,
    input: f64,
    output: f64,
    cache_read: f64,
    cache_write: f64,
    sum: f64,
}

pub fn pi(host: &str, roots: &[PathBuf], since_ms: i64, pricing: &Pricing) -> Vec<Row> {
    let mut files = Vec::new();
    for root in roots {
        walk_jsonl(root, &mut files);
    }
    let mut best: HashMap<String, PiMsg> = HashMap::new();
    for (file_idx, file) in files.iter().enumerate() {
        let Ok(text) = fs::read_to_string(file) else {
            continue;
        };
        for (line_idx, line) in text.lines().enumerate() {
            let Ok(obj) = serde_json::from_str::<PiLine>(line) else {
                continue;
            };
            if obj.kind.as_deref() != Some("message") {
                continue;
            }
            let Some(message) = obj.message else { continue };
            if message.role.as_deref() != Some("assistant") {
                continue;
            }
            let Some(usage) = message.usage else { continue };
            let Some(timestamp) = obj.timestamp.as_deref() else {
                continue;
            };
            let Some(day) = local_day(timestamp) else {
                continue;
            };
            let ts_ms = OffsetDateTime::parse(timestamp, &Rfc3339)
                .map(|t| (t.unix_timestamp_nanos() / 1_000_000) as i64)
                .unwrap_or(0);
            if ts_ms < since_ms {
                continue;
            }
            let input = usage.input.unwrap_or(0.0);
            let output = usage.output.unwrap_or(0.0);
            let cache_read = usage.cache_read.unwrap_or(0.0);
            let cache_write = usage.cache_write.unwrap_or(0.0);
            let sum = input + output + cache_read + cache_write;
            let key = obj
                .id
                .clone()
                .or(message.id.clone())
                .unwrap_or_else(|| format!("{}|{}", file_idx, line_idx));
            if let Some(previous) = best.get(&key) {
                if previous.sum >= sum {
                    continue;
                }
            }
            best.insert(
                key,
                PiMsg {
                    day,
                    project: obj.cwd.unwrap_or_default(),
                    provider: pi_provider(message.provider.as_deref().unwrap_or("")).to_string(),
                    model: bare_model(message.model.as_deref().unwrap_or("")),
                    input,
                    output,
                    cache_read,
                    cache_write,
                    sum,
                },
            );
        }
    }
    best.into_values()
        .filter_map(|msg| {
            let cost = pricing.cost(&msg.model, None)?;
            let spent =
                pricing.claude(cost, msg.input, msg.cache_read, msg.cache_write, msg.output);
            let tokens = (msg.input + msg.output + msg.cache_read + msg.cache_write) as i64;
            if spent <= 0.004 && tokens == 0 {
                return None;
            }
            Some(Row {
                host: host.to_string(),
                day: msg.day,
                provider: msg.provider,
                project: msg.project,
                model: msg.model,
                spent,
                tokens,
                source: "estimated".to_string(),
            })
        })
        .collect()
}

// MARK: - Claude Code sessions

#[derive(Deserialize)]
struct ClaudeLine {
    #[serde(rename = "type")]
    kind: Option<String>,
    timestamp: Option<String>,
    cwd: Option<String>,
    #[serde(rename = "requestId")]
    request_id: Option<String>,
    message: Option<ClaudeMessage>,
}

#[derive(Deserialize)]
struct ClaudeMessage {
    id: Option<String>,
    model: Option<String>,
    usage: Option<ClaudeUsage>,
}

#[derive(Deserialize, Default)]
struct ClaudeUsage {
    input_tokens: Option<f64>,
    output_tokens: Option<f64>,
    cache_read_input_tokens: Option<f64>,
    cache_creation_input_tokens: Option<f64>,
    cache_creation: Option<HashMap<String, f64>>,
}

struct ClaudeMsg {
    day: String,
    project: String,
    model: String,
    input: f64,
    output: f64,
    cache_read: f64,
    cache_write: f64,
    sum: f64,
}

pub fn claude(host: &str, roots: &[PathBuf], since_ms: i64, pricing: &Pricing) -> Vec<Row> {
    let mut files = Vec::new();
    for root in roots {
        walk_jsonl(root, &mut files);
    }
    let mut best: HashMap<String, ClaudeMsg> = HashMap::new();
    for file in files {
        let Ok(text) = fs::read_to_string(&file) else {
            continue;
        };
        for line in text.lines() {
            let Ok(obj) = serde_json::from_str::<ClaudeLine>(line) else {
                continue;
            };
            if obj.kind.as_deref() != Some("assistant") {
                continue;
            }
            let Some(message) = obj.message else { continue };
            let Some(usage) = message.usage else { continue };
            let Some(timestamp) = obj.timestamp.as_deref() else {
                continue;
            };
            let Some(day) = local_day(timestamp) else {
                continue;
            };
            let ts_ms = OffsetDateTime::parse(timestamp, &Rfc3339)
                .map(|t| (t.unix_timestamp_nanos() / 1_000_000) as i64)
                .unwrap_or(0);
            if ts_ms < since_ms {
                continue;
            }
            let input = usage.input_tokens.unwrap_or(0.0);
            let output = usage.output_tokens.unwrap_or(0.0);
            let cache_read = usage.cache_read_input_tokens.unwrap_or(0.0);
            let cache_write = usage
                .cache_creation
                .as_ref()
                .map(|map| map.values().sum())
                .unwrap_or_else(|| usage.cache_creation_input_tokens.unwrap_or(0.0));
            let sum = input + output + cache_read + cache_write;
            let key = format!(
                "{}|{}",
                message.id.clone().unwrap_or_default(),
                obj.request_id.clone().unwrap_or_default()
            );
            if let Some(previous) = best.get(&key) {
                if previous.sum >= sum {
                    continue;
                }
            }
            best.insert(
                key,
                ClaudeMsg {
                    day,
                    project: obj.cwd.clone().unwrap_or_default(),
                    model: bare_model(message.model.as_deref().unwrap_or("")),
                    input,
                    output,
                    cache_read,
                    cache_write,
                    sum,
                },
            );
        }
    }
    best.into_values()
        .filter_map(|msg| {
            let cost = pricing.cost(&msg.model, None)?;
            let spent =
                pricing.claude(cost, msg.input, msg.cache_read, msg.cache_write, msg.output);
            let tokens = (msg.input + msg.output + msg.cache_read + msg.cache_write) as i64;
            if spent <= 0.004 && tokens == 0 {
                return None;
            }
            Some(Row {
                host: host.to_string(),
                day: msg.day,
                provider: "claude".to_string(),
                project: msg.project,
                model: msg.model,
                spent,
                tokens,
                source: "estimated".to_string(),
            })
        })
        .collect()
}

pub fn walk_jsonl(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            walk_jsonl(&path, out);
        } else if path.extension().and_then(|e| e.to_str()) == Some("jsonl") {
            out.push(path);
        }
    }
}
