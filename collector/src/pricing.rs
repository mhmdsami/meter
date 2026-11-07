use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::process::Command;

#[derive(Clone, Copy, Default)]
pub struct Cost {
    pub input: f64,
    pub output: f64,
    pub cache_read: f64,
    pub cache_write: f64,
}

pub struct Pricing {
    models: HashMap<String, Cost>,
    by_provider: HashMap<String, HashMap<String, Cost>>,
}

const OFFICIAL: &[&str] = &[
    "anthropic",
    "openai",
    "google",
    "google-vertex",
    "azure",
    "xai",
    "moonshotai",
    "deepseek",
    "zai",
    "minimax",
    "qwen",
    "mistral",
];

/// Only the fields meter prices with; the file carries far more, and a typed
/// parse keeps the whole table from becoming a JSON tree in memory.
#[derive(Deserialize)]
struct Root {
    #[serde(flatten)]
    providers: std::collections::HashMap<String, Provider>,
}

#[derive(Deserialize)]
struct Provider {
    models: Option<std::collections::HashMap<String, Model>>,
}

#[derive(Deserialize)]
struct Model {
    cost: Option<CostJson>,
}

#[derive(Deserialize)]
struct CostJson {
    input: Option<f64>,
    output: Option<f64>,
    cache_read: Option<f64>,
    cache_write: Option<f64>,
}

fn parse_cost(cost: &CostJson) -> Cost {
    Cost {
        input: cost.input.unwrap_or(0.0),
        output: cost.output.unwrap_or(0.0),
        cache_read: cost.cache_read.unwrap_or(0.0),
        cache_write: cost.cache_write.unwrap_or(0.0),
    }
}

/// Official beats reseller; within the same tier the higher list price wins so
/// zero-cost mirrors never shadow a real price.
fn beats(candidate: Cost, candidate_official: bool, existing: (bool, Cost)) -> bool {
    if candidate_official != existing.0 {
        return candidate_official;
    }
    candidate.input + candidate.output > existing.1.input + existing.1.output
}

impl Pricing {
    pub fn load(cache: &Path) -> Pricing {
        refresh(cache);
        let Ok(bytes) = fs::read(cache) else {
            return Pricing {
                models: HashMap::new(),
                by_provider: HashMap::new(),
            };
        };
        let Ok(root) = serde_json::from_slice::<Root>(&bytes) else {
            return Pricing {
                models: HashMap::new(),
                by_provider: HashMap::new(),
            };
        };
        let mut models: HashMap<String, (bool, Cost)> = HashMap::new();
        let mut by_provider: HashMap<String, HashMap<String, Cost>> = HashMap::new();
        for (provider, body) in &root.providers {
            let Some(model_map) = body.models.as_ref() else {
                continue;
            };
            let official = OFFICIAL.contains(&provider.as_str());
            let entry = by_provider.entry(provider.to_lowercase()).or_default();
            for (id, model) in model_map {
                let Some(cost) = model.cost.as_ref() else {
                    continue;
                };
                let parsed = parse_cost(cost);
                let key = id.to_lowercase();
                entry.insert(key.clone(), parsed);
                if let Some(existing) = models.get(&key).copied() {
                    if !beats(parsed, official, existing) {
                        continue;
                    }
                }
                models.insert(key, (official, parsed));
            }
        }
        Pricing {
            models: models
                .into_iter()
                .map(|(key, (_, cost))| (key, cost))
                .collect(),
            by_provider,
        }
    }

    /// Rates are irrelevant to the day-bucketing test; any known model will do.
    #[cfg(test)]
    pub fn with_rate(model: &str, cost: Cost) -> Pricing {
        let mut models = HashMap::new();
        models.insert(model.to_string(), cost);
        Pricing {
            models,
            by_provider: HashMap::new(),
        }
    }

    pub fn cost(&self, model: &str, provider: Option<&str>) -> Option<Cost> {
        let base = model.to_lowercase();
        if let Some(provider) = provider {
            if let Some(cost) = self
                .by_provider
                .get(&provider.to_lowercase())
                .and_then(|m| m.get(&base))
            {
                return Some(*cost);
            }
        }
        self.models.get(&base).copied().or_else(|| {
            self.models
                .iter()
                .filter(|(k, _)| k.starts_with(&format!("{base}-20")))
                .max_by_key(|(k, _)| k.len())
                .map(|(_, cost)| *cost)
        })
    }

    pub fn claude(
        &self,
        cost: Cost,
        input: f64,
        cache_read: f64,
        cache_write: f64,
        output: f64,
    ) -> f64 {
        input / 1e6 * cost.input
            + cache_read / 1e6 * cost.cache_read
            + cache_write / 1e6 * cost.cache_write
            + output / 1e6 * cost.output
    }

    /// Codex reports cached input as a subset of input, so it is repriced at
    /// the cache rate instead of double counting.
    pub fn codex(&self, cost: Cost, input: f64, cached_input: f64, output: f64) -> f64 {
        let cached = cached_input.min(input);
        (input - cached) / 1e6 * cost.input
            + cached / 1e6 * cost.cache_read
            + output / 1e6 * cost.output
    }
}

fn refresh(cache: &Path) {
    if let Ok(meta) = fs::metadata(cache) {
        if let Ok(modified) = meta.modified() {
            if let Ok(age) = modified.elapsed() {
                if age.as_secs() < 86_400 {
                    return;
                }
            }
        }
    }
    let Some(dir) = cache.parent() else { return };
    let _ = fs::create_dir_all(dir);
    let tmp = cache.with_extension("json.tmp");
    let ok = Command::new("curl")
        .args([
            "-fsSL",
            "--max-time",
            "30",
            "https://models.dev/api.json",
            "-o",
        ])
        .arg(&tmp)
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if ok {
        let _ = fs::rename(&tmp, cache);
    } else {
        let _ = fs::remove_file(&tmp);
    }
}
