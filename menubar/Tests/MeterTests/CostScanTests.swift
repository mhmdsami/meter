import XCTest
import SQLite3
@testable import meter

final class CostScanTests: XCTestCase {
    private func day(_ ts: String) -> Date {
        Calendar.current.startOfDay(for: isoDate(ts)!)
    }

    private var pricing: Pricing {
        let p = Pricing()
        p.parse([
            "openai": ["models": ["gpt-5.2": ["cost": ["input": 1.0, "output": 2.0, "cache_read": 0.5]]]],
            "anthropic": ["models": ["claude-sonnet-4-5": ["cost": ["input": 3.0, "output": 15.0, "cache_read": 0.3, "cache_write": 3.75]]]],
        ])
        return p
    }

    // MARK: - Codex cumulative deltas

    private func codexLine(_ ts: String, input: Int, cached: Int, output: Int) -> String {
        """
        {"type":"event_msg","timestamp":"\(ts)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output)}}}}
        """
    }

    func testCodexSessionStartedToday() {
        let text = """
        {"type":"turn_context","payload":{"model":"gpt-5.2"}}
        \(codexLine("2026-01-02T09:00:00Z", input: 1_000_000, cached: 0, output: 500_000))
        \(codexLine("2026-01-02T10:00:00Z", input: 2_000_000, cached: 0, output: 1_000_000))
        """
        let b = CostScan.fileBuckets(text: text, format: .codex, pricing: pricing)
        // max today: 2M in @ $1 + 1M out @ $2
        XCTAssertEqual(b[day("2026-01-02T10:00:00Z")] ?? -1, 4.0, accuracy: 0.0001)
    }

    func testCodexSessionStraddlingMidnightBillsEachDay() {
        let text = """
        {"type":"turn_context","payload":{"model":"gpt-5.2"}}
        \(codexLine("2026-01-01T12:00:00Z", input: 1_000_000, cached: 500_000, output: 500_000))
        \(codexLine("2026-01-02T12:00:00Z", input: 3_000_000, cached: 1_500_000, output: 1_500_000))
        """
        let b = CostScan.fileBuckets(text: text, format: .codex, pricing: pricing)
        // day 1: full totals (1M in @ $1 + 0.5M cached @ $0.5 + 0.5M out @ $2)
        XCTAssertEqual(b[day("2026-01-01T12:00:00Z")] ?? -1, 1.75, accuracy: 0.0001)
        // day 2: deltas (2M fresh in @ $1 + 1M cached @ $0.5 + 1M out @ $2)
        XCTAssertEqual(b[day("2026-01-02T12:00:00Z")] ?? -1, 3.5, accuracy: 0.0001)
    }

    func testCodexDayDatesCoverTodayAndWindow() {
        let now = isoDate("2026-10-08T15:00:00Z")!
        let windowStart = isoDate("2026-09-09T00:00:00Z")!
        let dates = CostScan.codexDayDates(windowStart: windowStart, now: now)
        // newest first, today included, and never older than the window start
        XCTAssertEqual(dates.first.map { Calendar.current.startOfDay(for: $0) },
                       Calendar.current.startOfDay(for: now))
        XCTAssertGreaterThanOrEqual(dates.count, 31)
        XCTAssertTrue(dates.allSatisfy { $0 <= now })
        XCTAssertTrue(dates.allSatisfy { $0 >= windowStart.addingTimeInterval(-3 * 86_400) })
    }

    func testCodexBillsToLastPricedModelWhenLabelIsUnpriced() {
        // a subagent label with no price must not zero the day
        let text = """
        {"type":"session_meta","payload":{"cwd":"/Users/me/dev/x"}}
        {"type":"turn_context","payload":{"model":"gpt-5.2"}}
        \(codexLine("2026-01-02T10:00:00Z", input: 1_000_000, cached: 0, output: 0))
        {"type":"turn_context","payload":{"model":"codex-auto-review"}}
        \(codexLine("2026-01-02T11:00:00Z", input: 2_000_000, cached: 0, output: 0))
        """
        let rows = CostScan.fileSpend(text: text, format: .codex, pricing: pricing)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].model, "gpt-5.2")
        XCTAssertEqual(rows[0].spent, 2.0, accuracy: 0.0001)
    }

    func testCodexUnknownModelCostsNothing() {
        let text = """
        {"type":"turn_context","payload":{"model":"mystery-model"}}
        \(codexLine("2026-01-02T10:00:00Z", input: 1_000_000, cached: 0, output: 1_000_000))
        """
        XCTAssertEqual(CostScan.fileBuckets(text: text, format: .codex, pricing: pricing), [:])
    }

    // MARK: - Claude per-message usage

    private func claudeLine(_ ts: String, id: String, reqId: String, input: Int, output: Int,
                            cacheRead: Int = 0, cacheWrite: Int = 0) -> String {
        """
        {"type":"assistant","timestamp":"\(ts)","requestId":"\(reqId)","message":{"id":"\(id)","model":"claude-sonnet-4-5","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheWrite)}}}
        """
    }

    func testClaudeDedupesStreamingChunks() {
        // same (id, requestId) streamed twice with growing output — only the max counts
        let text = """
        \(claudeLine("2026-01-02T09:00:00Z", id: "m1", reqId: "r1", input: 1_000_000, output: 100_000))
        \(claudeLine("2026-01-02T09:00:01Z", id: "m1", reqId: "r1", input: 1_000_000, output: 200_000))
        """
        let b = CostScan.fileBuckets(text: text, format: .claude, pricing: pricing)
        // 1M in @ $3 + 0.2M out @ $15
        XCTAssertEqual(b[day("2026-01-02T09:00:00Z")] ?? -1, 6.0, accuracy: 0.0001)
    }

    func testClaudeBucketsPerDay() {
        let text = """
        \(claudeLine("2026-01-01T12:00:00Z", id: "m1", reqId: "r1", input: 1_000_000, output: 0))
        \(claudeLine("2026-01-02T12:00:00Z", id: "m2", reqId: "r2", input: 2_000_000, output: 0))
        """
        let b = CostScan.fileBuckets(text: text, format: .claude, pricing: pricing)
        XCTAssertEqual(b[day("2026-01-01T12:00:00Z")] ?? -1, 3.0, accuracy: 0.0001)
        XCTAssertEqual(b[day("2026-01-02T12:00:00Z")] ?? -1, 6.0, accuracy: 0.0001)
    }

    func testClaudeCacheCreationDict() {
        let text = """
        {"type":"assistant","timestamp":"2026-01-02T09:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-4-5","usage":{"input_tokens":0,"output_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":500000}}}}
        """
        let b = CostScan.fileBuckets(text: text, format: .claude, pricing: pricing)
        // 0.5M cache-write @ $3.75
        XCTAssertEqual(b[day("2026-01-02T09:00:00Z")] ?? -1, 1.875, accuracy: 0.0001)
    }

    // MARK: - fx gateway split

    private func fxLine(_ id: String, cost: Double, model: String, input: Int, read: Int = 0, output: Int = 0) -> String {
        """
        {"kind":"generation","fact":{"id":"\(id)","created_at_ms":1770000000000,"model":"\(model)","input_tokens":\(input),"cache_read_tokens":\(read),"output_tokens":\(output),"total_cost":\(cost)}}
        """
    }

    func testFxPaidUsageStaysWithGateway() {
        let text = fxLine("g1", cost: 1.5, model: "openai/gpt-5.2", input: 1_000_000, output: 0)
        let vercel = CostScan.fileBuckets(text: text, format: .vercel, pricing: pricing)
        XCTAssertEqual(vercel[day("2026-02-02T00:00:00Z")] ?? -1, 1.5, accuracy: 0.0001)
        XCTAssertTrue(CostScan.fxCodexSpend(text: text, pricing: pricing).isEmpty)
    }

    func testFxZeroCostCodexUsageBelongsToCodex() {
        // subscription-billed codex models report $0 and must not inflate the gateway row
        let text = fxLine("g1", cost: 0, model: "codex/gpt-5.2", input: 1_000_000, read: 0, output: 1_000_000)
        XCTAssertTrue(CostScan.fileBuckets(text: text, format: .vercel, pricing: pricing).isEmpty)
        let codexRows = CostScan.fxCodexSpend(text: text, pricing: pricing)
        var codex: [Date: Double] = [:]
        for row in codexRows { codex[row.day, default: 0] += row.spent }
        XCTAssertEqual(codex[day("2026-02-02T00:00:00Z")] ?? -1, 3.0, accuracy: 0.0001)
    }

    // MARK: - pi sessions

    private func piLine(_ ts: String, id: String, model: String,
                        input: Int, read: Int = 0, write: Int = 0, output: Int) -> String {
        """
        {"type":"message","id":"\(id)","timestamp":"\(ts)","message":{"role":"assistant","model":"\(model)","usage":{"input":\(input),"cacheRead":\(read),"cacheWrite":\(write),"output":\(output)}}}
        """
    }

    func testPiAssistantUsagePricedAtList() {
        let text = """
        {"type":"session","version":3,"id":"abc"}
        \(piLine("2026-01-02T09:00:00Z", id: "m1", model: "anthropic/claude-sonnet-4-5", input: 1_000_000, read: 500_000, output: 100_000))
        """
        // 1M fresh in @ $3 + 0.5M cache-read @ $0.3 + 0.1M out @ $15
        let b = CostScan.fileBuckets(text: text, format: .pi, pricing: pricing)
        XCTAssertEqual(b[day("2026-01-02T09:00:00Z")] ?? -1, 3.0 + 0.15 + 1.5, accuracy: 0.0001)
    }

    func testPiThinkingSuffixStrippedForPricing() {
        let text = piLine("2026-01-02T09:00:00Z", id: "m1",
                          model: "anthropic/claude-sonnet-4-5-thinking-medium",
                          input: 1_000_000, output: 0)
        let b = CostScan.fileBuckets(text: text, format: .pi, pricing: pricing)
        XCTAssertEqual(b[day("2026-01-02T09:00:00Z")] ?? -1, 3.0, accuracy: 0.0001)
    }

    func testPiIgnoresUserRowsAndDeduplicates() {
        let text = """
        {"type":"message","id":"u1","timestamp":"2026-01-02T09:00:00Z","message":{"role":"user","content":[]}}
        \(piLine("2026-01-02T09:00:00Z", id: "m1", model: "anthropic/claude-sonnet-4-5", input: 1_000_000, output: 0))
        \(piLine("2026-01-02T09:00:00Z", id: "m1", model: "anthropic/claude-sonnet-4-5", input: 2_000_000, output: 0))
        """
        let b = CostScan.fileBuckets(text: text, format: .pi, pricing: pricing)
        XCTAssertEqual(b[day("2026-01-02T09:00:00Z")] ?? -1, 6.0, accuracy: 0.0001)
    }

    // MARK: - per-file cache

    private func writeFixture(_ url: URL, _ text: String) throws {
        try text.data(using: .utf8)!.write(to: url)
    }

    func testBucketsCacheUnchangedFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meter-cache-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(url, """
        {"type":"turn_context","payload":{"model":"gpt-5.2"}}
        \(codexLine("2026-01-02T10:00:00Z", input: 1_000_000, cached: 0, output: 0))
        """)
        let windowStart = isoDate("2026-01-02T00:00:00Z")!
        let first = CostScan.buckets(urls: [url], format: .codex, windowStart: windowStart, pricing: pricing)
        // rewrite content but restore the original mtime — the stamp is
        // unchanged, so the cached buckets must survive
        let originalMtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
        try writeFixture(url, """
        {"type":"turn_context","payload":{"model":"gpt-5.2"}}
        \(codexLine("2026-01-02T10:00:00Z", input: 1_000_001, cached: 0, output: 0))
        """)
        try FileManager.default.setAttributes([.modificationDate: originalMtime], ofItemAtPath: url.path)
        let second = CostScan.buckets(urls: [url], format: .codex, windowStart: windowStart, pricing: pricing)
        XCTAssertEqual(first[day("2026-01-02T10:00:00Z")] ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(second, first)
    }

    func testBucketsSkipFilesUntouchedSinceWindowStart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meter-old-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(url, codexLine("2025-06-01T10:00:00Z", input: 1_000_000, cached: 0, output: 0))
        // backdate the file below the window; it must contribute nothing
        try FileManager.default.setAttributes([.modificationDate: isoDate("2025-06-01T10:00:00Z")!], ofItemAtPath: url.path)
        let b = CostScan.buckets(urls: [url], format: .codex,
                                 windowStart: isoDate("2026-01-02T00:00:00Z")!, pricing: pricing)
        XCTAssertEqual(b, [:])
    }
}

// MARK: - project / model attribution

extension CostScanTests {
    func testClaudeRowsCarryProjectAndModel() {
        let text = """
        {"type":"user","cwd":"/Users/me/dev/projects/payload","timestamp":"2026-01-02T09:00:00Z"}
        {"type":"assistant","cwd":"/Users/me/dev/projects/payload","timestamp":"2026-01-02T09:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-4-5","usage":{"input_tokens":1000000,"output_tokens":0}}}
        """
        let rows = CostScan.fileSpend(text: text, format: .claude, pricing: pricing)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].project, "/Users/me/dev/projects/payload")
        XCTAssertEqual(rows[0].model, "claude-sonnet-4-5")
        XCTAssertEqual(rows[0].spent, 3.0, accuracy: 0.0001)
    }

    func testClaudeFallsBackToFolderNameWithoutCwd() {
        let text = """
        {"type":"assistant","timestamp":"2026-01-02T09:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-4-5","usage":{"input_tokens":1000000,"output_tokens":0}}}
        """
        let rows = CostScan.fileSpend(text: text, format: .claude, pricing: pricing,
                                      fallbackProject: "-Users-me-dev-payload")
        XCTAssertEqual(rows[0].project, "-Users-me-dev-payload")
    }

    func testCodexRowsCarrySessionProjectAndDayModel() {
        let text = """
        {"type":"session_meta","payload":{"cwd":"/Users/me/dev/projects/acq-helper"}}
        {"type":"turn_context","payload":{"model":"gpt-5.2","cwd":"/Users/me/dev/projects/acq-helper"}}
        \(codexLine("2026-01-02T12:00:00Z", input: 1_000_000, cached: 0, output: 0))
        """
        let rows = CostScan.fileSpend(text: text, format: .codex, pricing: pricing)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].project, "/Users/me/dev/projects/acq-helper")
        XCTAssertEqual(rows[0].model, "gpt-5.2")
        XCTAssertEqual(rows[0].spent, 1.0, accuracy: 0.0001)
    }

    func testPiRowsUseSessionCwdAndBareModel() {
        let text = """
        {"type":"session","version":3,"id":"abc","cwd":"/Users/me/dev/meter"}
        \(piLine("2026-01-02T09:00:00Z", id: "m1", model: "anthropic/claude-sonnet-4-5-thinking-medium", input: 1_000_000, output: 0))
        """
        let rows = CostScan.fileSpend(text: text, format: .pi, pricing: pricing)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].project, "/Users/me/dev/meter")
        XCTAssertEqual(rows[0].model, "claude-sonnet-4-5")
        XCTAssertEqual(rows[0].spent, 3.0, accuracy: 0.0001)
    }

    func testVercePaidRowsHaveModelButNoProject() {
        let text = fxLine("g1", cost: 2.0, model: "anthropic/claude-sonnet-4-5", input: 1_000_000, output: 0)
        let rows = CostScan.fileSpend(text: text, format: .vercel, pricing: pricing)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].project, "")
        XCTAssertEqual(rows[0].model, "anthropic/claude-sonnet-4-5")
    }

    func testPiProviderTypeMapping() {
        XCTAssertEqual(CostScan.piProviderType("straitly"), "straitly")
        XCTAssertEqual(CostScan.piProviderType("openai-codex"), "codex")
        XCTAssertEqual(CostScan.piProviderType("opencode-go"), "opencode")
        XCTAssertEqual(CostScan.piProviderType("openrouter"), "openrouter")
        XCTAssertNil(CostScan.piProviderType("mystery-provider"))
    }

    func testPiRowsCarryTheirProvider() {
        let text = """
        {"type":"message","id":"m1","timestamp":"2026-01-02T09:00:00Z","message":{"role":"assistant","provider":"openai-codex","model":"openai/gpt-5.2","usage":{"input":1000000,"output":0}}}
        """
        let rows = CostScan.fileSpend(text: text, format: .pi, pricing: pricing)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].provider, "openai-codex")
        XCTAssertEqual(CostScan.piProviderType(rows[0].provider), "codex")
    }

    func testDailyTotalsCollapseAttributedRows() {
        let day = CostScan.startOfToday
        let spend = ["claude": [CostScan.Spend(day: day, project: "/a", model: "m1", spent: 2),
                                CostScan.Spend(day: day, project: "/b", model: "m1", spent: 3)]]
        let daily = CostScan.dailyTotals(spend, days: 1)
        XCTAssertEqual(daily["claude"]?.first ?? 0, 5.0, accuracy: 0.0001)
    }
}

// MARK: - opencode v2 db

extension CostScanTests {
    private func makeOpencodeDB(_ statements: [String]) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("meter-opencode-\(UUID().uuidString).db").path
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        for sql in statements {
            XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        return path
    }

    func testOpencodeV2AttributesSessionMessageCost() throws {
        let ts = isoDate("2026-01-02T09:00:00Z")!
        let ms = Int64(ts.timeIntervalSince1970 * 1000)
        func assistant(_ id: String, seq: Int, provider: String, cost: Double) -> String {
            """
            INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
            VALUES ('\(id)','ses1','assistant',\(seq),\(ms),\(ms),
              '{"model":{"id":"deepseek-v4.1-flash","providerID":"\(provider)"},"cost":\(cost),"tokens":{"input":1000,"output":200,"cache":{"read":100,"write":0}}}')
            """
        }
        let path = try makeOpencodeDB([
            """
            CREATE TABLE session_v2 (id text PRIMARY KEY, project_id text NOT NULL, slug text NOT NULL,
              directory text NOT NULL, version text NOT NULL, cost real DEFAULT 0 NOT NULL,
              model text, time_created integer NOT NULL, time_updated integer NOT NULL)
            """,
            """
            CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL,
              seq integer NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)
            """,
            "INSERT INTO session_v2 (id, project_id, slug, directory, version, time_created, time_updated) VALUES ('ses1','p1','x','/Users/me/dev/proj','1',\(ms),\(ms))",
            assistant("m1", seq: 1, provider: "opencode-go", cost: 0.5),
            assistant("m2", seq: 2, provider: "opencode-go", cost: 0.25),
            assistant("m3", seq: 3, provider: "anthropic", cost: 9.99),
            "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('u1','ses1','user',4,\(ms),\(ms),'{}')",
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let rows = CostScan.opencodeSpend(windowStart: isoDate("2026-01-01T00:00:00Z")!, pricing: pricing, dbPath: path)
        // every provider is returned and tagged; routing to a row happens in Providers
        XCTAssertEqual(rows.count, 2)
        let oc = try XCTUnwrap(rows.first { $0.provider == "opencode-go" })
        XCTAssertEqual(oc.project, "/Users/me/dev/proj")
        XCTAssertEqual(oc.model, "deepseek-v4.1-flash")
        XCTAssertEqual(oc.spent, 0.75, accuracy: 0.0001)
        XCTAssertEqual(oc.tokens, 2600) // (1000 in + 200 out + 100 cache read) × 2
        XCTAssertEqual(Calendar.current.startOfDay(for: oc.day),
                       Calendar.current.startOfDay(for: ts))
        XCTAssertEqual(rows.first { $0.provider == "anthropic" }?.spent ?? -1, 9.99, accuracy: 0.0001)
    }

    func testOpencodeProviderTypeMapping() {
        XCTAssertEqual(CostScan.opencodeProviderType("opencode-go"), "opencode")
        XCTAssertEqual(CostScan.opencodeProviderType("opencode"), "opencode")
        XCTAssertNil(CostScan.opencodeProviderType("inception")) // → catch-all
    }

    func testOpencodeV2IgnoresRowsBeforeWindow() throws {
        let ts = isoDate("2026-01-02T09:00:00Z")!
        let ms = Int64(ts.timeIntervalSince1970 * 1000)
        let path = try makeOpencodeDB([
            "CREATE TABLE session_v2 (id text PRIMARY KEY, project_id text NOT NULL, slug text NOT NULL, directory text NOT NULL, version text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL)",
            "CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL, seq integer NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)",
            "INSERT INTO session_v2 (id, project_id, slug, directory, version, time_created, time_updated) VALUES ('ses1','p1','x','/p','1',\(ms),\(ms))",
            """
            INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
            VALUES ('m1','ses1','assistant',1,\(ms),\(ms),
              '{"model":{"id":"m","providerID":"opencode-go"},"cost":5.0,"tokens":{"input":1,"output":1}}')
            """,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertTrue(CostScan.opencodeSpend(windowStart: isoDate("2026-02-01T00:00:00Z")!, pricing: pricing, dbPath: path).isEmpty)
    }
}

// MARK: - Antigravity protobuf

extension CostScanTests {
    private func varint(_ value: Int) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    private func tag(_ field: Int, _ wire: Int) -> [UInt8] { varint((field << 3) | wire) }

    private func bytesField(_ field: Int, _ bytes: [UInt8]) -> [UInt8] {
        tag(field, 2) + varint(bytes.count) + bytes
    }

    private func varintField(_ field: Int, _ value: Int) -> [UInt8] {
        tag(field, 0) + varint(value)
    }

    func testAntigravityMetaParsing() {
        let model = Array("claude-sonnet-4-6".utf8)
        let usage = varintField(2, 9613) + varintField(3, 183) + varintField(5, 9116)
        let inner = bytesField(19, model) + bytesField(4, usage)
        let data = Data(bytesField(1, inner))

        let meta = CostScan.parseAntigravityMeta(data)
        XCTAssertEqual(meta?.model, "claude-sonnet-4-6")
        XCTAssertEqual(meta?.input, 9613)
        XCTAssertEqual(meta?.output, 183)
        XCTAssertEqual(meta?.cache, 9116)
    }
}

// MARK: - Streamed line parsing

extension CostScanTests {
    func testStreamedFileMatchesTextParse() throws {
        let text = """
        {"type":"turn_context","payload":{"model":"gpt-5.2","cwd":"/tmp/p"}}
        \(codexLine("2026-01-02T09:00:00Z", input: 1_000_000, cached: 0, output: 500_000))
        \(codexLine("2026-01-02T10:00:00Z", input: 2_000_000, cached: 0, output: 1_000_000))
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meter-stream-\(UUID().uuidString).jsonl")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let streamed = CostScan.fileSpend(source: .file(url), format: .codex, pricing: pricing)
        let inMemory = CostScan.fileSpend(text: text, format: .codex, pricing: pricing)
        XCTAssertEqual(streamed.count, inMemory.count)
        XCTAssertEqual(streamed.first?.spent ?? -1, inMemory.first?.spent ?? -2, accuracy: 0.0001)
        XCTAssertEqual(streamed.first?.project, "/tmp/p")
    }

    func testStreamedFileWithoutTrailingNewline() throws {
        let text = "{\"kind\":\"generation\",\"fact\":{\"id\":\"a\",\"created_at_ms\":1767225600000,\"input_tokens\":10,\"output_tokens\":5,\"total_cost\":0.25,\"model\":\"m\"}}"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meter-stream-\(UUID().uuidString).jsonl")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let rows = CostScan.fileSpend(source: .file(url), format: .vercel, pricing: pricing)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].spent, 0.25, accuracy: 0.0001)
    }
}

// MARK: - discovery window

extension CostScanTests {
    func testCodexDiscoveryReachesBackForResumedSessions() {
        let today = CostScan.startOfToday
        let windowStart = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let expected = Calendar.current.date(byAdding: .day, value: -29, to: today)!
        // a resumed codex thread writes today's usage into its start-day directory
        XCTAssertEqual(CostScan.discoveryStart(for: "codex", windowStart: windowStart), expected)
        // every other source timestamps each row, so the row window is enough
        XCTAssertEqual(CostScan.discoveryStart(for: "claude", windowStart: windowStart), windowStart)
    }
}

extension CostScanTests {
    func testOpencodeZeroCostIsPricedFromTokensIncludingReasoning() throws {
        let ts = isoDate("2026-01-03T09:00:00Z")!
        let ms = Int64(ts.timeIntervalSince1970 * 1000)
        let path = try makeOpencodeDB([
            """
            CREATE TABLE session_v2 (id text PRIMARY KEY, project_id text NOT NULL, slug text NOT NULL,
              directory text NOT NULL, version text NOT NULL, cost real DEFAULT 0 NOT NULL,
              model text, time_created integer NOT NULL, time_updated integer NOT NULL)
            """,
            """
            CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL,
              seq integer NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)
            """,
            "INSERT INTO session_v2 (id, project_id, slug, directory, version, time_created, time_updated) VALUES ('ses1','p1','x','/p','1',\(ms),\(ms))",
            """
            INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
            VALUES ('m1','ses1','assistant',1,\(ms),\(ms),
              '{"model":{"id":"gpt-5.2","providerID":"opencode-go"},"cost":0,"tokens":{"input":1000000,"output":1000000,"reasoning":1000000,"cache":{"read":1000000,"write":0}}}')
            """,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let rows = CostScan.opencodeSpend(windowStart: isoDate("2026-01-01T00:00:00Z")!,
                                          pricing: pricing, dbPath: path)
        let row = try XCTUnwrap(rows.first)
        XCTAssertTrue(row.estimated)
        // gpt-5.2: 1M in @ $1 + 2M out (output + reasoning) @ $2 + 1M cache @ $0.5
        XCTAssertEqual(row.spent, 5.5, accuracy: 0.0001)
        XCTAssertEqual(row.tokens, 4_000_000)
    }
}
