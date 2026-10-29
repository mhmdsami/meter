import XCTest
@testable import meter

final class StoreTests: XCTestCase {
    func testHistoryDailyMergesScanAndLedgerWithoutDoubleCounting() {
        // index 0 = today; scans are device-wide per provider, ledger is the day total
        let scans = ["claude": [1.0, 2.0, 3.0], "opencode": [0.5, 0.0, 0.0]]
        let ledger = [1.0, 5.0, 0.0]
        let merged = Store.historyDaily(scans: scans, ledger: ledger)
        // per day: max(scan sum, ledger) — the ledger already contains the scans
        XCTAssertEqual(merged["total"], [1.5, 5.0, 3.0])
    }

    func testLedgerSpendSplitsCatchAllByRealProvider() {
        let day = CostScan.startOfToday
        let spend = [
            "codex": [CostScan.Spend(day: day, project: "/p", model: "gpt", spent: 1,
                                    provider: "openai-codex")],
            "other": [
                CostScan.Spend(day: day, project: "/p", model: "mercury-3", spent: 2,
                               provider: "inception"),
                CostScan.Spend(day: day, project: "/p", model: "foo", spent: 3,
                               provider: "acme"),
            ],
        ]
        let ledger = Store.ledgerSpend(spend)
        XCTAssertNil(ledger["other"])                       // no catch-all bucket in the ledger
        XCTAssertEqual(ledger["inception"]?.first?.model, "mercury-3")
        XCTAssertEqual(ledger["acme"]?.first?.spent, 3)
        XCTAssertEqual(ledger["codex"]?.first?.model, "gpt") // mapped rows untouched
    }

    func testMergeTodayPrefersLedgerAndKeepsNewerScan() {
        let scans = ["opencode": 0.21]
        let ledger = ["claude": 31.09, "opencode": 0.19]
        let merged = Store.mergeToday(scans: scans, ledger: ledger)
        XCTAssertEqual(merged["claude"] ?? 0, 31.09, accuracy: 0.0001) // imported, scan absent
        XCTAssertEqual(merged["opencode"] ?? 0, 0.21, accuracy: 0.0001) // scan newer than ledger
    }
}

extension StoreTests {
    func testCarrySpendKeepsOldValuesOnFreshReadings() {
        let old = [
            InstanceReading(id: "a", type: "claude", name: "Claude", spendToday: 9.5),
            InstanceReading(id: "b", type: "codex", name: "Codex", spendToday: 2.0),
        ]
        let fresh = [
            InstanceReading(id: "a", type: "claude", name: "Claude"),
            InstanceReading(id: "c", type: "amp", name: "Amp"),
        ]
        let out = Store.carrySpend(fresh, from: old)
        XCTAssertEqual(out[0].spendToday ?? -1, 9.5, accuracy: 0.0001)
        XCTAssertNil(out[1].spendToday) // no previous row for this name
    }
}

extension StoreTests {
    func testScanCadence() {
        let now = Date()
        XCTAssertTrue(Store.scanDue(now: now, lastScan: nil, force: false, every: 600))
        XCTAssertFalse(Store.scanDue(now: now, lastScan: now.addingTimeInterval(-599),
                                     force: false, every: 600))
        XCTAssertTrue(Store.scanDue(now: now, lastScan: now.addingTimeInterval(-600),
                                    force: false, every: 600))
        XCTAssertTrue(Store.scanDue(now: now, lastScan: now.addingTimeInterval(-1),
                                    force: true, every: 600))
    }
}

extension StoreTests {
    func testEstimatedDaysFlagsOnlyEstimatedRows() {
        let day = CostScan.startOfToday
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let spend = ["opencode": [
            CostScan.Spend(day: day, project: "/p", model: "a", spent: 1, estimated: true),
            CostScan.Spend(day: day, project: "/p", model: "b", spent: 2),
        ]]
        let set = Store.estimatedDays(spend)
        XCTAssertTrue(set.contains("opencode|" + fmt.string(from: day)))
        XCTAssertFalse(Store.estimatedDays(["vercel": [
            CostScan.Spend(day: day, project: "", model: "m", spent: 3),
        ]]).contains("vercel|" + fmt.string(from: day)))
    }
}
