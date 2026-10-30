import Foundation

/// Cross-machine usage as the Worker reports it. The menubar no longer scans
/// logs; the collector owns collection and this is the only spend source.
struct SummaryRow: Codable {
    let day: String
    let host: String
    let provider: String
    let spent: Double
    let tokens: Int
}

struct Summary: Codable {
    let generatedAt: String
    let today: String
    let days: Int
    let rows: [SummaryRow]
    let todayByProvider: [String: Double]
    let todayByHost: [String: Double]
    let todayTotal: Double

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case today
        case days
        case rows
        case todayByProvider = "today_by_provider"
        case todayByHost = "today_by_host"
        case todayTotal = "today_total"
    }
}

enum SummaryClient {
    static let cacheInterval: TimeInterval = 5 * 60

    static func token() -> String? {
        if let value = ProcessInfo.processInfo.environment["METER_TOKEN"], !value.isEmpty {
            return value
        }
        return Keychain.generic(service: "meter/collector")
    }

    static func hostName(_ configured: String) -> String {
        if !configured.isEmpty { return configured }
        let raw = ProcessInfo.processInfo.hostName
        return raw.hasSuffix(".local") ? String(raw.dropLast(6)) : raw
    }

    nonisolated private static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/meter/summary.json")
    }

    /// Last successful response, so an offline launch still shows a total.
    static func cached() -> Summary? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(Summary.self, from: data)
    }

    static func persist(_ summary: Summary) {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(summary) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// Every host's usage, including this one: the collector pushes it, so the
    /// app never filters itself out.
    static func fetch(config: CollectorConfig) async -> Summary? {
        guard config.enabled, !config.url.isEmpty, let base = URL(string: config.url),
              let token = token() else { return nil }
        var components = URLComponents(url: base.appendingPathComponent("api/summary"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "days", value: "30"),
            URLQueryItem(name: "today", value: dayString(Date())),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await HTTP.session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let summary = try? JSONDecoder().decode(Summary.self, from: data) else { return nil }
        persist(summary)
        return summary
    }

    nonisolated static func dayString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    /// Daily totals, oldest first, keyed by provider type so the menu's rows and
    /// the bar title agree on ordering.
    static func dailyByProvider(_ summary: Summary, days: Int) -> [String: [Double]] {
        let today = Calendar.current.startOfDay(for: Date())
        let keys = (0..<days).reversed().map { offset -> String in
            dayString(Calendar.current.date(byAdding: .day, value: -offset, to: today) ?? today)
        }
        let index = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
        var out: [String: [Double]] = [:]
        for row in summary.rows {
            guard let position = index[row.day] else { continue }
            var values = out[row.provider] ?? Array(repeating: 0, count: days)
            values[position] += row.spent
            out[row.provider] = values
        }
        return out
    }

    static func dailyTotal(_ summary: Summary, days: Int) -> [Double] {
        let byProvider = dailyByProvider(summary, days: days)
        return (0..<days).map { index in
            byProvider.values.reduce(0) { $0 + ($1.count > index ? $1[index] : 0) }
        }
    }
}
