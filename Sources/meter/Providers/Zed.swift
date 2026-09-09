import Foundation

enum Zed {
    static let defaultServer = "https://zed.dev"

    /// credentials_url (or server_url) in ~/.config/zed/settings.json selects which
    /// keychain entry holds the session; cross-origin overrides are rejected.
    static var server: String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/zed/settings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = (obj["credentials_url"] as? String) ?? (obj["server_url"] as? String) else {
            return defaultServer
        }
        guard let comps = URLComponents(string: raw),
              comps.scheme == "https",
              comps.host != nil else { return defaultServer }
        let normalized = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        guard normalized == defaultServer || normalized.hasPrefix(defaultServer) else { return defaultServer }
        return normalized
    }

    static func fetch(_ instance: ProviderInstance) async throws -> InstanceReading {
        // the editor rotates this keychain item on re-auth; our cached copy can go stale
        let server = Self.server
        let obj = try await retryingOn401(
            invalidate: { Keychain.invalidateInternet(server: server) },
            staleMessage: "Zed session rejected after re-read — sign in again from the Zed editor"
        ) {
            guard let creds = Keychain.internet(server: server) else {
                throw ProviderError.missingKey("not signed in to Zed (no keychain entry for \(server)) — sign in from the Zed editor")
            }
            return try await HTTP.getJSON(
                URL(string: "https://cloud.zed.dev/client/users/me")!,
                headers: ["Authorization": "\(creds.account) \(creds.secret)"])
        }

        guard let root = obj as? [String: Any],
              let plan = root["plan"] as? [String: Any] else {
            throw ProviderError.badResponse("no plan in users/me response")
        }
        return map(instance: instance, plan: plan)
    }

    static func map(instance: ProviderInstance, plan: [String: Any]) -> InstanceReading {
        var windows: [UsageWindow] = []
        let resets = isoDate((plan["subscription_period"] as? [String: Any])?["ended_at"] as? String)
        var note: String?
        if optNum(plan["has_overdue_invoices"]) == 1 {
            note = "overdue invoice — settle billing"
        }

        if let usage = plan["usage"] as? [String: Any],
           let preds = usage["edit_predictions"] as? [String: Any],
           let used = optNum(preds["used"]) {
            let limit = optNum((preds["limit"] as? [String: Any])?["limited"])
            if let limit, limit > 0 {
                windows.append(UsageWindow(
                    id: "edits", label: "Edits",
                    usedPercent: used / limit * 100,
                    resetsAt: resets,
                    note: String(format: "%.0f of %.0f", used, limit)))
            } else {
                windows.append(UsageWindow(
                    id: "edits", label: "Edits", usedPercent: nil, resetsAt: resets,
                    note: plan["plan_v3"] as? String == "zed_free" ? "free plan" : "unlimited"))
            }
        }

        return InstanceReading(id: instance.name, type: instance.type, name: instance.name,
                               windows: windows, balanceNote: note)
    }
}
