import XCTest
@testable import meter

final class CloudflareTests: XCTestCase {
    private let payload = """
    {"result":[
      {"id":"a","created_at":"2026-10-01T09:00:00Z","cost":0.5,"tokens_in":1000,"tokens_out":200,"success":true},
      {"id":"b","created_at":"2026-10-01T09:05:00Z","cost":0,"tokens_in":500,"tokens_out":100,"success":false}
    ],"success":true}
    """

    func testParseAndSummarize() {
        let entries = Cloudflare.parse(Data(payload.utf8))
        XCTAssertEqual(entries.count, 2)
        let summary = Cloudflare.summarize(entries)
        XCTAssertEqual(summary.requests, 2)
        XCTAssertEqual(summary.errors, 1)
        XCTAssertEqual(summary.tokens, 1800)
        XCTAssertEqual(summary.cost, 0.5, accuracy: 0.0001)
    }

    func testParseRejectsRowsWithoutTimestamp() {
        let bad = Data(#"{"result":[{"cost":1}]}"#.utf8)
        XCTAssertTrue(Cloudflare.parse(bad).isEmpty)
    }

    func testCreditBalanceParsesCents() {
        let json = Data(#"{"success":true,"result":{"balance":2000,"has_default_payment_method":true}}"#.utf8)
        XCTAssertEqual(Cloudflare.parseCreditBalance(json), 20.0)
        XCTAssertNil(Cloudflare.parseCreditBalance(Data(#"{"success":false}"#.utf8)))
    }

    func testCreditBalanceAllowsNegative() {
        let json = Data(#"{"result":{"balance":-125}}"#.utf8)
        XCTAssertEqual(Cloudflare.parseCreditBalance(json), -1.25)
    }

    func testTodayFilteringViaSummarize() {
        let entries = Cloudflare.parse(Data("""
        {"result":[
          {"id":"old","created_at":"2026-09-30T09:00:00Z","cost":9,"tokens_in":10,"tokens_out":10,"success":true},
          {"id":"new","created_at":"2026-10-01T09:00:00Z","cost":1,"tokens_in":10,"tokens_out":10,"success":true}
        ]}
        """.utf8))
        let today = entries.filter { $0.createdAt >= isoDate("2026-10-01T00:00:00Z")! }
        XCTAssertEqual(Cloudflare.summarize(today).cost, 1, accuracy: 0.0001)
    }
}
