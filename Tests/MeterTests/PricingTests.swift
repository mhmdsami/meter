import XCTest
@testable import meter

final class PricingTests: XCTestCase {
    private func pricing(_ root: [String: Any]) -> Pricing {
        let p = Pricing()
        p.parse(root)
        return p
    }

    private func provider(_ models: [String: [String: Double]]) -> [String: Any] {
        ["models": models.mapValues { ["cost": $0] }]
    }

    func testOfficialBeatsReseller() {
        let p = pricing([
            "anthropic": provider(["claude-sonnet-4-5": ["input": 3, "output": 15, "cache_read": 0.3, "cache_write": 3.75]]),
            "somereseller": provider(["claude-sonnet-4-5": ["input": 99, "output": 99]]),
        ])
        XCTAssertEqual(p.cost(for: "claude-sonnet-4-5")?.input, 3)
    }

    func testZeroCostMirrorLoses() {
        let p = pricing([
            "freereseller": provider(["gpt-5": ["input": 0, "output": 0]]),
            "paidreseller": provider(["gpt-5": ["input": 1.25, "output": 10]]),
        ])
        XCTAssertEqual(p.cost(for: "gpt-5")?.input, 1.25)
    }

    func testParseOrderIndependent() {
        let official = provider(["m": ["input": 3, "output": 15]])
        let reseller = provider(["m": ["input": 99, "output": 99]])
        let a = pricing(["anthropic": official, "reseller": reseller])
        let b = pricing(["reseller": reseller, "anthropic": official])
        XCTAssertEqual(a.cost(for: "m"), b.cost(for: "m"))
    }

    func testCostLookupFallbacks() {
        let p = pricing([
            "anthropic": provider(["claude-sonnet-4-5-20250929": ["input": 3, "output": 15]]),
        ])
        XCTAssertEqual(p.cost(for: "claude-sonnet-4-5-20250929")?.input, 3)  // exact
        XCTAssertEqual(p.cost(for: "Claude-Sonnet-4-5-20250929")?.input, 3)  // case-insensitive
        XCTAssertEqual(p.cost(for: "claude-sonnet-4-5")?.input, 3)           // versioned suffix
        XCTAssertEqual(p.cost(for: "claude-sonnet-4-5[1m]")?.input, 3)       // bracket variant
        XCTAssertNil(p.cost(for: "unknown-model"))
    }

    func testDollarsCodex() {
        let cost = Pricing.ModelCost(input: 2, output: 8, cacheRead: 0.5, cacheWrite: 0)
        // 1M input of which 400k cached, 200k output
        let d = Pricing.dollars(cost, input: 1_000_000, cachedInput: 400_000, output: 200_000)
        XCTAssertEqual(d, 0.6 * 2 + 0.4 * 0.5 + 0.2 * 8, accuracy: 0.0001)
        // cached reported above input must not go negative
        XCTAssertGreaterThanOrEqual(Pricing.dollars(cost, input: 100, cachedInput: 200, output: 0), 0)
    }

    func testDollarsClaude() {
        let cost = Pricing.ModelCost(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)
        let d = Pricing.dollarsClaude(cost, input: 1_000_000, cacheRead: 2_000_000,
                                      cacheWrite: 500_000, output: 100_000)
        XCTAssertEqual(d, 3 + 2 * 0.3 + 0.5 * 3.75 + 0.1 * 15, accuracy: 0.0001)
    }
}
