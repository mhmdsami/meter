use crate::platform;
use crate::pricing::Pricing;
use crate::scan::Row;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::process::Command;
use time::format_description::well_known::Rfc3339;
use time::{OffsetDateTime, UtcOffset};

const SUMMARIES_QUERY: &str = r#"
import sqlite3, json, sys
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
try:
    rows = con.execute("SELECT conversation_id, workspace_uris FROM conversation_summaries").fetchall()
except Exception:
    rows = []
print(json.dumps(rows))
"#;

const META_QUERY: &str = r#"
import sqlite3, json, sys, binascii
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
try:
    rows = con.execute("SELECT data FROM gen_metadata ORDER BY idx").fetchall()
except Exception:
    rows = []
print(json.dumps([binascii.hexlify(r[0]).decode() for r in rows if r[0]]))
"#;

struct Field {
    number: u64,
    bytes: Option<Vec<u8>>,
    varint: Option<u64>,
}

fn varint(data: &[u8], mut at: usize) -> Option<(u64, usize)> {
    let mut value = 0u64;
    let mut shift = 0u32;
    while at < data.len() {
        let byte = data[at];
        at += 1;
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Some((value, at));
        }
        shift += 7;
    }
    None
}

fn fields(data: &[u8]) -> Vec<Field> {
    let mut out = Vec::new();
    let mut at = 0usize;
    while at < data.len() {
        let Some((key, next)) = varint(data, at) else {
            break;
        };
        at = next;
        let number = key >> 3;
        match key & 7 {
            0 => {
                let Some((value, next)) = varint(data, at) else {
                    break;
                };
                at = next;
                out.push(Field {
                    number,
                    bytes: None,
                    varint: Some(value),
                });
            }
            2 => {
                let Some((len, next)) = varint(data, at) else {
                    break;
                };
                at = next;
                let end = at.saturating_add(len as usize);
                if end > data.len() {
                    break;
                }
                out.push(Field {
                    number,
                    bytes: Some(data[at..end].to_vec()),
                    varint: None,
                });
                at = end;
            }
            1 => at = at.saturating_add(8),
            5 => at = at.saturating_add(4),
            _ => break,
        }
    }
    out
}

fn member(fields: &[Field], number: u64) -> Option<&Field> {
    fields.iter().find(|field| field.number == number)
}

struct Meta {
    model: String,
    input: f64,
    cache: f64,
    output: f64,
}

/// Model id is protobuf `1.19`; usage is `1.4.{2,3,5}` = input/output/cache.
fn parse_meta(data: &[u8]) -> Option<Meta> {
    let outer = fields(data);
    let inner = member(&outer, 1)?.bytes.as_deref()?;
    let inner = fields(inner);
    let model = String::from_utf8(member(&inner, 19)?.bytes.clone()?).ok()?;
    let usage = fields(member(&inner, 4)?.bytes.as_deref()?);
    let input = member(&usage, 2)?.varint? as f64;
    let output = member(&usage, 3)?.varint? as f64;
    let cache = member(&usage, 5)?.varint? as f64;
    if input + output + cache <= 0.0 {
        return None;
    }
    Some(Meta {
        model,
        input,
        cache,
        output,
    })
}

struct Turn {
    day: String,
}

#[derive(Deserialize)]
struct TranscriptLine {
    #[serde(rename = "type")]
    kind: Option<String>,
    created_at: Option<String>,
}

fn turns(path: &Path) -> Vec<Turn> {
    let Ok(text) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for line in text.lines() {
        let Ok(obj) = serde_json::from_str::<TranscriptLine>(line) else {
            continue;
        };
        if obj.kind.as_deref() != Some("PLANNER_RESPONSE") {
            continue;
        }
        let Some(created) = obj.created_at else {
            continue;
        };
        let Ok(parsed) = OffsetDateTime::parse(&created, &Rfc3339) else {
            continue;
        };
        let offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
        out.push(Turn {
            day: parsed.to_offset(offset).date().to_string(),
        });
    }
    out
}

fn python_json(script: &str, path: &Path) -> Option<serde_json::Value> {
    let python = platform::python()?;
    let output = Command::new(python)
        .args(["-c", script])
        .arg(path)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    serde_json::from_slice(&output.stdout).ok()
}

fn project_map(root: &Path) -> HashMap<String, String> {
    let mut out = HashMap::new();
    if let Some(serde_json::Value::Array(rows)) =
        python_json(SUMMARIES_QUERY, &root.join("conversation_summaries.db"))
    {
        for row in rows {
            let Some(id) = row.get(0).and_then(|value| value.as_str()) else {
                continue;
            };
            let Some(uris) = row.get(1).and_then(|value| value.as_str()) else {
                continue;
            };
            let Ok(serde_json::Value::Array(uris)) =
                serde_json::from_str::<serde_json::Value>(uris)
            else {
                continue;
            };
            let Some(first) = uris.first().and_then(|value| value.as_str()) else {
                continue;
            };
            out.insert(
                id.to_string(),
                first.trim_start_matches("file://").to_string(),
            );
        }
    }
    // The CLI sometimes holds a write lock on the summaries DB; this cache maps
    // workspace -> conversation and covers that refresh.
    let fallback = root.join("cache/last_conversations.json");
    if let Ok(text) = fs::read_to_string(fallback) {
        if let Ok(serde_json::Value::Object(map)) = serde_json::from_str(&text) {
            for (workspace, id) in map {
                if let Some(id) = id.as_str() {
                    out.entry(id.to_string()).or_insert(workspace);
                }
            }
        }
    }
    out
}

pub fn scan(host: &str, root: &Path, since_day: &str, pricing: &Pricing) -> Vec<Row> {
    let conversations = root.join("conversations");
    let Ok(entries) = fs::read_dir(&conversations) else {
        return Vec::new();
    };
    let projects = project_map(root);
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("db") {
            continue;
        }
        let Some(id) = path.file_stem().and_then(|stem| stem.to_str()) else {
            continue;
        };
        let transcript = root
            .join("brain")
            .join(id)
            .join(".system_generated/logs/transcript.jsonl");
        let turns = turns(&transcript);
        if turns.is_empty() {
            continue;
        }
        let Some(serde_json::Value::Array(encoded)) = python_json(META_QUERY, &path) else {
            continue;
        };
        let metas: Vec<Meta> = encoded
            .iter()
            .filter_map(|value| value.as_str())
            .filter_map(hex_bytes)
            .filter_map(|data| parse_meta(&data))
            .collect();
        let project = projects.get(id).cloned().unwrap_or_default();
        for (meta, turn) in metas.iter().zip(turns.iter()) {
            if turn.day.as_str() < since_day {
                continue;
            }
            let Some(cost) = pricing.cost(&meta.model, None) else {
                continue;
            };
            let spent = pricing.claude(cost, meta.input, meta.cache, 0.0, meta.output);
            let tokens = (meta.input + meta.cache + meta.output) as i64;
            if spent <= 0.0 && tokens == 0 {
                continue;
            }
            out.push(Row {
                host: host.to_string(),
                day: turn.day.clone(),
                provider: "antigravity".to_string(),
                project: project.clone(),
                model: meta.model.clone(),
                spent,
                tokens,
                source: "estimated".to_string(),
            });
        }
    }
    out
}

fn hex_bytes(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|at| u8::from_str_radix(&text[at..at + 2], 16).ok())
        .collect()
}
