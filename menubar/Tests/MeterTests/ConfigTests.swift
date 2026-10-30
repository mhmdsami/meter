import XCTest
import SQLite3
@testable import meter

final class ConfigTests: XCTestCase {
    func testDecode() throws {
        let json = """
        {
          "interval_minutes": 2,
          "providers": [
            {"type": "opencode", "name": "OC-1", "key": "auth:opencode-go", "interval_minutes": 15},
            {"type": "openrouter", "name": "OR", "enabled": false}
          ]
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertEqual(config.intervalMinutes, 2)
        XCTAssertEqual(config.providers.count, 2)
        XCTAssertEqual(config.providers[0].key, "auth:opencode-go")
        XCTAssertEqual(config.providers[0].enabled, true)
        XCTAssertEqual(config.providers[0].intervalMinutes, 15)
        XCTAssertEqual(config.providers[1].enabled, false)
        XCTAssertEqual(config.providers[1].id, "OR")
    }

    func testWindowCountdown() {
        var win = UsageWindow(id: "w", label: "L", usedPercent: 42, resetsAt: Date().addingTimeInterval(2 * 3600 + 53 * 60))
        XCTAssertEqual(win.resetsIn, "2h 53m")
        XCTAssertEqual(win.barColor, .green)
        win.usedPercent = 90
        XCTAssertEqual(win.barColor, .red)
        win.usedPercent = 70
        XCTAssertEqual(win.barColor, .orange)
        win.resetsAt = Date().addingTimeInterval(40)
        XCTAssertEqual(win.resetsIn, "0m")
        win.resetsAt = Date().addingTimeInterval(26 * 3600)
        XCTAssertEqual(win.resetsIn, "1d 2h")
    }

    func testTotalToday() {
        let readings: [InstanceReading] = [
            InstanceReading(id: "a", type: "t", name: "a", spendToday: 1.25),
            InstanceReading(id: "b", type: "t", name: "b", spendToday: 0.75),
            InstanceReading(id: "c", type: "t", name: "c", error: "401"),
        ]
        XCTAssertEqual(readings.totalToday, 2.0, accuracy: 0.001)
    }

    func testUsageWindowPercentFromNSNumbers() {
        // OpenCode returns percent as integer JSON numbers
        let lane: [String: Any] = ["percent": 46, "resetsAt": "2026-09-03T12:27:08.355Z"]
        let pct = (lane["percent"] as? Double) ?? ((lane["percent"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(pct, 46)
        XCTAssertNotNil(isoDate("2026-09-03T12:27:08.355Z"))
        XCTAssertNotNil(isoDate("2026-09-03T12:27:08Z"))
    }

    func testOpencodeV2CredentialFromDB() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("meter-cred-\(UUID().uuidString).db").path
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let sql = """
        CREATE TABLE credential (id text PRIMARY KEY, integration_id text, label text NOT NULL,
          value text NOT NULL, connector_id text, method_id text, active integer,
          time_created integer NOT NULL, time_updated integer NOT NULL);
        INSERT INTO credential (id, integration_id, label, value, active, time_created, time_updated)
          VALUES ('c1','openrouter','OpenRouter','{"type":"api","key":"sk-or-test"}',1,1,1);
        """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)

        XCTAssertEqual(Secrets.opencodeCredential("openrouter", dbPath: path), "sk-or-test")
        XCTAssertNil(Secrets.opencodeCredential("anthropic", dbPath: path))
    }

    func testDueInstances() {
        Providers.backoffUntil = [:]
        let providers = [
            ProviderInstance(type: "codex", name: "Codex"),
            ProviderInstance(type: "claude", name: "Claude", enabled: false),
            ProviderInstance(type: "claude", name: "Claude Slow", intervalMinutes: 15),
        ]
        let now = Date()
        let lastFetch = ["Codex": now.addingTimeInterval(-60)]  // fetched 1 min ago

        // not forced: Codex inside its 5-min window stays deferred, disabled never fetches
        XCTAssertEqual(
            Store.dueInstances(providers, lastFetch: lastFetch, now: now,
                               force: false, globalIntervalMinutes: 5),
            ["Claude Slow"])

        // force: interval bypassed
        XCTAssertEqual(
            Store.dueInstances(providers, lastFetch: lastFetch, now: now,
                               force: true, globalIntervalMinutes: 5).sorted(),
            ["Claude Slow", "Codex"])

        // 429 backoff blocks even a forced refresh
        Providers.setBackoff("Codex", seconds: 120)
        XCTAssertEqual(
            Store.dueInstances(providers, lastFetch: lastFetch, now: now,
                               force: true, globalIntervalMinutes: 5),
            ["Claude Slow"])
        Providers.backoffUntil = [:]
    }
}
