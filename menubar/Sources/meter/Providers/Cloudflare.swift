import Foundation

/// Cloudflare AI Gateway usage. Reads the gateway's request logs for today and
/// totals cost/tokens, so the row mirrors the Vercel gateway: spend when
/// Cloudflare bills it (unified billing), plus a requests/tokens note.
enum Cloudflare {
    struct LogEntry {
        let createdAt: Date
        let cost: Double
        let tokensIn: Double
        let tokensOut: Double
        let success: Bool
    }

    static func fetch(_ instance: ProviderInstance) async throws -> InstanceReading {
        let token = try Secrets.apiKey(for: instance)
        // config options first, then the usual env vars, so a single env block can
        // carry everything the gateway needs
        let account = option("account_id", instance: instance, env: "CLOUDFLARE_ACCOUNT_ID")
        let gateway = option("gateway_id", instance: instance, env: "CLOUDFLARE_GATEWAY_ID")
        guard let account, !account.isEmpty else {
            throw ProviderError.badResponse("set options.account_id (or CLOUDFLARE_ACCOUNT_ID) for the Cloudflare gateway")
        }
        let gatewayID: String
        if let gateway, !gateway.isEmpty {
            gatewayID = gateway
        } else {
            // no gateway configured: ask the API (needs AI Gateway Read) and use
            // the only one, or name the choices
            gatewayID = try await discoverGateway(token: token, account: account)
        }

        let forbidden = ProviderError.badResponse(
            "Cloudflare token can't read AI Gateway — create an API token with Account → AI Gateway → Read (an AI Gateway request token like cfut_… has no read access)")
        let since = Calendar.current.startOfDay(for: Date())
        var entries: [LogEntry] = []
        // Bounded pagination: newest first, stop once a page predates today
        for page in 1...10 {
            let rows: [LogEntry]
            do {
                rows = try await fetchPage(token: token, account: account, gateway: gatewayID, page: page)
            } catch ProviderError.http(403, _) {
                throw forbidden
            } catch ProviderError.http(404, _) {
                break  // gateway not created yet: no usage to report
            }
            if rows.isEmpty { break }
            entries.append(contentsOf: rows)
            if rows.contains(where: { $0.createdAt < since }) { break }
        }

        let today = entries.filter { $0.createdAt >= since }
        let summary = summarize(today)
        // prepaid Unified Billing credits; the API reports cents (like the rest of
        // the AI Gateway billing endpoints), so 2000 means $20.00
        let credits = try? await fetchCreditBalance(token: token, account: account)
        var parts: [String] = []
        if let credits { parts.append(creditNote(credits)) }
        if summary.requests > 0 {
            var usage = "\(summary.requests) req · \(formatTokens(summary.tokens)) tok"
            if summary.errors > 0 { usage += " · \(summary.errors) err" }
            parts.append(usage)
        }
        return InstanceReading(id: instance.name, type: instance.type, name: instance.name,
                               balanceNote: parts.isEmpty ? nil : parts.joined(separator: " · "),
                               spendToday: summary.cost)
    }

    /// Pure so it can be tested: the response carries the balance in cents.
    static func parseCreditBalance(_ data: Data) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let cents = optNum(result["balance"]) else { return nil }
        return cents / 100
    }

    private static func fetchCreditBalance(token: String, account: String) async throws -> Double {
        let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(account)/ai-gateway/billing/credit-balance")!
        let resp = try await HTTP.request(url, headers: ["Authorization": "Bearer \(token)"])
        guard let balance = parseCreditBalance(resp.data) else {
            throw ProviderError.badResponse("no credit balance in Cloudflare response")
        }
        return balance
    }

    private static func creditNote(_ dollars: Double) -> String {
        String(format: "%@$%.2f left", dollars < 0 ? "-" : "", abs(dollars))
    }

    private static func option(_ key: String, instance: ProviderInstance, env: String) -> String? {
        if let value = instance.options?[key], !value.isEmpty { return value }
        if let value = ProcessInfo.processInfo.environment[env], !value.isEmpty { return value }
        return Secrets.shellEnv()[env]
    }

    struct Summary {
        let requests: Int
        let errors: Int
        let tokens: Int
        let cost: Double
    }

    /// Pure so it can be tested against fixtures.
    static func summarize(_ entries: [LogEntry]) -> Summary {
        let tokens = Int(entries.reduce(0) { $0 + $1.tokensIn + $1.tokensOut })
        return Summary(requests: entries.count,
                       errors: entries.filter { !$0.success }.count,
                       tokens: tokens,
                       cost: entries.reduce(0) { $0 + $1.cost })
    }

    /// Parses the documented logs payload: {"result": [{created_at, cost, tokens_in, ...}]}
    static func parse(_ data: Data) -> [LogEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [[String: Any]] else { return [] }
        return result.compactMap { row in
            guard let createdAt = (row["created_at"] as? String).flatMap(isoDate) else { return nil }
            return LogEntry(createdAt: createdAt,
                            cost: optNum(row["cost"]) ?? 0,
                            tokensIn: optNum(row["tokens_in"]) ?? 0,
                            tokensOut: optNum(row["tokens_out"]) ?? 0,
                            success: (row["success"] as? Bool) ?? true)
        }
    }

    /// Picks the gateway when none is configured: exactly one is unambiguous,
    /// several are named so the user can set options.gateway_id.
    static func discoverGateway(token: String, account: String) async throws -> String {
        let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(account)/ai-gateway/gateways?per_page=50")!
        let resp: HTTPResponse
        do {
            resp = try await HTTP.request(url, headers: ["Authorization": "Bearer \(token)"])
        } catch ProviderError.http(403, _) {
            throw ProviderError.badResponse(
                "Cloudflare token can't read AI Gateway — create an API token with Account → AI Gateway → Read (an AI Gateway request token like cfut_… has no read access)")
        }
        guard let root = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
              let result = root["result"] as? [[String: Any]] else {
            throw ProviderError.badResponse("no gateways in Cloudflare response")
        }
        let gateways = result.compactMap { $0["id"] as? String }
        switch gateways.count {
        // Cloudflare auto-creates a gateway named `default` on the first
        // authenticated request, so an empty list still has a usable id
        case 0: return "default"
        case 1: return gateways[0]
        default: throw ProviderError.badResponse("multiple gateways — set options.gateway_id (or CLOUDFLARE_GATEWAY_ID): \(gateways.joined(separator: ", "))")
        }
    }

    private static func fetchPage(token: String, account: String, gateway: String, page: Int) async throws -> [LogEntry] {
        var components = URLComponents(string: "https://api.cloudflare.com/client/v4/accounts/\(account)/ai-gateway/gateways/\(gateway)/logs")!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "50"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "order_by", value: "created_at"),
            URLQueryItem(name: "direction", value: "desc"),
        ]
        let resp = try await HTTP.request(components.url!, headers: ["Authorization": "Bearer \(token)"])
        return parse(resp.data)
    }

    private static func formatTokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return String(format: "%.1fK", Double(count) / 1_000)
        default: return String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }
}
