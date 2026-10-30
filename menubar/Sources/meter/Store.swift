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
    @Published var isRefreshing = false
    private var pollTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var lastFetch: [String: Date] = [:]
    private var lastSummary: Date?
    private var latestSummary: Summary?
    private var refreshInFlight = false
    private var queuedForce = false

    init(config: Config) {
        self.config = config
        // cached readings and summary keep the bar and history populated across
        // launches, before the first network round trip returns
        if let data = try? Data(contentsOf: Self.readingsCacheURL),
           let cached = try? JSONDecoder().decode([InstanceReading].self, from: data) {
            readings = cached
        }
        if let summary = SummaryClient.cached() {
            latestSummary = summary
            history = Self.historyLines(SummaryClient.dailyByProvider(summary, days: 30))
            readings = Providers.attachSpend(readings, enabled: config.providers.filter(\.enabled),
                                             today: summary.todayByProvider)
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

    /// "Last 7/30 days" totals with per-day bars, from the same cross-machine
    /// summary the menu total comes from.
    nonisolated static func historyLines(_ daily: [String: [Double]]) -> [HistoryLine] {
        func sum(_ d: [Double], _ n: Int) -> Double { d.suffix(n).reduce(0, +) }
        var lines: [HistoryLine] = []
        for (id, label, n) in [("7d", "Last 7 days", 7), ("30d", "Last 30 days", 30)] {
            let total = daily.reduce(0.0) { $0 + sum($1.value, n) }
            guard total > 0.004 else { continue }
            let daySums = (0..<n).map { i in
                daily.values.reduce(0.0) { sum, values in
                    guard values.count >= n else { return sum }
                    let value = values[values.count - n + i]
                    return sum + (value.isFinite ? value : 0)
                }
            }
            let max = daySums.max() ?? 0
            let spark = max > 0 ? daySums.map { $0 / max } : []
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

    /// One refresh at a time; a manual refresh that lands mid-cycle is queued and
    /// re-runs as a forced pass instead of racing the background one.
    func refreshAll(force: Bool = false, interactive: Bool = false) async {
        if refreshInFlight {
            if force { queuedForce = true }
            return
        }
        refreshInFlight = true
        isRefreshing = true
        defer {
            refreshInFlight = false
            isRefreshing = false
        }
        var forced = force
        repeat {
            queuedForce = false
            await refreshOnce(force: forced, interactive: interactive)
            forced = true
        } while queuedForce
    }

    /// `interactive` is true only for user-initiated refreshes, which may raise a
    /// keychain authorization dialog; background cycles read without prompting.
    private func refreshOnce(force: Bool, interactive: Bool) async {
        // offline: make no requests at all; keep showing cached readings and
        // wait for the reconnect watcher to force a refresh
        guard NetworkMonitor.shared.isOnline else { return }
        config = ConfigStore.load()
        let now = Date()
        let dueNames = Self.dueInstances(
            config.providers, lastFetch: lastFetch, now: now,
            force: force, globalIntervalMinutes: config.intervalMinutes)
        let due = config.providers.filter { dueNames.contains($0.name) }
        let summaryDue = force || lastSummary.map {
            now.timeIntervalSince($0) >= SummaryClient.cacheInterval
        } ?? true
        guard !due.isEmpty || summaryDue else { return }

        Keychain.setInteraction(interactive)
        defer { Keychain.setInteraction(false) }

        let collector = config.collector
        async let fetched = Providers.fetchAll(due)
        async let summaryResult: Summary? = {
            guard summaryDue, let collector else { return nil }
            return await SummaryClient.fetch(config: collector)
        }()
        let fresh = await fetched
        let summary = await summaryResult

        var merged: [InstanceReading] = []
        for p in config.providers where p.enabled {
            if let reading = fresh.first(where: { $0.name == p.name }) {
                merged.append(reading)
                lastFetch[p.name] = Date()
            } else if let old = readings.first(where: { $0.name == p.name }) {
                merged.append(old)
            }
        }
        readings = merged

        if let summary {
            lastSummary = now
            latestSummary = summary
            history = Self.historyLines(SummaryClient.dailyByProvider(summary, days: 30))
        }
        readings = Providers.attachSpend(
            readings, enabled: config.providers.filter(\.enabled),
            today: latestSummary?.todayByProvider ?? [:])

        let names = Set(config.providers.map(\.name))
        lastFetch = lastFetch.filter { names.contains($0.key) }
        lastRefresh = Date()
        let snapshot = readings
        Task.detached { Self.persist(snapshot) }
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
