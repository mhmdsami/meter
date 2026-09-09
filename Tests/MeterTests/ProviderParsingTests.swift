import XCTest
@testable import meter

final class ProviderParsingTests: XCTestCase {
    private let instance = ProviderInstance(type: "x", name: "X")

    func testAmpBalanceParsing() {
        let fixture = """
        Signed in as user@example.com
        Individual credits: $20 remaining (set up auto-reload to avoid running out) - https://ampcode.com/settings
        """
        XCTAssertEqual(Amp.parseBalance(fixture), "$20 left")
        XCTAssertEqual(Amp.parseBalance("Team credits: $1,234.56 remaining"), "$1,234.56 left")
        XCTAssertEqual(Amp.parseBalance("Signed in as user@example.com"), "Signed in as user@example.com")
        XCTAssertNil(Amp.parseBalance(""))
    }

    func testAmpCLIParsingBold() {
        // amp CLI 0.0.1787544825+ wraps labels in **bold**
        let fixture = """
        Signed in as user@example.com
        **Amp Free:** 25% remaining today (resets daily) - https://ampcode.com/settings
        **Amp Megawatt Subscription:** 68% other usage and 97% orb usage remaining - resets upon renewal in 5 days
        **Individual credits:** $3.23 remaining (set up auto-reload to avoid running out) - https://ampcode.com/settings
        """
        let r = try! Amp.parseCLI(fixture, instance)
        XCTAssertEqual(r.windows.map(\.id), ["free", "other", "orb"])
        XCTAssertEqual(r.windows[0].usedPercent, 75)
        XCTAssertEqual(r.windows[1].label, "Megawatt")
        XCTAssertEqual(r.windows[1].usedPercent, 32)
        XCTAssertEqual(r.windows[2].usedPercent, 3)
        XCTAssertEqual(r.windows[2].note, "renews in 5 days")
        XCTAssertEqual(r.balanceNote, "$3.23 left")
    }

    func testAmpCLIParsingPlain() {
        let fixture = """
        Signed in as user@example.com
        Amp Free: 0% remaining today (resets daily) - https://ampcode.com/settings
        Individual credits: $20 remaining (set up auto-reload to avoid running out) - https://ampcode.com/settings
        """
        let r = try! Amp.parseCLI(fixture, instance)
        XCTAssertEqual(r.windows.map(\.id), ["free"])
        XCTAssertEqual(r.windows[0].usedPercent, 100)
        XCTAssertEqual(r.balanceNote, "$20.00 left")
    }

    func testAmpCLIParsingNoUsageThrows() {
        XCTAssertThrowsError(try Amp.parseCLI("Signed in as user@example.com\n", instance))
    }

    func testCodexRPCMap() {
        let result: [String: Any] = [
            "rateLimits": [
                "primary": ["usedPercent": 0, "resetsAt": 1_788_817_783],
                "secondary": ["usedPercent": 7, "resetsAt": 1_789_374_334],
                "rateLimitResetCredits": ["availableCount": 2],
            ]
        ]
        let r = try! Codex.mapRPC(instance: instance, result: result)
        XCTAssertEqual(r.windows.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(r.windows[1].usedPercent, 7)
        XCTAssertEqual(r.balanceNote, "2 reset credits")
    }

    func testCodexMapAdditionalLimits() {
        let usage: [String: Any] = [
            "rate_limit": ["primary_window": ["used_percent": 10]],
            "additional_rate_limits": [["limit_id": "codex-spark", "limit_name": "Codex Spark",
                                        "primary_window": ["used_percent": 55]]],
        ]
        let r = Codex.map(instance: instance, usage: usage)
        XCTAssertEqual(r.windows.map(\.id), ["session", "codex-spark"])
        XCTAssertEqual(r.windows[1].label, "Codex Spark")
        XCTAssertEqual(r.windows[1].usedPercent, 55)
    }

    func testHistoryLines() {
        let daily = ["claude": Array(repeating: 10.0, count: 30).enumerated().map { Double($0.offset) + 1 },
                     "codex": [2, 0, 4, 0, 0, 0, 1] + Array(repeating: 0.0, count: 23).map { $0 }]
        let lines = Store.historyLines(daily)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].id, "7d")
        // 7d: claude 1..7 = 28, codex 2+4+1 = 7
        XCTAssertEqual(lines[0].total, "$35.00")
        XCTAssertTrue(lines[0].breakdown.contains("Claude $28.00"))
        XCTAssertTrue(lines[0].breakdown.contains("Codex $7.00"))
        // spark oldest-first: totals 8,6,5,4,7,2,3 — max 8 at index 0
        XCTAssertEqual(lines[0].spark.count, 7)
        XCTAssertEqual(lines[0].spark.first ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(lines[0].spark.last ?? 0, 3.0 / 8.0, accuracy: 0.0001)
        // 30d totals
        XCTAssertEqual(lines[1].id, "30d")
        XCTAssertEqual(lines[1].breakdown.contains("Codex $7.00"), true)
        XCTAssertEqual(lines[1].breakdown.contains("Claude $465.00"), true)
        XCTAssertEqual(lines[1].total, "$472.00")
    }

    func testHistoryLinesSkipsEmpty() {
        XCTAssertEqual(Store.historyLines(["claude": Array(repeating: 0.0, count: 30)]), [])
    }

    func testCodexMap() {
        let usage: [String: Any] = [
            "rate_limit": [
                "primary_window": ["used_percent": 42, "reset_at": 1_767_312_000],
                "secondary_window": ["used_percent": 7.5],
            ]
        ]
        let r = Codex.map(instance: instance, usage: usage)
        XCTAssertEqual(r.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(r.windows[0].usedPercent, 42)
        XCTAssertEqual(r.windows[0].resetsAt, Date(timeIntervalSince1970: 1_767_312_000))
        XCTAssertEqual(r.windows[1].usedPercent, 7.5)
        XCTAssertNil(r.windows[1].resetsAt)
    }

    func testClaudeMap() {
        let usage: [String: Any] = [
            "five_hour": ["utilization": 61, "resets_at": "2026-01-02T15:00:00Z"],
            "seven_day": ["utilization": 12.5],
        ]
        let r = Claude.map(instance: instance, usage: usage)
        XCTAssertEqual(r.windows.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(r.windows[0].usedPercent, 61)
        XCTAssertNotNil(r.windows[0].resetsAt)
        XCTAssertEqual(r.windows[1].usedPercent, 12.5)
    }

    func testZedMapLimited() {
        let plan: [String: Any] = [
            "subscription_period": ["ended_at": "2026-01-31T00:00:00Z"],
            "usage": ["edit_predictions": ["used": 250, "limit": ["limited": 2000]]],
        ]
        let r = Zed.map(instance: instance, plan: plan)
        XCTAssertEqual(r.windows.count, 1)
        XCTAssertEqual(r.windows[0].usedPercent!, 12.5, accuracy: 0.001)
        XCTAssertEqual(r.windows[0].note, "250 of 2000")
    }

    func testZedMapFreePlan() {
        let plan: [String: Any] = [
            "plan_v3": "zed_free",
            "usage": ["edit_predictions": ["used": 10]],
        ]
        let r = Zed.map(instance: instance, plan: plan)
        XCTAssertNil(r.windows[0].usedPercent)
        XCTAssertEqual(r.windows[0].note, "free plan")
    }

    func testHideEmpty() {
        let readings = [
            InstanceReading(id: "a", type: "t", name: "a"),                    // nothing → hidden
            InstanceReading(id: "b", type: "t", name: "b", spendToday: 0),     // real $0 → visible
            InstanceReading(id: "c", type: "t", name: "c", error: "boom"),     // error → visible
        ]
        XCTAssertEqual(Providers.hideEmpty(readings).map(\.name), ["b", "c"])
    }
}
