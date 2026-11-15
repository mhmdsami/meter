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

    func testAttachSpendFallsBackToTheFirstInstance() {
        let enabled = [
            ProviderInstance(type: "claude", name: "Claude work"),
            ProviderInstance(type: "claude", name: "Claude personal"),
            ProviderInstance(type: "codex", name: "Codex"),
        ]
        let readings = [
            InstanceReading(id: "Claude work", type: "claude", name: "Claude work"),
            InstanceReading(id: "Claude personal", type: "claude", name: "Claude personal"),
            InstanceReading(id: "Codex", type: "codex", name: "Codex"),
        ]
        let out = Providers.attachSpend(readings, enabled: enabled,
                                        today: ["claude": 12.5, "codex": 3])
        // the split is unknowable, so the total lands on the first instance
        XCTAssertEqual(out.first { $0.name == "Claude work" }?.spendToday ?? -1, 12.5, accuracy: 0.0001)
        XCTAssertNil(out.first { $0.name == "Claude personal" })
        XCTAssertEqual(out.first { $0.name == "Codex" }?.spendToday ?? -1, 3, accuracy: 0.0001)
    }

    func testEveryProvidersSpendLandsOnSomeRow() {
        let enabled = [
            ProviderInstance(type: "claude", name: "Claude a"),
            ProviderInstance(type: "claude", name: "Claude b"),
            ProviderInstance(type: "opencode", name: "OpenCode a"),
            ProviderInstance(type: "opencode", name: "OpenCode b"),
            ProviderInstance(type: "codex", name: "Codex"),
        ]
        let readings = enabled.map {
            InstanceReading(id: $0.name, type: $0.type, name: $0.name,
                            windows: [UsageWindow(id: "w", label: "W", usedPercent: 1)])
        }
        let today = ["claude": 5.0, "opencode": 1.0, "codex": 2.0]
        let out = Providers.attachSpend(readings, enabled: enabled, today: today)
        XCTAssertEqual(out.compactMap(\.spendToday).reduce(0, +), 8.0, accuracy: 0.0001)
        XCTAssertEqual(out.filter { $0.type == "claude" }.compactMap(\.spendToday).count, 1)
        XCTAssertEqual(out.filter { $0.type == "opencode" }.compactMap(\.spendToday).count, 1)
    }

    func testFirstInstanceAlwaysClaimsTheTotal() {
        let enabled = [
            ProviderInstance(type: "opencode", name: "OpenCode a"),
            ProviderInstance(type: "opencode", name: "OpenCode b"),
        ]
        let readings = enabled.map {
            InstanceReading(id: $0.name, type: $0.type, name: $0.name,
                            windows: [UsageWindow(id: "w", label: "W", usedPercent: 1)])
        }
        let out = Providers.attachSpend(readings, enabled: enabled, today: ["opencode": 4])
        XCTAssertEqual(out.first { $0.name == "OpenCode a" }?.spendToday ?? -1, 4, accuracy: 0.0001)
        XCTAssertNil(out.first { $0.name == "OpenCode b" }?.spendToday)
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
