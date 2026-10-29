import Foundation

enum Claude {
    static let keychainService = "Claude Code-credentials"

    static func fetch(_ instance: ProviderInstance) async throws -> InstanceReading {
        // an expired token gets a 429 from Anthropic, not a 401 — surface the real
        // problem instead of backing off on a bogus rate limit for hours
        let creds = try loadCredentials()
        if let expiry = creds.expiresAt, expiry <= Date() {
            let when = DateFormatter.localizedString(from: expiry, dateStyle: .short, timeStyle: .short)
            throw ProviderError.badResponse("Claude credentials expired \(when) — run `claude login`")
        }
        let obj = try await retryingOn401(
            invalidate: { Keychain.invalidateGeneric(service: keychainService) },
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

    struct Credentials {
        let token: String
        let expiresAt: Date?
    }

    /// Credential sources, newest first is decided by the caller: the file and
    /// Claude Code's keychain item. Reads are cached per launch, so an expired
    /// cached read must be re-read rather than trusted — Claude Code rotates the
    /// token underneath us while the agent keeps running.
    private static func candidates() -> [Credentials] {
        var out: [Credentials] = []
        if let data = try? Data(contentsOf: credsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let creds = try? parse(obj) {
            out.append(creds)
        }
        if let raw = Keychain.generic(service: keychainService),
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

    static func loadCredentials() throws -> Credentials {
        if let creds = usable(candidates()) { return creds }
        // everything we can see is expired: drop the per-launch cache and re-read,
        // in case the item rotated since it was cached
        Keychain.invalidateGeneric(service: keychainService)
        let retried = candidates()
        if let creds = usable(retried) { return creds }
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

    static func loadToken() throws -> String {
        try loadCredentials().token
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
