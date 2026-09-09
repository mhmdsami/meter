import XCTest
@testable import meter

final class CostScanTests: XCTestCase {
    private let since = isoDate("2026-01-02T00:00:00Z")!

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
        let total = CostScan.scan(text: text, since: since, pricing: pricing, format: .codex)
        // max today: 2M in @ $1 + 1M out @ $2
        XCTAssertEqual(total, 4.0, accuracy: 0.0001)
    }

    func testCodexSessionStraddlingMidnightBillsOnlyToday() {
        let text = """
        {"type":"turn_context","payload":{"model":"gpt-5.2"}}
        \(codexLine("2026-01-01T23:00:00Z", input: 1_000_000, cached: 500_000, output: 500_000))
        \(codexLine("2026-01-02T10:00:00Z", input: 3_000_000, cached: 1_500_000, output: 1_500_000))
        """
        let total = CostScan.scan(text: text, since: since, pricing: pricing, format: .codex)
        // deltas: input 2M (1M cached @ $0.5, 1M fresh @ $1) + output 1M @ $2
        XCTAssertEqual(total, 1.0 + 0.5 + 2.0, accuracy: 0.0001)
    }

    func testCodexUnknownModelCostsNothing() {
        let text = """
        {"type":"turn_context","payload":{"model":"mystery-model"}}
        \(codexLine("2026-01-02T10:00:00Z", input: 1_000_000, cached: 0, output: 1_000_000))
        """
        XCTAssertEqual(CostScan.scan(text: text, since: since, pricing: pricing, format: .codex), 0)
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
        \(claudeLine("2026-01-02T10:00:00Z", id: "msg1", reqId: "r1", input: 1_000_000, output: 100_000))
        \(claudeLine("2026-01-02T10:00:01Z", id: "msg1", reqId: "r1", input: 1_000_000, output: 200_000))
        """
        let total = CostScan.scan(text: text, since: since, pricing: pricing, format: .claude)
        XCTAssertEqual(total, 3.0 + 0.2 * 15, accuracy: 0.0001)
    }

    func testClaudeIgnoresLinesBeforeSince() {
        let text = """
        \(claudeLine("2026-01-01T10:00:00Z", id: "old", reqId: "r0", input: 1_000_000, output: 1_000_000))
        \(claudeLine("2026-01-02T10:00:00Z", id: "new", reqId: "r1", input: 1_000_000, output: 0))
        """
        let total = CostScan.scan(text: text, since: since, pricing: pricing, format: .claude)
        XCTAssertEqual(total, 3.0, accuracy: 0.0001)
    }

    func testClaudeCacheCreationDict() {
        let text = """
        {"type":"assistant","timestamp":"2026-01-02T10:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-4-5","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":600000,"ephemeral_1h_input_tokens":400000}}}}
        """
        let total = CostScan.scan(text: text, since: since, pricing: pricing, format: .claude)
        XCTAssertEqual(total, 3.75, accuracy: 0.0001)
    }

    // MARK: - per-file cache

    func testScanUrlsCachesUnchangedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")

        // whole-second mtime survives the setAttributes round trip exactly
        let mtime = since.addingTimeInterval(36_000)
        let line1 = claudeLine("2026-01-02T10:00:00Z", id: "m1", reqId: "r1", input: 1_000_000, output: 0)
        try line1.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        let p = pricing

        let first = CostScan.scan(urls: [url], since: since, pricing: p, format: .claude)
        XCTAssertEqual(first, 3.0, accuracy: 0.0001)

        // rewrite with different content but identical size + mtime → cache must serve the old value
        let line2 = claudeLine("2026-01-02T11:00:00Z", id: "m2", reqId: "r2", input: 2_000_000, output: 0)
        XCTAssertEqual(line1.utf8.count, line2.utf8.count)
        try line2.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        XCTAssertEqual(CostScan.scan(urls: [url], since: since, pricing: p, format: .claude), 3.0, accuracy: 0.0001)

        // size change → rescan picks up new total (line2 2M + line1 1M = $9)
        try (line2 + "\n" + line1).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        let second = CostScan.scan(urls: [url], since: since, pricing: p, format: .claude)
        XCTAssertEqual(second, 9.0, accuracy: 0.0001)
    }

    func testScanUrlsSkipsFilesUntouchedSinceWindowStart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("old.jsonl")
        try claudeLine("2026-01-02T10:00:00Z", id: "m1", reqId: "r1", input: 1_000_000, output: 0)
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: since.addingTimeInterval(-3600)], ofItemAtPath: url.path)
        XCTAssertEqual(CostScan.scan(urls: [url], since: since, pricing: pricing, format: .claude), 0)
    }
}
