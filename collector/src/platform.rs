use std::path::PathBuf;
use std::process::Command;

/// Home directory on macOS and Linux, profile directory on Windows.
pub fn home() -> PathBuf {
    for key in ["HOME", "USERPROFILE"] {
        if let Ok(value) = std::env::var(key) {
            if !value.is_empty() {
                return PathBuf::from(value);
            }
        }
    }
    PathBuf::from(".")
}

/// Interpreter for the read-only SQLite queries. Windows has no `python3`, so
/// try `python` too and let the caller skip the source when neither exists.
pub fn python() -> Option<&'static str> {
    for candidate in ["python3", "python"] {
        let ok = Command::new(candidate)
            .arg("--version")
            .output()
            .map(|output| output.status.success())
            .unwrap_or(false);
        if ok {
            return Some(candidate);
        }
    }
    None
}

/// Hosts that keep the token in the login keychain instead of the env file.
#[cfg(target_os = "macos")]
pub fn keychain_token(service: &str) -> Option<String> {
    let output = Command::new("security")
        .args(["find-generic-password", "-s", service, "-w"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let token = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if token.is_empty() {
        None
    } else {
        Some(token)
    }
}

#[cfg(not(target_os = "macos"))]
pub fn keychain_token(_service: &str) -> Option<String> {
    None
}

pub fn host_name() -> String {
    for path in ["/etc/hostname", "/proc/sys/kernel/hostname"] {
        if let Ok(name) = std::fs::read_to_string(path) {
            let name = name.trim();
            if !name.is_empty() {
                return name.to_string();
            }
        }
    }
    if let Ok(output) = Command::new("hostname").output() {
        let name = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !name.is_empty() {
            return name;
        }
    }
    std::env::var("COMPUTERNAME")
        .ok()
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "unknown".to_string())
}
