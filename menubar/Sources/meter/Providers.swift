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

    /// Instance name each device-wide cost source currently attaches to, used as
    /// the ledger's account label (device-wide scans are per provider, not per key).
    static func costTargetNames(enabled: [ProviderInstance]) -> [String: String] {
        var out: [String: String] = [:]
        for source in LocalCostSource.all {
            if let name = source.target(enabled)?.name { out[source.type] = name }
        }
        return out
    }

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
        let spend: @Sendable (Pricing, Date) -> [CostScan.Spend]
        /// Which enabled instance owns the device-wide total. Codex, Claude and
        /// Vercel hold a single device-wide credential, so first enabled is the
        /// only correct answer; opencode matches the actively billed key.
        let target: @Sendable ([ProviderInstance]) -> ProviderInstance?
        /// Hide the row while its total is ~zero (used by the catch-all).
        var hideWhenZero: Bool = false

        static func firstEnabled(
            _ type: String,
            _ spend: @escaping @Sendable (Pricing, Date) -> [CostScan.Spend]
        ) -> LocalCostSource {
            .init(type: type, spend: spend,
                  target: { enabled in enabled.first { $0.type == type } })
        }

        /// pi tags each message with the provider that actually served it, so its
        /// spend joins that provider's row rather than a single router row.
        private static func piSpend(for type: String, pricing: Pricing, windowStart: Date) -> [CostScan.Spend] {
            CostScan.spend(urls: CostScan.piURLs(), format: .pi,
                           windowStart: windowStart, pricing: pricing)
                .filter { CostScan.piProviderType($0.provider) == type }
        }

        static let all: [LocalCostSource] = [
            .firstEnabled("codex") { pricing, windowStart in
                CostScan.codexSourceSpend(windowStart: windowStart, pricing: pricing)
                    + piSpend(for: "codex", pricing: pricing, windowStart: windowStart)
            },
            .firstEnabled("claude") { pricing, windowStart in
                CostScan.spend(urls: CostScan.claudeURLs(), format: .claude,
                               windowStart: windowStart, pricing: pricing)
                    + piSpend(for: "claude", pricing: pricing, windowStart: windowStart)
            },
            .firstEnabled("antigravity") { pricing, windowStart in
                CostScan.antigravitySpend(windowStart: windowStart, pricing: pricing)
                    + piSpend(for: "antigravity", pricing: pricing, windowStart: windowStart)
            },
            .firstEnabled("straitly") { pricing, windowStart in
                piSpend(for: "straitly", pricing: pricing, windowStart: windowStart)
            },
            .firstEnabled("vercel") { pricing, windowStart in
                CostScan.spend(urls: [CostScan.fxURL()], format: .vercel,
                               windowStart: windowStart, pricing: pricing)
            },
            .init(type: "opencode",
                  spend: { pricing, windowStart in
                      CostScan.opencodeSpend(windowStart: windowStart, pricing: pricing)
                          .filter { CostScan.opencodeProviderType($0.provider) == "opencode" }
                          + piSpend(for: "opencode", pricing: pricing, windowStart: windowStart)
                  },
                  target: { enabled in
                      let activeKey = OpenCode.activeAccountKey()
                      return enabled.first { inst in
                          guard inst.type == "opencode",
                                let key = try? Secrets.apiKey(for: inst) else { return false }
                          return key == activeKey
                      } ?? enabled.first { $0.type == "opencode" }
                  }),
            .init(type: "other",
                  spend: { pricing, windowStart in
                      // every pi/opencode provider no dedicated row claims; the
                      // menubar aggregates these, the ledger splits them by provider
                      let pi = CostScan.spend(urls: CostScan.piURLs(), format: .pi,
                                              windowStart: windowStart, pricing: pricing)
                          .filter { CostScan.piProviderType($0.provider) == nil }
                      let oc = CostScan.opencodeSpend(windowStart: windowStart, pricing: pricing)
                          .filter { CostScan.opencodeProviderType($0.provider) == nil }
                      return pi + oc
                  },
                  target: { enabled in enabled.first { $0.type == "other" } },
                  hideWhenZero: true),
        ]
    }

    /// Attaches today's device-wide totals (precomputed by `CostScan.dailyTotals`)
    /// to the merged reading list — callers must pass every enabled instance and
    /// every reading (fresh or stale), or stale spendToday values survive the
    /// rotation of an actively billed key.
    static func attachLocalCosts(_ readings: [InstanceReading], enabled: [ProviderInstance],
                                 today: [String: Double]) -> [InstanceReading] {
        var out = readings
        for source in LocalCostSource.all {
            guard let name = source.target(enabled)?.name,
                  let value = today[source.type] else { continue }
            if source.hideWhenZero && value <= 0.004 { continue }
            if let idx = out.firstIndex(where: { $0.name == name }) {
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
