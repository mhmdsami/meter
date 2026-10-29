import Foundation

/// Push this machine's rows to the meter worker and read the other hosts back.
/// The menubar adds the remote total to its local day; `exclude_host` keeps the
/// rows this app just pushed from being counted twice.
enum Collector {
    private struct Row: Encodable {
        let day: String
        let provider: String
        let project: String
        let model: String
        let spent: Double
        let tokens: Int
        let source: String
    }

    private struct Payload: Encodable {
        let host: String
        let generated_at: String
        let rows: [Row]
    }

    private struct Summary: Decodable {
        let today_by_provider: [String: Double]?
    }

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

    private static var dayFormatter: DateFormatter {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }

    /// Rows are the type-keyed local scan; the worker replaces whole
    /// (host, day, provider) groups, so retries and corrections are safe.
    static func push(_ spend: [String: [CostScan.Spend]], config: CollectorConfig) async {
        guard config.enabled, !config.url.isEmpty, let base = URL(string: config.url), let token = token() else { return }
        let fmt = dayFormatter
        // Two days, not the whole 30-day scan: a push is one Worker invocation,
        // and per-group D1 batches hit the platform's subrequest budget fast.
        let cutoff = Calendar.current.date(byAdding: .day, value: -1, to: CostScan.startOfToday) ?? .distantPast
        var rows: [Row] = []
        for (type, list) in spend {
            for row in list where row.day >= cutoff && (row.spent > 0.004 || row.tokens > 0) {
                let source = row.estimated || !Store.reportedProviders.contains(type)
                    ? "estimated" : "reported"
                rows.append(Row(day: fmt.string(from: row.day),
                                provider: type,
                                project: row.project,
                                model: row.model,
                                spent: row.spent,
                                tokens: row.tokens,
                                source: source))
            }
        }
        guard !rows.isEmpty else { return }
        let body: Data
        do {
            body = try JSONEncoder().encode(
                Payload(host: hostName(config.host),
                        generated_at: ISO8601DateFormatter().string(from: Date()),
                        rows: rows))
        } catch { return }

        var request = URLRequest(url: base.appendingPathComponent("api/ingest"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        _ = try? await HTTP.session.data(for: request)
    }

    /// Today's per-provider spend from every host except this one.
    static func today(config: CollectorConfig) async -> [String: Double] {
        guard config.enabled, !config.url.isEmpty, let base = URL(string: config.url), let token = token() else { return [:] }
        var components = URLComponents(url: base.appendingPathComponent("api/summary"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "days", value: "1"),
            URLQueryItem(name: "today", value: dayFormatter.string(from: Date())),
            URLQueryItem(name: "exclude_host", value: hostName(config.host)),
        ]
        guard let url = components?.url else { return [:] }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await HTTP.session.data(for: request),
              let summary = try? JSONDecoder().decode(Summary.self, from: data) else { return [:] }
        return summary.today_by_provider ?? [:]
    }
}
