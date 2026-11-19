use crate::pricing::Pricing;
use crate::scan::Row;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};
use time::format_description::well_known::Rfc3339;
use time::{OffsetDateTime, UtcOffset};

/// Amp serves every request itself, so its CLI threads and its orbs never reach
/// the local Claude logs. `amp usage` is the only local record of those tokens.
const MAX_FETCHES: usize = 8;
const MAX_RUNTIME: Duration = Duration::from_secs(20);

#[derive(Clone, serde::Serialize, serde::Deserialize)]
struct ModelUsage {
    model: String,
    input: f64,
    cache_read: f64,
    cache_write: f64,
    output: f64,
}

/// Usage lookups and thread drill-downs share a 60-request hourly limit, so a
/// final day is fetched once and kept; only today is asked for again.
pub fn rows(host: &str, cache: &Path, days: i64, pricing: &Pricing) -> Vec<Row> {
    let Some(bin) = find() else { return Vec::new() };
    let offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    let today = OffsetDateTime::now_utc().to_offset(offset).date();
    let since = today - time::Duration::days(days);
    let mut saved: BTreeMap<String, Vec<ModelUsage>> = load(cache);
    let mut left = MAX_FETCHES;
    let mut changed = false;

    let mut day = today;
    while day >= since && left > 0 {
        let key = day.to_string();
        if day < today && saved.contains_key(&key) {
            day -= time::Duration::days(1);
            continue;
        }
        left -= 1;
        if let Some(usage) = fetch(&bin, day, offset) {
            saved.insert(key, usage);
            changed = true;
        }
        day -= time::Duration::days(1);
    }

    let oldest = since.to_string();
    saved.retain(|day, _| day.as_str() >= oldest.as_str());
    if changed {
        save(cache, &saved);
    }

    let mut rows = Vec::new();
    for (day, usage) in &saved {
        for item in usage {
            let Some(model) = resolve(&item.model, pricing) else {
                continue;
            };
            let Some(cost) = pricing.cost(&model, None) else {
                continue;
            };
            let tokens = (item.input + item.cache_read + item.cache_write + item.output) as i64;
            if tokens == 0 {
                continue;
            }
            rows.push(Row {
                host: host.to_string(),
                day: day.clone(),
                provider: "claude".to_string(),
                project: "amp".to_string(),
                model,
                spent: pricing.claude(
                    cost,
                    item.input,
                    item.cache_read,
                    item.cache_write,
                    item.output,
                ),
                tokens,
                source: "estimated".to_string(),
            });
        }
    }
    rows
}

fn fetch(bin: &Path, day: time::Date, offset: UtcOffset) -> Option<Vec<ModelUsage>> {
    let start = day
        .midnight()
        .assume_offset(offset)
        .to_offset(UtcOffset::UTC);
    let end = (day + time::Duration::days(1))
        .midnight()
        .assume_offset(offset)
        .to_offset(UtcOffset::UTC);
    let start = start.format(&Rfc3339).ok()?;
    let end = end.format(&Rfc3339).ok()?;
    let text = run(
        bin,
        &["usage", "--start", &start, "--end", &end, "--details"],
    )?;
    // A body without the summary is an error page, not a quiet day; leaving it
    // uncached means the next run asks again.
    if !text.contains("Total tokens") {
        return None;
    }
    Some(parse_models(&text))
}

fn run(bin: &Path, args: &[&str]) -> Option<String> {
    let path = std::env::temp_dir().join(format!("meter-amp-{}.txt", std::process::id()));
    let file = fs::File::create(&path).ok()?;
    let mut child = Command::new(bin)
        .args(args)
        .stdout(Stdio::from(file))
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if started.elapsed() < MAX_RUNTIME => {
                std::thread::sleep(Duration::from_millis(100));
            }
            _ => {
                let _ = child.kill();
                break child.wait().ok()?;
            }
        }
    };
    let text = fs::read_to_string(&path).ok();
    let _ = fs::remove_file(&path);
    status.success().then_some(text).flatten()
}

/// The account report names models by display name; the price table is keyed by
/// id. Only a name that resolves to a published rate is billed.
fn resolve(display: &str, pricing: &Pricing) -> Option<String> {
    let base = display.to_lowercase().replace(' ', "-");
    let candidates = [
        base.clone(),
        format!("claude-{base}"),
        base.replace('.', "-"),
        format!("claude-{}", base.replace('.', "-")),
    ];
    candidates
        .iter()
        .find(|candidate| pricing.official(candidate).is_some())
        .or_else(|| {
            candidates
                .iter()
                .find(|candidate| pricing.cost(candidate, None).is_some())
        })
        .cloned()
}

fn parse_models(text: &str) -> Vec<ModelUsage> {
    let mut usage = Vec::new();
    let mut in_models = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with("## ") {
            in_models = line == "## Models";
            continue;
        }
        if !in_models || !line.starts_with('|') {
            continue;
        }
        let cells: Vec<&str> = line.trim_matches('|').split('|').map(str::trim).collect();
        if cells.len() < 6 {
            continue;
        }
        let (Some(input), Some(cache_read), Some(cache_write), Some(output)) = (
            number(cells[1]),
            number(cells[2]),
            number(cells[3]),
            number(cells[4]),
        ) else {
            continue;
        };
        usage.push(ModelUsage {
            model: cells[0].to_string(),
            input,
            cache_read,
            cache_write,
            output,
        });
    }
    usage
}

fn number(text: &str) -> Option<f64> {
    text.replace(',', "").parse().ok()
}

fn find() -> Option<PathBuf> {
    let mut candidates = Vec::new();
    if let Ok(path) = std::env::var("PATH") {
        for dir in path.split(':').filter(|dir| !dir.is_empty()) {
            candidates.push(PathBuf::from(dir).join("amp"));
        }
    }
    candidates.push(crate::platform::home().join(".local/bin/amp"));
    candidates.push(PathBuf::from("/opt/homebrew/bin/amp"));
    candidates.push(PathBuf::from("/usr/local/bin/amp"));
    candidates.into_iter().find(|path| path.is_file())
}

fn load(cache: &Path) -> BTreeMap<String, Vec<ModelUsage>> {
    fs::read_to_string(cache)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

fn save(cache: &Path, saved: &BTreeMap<String, Vec<ModelUsage>>) {
    if let Some(dir) = cache.parent() {
        let _ = fs::create_dir_all(dir);
    }
    if let Ok(text) = serde_json::to_string(saved) {
        let _ = fs::write(cache, text);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pricing::Cost;

    const REPORT: &str = "\
## Amp Tier: Agent Usage Pool

| Source | Recorded cost |
| --- | ---: |
| **All sources** | **$19.04** |
| Opus 5.5 | $19.03 |

## Models

Sorted by recorded cost. Uncached input, cache read, cache write, and output tokens add up to Tokens.

| Model | Uncached input | Cache read | Cache write | Output | Tokens | Recorded cost |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Opus 5.5 | 746 | 59,194,364 | 1,746,377 | 241,845 | 61,183,332 | $0.00 |

## Daily Recorded Cost
";

    #[test]
    fn only_the_models_table_is_read() {
        let usage = parse_models(REPORT);
        assert_eq!(usage.len(), 1);
        assert_eq!(usage[0].model, "Opus 5.5");
        assert_eq!(usage[0].input, 746.0);
        assert_eq!(usage[0].cache_read, 59_194_364.0);
        assert_eq!(usage[0].cache_write, 1_746_377.0);
        assert_eq!(usage[0].output, 241_845.0);
    }

    #[test]
    fn display_names_resolve_to_the_price_table() {
        let pricing = Pricing::with_rates(&[
            (
                "anthropic",
                "claude-opus-5-5",
                Cost {
                    input: 4.0,
                    ..Cost::default()
                },
            ),
            (
                "reseller",
                "claude-opus-5.5",
                Cost {
                    input: 9.0,
                    ..Cost::default()
                },
            ),
        ]);
        assert_eq!(
            resolve("Opus 5.5", &pricing).as_deref(),
            Some("claude-opus-5-5")
        );
        assert_eq!(resolve("Unknown 9", &pricing), None);
    }
}
