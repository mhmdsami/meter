import Foundation

enum OpenCode {
    static func fetch(_ instance: ProviderInstance) async throws -> InstanceReading {
        // key rotated out-of-band: drop the cached keychain copy and retry once
        let ref = instance.key ?? instance.name
        return try await retryingOn401(
            invalidate: {
                if !ref.hasPrefix("env:"), !ref.hasPrefix("auth:") {
                    Keychain.invalidateGeneric(service: "meter/\(ref)")
                }
            },
            staleMessage: "key rejected after re-read — update meter/\(ref) with the new key"
        ) {
            try await fetchWithKey(instance)
        }
    }

    static func fetchWithKey(_ instance: ProviderInstance) async throws -> InstanceReading {
        let key = try Secrets.apiKey(for: instance)

        var windows: [UsageWindow] = []
        do {
            let obj = try await HTTP.getJSON(
                URL(string: "https://opencode.ai/zen/go/v1/usage")!,
                headers: ["Authorization": "Bearer \(key)"])

            guard let root = obj as? [String: Any],
                  let usage = root["usage"] as? [String: Any] else {
                throw ProviderError.badResponse("missing usage object")
            }

            let lanes: [(String, String)] = [("rolling", "Rolling"), ("weekly", "Weekly"), ("monthly", "Monthly")]
            for (id, label) in lanes {
                guard let lane = usage[id] as? [String: Any] else { continue }
                windows.append(UsageWindow(
                    id: id, label: label,
                    usedPercent: optNum(lane["percent"]),
                    resetsAt: isoDate(lane["resetsAt"] as? String)))
            }
        } catch ProviderError.http(403, let body) where body.contains("subscription required") {
            // credits-only account: no Go plan, windows stay empty — balance (cookie) still shows
        }

        var balanceNote: String?
        if let cookie = instance.cookie, !cookie.isEmpty {
            balanceNote = try await zenBalance(cookie: cookie)
        }

        return InstanceReading(id: instance.name, type: instance.type, name: instance.name,
                               windows: windows, balanceNote: balanceNote)
    }

    /// The opencode-go key opencode currently bills to: auth.json is opencode's live
    /// credential store (what /connect writes). account.json's "active" pointer goes
    /// stale for months, so it is only a fallback.
    static func activeAccountKey() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let data = try? Data(contentsOf: home.appendingPathComponent(".local/share/opencode/auth.json")),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entry = root["opencode-go"] as? [String: Any],
           let key = entry["key"] as? String {
            return key
        }
        if let data = try? Data(contentsOf: home.appendingPathComponent(".local/share/opencode/account.json")),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let accounts = root["accounts"] as? [String: Any],
           let active = root["active"] as? [String: String],
           let activeID = active["opencode-go"],
           let account = accounts[activeID] as? [String: Any],
           let credential = account["credential"] as? [String: Any],
           let key = credential["key"] as? String {
            return key
        }
        return nil
    }

    // MARK: - Zen credit balance (web RPC; session-cookie auth only — no API-key path exists)

    // server function IDs, lifted from CodexBar's OpenCodeUsageFetcher
    private static let workspacesID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    private static let billingID = "c83b78a614689c38ebee981f9b39a8b377716db85c1fd7dbab604adc02d3313d"
    private static let usdScale = 100_000_000.0

    static func zenBalance(cookie: String) async throws -> String {
        async let wsText = serverRPC(id: workspacesID, args: nil, cookie: cookie)
        guard let ws = try await wsText,
              let range = ws.range(of: #"wrk_[A-Za-z0-9]+"#, options: .regularExpression) else {
            throw ProviderError.badResponse("no workspace in opencode RPC (cookie expired?)")
        }
        let workspaceID = String(ws[range])

        let args = "[\"" + workspaceID + "\"]"
        guard let billingText = try await serverRPC(id: billingID, args: args, cookie: cookie) else {
            throw ProviderError.badResponse("empty billing payload")
        }
        // balance/monthlyUsage arrive scaled by 1e8; trust numbers only when customerID is present
        guard billingText.contains("customerID") else {
            throw ProviderError.badResponse("billing payload missing customerID")
        }
        let balance = number(field: "balance", in: billingText).map { $0 / usdScale }
        let usageUSD = number(field: "monthlyUsage", in: billingText).map { $0 / usdScale }
        let limit = number(field: "monthlyLimit", in: billingText)
        switch (balance, usageUSD) {
        case (let bal?, _):
            var note = String(format: "$%.2f credits left", bal)
            if let usageUSD, let limit, limit > 0 {
                note += String(format: " · month $%.2f of $%.0f", usageUSD, limit)
            } else if let usageUSD {
                note += String(format: " · month $%.2f", usageUSD)
            }
            return note
        case (_, let u?):
            return String(format: "month $%.2f used", u)
        default:
            throw ProviderError.badResponse("billing payload had no balance fields")
        }
    }

    private static func serverRPC(id: String, args: String?, cookie: String) async throws -> String? {
        var components = URLComponents(string: "https://opencode.ai/_server")!
        var items = [URLQueryItem(name: "id", value: id)]
        if let args { items.append(URLQueryItem(name: "args", value: args)) }
        components.queryItems = items
        var req = URLRequest(url: components.url!)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(id, forHTTPHeaderField: "X-Server-Id")
        req.setValue("server-fn:\(UUID().uuidString)", forHTTPHeaderField: "X-Server-Instance")
        req.setValue("https://opencode.ai", forHTTPHeaderField: "Origin")
        req.setValue("https://opencode.ai", forHTTPHeaderField: "Referer")
        req.setValue("text/javascript, application/json;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, resp) = try await HTTP.session.data(for: req)
        guard let status = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw ProviderError.http(status, String(data: data.prefix(150), encoding: .utf8) ?? "")
        }
        return String(data: data, encoding: .utf8)
    }

    private static func number(field: String, in text: String) -> Double? {
        // matches JSON ("balance": 1) and SolidStart $R payload (balance:$R[3]=1)
        let pattern = "(?:\\\"" + field + "\\\"|" + field + ")\\s*:\\s*(?:\\$R\\[\\d+\\]\\s*=\\s*)?(-?[0-9]+(?:\\.[0-9]+)?)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }
}
