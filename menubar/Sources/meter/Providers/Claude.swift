import CryptoKit
import Foundation

enum Claude {
    static let keychainService = "Claude Code-credentials"

    /// Claude Code keeps one login per config directory, so a second account is
    /// a second directory. `CLAUDE_CONFIG_DIR` selects it for the CLI; the same
    /// path here selects the matching credentials.
    static func configDir(_ instance: ProviderInstance) -> URL? {
        guard let raw = instance.options?["config_dir"]?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath, isDirectory: true)
    }

    /// macOS keys the login-chain item to the directory: the default dir keeps
    /// the plain service name and every other dir appends a hash of its path.
    static func keychainService(_ dir: URL?) -> String {
        guard let dir else { return keychainService }
        let path = dir.standardizedFileURL.path
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        if path == fallback { return keychainService }
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + digest.prefix(8)
    }

    /// Claude Code rewrites its credential item on `/login`, which is how an
    /// account switch reaches us. Metadata changes without reading the secret,
    /// so the cache is dropped only when the item actually changed.
    private static var lastSeen: [String: Date?] = [:]

    /// Last credential that worked. A rotation re-seals the keychain ACL, so a
    /// background re-read can fail while Claude Code still holds a valid login;
    /// keep serving that token instead of surfacing an approval error each cycle.
    private static var lastGood: [String: Credentials] = [:]
    private static let lastGoodLock = NSLock()

    private static func remember(_ creds: Credentials, service: String) {
        lastGoodLock.lock(); defer { lastGoodLock.unlock() }
        lastGood[service] = creds
    }

    private static func remembered(_ service: String) -> Credentials? {
        lastGoodLock.lock(); defer { lastGoodLock.unlock() }
        return lastGood[service]
    }

    private static func refreshIfChanged(configDir dir: URL?) {
        let service = keychainService(dir)
        let keychainDate = Keychain.modificationDate(service: service)
        let fileDate = (try? FileManager.default.attributesOfItem(atPath: credsURL(dir).path))?[.modificationDate] as? Date
        let stamp = [keychainDate, fileDate].compactMap { $0 }.max()
        if lastSeen[service] != stamp {
            lastSeen[service] = stamp
            Keychain.invalidateGeneric(service: service)
        }
    }

    static func fetch(_ instance: ProviderInstance) async throws -> InstanceReading {
        let dir = configDir(instance)
        refreshIfChanged(configDir: dir)
        // an expired token gets a 429 from Anthropic, not a 401 — surface the real
        // problem instead of backing off on a bogus rate limit for hours
        let creds = try loadCredentials(configDir: dir)
        if let expiry = creds.expiresAt, expiry <= Date() {
            let when = DateFormatter.localizedString(from: expiry, dateStyle: .short, timeStyle: .short)
            throw ProviderError.badResponse("Claude credentials expired \(when) — run `claude login`")
        }
        let obj = try await retryingOn401(
            invalidate: { Keychain.invalidateGeneric(service: keychainService(dir)) },
            staleMessage: "Claude token rotated — click Refresh (choose Always Allow once)"
        ) {
            try await usage(token: creds.token)
        }
        return map(instance: instance, usage: obj)
    }

    // MARK: - credentials

    static var credsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }

    static func credsURL(_ dir: URL?) -> URL {
        guard let dir else { return credsURL }
        return dir.appendingPathComponent(".credentials.json")
    }

    struct Credentials {
        let token: String
        let expiresAt: Date?
    }

    /// Credential sources, newest first is decided by the caller: the file and
    /// Claude Code's keychain item. Reads are cached per launch, so an expired
    /// cached read must be re-read rather than trusted — Claude Code rotates the
    /// token underneath us while the agent keeps running.
    private static func candidates(configDir dir: URL?) -> [Credentials] {
        var out: [Credentials] = []
        if let data = try? Data(contentsOf: credsURL(dir)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let creds = try? parse(obj) {
            out.append(creds)
        }
        if let raw = Keychain.generic(service: keychainService(dir)),
           let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let creds = try? parse(obj) {
            out.append(creds)
        }
        return out
    }

    private static func usable(_ creds: [Credentials]) -> Credentials? {
        creds.first { $0.expiresAt == nil || $0.expiresAt! > Date() }
    }

    static func loadCredentials(configDir dir: URL? = nil) throws -> Credentials {
        let service = keychainService(dir)
        if let creds = usable(candidates(configDir: dir)) {
            remember(creds, service: service)
            return creds
        }
        // everything we can see is expired: drop the per-launch cache and re-read,
        // in case the item rotated since it was cached
        Keychain.invalidateGeneric(service: service)
        let retried = candidates(configDir: dir)
        if let creds = usable(retried) {
            remember(creds, service: service)
            return creds
        }
        if let cached = remembered(service), cached.expiresAt.map({ $0 > Date() }) ?? true {
            return cached
        }
        if let newest = retried.compactMap(\.expiresAt).max() {
            let when = DateFormatter.localizedString(from: newest, dateStyle: .short, timeStyle: .short)
            throw ProviderError.badResponse("Claude credentials expired \(when) — run `claude login`")
        }
        if Keychain.needsAuthorization {
            throw ProviderError.missingKey("Claude keychain access needs approval — click Refresh and choose Always Allow")
        }
        throw ProviderError.badResponse("no Claude credentials — run `claude login`")
    }

    private static func parse(_ root: [String: Any]) throws -> Credentials {
        // 2.1.x keychain items may hold only mcpOAuth state
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let access = oauth["accessToken"] as? String else {
            throw ProviderError.badResponse("credentials hold no claudeAiOauth token (Claude Code 2.1.x move?) — re-auth via `claude login`")
        }
        let expiry = optNum(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credentials(token: access, expiresAt: expiry)
    }

    static func loadToken(configDir dir: URL? = nil) throws -> String {
        try loadCredentials(configDir: dir).token
    }

    // MARK: - usage API

    static func usage(token: String) async throws -> [String: Any] {
        let obj = try await HTTP.getJSON(
            URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            headers: [
                "Authorization": "Bearer \(token)",
                "anthropic-beta": "oauth-2025-04-20",
            ])
        return obj as? [String: Any] ?? [:]
    }

    static func map(instance: ProviderInstance, usage obj: [String: Any]) -> InstanceReading {
        var windows: [UsageWindow] = []
        if let five = obj["five_hour"] as? [String: Any] {
            windows.append(lane(id: "session", label: "Session", lane: five))
        }
        if let seven = obj["seven_day"] as? [String: Any] {
            windows.append(lane(id: "weekly", label: "Weekly", lane: seven))
        }
        return InstanceReading(id: instance.name, type: instance.type, name: instance.name, windows: windows)
    }

    static func lane(id: String, label: String, lane: [String: Any]) -> UsageWindow {
        UsageWindow(id: id, label: label,
                    usedPercent: num(lane["utilization"]),
                    resetsAt: isoDate(lane["resets_at"] as? String))
    }
}
