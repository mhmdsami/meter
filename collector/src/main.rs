mod antigravity;
mod codex;
mod fx;
mod platform;
mod pricing;
mod scan;

use pricing::Pricing;
use scan::Row;
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;
use std::process::Command;
use time::OffsetDateTime;

struct Config {
    url: String,
    token: String,
    host: String,
    days: i64,
}

/// D1's free tier meters rows written, and ingest replaces a whole
/// (day, provider) group. Sending an unchanged window every run burns the
/// budget for nothing, so each day's content is hashed and only changed days
/// are pushed; one full push a day still reconciles pruned or edited logs.
#[derive(serde::Serialize, serde::Deserialize, Default)]
struct PushState {
    full_pushed_ms: i64,
    days: BTreeMap<String, u64>,
}

fn state_path() -> PathBuf {
    home().join(".cache/meter/collector-state.json")
}

fn load_state() -> PushState {
    fs::read_to_string(state_path())
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

fn save_state(state: &PushState) {
    let path = state_path();
    if let Some(dir) = path.parent() {
        let _ = fs::create_dir_all(dir);
    }
    if let Ok(text) = serde_json::to_string(state) {
        let _ = fs::write(path, text);
    }
}

fn row_hash(row: &Row) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    row.provider.hash(&mut hasher);
    row.project.hash(&mut hasher);
    row.model.hash(&mut hasher);
    row.spent.to_bits().hash(&mut hasher);
    row.tokens.hash(&mut hasher);
    row.source.hash(&mut hasher);
    hasher.finish()
}

/// Order-independent: rows with the same key come from several files and
/// arrive in map iteration order, so a positional hash would look changed
/// on every run.
fn day_hash(rows: &[Row]) -> u64 {
    rows.iter()
        .fold(0u64, |acc, row| acc.wrapping_add(row_hash(row)))
}

fn home() -> PathBuf {
    platform::home()
}

fn env_file() -> PathBuf {
    home().join(".config/meter/collector.env")
}

fn load_config() -> Config {
    let mut map: HashMap<String, String> = HashMap::new();
    if let Ok(text) = fs::read_to_string(env_file()) {
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some((key, value)) = line.split_once('=') {
                map.insert(key.trim().to_string(), value.trim().to_string());
            }
        }
    }
    let get = |key: &str| {
        std::env::var(key)
            .ok()
            .filter(|value| !value.is_empty())
            .or_else(|| map.get(key).cloned().filter(|value| !value.is_empty()))
    };
    let host = get("METER_HOST").unwrap_or_else(platform::host_name);
    Config {
        url: get("METER_URL").unwrap_or_default(),
        // macOS keeps the token in the login keychain, same slot the menubar uses.
        token: get("METER_TOKEN")
            .or_else(|| platform::keychain_token("meter/collector"))
            .unwrap_or_default(),
        host,
        days: get("METER_DAYS").and_then(|v| v.parse().ok()).unwrap_or(30),
    }
}

fn main() {
    let config = load_config();
    let dry_run = std::env::args().any(|a| a == "--dry-run");
    if config.token.is_empty() && !dry_run {
        eprintln!(
            "meter-collector: METER_TOKEN is not set ({})",
            env_file().display()
        );
        std::process::exit(2);
    }
    if config.url.is_empty() && !dry_run {
        eprintln!(
            "meter-collector: METER_URL is not set ({})",
            env_file().display()
        );
        std::process::exit(2);
    }

    let pricing = Pricing::load(&home().join(".cache/meter/models.json"));
    let now = OffsetDateTime::now_utc();
    let now_ms = (now.unix_timestamp_nanos() / 1_000_000) as i64;
    let since_ms = now_ms - config.days * 86_400_000;
    let offset = time::UtcOffset::current_local_offset().unwrap_or(time::UtcOffset::UTC);
    let since_day = (now.to_offset(offset).date() - time::Duration::days(config.days)).to_string();

    let oc_path = home().join(".local/share/opencode/opencode.db");
    let pi_roots = vec![
        home().join(".pi/agent/sessions"),
        home().join(".omp/agent/sessions"),
    ];
    let mut claude_roots = vec![
        home().join(".claude/projects"),
        home().join(".config/claude/projects"),
    ];
    claude_roots.extend(scan::desktop_claude_roots(&home()));
    let codex_roots = vec![
        home().join(".codex/sessions"),
        home().join(".codex/archived_sessions"),
    ];
    let fx_path = home().join(".fx/usage.jsonl");
    let antigravity_root = home().join(".gemini/antigravity-cli");

    let mut rows: Vec<Row> = Vec::new();
    rows.extend(scan::opencode(&config.host, &oc_path, since_ms, &pricing));
    rows.extend(scan::pi(&config.host, &pi_roots, since_ms, &pricing));
    rows.extend(scan::claude(
        &config.host,
        &claude_roots,
        since_ms,
        &pricing,
    ));
    rows.extend(codex::scan(
        &config.host,
        &codex_roots,
        since_ms,
        &since_day,
        &pricing,
    ));
    rows.extend(fx::rows(&config.host, &fx_path, &since_day, &pricing));
    rows.extend(antigravity::scan(
        &config.host,
        &antigravity_root,
        &since_day,
        &pricing,
    ));
    rows.sort_by(|a, b| {
        (&a.day, &a.provider, &a.project, &a.model).cmp(&(
            &b.day,
            &b.provider,
            &b.project,
            &b.model,
        ))
    });

    let mut by_day: BTreeMap<String, Vec<Row>> = BTreeMap::new();
    for row in &rows {
        by_day.entry(row.day.clone()).or_default().push(row.clone());
    }
    let mut state = load_state();
    let full_every_ms = 24 * 3_600_000;
    let force_full = std::env::args().any(|a| a == "--full");
    let full_due = force_full || now_ms - state.full_pushed_ms >= full_every_ms;
    let mut selected: Vec<String> = Vec::new();
    for (day, day_rows) in &by_day {
        let hash = day_hash(day_rows);
        if full_due || state.days.get(day) != Some(&hash) {
            selected.push(day.clone());
        }
    }

    let spend: f64 = rows.iter().map(|row| row.spent).sum();
    let tokens: i64 = rows.iter().map(|row| row.tokens).sum();
    println!(
        "{}: {} rows · ${:.2} · {} tokens ({}d)",
        config.host,
        rows.len(),
        spend,
        tokens,
        config.days
    );

    if selected.is_empty() {
        println!("no changes since the last push");
        return;
    }
    let push_rows: Vec<Row> = selected
        .iter()
        .flat_map(|day| by_day.get(day).cloned().unwrap_or_default())
        .collect();
    println!(
        "pushing {} of {} days ({} rows{})",
        selected.len(),
        by_day.len(),
        push_rows.len(),
        if full_due { ", full" } else { "" }
    );

    let payload = serde_json::json!({
        "host": config.host,
        "generated_at": OffsetDateTime::now_utc().to_string(),
        "rows": push_rows,
    });
    let body = match serde_json::to_vec(&payload) {
        Ok(body) => body,
        Err(err) => {
            eprintln!("meter-collector: {err}");
            std::process::exit(1);
        }
    };

    if dry_run {
        println!("{}", String::from_utf8_lossy(&body));
        return;
    }

    let tmp = std::env::temp_dir().join(format!("meter-rows-{}.json", std::process::id()));
    if let Err(err) = fs::write(&tmp, &body) {
        eprintln!("meter-collector: {err}");
        std::process::exit(1);
    }
    let endpoint = format!("{}/api/ingest", config.url.trim_end_matches('/'));
    let output = Command::new("curl")
        .args(["-fsS", "--max-time", "30", "-X", "POST"])
        .arg("-H")
        .arg(format!("Authorization: Bearer {}", config.token))
        .args(["-H", "Content-Type: application/json"])
        .arg("--data-binary")
        .arg(format!("@{}", tmp.display()))
        .arg(&endpoint)
        .output();
    let _ = fs::remove_file(&tmp);

    match output {
        Ok(output) if output.status.success() => {
            println!("{}", String::from_utf8_lossy(&output.stdout).trim());
            if full_due {
                state.full_pushed_ms = now_ms;
            }
            for day in &selected {
                if let Some(day_rows) = by_day.get(day) {
                    state.days.insert(day.clone(), day_hash(day_rows));
                }
            }
            let oldest = since_day.clone();
            state.days.retain(|day, _| day.as_str() >= oldest.as_str());
            save_state(&state);
        }
        Ok(output) => {
            eprintln!(
                "meter-collector: push failed ({}): {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            );
            std::process::exit(1);
        }
        Err(err) => {
            eprintln!("meter-collector: {err}");
            std::process::exit(1);
        }
    }
}
