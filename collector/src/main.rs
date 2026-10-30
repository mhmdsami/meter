mod antigravity;
mod codex;
mod fx;
mod platform;
mod pricing;
mod scan;

use pricing::Pricing;
use scan::Row;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use time::OffsetDateTime;

struct Config {
    url: String,
    token: String,
    host: String,
    days: i64,
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

    let payload = serde_json::json!({
        "host": config.host,
        "generated_at": OffsetDateTime::now_utc().to_string(),
        "rows": rows,
    });
    let body = match serde_json::to_vec(&payload) {
        Ok(body) => body,
        Err(err) => {
            eprintln!("meter-collector: {err}");
            std::process::exit(1);
        }
    };

    let spend: f64 = rows.iter().map(|row| row.spent).sum();
    let tokens: i64 = rows.iter().map(|row| row.tokens).sum();
    println!(
        "{}: {} rows · ${:.2} · {} tokens ({}d)",
        payload["host"].as_str().unwrap_or(""),
        rows.len(),
        spend,
        tokens,
        config.days
    );

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
