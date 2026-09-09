import XCTest
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
