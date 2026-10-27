import Foundation

/// Per-million-token prices from models.dev, cached on disk.
final class Pricing {
    struct ModelCost: Equatable {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double
    }

    private var models: [String: ModelCost] = [:]

    /// Bumps whenever the price table itself changes, so derived caches can invalidate.
    var generation: Date = .distantPast

    private static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/meter/models.json")
    }

    private static let cacheLock = NSLock()
    private static var parsed: (mtime: Date, pricing: Pricing)?

    /// The price table is ~6 MB of JSON; parse it once per file revision rather
    /// than on every refresh. A pricing object is read-only after `parse`.
    static func load() async -> Pricing {
        let fm = FileManager.default
        let mtime = (try? fm.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date

        cacheLock.lock()
        let hit = parsed
        cacheLock.unlock()
        if let hit, hit.mtime == mtime { return hit.pricing }

        let pricing = Pricing()

        var data = try? Data(contentsOf: cacheURL)
        var generation = mtime

        let isFresh = generation.map { Date().timeIntervalSince($0) < 86_400 } ?? false
        if data == nil || !isFresh {
            if let (fetched, _) = try? await HTTP.session.data(from: URL(string: "https://models.dev/api.json")!) {
                data = fetched
                generation = Date()
                try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fetched.write(to: cacheURL)
            }
        }

        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return pricing }
        pricing.parse(obj)
        pricing.generation = generation ?? .distantPast
        // only cache a real table; an empty result must retry on the next refresh
        if let onDisk = (try? fm.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date {
            cacheLock.lock()
            parsed = (onDisk, pricing)
            cacheLock.unlock()
        }
        return pricing
    }

    /// First-party providers publish official list prices; resellers mark up or discount.
    private static let officialProviders: Set<String> = [
        "anthropic", "openai", "google", "google-vertex", "azure", "xai",
        "moonshotai", "deepseek", "zai", "minimax", "qwen", "mistral",
    ]

    func parse(_ root: [String: Any]) {
        var entries: [String: (isOfficial: Bool, cost: ModelCost)] = [:]
        for (providerKey, provider) in root {
            guard let providerDict = provider as? [String: Any],
                  let modelDict = providerDict["models"] as? [String: Any] else { continue }
            let isOfficial = Self.officialProviders.contains(providerKey)
            for (id, model) in modelDict {
                guard let m = model as? [String: Any],
                      let cost = m["cost"] as? [String: Any] else { continue }
                let parsed = ModelCost(
                    input: num(cost["input"]), output: num(cost["output"]),
                    cacheRead: num(cost["cache_read"]), cacheWrite: num(cost["cache_write"]))
                let key = id.lowercased()
                if let existing = entries[key], !beats(parsed, isOfficial, existing) { continue }
                entries[key] = (isOfficial, parsed)
            }
        }
        models = entries.mapValues(\.cost)
    }

    /// Official beats reseller; within the same tier the higher list price wins so
    /// free/zero-cost mirrors never shadow a real price.
    private func beats(
        _ candidate: ModelCost, _ isOfficial: Bool,
        _ existing: (isOfficial: Bool, cost: ModelCost)
    ) -> Bool {
        if isOfficial != existing.isOfficial { return isOfficial }
        return candidate.input + candidate.output > existing.cost.input + existing.cost.output
    }

    func cost(for modelID: String) -> ModelCost? {
        let base = modelID.lowercased()
        if let exact = models[base] { return exact }
        // strip bracket variants like "claude-sonnet-4-5[1m]"
        let stripped = base.replacingOccurrences(of: #"\[.*\]$"#, with: "", options: .regularExpression)
        if let s = models[stripped] { return s }
        // versioned ids: log says "claude-sonnet-4-5", models.dev has "claude-sonnet-4-5-20250929"
        return models.keys.filter { $0.hasPrefix(stripped + "-20") }.sorted().last.flatMap { models[$0] }
    }

    /// Codex token counts: cached_input_tokens is a subset of input_tokens.
    static func dollars(_ cost: ModelCost, input: Double, cachedInput: Double, output: Double) -> Double {
        let cached = min(cachedInput, input)
        return max(0, input - cached) / 1_000_000 * cost.input
            + cached / 1_000_000 * cost.cacheRead
            + output / 1_000_000 * cost.output
    }

    /// Claude token counts: cache read/write are separate from input.
    static func dollarsClaude(_ cost: ModelCost, input: Double, cacheRead: Double, cacheWrite: Double, output: Double) -> Double {
        input / 1_000_000 * cost.input
            + cacheRead / 1_000_000 * cost.cacheRead
            + cacheWrite / 1_000_000 * cost.cacheWrite
            + output / 1_000_000 * cost.output
    }
}
