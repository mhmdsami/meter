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

    private static var readingsCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/meter/readings.json")
    }

    private static func persist(_ readings: [InstanceReading]) {
        let url = readingsCacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(readings) else { return }
        try? data.write(to: url, options: .atomic)
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

    func refreshAll(force: Bool = false) async {
        // offline: make no requests at all; keep showing cached readings and
        // wait for the reconnect watcher to force a refresh
        guard NetworkMonitor.shared.isOnline else { return }
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
        let today = await Task.detached {
            CostScan.dailyTotals(days: 1, types: types, pricing: pricing)
        }.value
        readings = Providers.attachLocalCosts(
            merged, enabled: config.providers.filter(\.enabled),
            today: today.mapValues { $0.first ?? 0 })
        let daily = await Task.detached {
            CostScan.dailyTotals(days: 30, types: types, pricing: pricing)
        }.value
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
