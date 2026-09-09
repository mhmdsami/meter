import Foundation

/// Device-wide spend scans, bucketed per local calendar day. Each log file is
/// parsed once per (mtime, size, price-table) stamp and yields every day's
/// total, so today's row and the 7/30-day history share one pass instead of
/// re-reading months of logs once per day-window.
enum CostScan {
    static var startOfToday: Date {
        Calendar.current.startOfDay(for: Date())
    }

    // MARK: - source URL discovery

    static func codexURLs(windowStart: Date) -> [URL] {
        let sessionsDir = NSString(string: "~/.codex/sessions").expandingTildeInPath
        let cal = Calendar.current
        var urls: [URL] = []
        // resumed threads keep appending to the rollout file of their start day,
        // so scan every UTC day dir back to the window; untouched files are
        // skipped by mtime and the cumulative-delta logic splits days correctly
        let utc = TimeZone(identifier: "UTC")!
        let back = (cal.dateComponents([.day], from: cal.dateComponents(in: utc, from: windowStart),
                                      to: cal.dateComponents(in: utc, from: Date())).day ?? 0) + 2
        for offset in 0..<max(2, back) {
            guard let d = cal.date(byAdding: .day, value: -offset, to: windowStart) else { continue }
            let comps = cal.dateComponents(in: utc, from: d)
            guard let y = comps.year, let m = comps.month, let day = comps.day else { continue }
            let dir = URL(fileURLWithPath: sessionsDir).appendingPathComponent(String(format: "%04d/%02d/%02d", y, m, day))
            if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                urls.append(contentsOf: files.filter { $0.pathExtension == "jsonl" })
            }
        }
        // archived rollouts live flat
        let archivedDir = URL(fileURLWithPath: NSString(string: "~/.codex/archived_sessions").expandingTildeInPath)
        if let files = try? FileManager.default.contentsOfDirectory(at: archivedDir, includingPropertiesForKeys: nil) {
            urls.append(contentsOf: files.filter { $0.pathExtension == "jsonl" })
        }
        return urls
    }

    static func claudeURLs() -> [URL] {
        let fm = FileManager.default
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots: [String] = []
        // CLAUDE_CONFIG_DIR selects exactly one literal root (commas are part of the path)
        if let cfgDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            roots.append(NSString(string: cfgDir).expandingTildeInPath)
        } else {
            roots.append(home.appendingPathComponent(".config/claude").path)
            roots.append(home.appendingPathComponent(".claude").path)
        }
        var urls: [URL] = []
        var seen = Set<String>()
        func collect(_ dir: URL) {
            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
            for case let url as URL in en where url.pathExtension == "jsonl" && seen.insert(url.path).inserted {
                urls.append(url)
            }
        }
        for root in roots {
            collect(URL(fileURLWithPath: root).appendingPathComponent("projects"))
        }
        // Claude Desktop embedded project stores: <store>/**/.claude/projects
        let appSup = home.appendingPathComponent("Library/Application Support/Claude")
        for store in ["local-agent-mode-sessions", "claude-code-sessions"] {
            guard let en = fm.enumerator(at: appSup.appendingPathComponent(store),
                                         includingPropertiesForKeys: nil) else { continue }
            for case let dir as URL in en where dir.lastPathComponent == "projects"
                && dir.deletingLastPathComponent().lastPathComponent == ".claude" {
                collect(dir)
            }
        }
        return urls
    }

    // MARK: - opencode db (costs are precomputed $)

    static func opencodeBuckets(windowStart: Date) -> [Date: Double] {
        let db = ReadOnlyDB(path: NSString(string: "~/.local/share/opencode/opencode.db").expandingTildeInPath)
        guard let db else { return [:] }
        let sinceMs = Int64(windowStart.timeIntervalSince1970 * 1000)
        let rows = db.rows("""
            SELECT time_created/3600000 AS hour, SUM(json_extract(data,'$.cost')) AS total
            FROM message
            WHERE json_extract(data,'$.role')='assistant'
              AND json_extract(data,'$.providerID')='opencode-go'
              AND time_created >= \(sinceMs)
            GROUP BY hour
            """)
        var out: [Date: Double] = [:]
        for row in rows {
            guard let hour = ReadOnlyDB.num(row["hour"]),
                  let total = ReadOnlyDB.num(row["total"]) else { continue }
            out[day(Date(timeIntervalSince1970: hour * 3600)), default: 0] += total
        }
        return out
    }

    // MARK: - shared JSONL bucketing

    enum LogFormat { case codex, claude, vercel }

    private struct Stamp: Equatable {
        let mtime: Date
        let size: Int
        let gen: Date

        // mtime can lose sub-microsecond precision across attribute writes
        static func == (a: Stamp, b: Stamp) -> Bool {
            a.size == b.size && a.gen == b.gen
                && abs(a.mtime.timeIntervalSince(b.mtime)) < 1.0
        }
    }

    private static var fileCache: [String: (Stamp, [Date: Double])] = [:]
    private static let cacheLock = NSLock()

    static func buckets(urls: [URL], format: LogFormat, windowStart: Date, pricing: Pricing) -> [Date: Double] {
        let fm = FileManager.default
        var out: [Date: Double] = [:]
        for url in urls {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date,
                  mtime >= windowStart else { continue }
            let stamp = Stamp(mtime: mtime, size: (attrs[.size] as? Int) ?? 0, gen: pricing.generation)
            cacheLock.lock()
            let hit = fileCache[url.path]
            cacheLock.unlock()
            let parsed: [Date: Double]
            if let hit, hit.0 == stamp {
                parsed = hit.1
            } else {
                guard let data = try? Data(contentsOf: url),
                      let text = String(data: data, encoding: .utf8) else { continue }
                parsed = fileBuckets(text: text, format: format, pricing: pricing)
                cacheLock.lock()
                fileCache[url.path] = (stamp, parsed)
                cacheLock.unlock()
            }
            for (dayStart, value) in parsed { out[dayStart, default: 0] += value }
        }
        return out
    }

    static func fileBuckets(text: String, format: LogFormat, pricing: Pricing) -> [Date: Double] {
        switch format {
        case .codex: return codexBuckets(text: text, pricing: pricing)
        case .claude: return claudeBuckets(text: text, pricing: pricing)
        case .vercel: return vercelBuckets(text: text, pricing: pricing)
        }
    }

    private static func day(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    // MARK: - multi-day history

    /// Per-type daily spend for the last `days` days (index 0 = today).
    static func dailyTotals(days: Int, types: Set<String>, pricing: Pricing) -> [String: [Double]] {
        let cal = Calendar.current
        let windowStart = cal.date(byAdding: .day, value: -(days - 1), to: startOfToday)!
        var out: [String: [Double]] = [:]
        for source in Providers.LocalCostSource.all where types.contains(source.type) {
            let buckets = source.buckets(pricing, windowStart)
            out[source.type] = (0..<days).map { offset in
                buckets[cal.date(byAdding: .day, value: -offset, to: startOfToday)!] ?? 0
            }
        }
        return out
    }

    // MARK: - Codex

    // Codex: token_count events carry session-CUMULATIVE totals; a day's spend is
    // its max total minus the max before that day started (counters are monotonic).
    static func codexBuckets(text: String, pricing: Pricing) -> [Date: Double] {
        struct Event { let ts: Date; var input: Double; var cached: Double; var output: Double }
        var events: [Event] = []
        var model: String?
        eachLine(text) { obj in
            switch obj["type"] as? String {
            case "turn_context":
                if let payload = obj["payload"] as? [String: Any], let m = payload["model"] as? String {
                    model = m
                }
            case "event_msg":
                guard let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let t = info["total_token_usage"] as? [String: Any],
                      let ts = (obj["timestamp"] as? String).flatMap(isoDate) else { return }
                events.append(Event(ts: ts,
                                    input: num(t["input_tokens"]),
                                    cached: num(t["cached_input_tokens"]),
                                    output: num(t["output_tokens"])))
            default: break
            }
        }
        guard !events.isEmpty, let model, let cost = pricing.cost(for: model) else { return [:] }
        events.sort { $0.ts < $1.ts }
        var out: [Date: Double] = [:]
        var before: (Double, Double, Double) = (-1, -1, -1)
        var i = 0
        while i < events.count {
            let dayStart = day(events[i].ts)
            var maxIn: (Double, Double, Double) = (-1, -1, -1)
            while i < events.count, day(events[i].ts) == dayStart {
                maxIn.0 = max(maxIn.0, events[i].input)
                maxIn.1 = max(maxIn.1, events[i].cached)
                maxIn.2 = max(maxIn.2, events[i].output)
                i += 1
            }
            func delta(_ value: Double, _ base: Double) -> Double {
                value < 0 ? 0 : max(0, value - max(base, 0))
            }
            out[dayStart, default: 0] += Pricing.dollars(
                cost,
                input: delta(maxIn.0, before.0),
                cachedInput: delta(maxIn.1, before.1),
                output: delta(maxIn.2, before.2))
            before.0 = max(before.0, maxIn.0)
            before.1 = max(before.1, maxIn.1)
            before.2 = max(before.2, maxIn.2)
        }
        return out
    }

    // MARK: - Claude

    // Claude: assistant lines carry per-message usage; dedupe streaming chunks
    // by (id, requestId), price each message, bucket by its timestamp.
    static func claudeBuckets(text: String, pricing: Pricing) -> [Date: Double] {
        struct Msg {
            var sum: Double
            var input: Double
            var read: Double
            var write: Double
            var output: Double
            var model: String
            var day: Date
        }
        var best: [String: Msg] = [:]
        eachLine(text) { obj in
            guard obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let ts = (obj["timestamp"] as? String).flatMap(isoDate) else { return }
            let id = (message["id"] as? String) ?? UUID().uuidString
            let key = id + "|" + ((obj["requestId"] as? String) ?? "")

            let input = num(usage["input_tokens"])
            let read = num(usage["cache_read_input_tokens"])
            let write: Double
            if let creation = usage["cache_creation"] as? [String: Any] {
                write = creation.values.compactMap(optNum).reduce(0, +)
            } else {
                write = num(usage["cache_creation_input_tokens"])
            }
            let output = num(usage["output_tokens"])
            let sum = input + output + read + write
            if sum > (best[key]?.sum ?? -1) {
                best[key] = Msg(sum: sum, input: input, read: read, write: write,
                                output: output, model: (message["model"] as? String) ?? "", day: day(ts))
            }
        }
        var out: [Date: Double] = [:]
        for msg in best.values {
            guard msg.sum > 0, let cost = pricing.cost(for: msg.model) else { continue }
            out[msg.day, default: 0] += Pricing.dollarsClaude(
                cost, input: msg.input, cacheRead: msg.read, cacheWrite: msg.write, output: msg.output)
        }
        return out
    }

    // MARK: - Vercel AI Gateway (fx CLI log)

    // ~/.fx/usage.jsonl logs every generation with a precomputed total_cost; "pending"
    // lines share ids with their final "generation" line, so dedupe by id. The gateway
    // reports $0 for subscription-billed codex/* models — estimate those at list price
    // from the logged tokens (cached reads are a subset of input, Codex-style).
    static func vercelBuckets(text: String, pricing: Pricing) -> [Date: Double] {
        struct Gen {
            var cost: Double
            var tokens: Double
            var input: Double
            var read: Double
            var output: Double
            var model: String
            var day: Date
        }
        var best: [String: Gen] = [:]
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["kind"] as? String == "generation",
                  let fact = obj["fact"] as? [String: Any],
                  let id = fact["id"] as? String,
                  let ms = optNum(fact["created_at_ms"]) else { continue }
            let created = Date(timeIntervalSince1970: ms / 1000)
            let input = optNum(fact["input_tokens"]) ?? 0
            let read = optNum(fact["cache_read_tokens"]) ?? 0
            let output = optNum(fact["output_tokens"]) ?? 0
            let gen = Gen(cost: optNum(fact["total_cost"]) ?? 0,
                          tokens: input + read + output,
                          input: input, read: read, output: output,
                          model: (fact["model"] as? String) ?? "",
                          day: day(created))
            if gen.cost > (best[id]?.cost ?? -1)
                || (gen.cost == best[id]?.cost && gen.tokens > (best[id]?.tokens ?? -1)) {
                best[id] = gen
            }
        }
        var out: [Date: Double] = [:]
        for gen in best.values {
            if gen.cost > 0 {
                out[gen.day, default: 0] += gen.cost
                continue
            }
            guard gen.model.hasPrefix("codex/"),
                  let cost = pricing.cost(for: String(gen.model.dropFirst("codex/".count))) else { continue }
            out[gen.day, default: 0] += Pricing.dollars(cost, input: gen.input, cachedInput: gen.read, output: gen.output)
        }
        return out
    }

    // MARK: - shared JSONL line iteration

    private static func eachLine(_ text: String, _ body: ([String: Any]) -> Void) {
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            body(obj)
        }
    }
}
