import Foundation

enum Claude {
    static let keychainService = "Claude Code-credentials"

    static func fetch(_ instance: ProviderInstance) async throws -> InstanceReading {
        // Claude Code rotates its access token; our per-launch keychain copy goes stale
        let obj = try await retryingOn401(
            invalidate: { Keychain.invalidateGeneric(service: keychainService) },
            staleMessage: "token rejected after re-read — run `claude login`"
        ) {
            try await usage(token: try loadToken())
        }
        return map(instance: instance, usage: obj)
    }

    // MARK: - credentials

    static var credsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }

    static func loadToken() throws -> String {
        var json: [String: Any]?
        if let data = try? Data(contentsOf: credsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = obj
        } else if let raw = Keychain.generic(service: keychainService),
                  let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = obj
        }
        guard let root = json else {
            throw ProviderError.badResponse("no Claude credentials — run `claude login`")
        }
        // 2.1.x keychain items may hold only mcpOAuth state
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let access = oauth["accessToken"] as? String else {
            throw ProviderError.badResponse("credentials hold no claudeAiOauth token (Claude Code 2.1.x move?) — re-auth via `claude login`")
        }
        return access
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
