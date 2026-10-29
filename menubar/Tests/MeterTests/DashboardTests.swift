import XCTest
@testable import meter

final class DashboardTests: XCTestCase {
    func testRenderEmbedsLedgerRows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meter-dash-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = Ledger(url: url)

        let day = isoDate("2026-10-21T12:00:00Z")!
        ledger.record(day: "2026-10-21", provider: "claude", account: "Claude", spent: 3.5,
                      source: "estimated", pricingGen: "g", final: false)
        ledger.recordBreakdown(
            ["claude": [CostScan.Spend(day: day, project: "/p", model: "claude-sonnet-5",
                                       spent: 3.5, tokens: 1000)]],
            targetNames: [:], pricingGen: Date(), reported: [])

        let html = Dashboard.render(days: 30, ledger: ledger, now: isoDate("2026-10-25T12:00:00Z")!)
        XCTAssertTrue(html.contains("id=\"data\""))
        XCTAssertTrue(html.contains("Spend over time"))
        XCTAssertTrue(html.contains("\"provider\":\"claude\""))
        XCTAssertTrue(html.contains("claude-sonnet-5"))
    }
}
