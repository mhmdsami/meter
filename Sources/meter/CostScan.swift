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
        /// billing provider id when the source records one (pi tags every message
        /// with the provider that served it); "" for sources that don't.
        var provider: String = ""
    }

    static var startOfToday: Date {
        Calendar.current.startOfDay(for: Date())
    }

    // MARK: - source URL discovery

    static func codexURLs(windowStart: Date) -> [URL] {
        let sessionsDir = NSString(string: "~/.codex/sessions").expandingTildeInPath
        let cal = Calendar.current
        let utc = TimeZone(identifier: "UTC")!
        var urls: [URL] = []
        // resumed threads keep appending to the rollout file of their start day,
        // so scan every UTC day dir back to the window; untouched files are
        // skipped by mtime and the cumulative-delta logic splits days correctly
        for d in codexDayDates(windowStart: windowStart) {
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

    /// UTC day dirs from today back to the window start (inclusive). Walking back
    /// from `windowStart` instead would only ever visit older days.
    static func codexDayDates(windowStart: Date, now: Date = Date()) -> [Date] {
        let cal = Calendar.current
        let utc = TimeZone(identifier: "UTC")!
        let days = (cal.dateComponents([.day], from: cal.dateComponents(in: utc, from: windowStart),
                                      to: cal.dateComponents(in: utc, from: now)).day ?? 0) + 2
        return (0..<max(2, days)).compactMap { offset in
            cal.date(byAdding: .day, value: -offset, to: now)
        }
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

    /// Directories the scans read. Only existing paths are watched; a root that
    /// appears later is still covered by the periodic full reconcile.
    static func watchRoots() -> [String] {
        var roots = [
            "~/.codex/sessions", "~/.codex/archived_sessions", "~/.fx",
            "~/.pi/agent/sessions", "~/.omp/agent/sessions",
            "~/.local/share/opencode", "~/.gemini/antigravity-cli",
            "~/Library/Application Support/Claude/local-agent-mode-sessions",
            "~/Library/Application Support/Claude/claude-code-sessions",
        ]
        let claude = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { [$0] } ?? ["~/.config/claude", "~/.claude"]
        roots.append(contentsOf: claude.map { $0 + "/projects" })
        return roots.map { NSString(string: $0).expandingTildeInPath }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - opencode db (v2; costs are precomputed $)

    /// opencode v2 keeps per-assistant-message cost/tokens in `session_message.data`
    /// and moved the project directory off the message onto `session_v2.directory`.
    /// The pre-v2 `message` table is gone, so only the v2 schema is read.
    static func opencodeSpend(windowStart: Date,
                              dbPath: String = NSString(string: "~/.local/share/opencode/opencode.db").expandingTildeInPath) -> [Spend] {
        let db = ReadOnlyDB(path: dbPath)
        guard let db else { return [] }
        let sinceMs = Int64(windowStart.timeIntervalSince1970 * 1000)
        // Group by the local date SQLite computes: bucketing on a truncated UTC hour
        // would pull early-morning usage (00:00–05:30 IST) onto the previous day.
        let rows = db.rows("""
            SELECT date(m.time_created/1000,'unixepoch','localtime') AS day,
                   s.directory AS cwd,
                   json_extract(m.data,'$.model.providerID') AS provider,
                   json_extract(m.data,'$.model.id') AS model,
                   SUM(json_extract(m.data,'$.cost')) AS total,
                   SUM(COALESCE(json_extract(m.data,'$.tokens.input'),0)
                     + COALESCE(json_extract(m.data,'$.tokens.output'),0)
                     + COALESCE(json_extract(m.data,'$.tokens.cache.read'),0)
                     + COALESCE(json_extract(m.data,'$.tokens.cache.write'),0)) AS tokens
            FROM session_message m
            JOIN session_v2 s ON s.id = m.session_id
            WHERE m.type='assistant'
              AND m.time_created >= \(sinceMs)
            GROUP BY day, cwd, provider, model
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
                         tokens: Int(ReadOnlyDB.num(row["tokens"]) ?? 0),
                         provider: ReadOnlyDB.text(row["provider"]) ?? "")
        }
    }

    /// opencode provider ids that belong to the OpenCode row; anything else
    /// (e.g. a vendor you are testing, like "inception") falls to the catch-all.
    static func opencodeProviderType(_ provider: String) -> String? {
        switch provider {
        case "opencode-go", "opencode": return "opencode"
        default: return nil
        }
    }

    // MARK: - shared JSONL scanning

    enum LogFormat { case codex, claude, vercel, pi }

    /// In-memory text (tests, small files) or a file streamed a line at a time so
    /// a 100 MB session log is never resident all at once.
    enum Lines {
        case text(String)
        case file(URL)
    }

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

    private struct CachedParse {
        var stamp: Stamp
        var rows: [Spend]
        var used: Date
    }

    private static var fileCache: [String: CachedParse] = [:]
    private static let cacheLock = NSLock()
    /// Bounds the cache when pruned sessions stop being visited.
    private static let cacheLimit = 4000

    static func spend(urls: [URL], format: LogFormat, windowStart: Date, pricing: Pricing) -> [Spend] {
        let fm = FileManager.default
        var out: [Spend] = []
        var seen: [String] = []
        for url in urls {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date,
                  mtime >= windowStart else { continue }
            let stamp = Stamp(mtime: mtime, size: (attrs[.size] as? Int) ?? 0, gen: pricing.generation)
            cacheLock.lock()
            let hit = fileCache[url.path]
            cacheLock.unlock()
            let parsed: [Spend]
            if let hit, hit.stamp == stamp {
                parsed = hit.rows
            } else {
                parsed = fileSpend(source: .file(url), format: format, pricing: pricing,
                                   fallbackProject: folderName(url))
                cacheLock.lock()
                fileCache[url.path] = CachedParse(stamp: stamp, rows: parsed, used: Date())
                cacheLock.unlock()
            }
            seen.append(url.path)
            out.append(contentsOf: parsed)
        }
        prune(seen: seen)
        return out
    }

    /// Old sessions fall out of the window and stop being visited; drop their
    /// rows rather than tracking every log file ever written.
    private static func prune(seen: [String]) {
        let now = Date()
        cacheLock.lock(); defer { cacheLock.unlock() }
        for path in seen { fileCache[path]?.used = now }
        guard fileCache.count > cacheLimit else { return }
        let keep = Set(seen)
        let excess = fileCache.count - cacheLimit
        let victims = fileCache
            .filter { !keep.contains($0.key) }
            .sorted { $0.value.used < $1.value.used }
            .prefix(excess)
            .map(\.key)
        for path in victims { fileCache.removeValue(forKey: path) }
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
        fileSpend(source: .text(text), format: format, pricing: pricing,
                  fallbackProject: fallbackProject)
    }

    static func fileSpend(source: Lines, format: LogFormat, pricing: Pricing,
                          fallbackProject: String = "") -> [Spend] {
        switch format {
        case .codex: return codexSpend(source, pricing: pricing)
        case .claude: return claudeSpend(source, pricing: pricing, fallbackProject: fallbackProject)
        case .vercel: return vercelSpend(source, pricing: pricing)
        case .pi: return piSpend(source, pricing: pricing)
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
            // parsers can surface older days from a resumed session file; the
            // window is what this pass is allowed to rewrite
            out[source.type] = source.spend(pricing, discoveryStart(for: source.type, windowStart: windowStart))
                .filter { $0.day >= windowStart }
        }
        return out
    }

    /// Codex keeps appending to the rollout file of the session's start day, so a
    /// resumed thread's *today* usage can sit in a month-old directory. Discovery
    /// always reaches back; only the returned rows are windowed.
    static func discoveryStart(for type: String, windowStart: Date) -> Date {
        guard type == "codex" else { return windowStart }
        let back = Calendar.current.date(byAdding: .day, value: -29, to: startOfToday)!
        return min(windowStart, back)
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
    static func codexSpend(_ source: Lines, pricing: Pricing) -> [Spend] {
        struct Event { let ts: Date; let input: Double; let cached: Double; let output: Double; let model: String }
        var events: [Event] = []
        var project = ""
        var currentModel = ""
        eachLine(source) { obj in
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
            var dayModels: [String] = []
            while i < events.count, day(events[i].ts) == dayStart {
                maxIn.0 = max(maxIn.0, events[i].input)
                maxIn.1 = max(maxIn.1, events[i].cached)
                maxIn.2 = max(maxIn.2, events[i].output)
                if !events[i].model.isEmpty, dayModels.last != events[i].model {
                    dayModels.append(events[i].model)
                }
                i += 1
            }
            defer {
                before.0 = max(before.0, maxIn.0)
                before.1 = max(before.1, maxIn.1)
                before.2 = max(before.2, maxIn.2)
            }
            // Subagent labels like "codex-auto-review" carry no price, and the
            // counters are session-wide, so bill the day to the last priced model.
            guard let dayModel = dayModels.reversed().first(where: { pricing.cost(for: $0) != nil }),
                  let cost = pricing.cost(for: dayModel) else { continue }
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
        out.append(contentsOf: fxCodexSpend(.file(fxURL()), pricing: pricing)
            .filter { $0.day >= windowStart })
        return out
    }

    // MARK: - Claude

    // Claude: assistant lines carry per-message usage and the session cwd; dedupe
    // streaming chunks by (id, requestId), price each message, bucket by timestamp.
    static func claudeSpend(_ source: Lines, pricing: Pricing, fallbackProject: String) -> [Spend] {
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
        eachLine(source) { obj in
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
    static func fxGenerations(_ source: Lines) -> [FxGeneration] {
        var best: [String: FxGeneration] = [:]
        eachLine(source) { obj in
            guard obj["kind"] as? String == "generation",
                  let fact = obj["fact"] as? [String: Any],
                  let id = fact["id"] as? String,
                  let ms = optNum(fact["created_at_ms"]) else { return }
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
    static func vercelSpend(_ source: Lines, pricing: Pricing) -> [Spend] {
        fxGenerations(source)
            .filter { $0.cost > 0 && $0.day > .distantPast }
            .map { Spend(day: $0.day, project: "", model: $0.model, spent: $0.cost,
                         tokens: Int($0.input + $0.read + $0.output)) }
    }

    /// Subscription-billed codex/* generations report $0; estimate them at list
    /// from the logged tokens (cached reads are a subset of input, Codex-style).
    static func fxCodexSpend(text: String, pricing: Pricing) -> [Spend] {
        fxCodexSpend(.text(text), pricing: pricing)
    }

    static func fxCodexSpend(_ source: Lines, pricing: Pricing) -> [Spend] {
        fxGenerations(source).compactMap { gen in
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
    static func piSpend(_ source: Lines, pricing: Pricing) -> [Spend] {
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
            var provider: String
        }
        var best: [String: Msg] = [:]
        var cwd = ""
        eachLine(source) { obj in
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
                               project: cwd, tokens: Int(input + read + write + output),
                               provider: (message["provider"] as? String) ?? "")
            }
        }
        return best.values.compactMap { msg in
            guard msg.sum > 0, let cost = piPricing(msg.model, pricing: pricing) else { return nil }
            let spent = Pricing.dollarsClaude(cost, input: msg.input, cacheRead: msg.read,
                                              cacheWrite: msg.write, output: msg.output)
            guard spent > 0 || msg.tokens > 0 else { return nil }
            return Spend(day: msg.day, project: msg.project, model: msg.model,
                         spent: spent, tokens: msg.tokens, provider: msg.provider)
        }
    }

    /// pi tags each message with the provider that served it ("straitly",
    /// "openai-codex", "opencode-go", "openrouter", …). Map that to the meter
    /// provider type that owns the row, so a session's spend lands where it was
    /// actually billed instead of all on one router.
    static func piProviderType(_ piProvider: String) -> String? {
        switch piProvider {
        case "straitly": return "straitly"
        case "openai-codex", "openai": return "codex"
        case "opencode-go", "opencode": return "opencode"
        case "openrouter": return "openrouter"
        case "anthropic": return "claude"
        case "google", "google-vertex", "gemini": return "antigravity"
        default: return nil
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

    // MARK: - antigravity CLI conversations

    /// The Antigravity CLI keeps one SQLite DB per conversation. Model and token
    /// counts are in `gen_metadata` protobuf blobs; timestamps are in the
    /// per-conversation transcript. The two lists line up one-to-one.
    static func antigravitySpend(windowStart: Date, pricing: Pricing) -> [Spend] {
        let root = NSString(string: "~/.gemini/antigravity-cli").expandingTildeInPath
        let projects = antigravityProjects(root: root)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: root + "/conversations") else {
            return []
        }
        var out: [Spend] = []
        for file in files where file.hasSuffix(".db") {
            let id = String(file.dropLast(3))
            let transcript = root + "/brain/\(id)/.system_generated/logs/transcript.jsonl"
            let turns = antigravityTurns(at: URL(fileURLWithPath: transcript))
            let metas = antigravityMeta(root: root, conversation: id)
            guard !turns.isEmpty, !metas.isEmpty else { continue }
            let project = projects[id] ?? ""
            for (meta, turn) in zip(metas, turns) where turn.at >= windowStart {
                guard let cost = pricing.cost(for: meta.model) else { continue }
                let spent = Pricing.dollarsClaude(cost, input: meta.input, cacheRead: meta.cache,
                                                  cacheWrite: 0, output: meta.output)
                let tokens = Int(meta.input + meta.cache + meta.output)
                guard spent > 0 || tokens > 0 else { continue }
                out.append(Spend(day: day(turn.at), project: project, model: meta.model,
                                 spent: spent, tokens: tokens, provider: "antigravity"))
            }
        }
        return out
    }

    struct AntigravityMeta {
        let model: String
        let input: Double
        let cache: Double
        let output: Double
    }

    struct AntigravityTurn {
        let at: Date
        let input: Double
        let cache: Double
        let output: Double
    }

    /// Model id is protobuf `1.19`; usage is `1.4.{2,3,5}` = input/output/cache.
    static func parseAntigravityMeta(_ data: Data) -> AntigravityMeta? {
        guard let inner = pbBytes(data, 1),
              let modelData = pbBytes(inner, 19),
              let model = String(data: modelData, encoding: .utf8),
              let usage = pbBytes(inner, 4) else { return nil }
        let input = Double(pbVarint(usage, 2) ?? 0)
        let output = Double(pbVarint(usage, 3) ?? 0)
        let cache = Double(pbVarint(usage, 5) ?? 0)
        guard input + output + cache > 0 else { return nil }
        return AntigravityMeta(model: model, input: input, cache: cache, output: output)
    }

    private static func antigravityMeta(root: String, conversation: String) -> [AntigravityMeta] {
        guard let db = ReadOnlyDB(path: root + "/conversations/\(conversation).db") else { return [] }
        return db.rows("SELECT data FROM gen_metadata ORDER BY idx").compactMap { row in
            guard let data = ReadOnlyDB.data(row["data"]) else { return nil }
            return parseAntigravityMeta(data)
        }
    }

    private static func antigravityTurns(at url: URL) -> [AntigravityTurn] {
        var out: [AntigravityTurn] = []
        eachLine(.file(url)) { obj in
            guard obj["type"] as? String == "PLANNER_RESPONSE",
                  let at = isoDate(obj["created_at"] as? String) else { return }
            out.append(AntigravityTurn(at: at,
                                       input: num(obj["input_tokens"]),
                                       cache: num(obj["cache_read_tokens"]),
                                       output: num(obj["output_tokens"])))
        }
        return out
    }

    private static func antigravityProjects(root: String) -> [String: String] {
        var out: [String: String] = [:]
        if let db = ReadOnlyDB(path: root + "/conversation_summaries.db") {
            for row in db.rows("SELECT conversation_id, workspace_uris FROM conversation_summaries") {
                guard let id = ReadOnlyDB.text(row["conversation_id"]),
                      let json = ReadOnlyDB.text(row["workspace_uris"]),
                      let data = json.data(using: .utf8),
                      let uris = try? JSONSerialization.jsonObject(with: data) as? [String],
                      let first = uris.first else { continue }
                out[id] = first.hasPrefix("file://") ? String(first.dropFirst(7)) : first
            }
        }
        // the CLI sometimes holds a write lock on the summaries DB; this cache
        // maps workspace -> conversation and covers that refresh
        let fallback = root + "/cache/last_conversations.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: fallback)),
           let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            for (workspace, id) in map where out[id] == nil { out[id] = workspace }
        }
        return out
    }

    // MARK: - protobuf wire format (minimal)

    private struct PBField {
        let number: Int
        let bytes: Data?
        let varint: UInt64?
    }

    private static func pbFields(_ data: Data) -> [PBField] {
        let b = [UInt8](data)
        var i = 0
        var out: [PBField] = []
        while i < b.count {
            var key: UInt64 = 0
            var shift: UInt64 = 0
            while i < b.count {
                let byte = b[i]; i += 1
                key |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
            }
            let number = Int(key >> 3)
            switch Int(key & 7) {
            case 0:
                var value: UInt64 = 0
                var s: UInt64 = 0
                while i < b.count {
                    let byte = b[i]; i += 1
                    value |= UInt64(byte & 0x7F) << s
                    if byte & 0x80 == 0 { break }
                    s += 7
                }
                out.append(PBField(number: number, bytes: nil, varint: value))
            case 2:
                var length: UInt64 = 0
                var s: UInt64 = 0
                while i < b.count {
                    let byte = b[i]; i += 1
                    length |= UInt64(byte & 0x7F) << s
                    if byte & 0x80 == 0 { break }
                    s += 7
                }
                let n = Int(length)
                guard i + n <= b.count else { return out }
                out.append(PBField(number: number, bytes: Data(b[i..<i + n]), varint: nil))
                i += n
            case 5: i += 4
            case 1: i += 8
            default: return out
            }
        }
        return out
    }

    private static func pbBytes(_ data: Data, _ number: Int) -> Data? {
        pbFields(data).first { $0.number == number }?.bytes
    }

    private static func pbVarint(_ data: Data, _ number: Int) -> UInt64? {
        pbFields(data).first { $0.number == number }?.varint
    }

    // MARK: - shared JSONL line iteration

    /// Feed JSON objects to `body` one line at a time. `.file` reads in fixed
    /// chunks and keeps only the unfinished tail, so a 100 MB rollout file never
    /// becomes a 200 MB Data + String pair; each line drains its autoreleased
    /// JSON objects before the next one is parsed.
    private static func eachLine(_ source: Lines, _ body: ([String: Any]) -> Void) {
        switch source {
        case .text(let text):
            for line in text.split(separator: "\n") {
                autoreleasepool {
                    parseLine(Data(line.utf8), body)
                }
            }
        case .file(let url):
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            var buffer = Data()
            while true {
                // read() hands back autoreleased NSData; on a detached cooperative
                // thread nothing drains it, so a 40 MB log would leak 40 MB per pass
                let chunk: Data? = autoreleasepool { try? handle.read(upToCount: 1 << 18) }
                guard let chunk, !chunk.isEmpty else { break }
                buffer.append(chunk)
                var start = buffer.startIndex
                while let newline = buffer[start...].firstIndex(of: 0x0A) {
                    autoreleasepool {
                        parseLine(Data(buffer[start..<newline]), body)
                    }
                    start = buffer.index(after: newline)
                }
                if start > buffer.startIndex { buffer = Data(buffer[start...]) }
            }
            if !buffer.isEmpty {
                autoreleasepool { parseLine(buffer, body) }
            }
        }
    }

    private static func parseLine(_ data: Data, _ body: ([String: Any]) -> Void) {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        body(obj)
    }
}
