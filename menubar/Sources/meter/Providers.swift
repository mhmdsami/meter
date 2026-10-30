import Foundation

typealias Fetcher = (ProviderInstance) async throws -> InstanceReading

enum Providers {
    // 429 backoff per instance; the poll loop defers these until the window passes
    static var backoffUntil: [String: Date] = [:]
    private static let backoffLock = NSLock()

    static func setBackoff(_ name: String, seconds: TimeInterval?) {
        backoffLock.lock(); defer { backoffLock.unlock() }
        backoffUntil[name] = Date().addingTimeInterval(max(60, seconds ?? 300))
    }

    static func backoffRemaining(_ name: String) -> TimeInterval? {
        backoffLock.lock(); defer { backoffLock.unlock() }
        guard let until = backoffUntil[name], until > Date() else { return nil }
        return until.timeIntervalSinceNow
    }
    static let all: [String: Fetcher] = [
        "openrouter": OpenRouter.fetch,
        "opencode": OpenCode.fetch,
        "codex": Codex.fetch,
        "claude": Claude.fetch,
        "zed": Zed.fetch,
        "vercel": VercelGateway.fetch,
        "antigravity": Antigravity.fetch,
        "amp": Amp.fetch,
        "cloudflare": Cloudflare.fetch,
        "straitly": Straitly.fetch,
        "other": CatchAll.fetch,
    ]

    static func fetch(_ instance: ProviderInstance) async -> InstanceReading {
        guard let fetch = all[instance.type] else {
            return InstanceReading(id: instance.name, type: instance.type, name: instance.name,
                                   error: "unknown type '\(instance.type)'")
        }
        do {
            return try await fetch(instance)
        } catch ProviderError.rateLimited(let retryAfter) {
            setBackoff(instance.name, seconds: retryAfter)
            let msg = ProviderError.rateLimited(retryAfter: retryAfter).errorDescription ?? "rate limited"
            return InstanceReading(id: instance.name, type: instance.type, name: instance.name,
                                   error: msg)
        } catch {
            return InstanceReading(id: instance.name, type: instance.type, name: instance.name,
                                   error: error.localizedDescription)
        }
    }

    static func fetchAll(_ instances: [ProviderInstance]) async -> [InstanceReading] {
        let enabled = instances.filter(\.enabled)
        let results = await withTaskGroup(of: InstanceReading.self) { group in
            for i in enabled { group.addTask { await fetch(i) } }
            var out: [InstanceReading] = []
            for await r in group { out.append(r) }
            return out
        }
        let order = Dictionary(uniqueKeysWithValues: enabled.enumerated().map { ($1.name, $0) })
        let readings = results.sorted { (order[$0.name] ?? .max) < (order[$1.name] ?? .max) }
        return readings
    }

    /// The summary reports spend per provider type, so the total attaches to the
    /// first enabled instance of that type. Extra instances of the same provider
    /// cannot be told apart server-side and show quota only.
    static func attachSpend(_ readings: [InstanceReading], enabled: [ProviderInstance],
                            today: [String: Double]) -> [InstanceReading] {
        var out = readings
        for i in out.indices { out[i].spendToday = nil }
        for (type, value) in today where value > 0.004 {
            guard let name = enabled.first(where: { $0.type == type })?.name,
                  let index = out.firstIndex(where: { $0.name == name }) else { continue }
            out[index].spendToday = value
        }
        return hideEmpty(out)
    }

    /// Hide rows with nothing to show; a real $0.00 spend still counts as something.
    static func hideEmpty(_ readings: [InstanceReading]) -> [InstanceReading] {
        readings.filter { r in
            guard r.error == nil else { return true }
            return !r.windows.isEmpty || r.balanceNote != nil || r.spendToday != nil
        }
    }
}
