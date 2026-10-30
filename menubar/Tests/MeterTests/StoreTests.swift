import XCTest
@testable import meter

final class StoreTests: XCTestCase {
    private func series(_ values: [Double], length: Int = 30) -> [Double] {
        Array(repeating: 0, count: max(0, length - values.count)) + values
    }

    func testHistoryLinesSumsTheLastSevenAndThirtyDays() {
        let daily = [
            "anthropic": series(Array(repeating: 1, count: 30)),
            "openai": series(Array(repeating: 0.5, count: 30)),
        ]
        let lines = Store.historyLines(daily)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].id, "7d")
        XCTAssertEqual(lines[0].total, "$10.50")
        XCTAssertEqual(lines[1].total, "$45.00")
        XCTAssertEqual(lines[1].spark.count, 30)
        XCTAssertEqual(lines[1].spark.max() ?? 0, 1, accuracy: 0.0001)
    }

    func testHistoryLinesSkipEmptyWindows() {
        XCTAssertTrue(Store.historyLines(["anthropic": series([])]).isEmpty)
    }

    func testAttachSpendUsesTheFirstInstanceOfEachType() {
        let enabled = [
            ProviderInstance(type: "claude", name: "Claude work"),
            ProviderInstance(type: "claude", name: "Claude personal"),
            ProviderInstance(type: "codex", name: "Codex"),
        ]
        let readings = [
            InstanceReading(id: "Claude work", type: "claude", name: "Claude work", spendToday: 9),
            InstanceReading(id: "Claude personal", type: "claude", name: "Claude personal"),
            InstanceReading(id: "Codex", type: "codex", name: "Codex"),
        ]
        let out = Providers.attachSpend(readings, enabled: enabled,
                                        today: ["claude": 12.5, "codex": 0])
        // rows with no spend left to show are hidden, so look up by name
        XCTAssertEqual(out.first { $0.name == "Claude work" }?.spendToday ?? -1, 12.5, accuracy: 0.0001)
        XCTAssertNil(out.first { $0.name == "Claude personal" })
        XCTAssertNil(out.first { $0.name == "Codex" })
    }

    func testAttachSpendClearsStaleValues() {
        let reading = InstanceReading(id: "Claude", type: "claude", name: "Claude", spendToday: 4)
        let out = Providers.attachSpend([reading], enabled: [ProviderInstance(type: "claude", name: "Claude")],
                                        today: [:])
        XCTAssertTrue(out.isEmpty)
    }

    func testDailyByProviderBucketsRowsIntoFixedWindows() {
        let today = SummaryClient.dayString(Date())
        let summary = Summary(generatedAt: "", today: today, days: 30,
                              rows: [SummaryRow(day: today, host: "mac", provider: "claude", spent: 2, tokens: 10)],
                              todayByProvider: ["claude": 2], todayByHost: ["mac": 2], todayTotal: 2)
        let daily = SummaryClient.dailyByProvider(summary, days: 30)
        XCTAssertEqual(daily["claude"]?.count, 30)
        XCTAssertEqual(daily["claude"]?.last ?? 0, 2, accuracy: 0.0001)
        XCTAssertEqual(SummaryClient.dailyTotal(summary, days: 30).last ?? 0, 2, accuracy: 0.0001)
    }

    func testDueInstancesHonoursIntervals() {
        let now = Date()
        let provider = ProviderInstance(type: "claude", name: "Claude", intervalMinutes: 5)
        XCTAssertEqual(Store.dueInstances([provider], lastFetch: [:], now: now, force: false,
                                          globalIntervalMinutes: 5), ["Claude"])
        XCTAssertEqual(Store.dueInstances([provider], lastFetch: ["Claude": now], now: now, force: false,
                                          globalIntervalMinutes: 5), [])
        XCTAssertEqual(Store.dueInstances([provider], lastFetch: ["Claude": now], now: now, force: true,
                                          globalIntervalMinutes: 5), ["Claude"])
    }
}
