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

    /// Local log scans are device-wide, so each source's total attaches to exactly
    /// one instance of its type, resolved by `LocalCostSource.target`.
    struct LocalCostSource {
        let type: String
        let scan: @Sendable (Pricing, Date) -> Double
        /// Which enabled instance owns the device-wide total. Codex, Claude and
        /// Vercel hold a single device-wide credential, so first enabled is the
        /// only correct answer; opencode matches the actively billed key.
        let target: @Sendable ([ProviderInstance]) -> ProviderInstance?

        static func firstEnabled(_ type: String,
                                 _ scan: @escaping @Sendable (Pricing, Date) -> Double) -> LocalCostSource {
            .init(type: type, scan: scan,
                  target: { enabled in enabled.first { $0.type == type } })
        }

        static let all: [LocalCostSource] = [
            .firstEnabled("codex") { CostScan.codexToday(pricing: $0, since: $1) },
            .firstEnabled("claude") { CostScan.claudeToday(pricing: $0, since: $1) },
            .firstEnabled("vercel") { CostScan.vercelToday(pricing: $0, since: $1) },
            .init(type: "opencode",
                  scan: { CostScan.opencodeToday(pricing: $0, since: $1) },
                  target: { enabled in
                      let activeKey = OpenCode.activeAccountKey()
                      return enabled.first { inst in
                          guard inst.type == "opencode",
                                let key = try? Secrets.apiKey(for: inst) else { return false }
                          return key == activeKey
                      } ?? enabled.first { $0.type == "opencode" }
                  }),
        ]
    }

    /// Attaches device-wide scans to the merged reading list — callers must pass
    /// every enabled instance and every reading (fresh or stale), or stale
    /// spendToday values survive the rotation of an actively billed key.
    static func attachLocalCosts(_ readings: [InstanceReading], enabled: [ProviderInstance]) async -> [InstanceReading] {
        let types = Set(enabled.map(\.type))
        let sources = LocalCostSource.all.filter { types.contains($0.type) }
        guard !sources.isEmpty else { return hideEmpty(readings) }

        let pricing = await Pricing.load()
        var out = readings
        for source in sources {
            let (name, value) = await Task.detached {
                (source.target(enabled)?.name, source.scan(pricing, CostScan.startOfToday))
            }.value
            if let name, let idx = out.firstIndex(where: { $0.name == name }) {
                out[idx].spendToday = value
            }
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
