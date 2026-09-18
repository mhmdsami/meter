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

    func testMetaRoundTrip() {
        let ledger = tempLedger()
        XCTAssertNil(ledger.meta("backfilled"))
        ledger.setMeta("backfilled", "2026-09-18T00:00:00Z")
        XCTAssertEqual(ledger.meta("backfilled"), "2026-09-18T00:00:00Z")
    }
}
