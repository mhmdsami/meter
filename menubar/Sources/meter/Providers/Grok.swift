import Foundation

/// The X Subscription: one weekly pool shared by Grok, Grok Bot, and Cursor.
/// This is the endpoint the official Grok CLI calls for `/usage`. Meter reads the
/// CLI's login and never writes it; when that login expires the CLI refreshes it
/// on its next run.
enum Grok {
    static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    struct Response: Decodable {
        let config: Body?

        struct Body: Decodable {
            let currentPeriod: Period?
            let creditUsagePercent: Double?
            let productUsage: [Product]?
            let prepaidBalance: Balance?
            let billingPeriodEnd: String?
            let isUnifiedBillingUser: Bool?
        }

        struct Period: Decodable {
            let end: String?
        }

        struct Product: Decodable {
            let product: String
            let usagePercent: Double?
        }

        struct Balance: Decodable {
            let val: Double?
        }
    }

    struct Login {
        let token: String
        let expiresAt: Date?
    }

    nonisolated static var authURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
    }

    private struct Entry: Decodable {
        let key: String?
        let expires_at: String?
    }

    /// The file can hold one entry per issuer; take the one that lives longest.
    static func login() throws -> Login {
        guard let data = try? Data(contentsOf: authURL),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            throw ProviderError.missingKey("no Grok login — run `grok login`")
        }
        let usable = entries.values
            .compactMap { entry -> Login? in
                guard let token = entry.key, !token.isEmpty else { return nil }
                return Login(token: token, expiresAt: isoDate(entry.expires_at))
            }
            .sorted { ($0.expiresAt ?? .distantPast) > ($1.expiresAt ?? .distantPast) }
        guard let login = usable.first else {
            throw ProviderError.missingKey("Grok login holds no token — run `grok login`")
        }
        return login
    }

    static func fetch(_ instance: ProviderInstance) async throws -> InstanceReading {
        let login = try login()
        if let expiry = login.expiresAt, expiry <= Date() {
            throw ProviderError.badResponse("Grok login expired — run `grok` to refresh it")
        }
        let response: HTTPResponse
        do {
            response = try await HTTP.request(billingURL, headers: [
                "Authorization": "Bearer \(login.token)",
                "x-xai-token-auth": "xai-grok-cli",
                "accept": "application/json",
            ])
        } catch ProviderError.http(let status, _) where status == 401 || status == 403 {
            throw ProviderError.badResponse("Grok login rejected — run `grok` to refresh it")
        }
        return try parse(response.data, instance: instance)
    }

    static func parse(_ data: Data, instance: ProviderInstance) throws -> InstanceReading {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let body = response.config else {
            throw ProviderError.badResponse("Grok billing returned unexpected JSON")
        }
        let used = body.creditUsagePercent ?? 0
        let reset = isoDate(body.billingPeriodEnd) ?? isoDate(body.currentPeriod?.end)
        var reading = InstanceReading(
            id: instance.name, type: instance.type, name: instance.name,
            windows: [UsageWindow(id: "weekly", label: "Weekly", usedPercent: used, resetsAt: reset)]
        )
        if let cents = body.prepaidBalance?.val, cents > 0 {
            reading.balanceNote = String(format: "$%.2f credit", cents / 100)
        }
        return reading
    }
}
