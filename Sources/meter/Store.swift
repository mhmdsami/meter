import Foundation
import Combine

@MainActor
final class Store: ObservableObject {
    static let shared = Store(config: ConfigStore.load())

    @Published var config: Config
    @Published var readings: [InstanceReading] = []
    @Published var history: [HistoryLine] = []
    @Published var lastRefresh: Date?
    private var pollTask: Task<Void, Never>?
    private var lastFetch: [String: Date] = [:]

    init(config: Config) {
        self.config = config
    }

    var totalToday: Double { readings.totalToday }

    struct HistoryLine: Identifiable, Equatable {
        let id: String
        let label: String
        let total: String
        /// daily values, oldest first, normalized to the row's max for the bar chart
        let spark: [Double]
    }

    nonisolated private static func dollars(_ value: Double) -> String {
        let s = String(format: "%.2f", max(0, value))
        var parts = s.split(separator: ".")
        var whole = String(parts.removeFirst())
        var grouped = ""
        while whole.count > 3 {
            let cut = whole.index(whole.endIndex, offsetBy: -3)
            grouped = "," + whole[cut...] + grouped
            whole = String(whole[..<cut])
        }
        return "$" + whole + grouped + "." + (parts.first.map(String.init) ?? "00")
    }

    /// "Last 7/30 days" totals with per-day bars, from the same device-wide
    /// scans that feed today's spend.
    nonisolated static func historyLines(_ daily: [String: [Double]]) -> [HistoryLine] {
        func sum(_ d: [Double], _ n: Int) -> Double { d.prefix(n).reduce(0, +) }
        var lines: [HistoryLine] = []
        for (id, label, n) in [("7d", "Last 7 days", 7), ("30d", "Last 30 days", 30)] {
            let total = daily.reduce(0.0) { $0 + sum($1.value, n) }
            guard total > 0.004 else { continue }
            // per-day sums, oldest first, normalized against the max day
            let daySums = (0..<n).map { i in
                daily.values.reduce(0.0) { $0 + ($1.count > i ? $1[i] : 0) }
            }
            let max = daySums.max() ?? 0
            let spark = max > 0 ? daySums.reversed().map { $0 / max } : []
            lines.append(HistoryLine(id: id, label: label,
                                     total: Self.dollars(total),
                                     spark: spark))
        }
        return lines
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.refreshAll()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.refreshAll()
            }
        }
    }

    func refreshAll(force: Bool = false) async {
        config = ConfigStore.load()
        let now = Date()
        let dueNames = Self.dueInstances(
            config.providers, lastFetch: lastFetch, now: now,
            force: force, globalIntervalMinutes: config.intervalMinutes)
        let due = config.providers.filter { dueNames.contains($0.name) }
        // deferred instances (interval not reached, or 429 backoff) keep their last reading
        let fresh = await Providers.fetchAll(due)
        var merged: [InstanceReading] = []
        for p in config.providers where p.enabled {
            if let r = fresh.first(where: { $0.name == p.name }) {
                merged.append(r)
                lastFetch[p.name] = Date()
            } else if let old = readings.first(where: { $0.name == p.name }) {
                merged.append(old)
            }
        }
        let types = Set(config.providers.filter(\.enabled).map(\.type))
        let pricing = await Pricing.load()
        let daily = await Task.detached {
            CostScan.dailyTotals(days: 30, types: types, pricing: pricing)
        }.value
        readings = Providers.attachLocalCosts(
            merged, enabled: config.providers.filter(\.enabled),
            today: daily.mapValues { $0.first ?? 0 })
        history = Self.historyLines(daily)
        let names = Set(config.providers.map(\.name))
        lastFetch = lastFetch.filter { names.contains($0.key) }
        lastRefresh = Date()
    }

    /// Which instances should fetch right now: force bypasses intervals but never
    /// an active 429 backoff; otherwise an instance is due once per interval.
    nonisolated static func dueInstances(
        _ providers: [ProviderInstance],
        lastFetch: [String: Date],
        now: Date,
        force: Bool,
        globalIntervalMinutes: Int
    ) -> [String] {
        providers.filter { p in
            guard p.enabled else { return false }
            if Providers.backoffRemaining(p.name) != nil { return false }
            if force { return true }
            let interval = TimeInterval(max(1, p.intervalMinutes ?? globalIntervalMinutes) * 60)
            return now.timeIntervalSince(lastFetch[p.name] ?? .distantPast) >= interval
        }.map(\.name)
    }
}
