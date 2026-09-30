import XCTest
@testable import meter

final class LedgerTests: XCTestCase {
    private func tempLedger() -> Ledger {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meter-ledger-\(UUID().uuidString).db")
        return Ledger(url: url)
    }

    func testUpsertIsIdempotent() {
        let ledger = tempLedger()
        ledger.record(day: "2026-09-17", provider: "claude", account: "Claude", spent: 10,
                      source: "estimated", pricingGen: "g1", final: true)
        ledger.record(day: "2026-09-17", provider: "claude", account: "Claude", spent: 12.5,
                      source: "estimated", pricingGen: "g1", final: false)

        let rows = ledger.days(from: "2026-09-17", to: "2026-09-17")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].spent, 12.5, accuracy: 0.0001)
        // final is sticky: a day already closed stays closed
        XCTAssertTrue(rows[0].final)
    }

    func testDaysRangeFiltersAndSorts() {
        let ledger = tempLedger()
        ledger.record(day: "2026-09-15", provider: "codex", account: "Codex", spent: 1,
                      source: "estimated", pricingGen: "g", final: true)
        ledger.record(day: "2026-09-17", provider: "claude", account: "Claude", spent: 2,
                      source: "estimated", pricingGen: "g", final: false)
        let rows = ledger.days(from: "2026-09-16", to: "2026-09-18")
        XCTAssertEqual(rows.map(\.day), ["2026-09-17"])
    }

    func testRecordDailyMarksPastDaysFinal() {
        let ledger = tempLedger()
        let names = ["claude": "Claude"]
        let daily = ["claude": [3.0, 2.0, 1.0]]  // today, yesterday, two days ago
        ledger.recordDaily(daily, targetNames: names, pricingGen: Date(), reported: [])

        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: cal.startOfDay(for: Date()))
        let yesterday = fmt.string(from: cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!)

        let rows = ledger.days(from: yesterday, to: today)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.day == today }?.final, false)
        XCTAssertEqual(rows.first { $0.day == yesterday }?.final, true)
    }

    func testBreakdownRoundTripAndAttribution() {
        let ledger = tempLedger()
        let day = Calendar.current.startOfDay(for: Date())
        let spend = ["claude": [
            CostScan.Spend(day: day, project: "/Users/me/dev/headout/payload", model: "claude-sonnet-4-5", spent: 4),
            CostScan.Spend(day: day, project: "/Users/me/dev/headout/kirby", model: "claude-opus-5", spent: 9),
        ]]
        ledger.recordBreakdown(spend, targetNames: [:], pricingGen: Date(), reported: [])

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let key = fmt.string(from: day)
        let projects = ledger.attribution(by: "project", from: key, to: key)
        XCTAssertEqual(projects.first?.label, "/Users/me/dev/headout/kirby")
        XCTAssertEqual(projects.first?.spent ?? 0, 9, accuracy: 0.0001)
        XCTAssertEqual(projects.count, 2)

        let models = ledger.attribution(by: "model", from: key, to: key)
        XCTAssertEqual(Set(models.map(\.label)), ["claude-opus-5", "claude-sonnet-4-5"])

        // same key upserts instead of adding
        ledger.recordBreakdown(spend, targetNames: [:], pricingGen: Date(), reported: [])
        XCTAssertEqual(ledger.attribution(by: "project", from: key, to: key).count, 2)
    }

    func testBreakdownSumsRowsSharingAKey() {
        let ledger = tempLedger()
        let day = CostScan.startOfToday
        // many messages share (day, provider, project, model): they must sum
        let spend = ["claude": [
            CostScan.Spend(day: day, project: "/p", model: "claude-sonnet-5", spent: 1),
            CostScan.Spend(day: day, project: "/p", model: "claude-sonnet-5", spent: 2),
            CostScan.Spend(day: day, project: "/p", model: "claude-sonnet-5", spent: 3),
        ]]
        ledger.recordBreakdown(spend, targetNames: [:], pricingGen: Date(), reported: [])
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let key = fmt.string(from: day)
        let rows = ledger.attribution(by: "project", from: key, to: key)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].spent, 6.0, accuracy: 0.0001)
    }

    func testFreeModelWithTokensIsKept() {
        let ledger = tempLedger()
        let day = CostScan.startOfToday
        let spend = ["opencode": [
            CostScan.Spend(day: day, project: "/p", model: "union-alpha", spent: 0, tokens: 4_350_000),
        ]]
        ledger.recordBreakdown(spend, targetNames: [:], pricingGen: Date(), reported: [])
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let key = fmt.string(from: day)
        let models = ledger.attribution(by: "model", from: key, to: key)
        XCTAssertEqual(models.first?.label, "union-alpha")
        XCTAssertEqual(models.first?.spent ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(models.first?.tokens, 4_350_000)
    }

    func testMetaRoundTrip() {
        let ledger = tempLedger()
        XCTAssertNil(ledger.meta("backfilled"))
        ledger.setMeta("backfilled", "2026-09-18T00:00:00Z")
        XCTAssertEqual(ledger.meta("backfilled"), "2026-09-18T00:00:00Z")
    }
}
