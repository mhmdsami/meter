import Foundation
import Combine
import Network

/// System connectivity, so meter makes zero requests while offline and
/// refreshes the moment the network returns.
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    @Published var isOnline = true
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isOnline = path.status == .satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "meter.netmon"))
    }
}

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
        // last known readings survive restarts, so the bar never blanks at $0
        // while the first refresh scans and fetches
        if let data = try? Data(contentsOf: Self.readingsCacheURL),
           let cached = try? JSONDecoder().decode([InstanceReading].self, from: data) {
            readings = cached
        }
    }

    nonisolated private static var readingsCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/meter/readings.json")
    }

    nonisolated private static func persist(_ readings: [InstanceReading]) {
        let url = readingsCacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(readings) else { return }
        try? data.write(to: url, options: .atomic)
    }

    var totalToday: Double { readings.totalToday }

    /// Providers whose spend is billed money rather than a list-price estimate.
    nonisolated static let reportedProviders: Set<String> = ["opencode", "vercel"]

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

    /// The menu's history arrays: the ledger is the durable source of truth
    /// (imported history, pruned logs), while live scans cover days the ledger
    /// has not recorded yet. Taking the larger per day never double-counts.
    nonisolated static func historyDaily(scans: [String: [Double]], ledger: [Double]) -> [String: [Double]] {
        var scanned = Array(repeating: 0.0, count: ledger.count)
        for values in scans.values {
            for i in 0..<min(scanned.count, values.count) {
                scanned[i] += values[i]
            }
        }
        return ["total": (0..<ledger.count).map { max(ledger[$0], scanned[$0]) }]
    }

    /// The menubar shows one "Other" row, but the ledger/dashboard should keep
    /// the real provider. Split the "other" bucket back out by `Spend.provider`.
    nonisolated static func ledgerSpend(_ spend: [String: [CostScan.Spend]]) -> [String: [CostScan.Spend]] {
        guard let catchAll = spend["other"] else { return spend }
        var out = spend
        out.removeValue(forKey: "other")
        for row in catchAll {
            out[row.provider.isEmpty ? "other" : row.provider, default: []].append(row)
        }
        return out
    }

    /// Today's per-provider spend for the menu bar and rows: the ledger's value
    /// (which already includes scans plus anything imported) wins; the live scan
    /// covers the window before the ledger's first write.
    nonisolated static func mergeToday(scans: [String: Double], ledger: [String: Double]) -> [String: Double] {
        var out = ledger
        for (type, value) in scans { out[type] = max(out[type] ?? 0, value) }
        return out
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
        reconnectTask = Task { [weak self] in
            var wasOnline = true
            while !Task.isCancelled {
                let online = NetworkMonitor.shared.isOnline
                if online, !wasOnline { await self?.refreshAll(force: true) }
                wasOnline = online
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var reconnectTask: Task<Void, Never>?

    /// `interactive` is true only for user-initiated refreshes, which may raise a
    /// keychain authorization dialog; background cycles read without prompting.
    func refreshAll(force: Bool = false, interactive: Bool = false) async {
        // offline: make no requests at all; keep showing cached readings and
        // wait for the reconnect watcher to force a refresh
        guard NetworkMonitor.shared.isOnline else { return }
        Keychain.setInteraction(interactive)
        defer { Keychain.setInteraction(false) }
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
        // publish readings fast: today's buckets only need files touched today;
        // the 30-day history pass below reuses their cached parse
        let types = Set(config.providers.filter(\.enabled).map(\.type))
        let pricing = await Pricing.load()
        let spend = await Task.detached {
            CostScan.spendTotals(days: 30, types: types, pricing: pricing)
        }.value
        let todayScan = CostScan.dailyTotals(spend, days: 1).mapValues { $0.first ?? 0 }
        let today = Self.mergeToday(scans: todayScan, ledger: Ledger.shared.todayByProvider())
        readings = Providers.attachLocalCosts(
            merged, enabled: config.providers.filter(\.enabled), today: today)
        let snapshot = readings
        Task.detached { Self.persist(snapshot) }
        let daily = CostScan.dailyTotals(spend, days: 30)
        history = Self.historyLines(Self.historyDaily(scans: daily,
                                                      ledger: Ledger.shared.recentDailyTotals(days: 30)))
        let enabled = config.providers.filter(\.enabled)
        let targets = Providers.costTargetNames(enabled: enabled)
        let gen = pricing.generation
        let backfillNeeded = Ledger.shared.meta("backfilled") == nil
        let typesForBackfill = types
        let snapshotReadings = readings
        // ledger/dashboard keep the real provider behind "other"; the menubar row
        // above stays aggregated, which is why this is separate from `daily`
        let ledgerSpend = Self.ledgerSpend(spend)
        let ledgerDaily = CostScan.dailyTotals(ledgerSpend, days: 30)
        Task.detached {
            Ledger.shared.recordDaily(ledgerDaily, targetNames: targets,
                                      pricingGen: gen, reported: Self.reportedProviders)
            Ledger.shared.recordBreakdown(ledgerSpend, targetNames: targets,
                                          pricingGen: gen, reported: Self.reportedProviders)
            if backfillNeeded {
                // one-time: seed the ledger with longer history from the same scans
                let widePricing = await Pricing.load()
                let wideSpend = CostScan.spendTotals(days: 90, types: typesForBackfill, pricing: widePricing)
                let wideLedger = Self.ledgerSpend(wideSpend)
                let wide = CostScan.dailyTotals(wideLedger, days: 90)
                Ledger.shared.recordDaily(wide, targetNames: targets,
                                          pricingGen: widePricing.generation,
                                          reported: Self.reportedProviders)
                Ledger.shared.recordBreakdown(wideLedger, targetNames: targets,
                                              pricingGen: widePricing.generation,
                                              reported: Self.reportedProviders)
                Ledger.shared.setMeta("backfilled", ISO8601DateFormatter().string(from: Date()))
            }
            Ledger.shared.recordQuotaSnapshots(snapshotReadings)
        }
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
