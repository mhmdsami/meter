import Foundation

/// Device-wide spend scans. Each log file is parsed once per (mtime, size,
/// price-table) stamp into per-day rows tagged with the project (cwd) and model
/// the usage belonged to; day buckets, today's totals, the 7/30-day history and
/// the ledger's breakdown all derive from that single pass.
enum CostScan {
    /// One attributed chunk of spend. `project` is a working directory ("" when
    /// the source has none, e.g. the AI Gateway), `model` the pricing key.
    struct Spend {
        let day: Date
        let project: String
        let model: String
        let spent: Double
        /// total tokens (input + output + cache), so free-tier usage is still visible
        var tokens: Int = 0
    }

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

    static func piURLs() -> [URL] {
        var urls: [URL] = []
        for root in ["~/.pi/agent/sessions", "~/.omp/agent/sessions"] {
            let dir = URL(fileURLWithPath: NSString(string: root).expandingTildeInPath)
            guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                urls.append(url)
            }
        }
        return urls
    }

    static func fxURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fx/usage.jsonl")
    }

    // MARK: - opencode db (costs are precomputed $)

    static func opencodeSpend(windowStart: Date) -> [Spend] {
        let db = ReadOnlyDB(path: NSString(string: "~/.local/share/opencode/opencode.db").expandingTildeInPath)
        guard let db else { return [] }
        let sinceMs = Int64(windowStart.timeIntervalSince1970 * 1000)
        // Group by the local date SQLite computes: bucketing on a truncated UTC hour
        // would pull early-morning usage (00:00–05:30 IST) onto the previous day.
        let rows = db.rows("""
            SELECT date(time_created/1000,'unixepoch','localtime') AS day,
                   json_extract(data,'$.path.cwd') AS cwd,
                   json_extract(data,'$.modelID') AS model,
                   SUM(json_extract(data,'$.cost')) AS total,
                   SUM(COALESCE(json_extract(data,'$.tokens.input'),0)
                     + COALESCE(json_extract(data,'$.tokens.output'),0)
                     + COALESCE(json_extract(data,'$.tokens.cache.read'),0)
                     + COALESCE(json_extract(data,'$.tokens.cache.write'),0)) AS tokens
            FROM message
            WHERE json_extract(data,'$.role')='assistant'
              AND json_extract(data,'$.providerID')='opencode-go'
              AND time_created >= \(sinceMs)
            GROUP BY day, cwd, model
            """)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return rows.compactMap { row in
            guard let dayText = ReadOnlyDB.text(row["day"]),
                  let parsed = fmt.date(from: dayText) else { return nil }
            return Spend(day: parsed,
                         project: ReadOnlyDB.text(row["cwd"]) ?? "",
                         model: ReadOnlyDB.text(row["model"])?.split(separator: "/").last.map(String.init) ?? "",
                         spent: ReadOnlyDB.num(row["total"]) ?? 0,
                         tokens: Int(ReadOnlyDB.num(row["tokens"]) ?? 0))
        }
    }

    // MARK: - shared JSONL scanning

    enum LogFormat { case codex, claude, vercel, pi }

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

    private static var fileCache: [String: (Stamp, [Spend])] = [:]
    private static let cacheLock = NSLock()

    static func spend(urls: [URL], format: LogFormat, windowStart: Date, pricing: Pricing) -> [Spend] {
        let fm = FileManager.default
        var out: [Spend] = []
        for url in urls {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date,
                  mtime >= windowStart else { continue }
            let stamp = Stamp(mtime: mtime, size: (attrs[.size] as? Int) ?? 0, gen: pricing.generation)
            cacheLock.lock()
            let hit = fileCache[url.path]
            cacheLock.unlock()
            let parsed: [Spend]
            if let hit, hit.0 == stamp {
                parsed = hit.1
            } else {
                guard let data = try? Data(contentsOf: url),
                      let text = String(data: data, encoding: .utf8) else { continue }
                parsed = fileSpend(text: text, format: format, pricing: pricing,
                                   fallbackProject: folderName(url))
                cacheLock.lock()
                fileCache[url.path] = (stamp, parsed)
                cacheLock.unlock()
            }
            out.append(contentsOf: parsed)
        }
        return out
    }

    /// Day totals, used by the menu's today row and history bars.
    static func buckets(urls: [URL], format: LogFormat, windowStart: Date, pricing: Pricing) -> [Date: Double] {
        var out: [Date: Double] = [:]
        for row in spend(urls: urls, format: format, windowStart: windowStart, pricing: pricing) {
            out[row.day, default: 0] += row.spent
        }
        return out
    }

    static func fileSpend(text: String, format: LogFormat, pricing: Pricing,
                          fallbackProject: String = "") -> [Spend] {
        switch format {
        case .codex: return codexSpend(text: text, pricing: pricing)
        case .claude: return claudeSpend(text: text, pricing: pricing, fallbackProject: fallbackProject)
        case .vercel: return vercelSpend(text: text, pricing: pricing)
        case .pi: return piSpend(text: text, pricing: pricing)
        }
    }

    static func fileBuckets(text: String, format: LogFormat, pricing: Pricing) -> [Date: Double] {
        var out: [Date: Double] = [:]
        for row in fileSpend(text: text, format: format, pricing: pricing) {
            out[row.day, default: 0] += row.spent
        }
        return out
    }

    private static func folderName(_ url: URL) -> String {
        url.deletingLastPathComponent().lastPathComponent
    }

    private static func day(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    // MARK: - multi-day totals

    /// Per-type attributed rows for the last `days` days (index 0 = today).
    static func spendTotals(days: Int, types: Set<String>, pricing: Pricing) -> [String: [Spend]] {
        let cal = Calendar.current
        let windowStart = cal.date(byAdding: .day, value: -(days - 1), to: startOfToday)!
        var out: [String: [Spend]] = [:]
        for source in Providers.LocalCostSource.all where types.contains(source.type) {
            out[source.type] = source.spend(pricing, windowStart)
        }
        return out
    }

    /// Collapse attributed rows into the per-type daily arrays the menu uses.
    static func dailyTotals(_ spend: [String: [Spend]], days: Int) -> [String: [Double]] {
        let cal = Calendar.current
        let today = startOfToday
        var out: [String: [Double]] = [:]
        for (type, rows) in spend {
            var byDay: [Date: Double] = [:]
            for row in rows { byDay[row.day, default: 0] += row.spent }
            out[type] = (0..<days).map { offset in
                byDay[cal.date(byAdding: .day, value: -offset, to: today)!] ?? 0
            }
        }
        return out
    }

    // MARK: - Codex

    // Codex: token_count events carry session-CUMULATIVE totals; a day's spend is
    // its max total minus the max before that day started (counters are monotonic).
    // Attribution is per file: the session's cwd for the project and the model of
    // the day's last turn (a session that switches models bills the day to the last).
    static func codexSpend(text: String, pricing: Pricing) -> [Spend] {
        struct Event { let ts: Date; let input: Double; let cached: Double; let output: Double; let model: String }
        var events: [Event] = []
        var project = ""
        var currentModel = ""
        eachLine(text) { obj in
            switch obj["type"] as? String {
            case "session_meta":
                if let payload = obj["payload"] as? [String: Any], let cwd = payload["cwd"] as? String {
                    project = cwd
                }
            case "turn_context":
                if let payload = obj["payload"] as? [String: Any] {
                    if let m = payload["model"] as? String { currentModel = m }
                    if project.isEmpty, let cwd = payload["cwd"] as? String { project = cwd }
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
                                    output: num(t["output_tokens"]),
                                    model: currentModel))
            default: break
            }
        }
        guard !events.isEmpty else { return [] }
        events.sort { $0.ts < $1.ts }
        var out: [Spend] = []
        var before: (Double, Double, Double) = (-1, -1, -1)
        var i = 0
        while i < events.count {
            let dayStart = day(events[i].ts)
            var maxIn: (Double, Double, Double) = (-1, -1, -1)
            var dayModel = events[i].model
            while i < events.count, day(events[i].ts) == dayStart {
                maxIn.0 = max(maxIn.0, events[i].input)
                maxIn.1 = max(maxIn.1, events[i].cached)
                maxIn.2 = max(maxIn.2, events[i].output)
                if !events[i].model.isEmpty { dayModel = events[i].model }
                i += 1
            }
            defer {
                before.0 = max(before.0, maxIn.0)
                before.1 = max(before.1, maxIn.1)
                before.2 = max(before.2, maxIn.2)
            }
            guard let cost = pricing.cost(for: dayModel) else { continue }
            func delta(_ value: Double, _ base: Double) -> Double {
                value < 0 ? 0 : max(0, value - max(base, 0))
            }
            let input = delta(maxIn.0, before.0)
            let cached = delta(maxIn.1, before.1)
            let output = delta(maxIn.2, before.2)
            let spent = Pricing.dollars(cost, input: input, cachedInput: cached, output: output)
            let tokens = Int(input + output)
            if spent > 0 || tokens > 0 {
                out.append(Spend(day: dayStart, project: project, model: dayModel,
                                 spent: spent, tokens: tokens))
            }
        }
        return out
    }

    /// Codex spend: local rollout files plus subscription-billed usage routed
    /// through the AI Gateway, which reports $0 for those models.
    static func codexSourceSpend(windowStart: Date, pricing: Pricing) -> [Spend] {
        var out = spend(urls: codexURLs(windowStart: windowStart), format: .codex,
                        windowStart: windowStart, pricing: pricing)
        if let data = try? Data(contentsOf: fxURL()), let text = String(data: data, encoding: .utf8) {
            out.append(contentsOf: fxCodexSpend(text: text, pricing: pricing).filter { $0.day >= windowStart })
        }
        return out
    }

    // MARK: - Claude

    // Claude: assistant lines carry per-message usage and the session cwd; dedupe
    // streaming chunks by (id, requestId), price each message, bucket by timestamp.
    static func claudeSpend(text: String, pricing: Pricing, fallbackProject: String) -> [Spend] {
        struct Msg {
            var sum: Double
            var input: Double
            var read: Double
            var write: Double
            var output: Double
            var model: String
            var day: Date
            var project: String
            var tokens: Int
        }
        var best: [String: Msg] = [:]
        var cwd = ""
        eachLine(text) { obj in
            if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
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
                best[key] = Msg(sum: sum, input: input, read: read, write: write, output: output,
                                model: (message["model"] as? String) ?? "", day: day(ts),
                                project: cwd.isEmpty ? fallbackProject : cwd,
                                tokens: Int(input + read + write + output))
            }
        }
        return best.values.compactMap { msg in
            guard msg.sum > 0, let cost = pricing.cost(for: msg.model) else { return nil }
            let spent = Pricing.dollarsClaude(cost, input: msg.input, cacheRead: msg.read,
                                              cacheWrite: msg.write, output: msg.output)
            guard spent > 0 || msg.tokens > 0 else { return nil }
            return Spend(day: msg.day, project: msg.project, model: msg.model,
                         spent: spent, tokens: msg.tokens)
        }
    }

    // MARK: - Vercel AI Gateway (fx CLI log)

    struct FxGeneration {
        let cost: Double
        let tokens: Double
        let input: Double
        let read: Double
        let output: Double
        let model: String
        let day: Date
    }

    /// ~/.fx/usage.jsonl logs every generation with a precomputed total_cost; "pending"
    /// lines share ids with their final "generation" line, so dedupe by id.
    static func fxGenerations(text: String) -> [FxGeneration] {
        var best: [String: FxGeneration] = [:]
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["kind"] as? String == "generation",
                  let fact = obj["fact"] as? [String: Any],
                  let id = fact["id"] as? String,
                  let ms = optNum(fact["created_at_ms"]) else { continue }
            let input = optNum(fact["input_tokens"]) ?? 0
            let read = optNum(fact["cache_read_tokens"]) ?? 0
            let output = optNum(fact["output_tokens"]) ?? 0
            let gen = FxGeneration(cost: optNum(fact["total_cost"]) ?? 0,
                                   tokens: input + read + output,
                                   input: input, read: read, output: output,
                                   model: (fact["model"] as? String) ?? "",
                                   day: day(Date(timeIntervalSince1970: ms / 1000)))
            if gen.cost > (best[id]?.cost ?? -1)
                || (gen.cost == best[id]?.cost && gen.tokens > (best[id]?.tokens ?? -1)) {
                best[id] = gen
            }
        }
        return Array(best.values)
    }

    /// What the gateway actually charged: paid generations only.
    static func vercelSpend(text: String, pricing: Pricing) -> [Spend] {
        fxGenerations(text: text)
            .filter { $0.cost > 0 && $0.day > .distantPast }
            .map { Spend(day: $0.day, project: "", model: $0.model, spent: $0.cost,
                         tokens: Int($0.input + $0.read + $0.output)) }
    }

    /// Subscription-billed codex/* generations report $0; estimate them at list
    /// from the logged tokens (cached reads are a subset of input, Codex-style).
    static func fxCodexSpend(text: String, pricing: Pricing) -> [Spend] {
        fxGenerations(text: text).compactMap { gen in
            let bare = String(gen.model.dropFirst("codex/".count))
            guard gen.cost == 0, gen.model.hasPrefix("codex/"),
                  let cost = pricing.cost(for: bare) else { return nil }
            let spent = Pricing.dollars(cost, input: gen.input, cachedInput: gen.read, output: gen.output)
            let tokens = Int(gen.input + gen.output)
            guard spent > 0 || tokens > 0 else { return nil }
            return Spend(day: gen.day, project: "", model: bare, spent: spent, tokens: tokens)
        }
    }

    // MARK: - pi / OMP agent sessions

    /// pi: one assistant "message" row per turn with Claude-style usage; dedupe by
    /// message id and price at list (pi's own cost field is unreliable).
    static func piSpend(text: String, pricing: Pricing) -> [Spend] {
        struct Msg {
            var sum: Double
            var input: Double
            var read: Double
            var write: Double
            var output: Double
            var model: String
            var day: Date
            var project: String
            var tokens: Int
        }
        var best: [String: Msg] = [:]
        var cwd = ""
        eachLine(text) { obj in
            if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            guard obj["type"] as? String == "message",
                  let message = obj["message"] as? [String: Any],
                  message["role"] as? String == "assistant",
                  let usage = message["usage"] as? [String: Any],
                  let ts = (obj["timestamp"] as? String).flatMap(isoDate) else { return }
            let id = (obj["id"] as? String) ?? UUID().uuidString
            let input = num(usage["input"])
            let read = num(usage["cacheRead"])
            let write = num(usage["cacheWrite"])
            let output = num(usage["output"])
            let sum = input + output + read + write
            if sum > (best[id]?.sum ?? -1) {
                best[id] = Msg(sum: sum, input: input, read: read, write: write, output: output,
                               model: bareModel((message["model"] as? String) ?? ""), day: day(ts),
                               project: cwd, tokens: Int(input + read + write + output))
            }
        }
        return best.values.compactMap { msg in
            guard msg.sum > 0, let cost = piPricing(msg.model, pricing: pricing) else { return nil }
            let spent = Pricing.dollarsClaude(cost, input: msg.input, cacheRead: msg.read,
                                              cacheWrite: msg.write, output: msg.output)
            guard spent > 0 || msg.tokens > 0 else { return nil }
            return Spend(day: msg.day, project: msg.project, model: msg.model,
                         spent: spent, tokens: msg.tokens)
        }
    }

    /// "anthropic/claude-sonnet-5-thinking-medium" → "claude-sonnet-5" (the
    /// pricing key, which is also what the leaderboard groups by).
    static func bareModel(_ routedModel: String) -> String {
        let bare = routedModel.split(separator: "/").last.map(String.init) ?? routedModel
        return bare.range(of: #"-thinking-(?:off|minimal|low|medium|high|xhigh|max)$"#, options: .regularExpression)
            .map { String(bare[..<$0.lowerBound]) } ?? bare
    }

    private static func piPricing(_ model: String, pricing: Pricing) -> Pricing.ModelCost? {
        pricing.cost(for: model)
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
