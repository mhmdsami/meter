import Foundation

/// Device-wide "today" spend estimates. Each scan covers one source and is
/// attached to the first enabled instance of that provider type.
enum CostScan {
    static var startOfToday: Date {
        Calendar.current.startOfDay(for: Date())
    }

    static func opencodeToday(pricing: Pricing, since: Date) -> Double {
        let db = ReadOnlyDB(path: NSString(string: "~/.local/share/opencode/opencode.db").expandingTildeInPath)
        guard let db else { return 0 }
        let sinceMs = Int64(since.timeIntervalSince1970 * 1000)
        let rows = db.rows("""
            SELECT json_extract(data,'$.modelID') AS model,
                   SUM(json_extract(data,'$.cost')) AS total
            FROM message
            WHERE json_extract(data,'$.role')='assistant'
              AND json_extract(data,'$.providerID')='opencode-go'
              AND time_created >= \(sinceMs)
            GROUP BY json_extract(data,'$.modelID')
            """)
        // db costs are already $ (opencode-computed); no pricing lookup needed
        return rows.compactMap { ReadOnlyDB.num($0["total"]) ?? 0 }.reduce(0, +)
    }

    // MARK: - Codex session logs

    static func codexToday(pricing: Pricing, since: Date) -> Double {
        let sessionsDir = NSString(string: "~/.codex/sessions").expandingTildeInPath
        let cal = Calendar.current
        var urls: [URL] = []
        // resumed threads keep appending to the rollout file of their start day,
        // so scan every UTC day dir back to `since`; untouched files are skipped
        // by mtime and the cumulative-delta logic only bills tokens after `since`
        let utc = TimeZone(identifier: "UTC")!
        let back = (cal.dateComponents([.day], from: cal.dateComponents(in: utc, from: since),
                                      to: cal.dateComponents(in: utc, from: Date())).day ?? 0) + 2
        for offset in 0..<max(2, back) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: since) else { continue }
            let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: day)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { continue }
            let dir = URL(fileURLWithPath: sessionsDir).appendingPathComponent(String(format: "%04d/%02d/%02d", y, m, d))
            if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                urls.append(contentsOf: files.filter { $0.pathExtension == "jsonl" })
            }
        }
        // archived rollouts live flat; mtime gate + delta handle old dates
        let archivedDir = URL(fileURLWithPath: NSString(string: "~/.codex/archived_sessions").expandingTildeInPath)
        if let files = try? FileManager.default.contentsOfDirectory(at: archivedDir, includingPropertiesForKeys: nil) {
            urls.append(contentsOf: files.filter { $0.pathExtension == "jsonl" })
        }
        return scan(urls: urls, since: since, pricing: pricing, format: .codex)
    }

    // MARK: - Claude project logs

    static func claudeToday(pricing: Pricing, since: Date) -> Double {
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
        return scan(urls: urls, since: since, pricing: pricing, format: .claude)
    }

    // MARK: - Vercel AI Gateway (fx CLI log)

    // ~/.fx/usage.jsonl logs every generation with a precomputed total_cost; "pending"
    // lines share ids with their final "generation" line, so dedupe by id. The gateway
    // reports $0 for subscription-billed codex/* models — estimate those at list price
    // from the logged tokens (cached reads are a subset of input, Codex-style).
    static func vercelToday(pricing: Pricing, since: Date) -> Double {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fx/usage.jsonl")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return 0 }
        let sinceMs = Int64(startOfToday.timeIntervalSince1970 * 1000)
        struct Gen { var cost: Double; var tokens: Double; var input: Double; var read: Double; var output: Double; var model: String }
        var best: [String: Gen] = [:]
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["kind"] as? String == "generation",
                  let fact = obj["fact"] as? [String: Any],
                  let id = fact["id"] as? String,
                  (optNum(fact["created_at_ms"]) ?? 0) >= Double(sinceMs) else { continue }
            let input = optNum(fact["input_tokens"]) ?? 0
            let read = optNum(fact["cache_read_tokens"]) ?? 0
            let output = optNum(fact["output_tokens"]) ?? 0
            let gen = Gen(cost: optNum(fact["total_cost"]) ?? 0,
                          tokens: input + read + output,
                          input: input, read: read, output: output,
                          model: (fact["model"] as? String) ?? "")
            if gen.cost > (best[id]?.cost ?? -1)
                || (gen.cost == best[id]?.cost && gen.tokens > (best[id]?.tokens ?? -1)) {
                best[id] = gen
            }
        }
        var total = 0.0
        for g in best.values {
            if g.cost > 0 { total += g.cost; continue }
            guard g.model.hasPrefix("codex/"),
                  let cost = pricing.cost(for: String(g.model.dropFirst("codex/".count))) else { continue }
            total += Pricing.dollars(cost, input: g.input, cachedInput: g.read, output: g.output)
        }
        return total
    }

    // MARK: - multi-day history

    /// Per-type daily spend for the last `days` days (index 0 = today). Completed
    /// days are cached until the price table changes; today recomputes each call.
    static func dailyTotals(days: Int, types: Set<String>, pricing: Pricing) -> [String: [Double]] {
        let cal = Calendar.current
        func dayKey(_ day: Date) -> String {
            let c = cal.dateComponents([.year, .month, .day], from: day)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }

        dayCacheLock.lock()
        if dayCacheGeneration != pricing.generation {
            dayCache = [:]
            dayCacheGeneration = pricing.generation
        }
        dayCacheLock.unlock()

        var out: [String: [Double]] = [:]
        for source in Providers.LocalCostSource.all where types.contains(source.type) {
            var daily: [Double] = []
            for offset in 0..<days {
                let day = cal.date(byAdding: .day, value: -offset, to: startOfToday)!
                let cacheKey = source.type + "|" + dayKey(day)
                dayCacheLock.lock()
                let hit = (offset > 0) ? dayCache[cacheKey] : nil
                dayCacheLock.unlock()
                if let hit {
                    daily.append(hit)
                    continue
                }
                let value = source.scan(pricing, day)
                daily.append(value)
                if offset > 0 {
                    dayCacheLock.lock()
                    dayCache[cacheKey] = value
                    dayCacheLock.unlock()
                }
            }
            out[source.type] = daily
        }
        return out
    }

    private static var dayCache: [String: Double] = [:]
    private static var dayCacheGeneration: Date?
    private static let dayCacheLock = NSLock()

    // MARK: - shared JSONL scanning

    enum LogFormat { case codex, claude }

    private struct FileStamp: Equatable {
        let mtime: Date
        let size: Int
        let since: Date
        let pricingGeneration: Date
    }

    private static var fileCache: [String: (stamp: FileStamp, value: Double)] = [:]
    private static let cacheLock = NSLock()

    static func scan(urls: [URL], since: Date, pricing: Pricing, format: LogFormat) -> Double {
        let fm = FileManager.default
        var total = 0.0
        for url in urls {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            // untouched since the window started → nothing billable today
            guard mtime >= since else { continue }
            let size = (attrs[.size] as? Int) ?? 0
            let stamp = FileStamp(mtime: mtime, size: size, since: since, pricingGeneration: pricing.generation)
            cacheLock.lock()
            let hit = fileCache[url.path]
            cacheLock.unlock()
            if let hit, hit.stamp == stamp {
                total += hit.value
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let value = scan(text: text, since: since, pricing: pricing, format: format)
            cacheLock.lock()
            fileCache[url.path] = (stamp, value)
            cacheLock.unlock()
            total += value
        }
        return total
    }

    static func scan(text: String, since: Date, pricing: Pricing, format: LogFormat) -> Double {
        switch format {
        case .codex: return scanCodex(text: text, since: since, pricing: pricing)
        case .claude: return scanClaude(text: text, since: since, pricing: pricing)
        }
    }

    private static func eachLine(_ text: String, _ body: ([String: Any]) -> Void) {
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            body(obj)
        }
    }

    // Codex: token_count events carry session-CUMULATIVE totals and their own timestamps.
    // Today's spend = (max total during today) − (last total before today), so a session
    // that started yesterday only bills today's tokens.
    private static func scanCodex(text: String, since: Date, pricing: Pricing) -> Double {
        struct Totals { var input: Double; var cached: Double; var output: Double }
        var maxToday: Totals?
        var lastBefore: Totals?
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
                      let t = info["total_token_usage"] as? [String: Any] else { return }
                let totals = Totals(input: num(t["input_tokens"]), cached: num(t["cached_input_tokens"]), output: num(t["output_tokens"]))
                let ts = (obj["timestamp"] as? String).flatMap(isoDate)
                let isToday = ts.map { $0 >= since } ?? true
                if isToday {
                    if totals.input + totals.output > (maxToday.map { $0.input + $0.output } ?? -1) {
                        maxToday = totals
                    }
                } else {
                    if totals.input + totals.output > (lastBefore.map { $0.input + $0.output } ?? -1) {
                        lastBefore = totals
                    }
                }
            default: break
            }
        }
        guard var today = maxToday else { return 0 }
        if let before = lastBefore {
            today.input = max(0, today.input - before.input)
            today.cached = max(0, today.cached - before.cached)
            today.output = max(0, today.output - before.output)
        }
        guard let model, let cost = pricing.cost(for: model) else { return 0 }
        return Pricing.dollars(cost, input: today.input, cachedInput: today.cached, output: today.output)
    }

    // Claude: assistant lines carry per-message usage; dedupe streaming chunks by (id, requestId).
    private static func scanClaude(text: String, since: Date, pricing: Pricing) -> Double {
        var best: [String: (input: Double, read: Double, write: Double, output: Double, model: String)] = [:]
        eachLine(text) { obj in
            guard obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }
            let ts = (obj["timestamp"] as? String).flatMap(isoDate)
            guard let ts, ts >= since else { return }
            let id = (message["id"] as? String) ?? UUID().uuidString
            let reqId = (obj["requestId"] as? String) ?? ""
            let key = id + "|" + reqId

            let input = num(usage["input_tokens"])
            let read = num(usage["cache_read_input_tokens"])
            let write: Double
            if let creation = usage["cache_creation"] as? [String: Any] {
                write = creation.values.compactMap(optNum).reduce(0, +)
            } else {
                write = num(usage["cache_creation_input_tokens"])
            }
            let output = num(usage["output_tokens"])
            let model = (message["model"] as? String) ?? ""

            let sum = input + output + read + write
            if sum > (best[key].map { $0.input + $0.output + $0.read + $0.write } ?? -1) {
                best[key] = (input, read, write, output, model)
            }
        }
        var total = 0.0
        for entry in best.values {
            guard entry.input + entry.output + entry.read + entry.write > 0,
                  let cost = pricing.cost(for: entry.model) else { continue }
            total += Pricing.dollarsClaude(cost, input: entry.input, cacheRead: entry.read,
                                           cacheWrite: entry.write, output: entry.output)
        }
        return total
    }
}
