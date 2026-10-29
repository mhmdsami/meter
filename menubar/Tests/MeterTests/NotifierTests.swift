import XCTest
@testable import meter

final class NotifierTests: XCTestCase {
    private func reading(type: String, name: String, window: String, percent: Double, reset: Date?) -> InstanceReading {
        InstanceReading(id: name, type: type, name: name,
                        windows: [UsageWindow(id: window, label: window.capitalized,
                                              usedPercent: percent, resetsAt: reset)])
    }

    func testFiresOncePerWindowPerReset() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let readings = [reading(type: "claude", name: "Claude", window: "weekly", percent: 95, reset: reset)]
        let settings = NotificationSettings()

        let first = Notifier.pending(readings: readings, todayTotal: 0, settings: settings, notified: [])
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0].title.contains("Claude Weekly at 95%"))

        // same window, same reset cycle → already notified, no repeat
        let second = Notifier.pending(readings: readings, todayTotal: 0, settings: settings,
                                      notified: Set(first.map(\.id)))
        XCTAssertTrue(second.isEmpty)

        // after the window resets (new reset date) it can fire again
        let nextCycle = [reading(type: "claude", name: "Claude", window: "weekly", percent: 92,
                                 reset: reset.addingTimeInterval(86_400))]
        let third = Notifier.pending(readings: nextCycle, todayTotal: 0, settings: settings,
                                     notified: Set(first.map(\.id)))
        XCTAssertEqual(third.count, 1)
    }

    func testIgnoresBelowThresholdAndErroredRows() {
        let readings = [reading(type: "claude", name: "Claude", window: "session", percent: 40, reset: nil),
                        InstanceReading(id: "Codex", type: "codex", name: "Codex",
                                        windows: [UsageWindow(id: "session", label: "Session", usedPercent: 99)],
                                        error: "rate limited (429)")]
        let alerts = Notifier.pending(readings: readings, todayTotal: 0,
                                      settings: NotificationSettings(), notified: [])
        XCTAssertTrue(alerts.isEmpty)
    }

    func testDailySpendFiresOncePerDay() {
        var settings = NotificationSettings()
        settings.dailySpend = 50
        let first = Notifier.pending(readings: [], todayTotal: 61.5, settings: settings, notified: [])
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0].title.contains("$61.50"))

        let second = Notifier.pending(readings: [], todayTotal: 80, settings: settings,
                                      notified: Set(first.map(\.id)))
        XCTAssertTrue(second.isEmpty)
    }

    func testDisabledSendsNothing() {
        var settings = NotificationSettings()
        settings.enabled = false
        let readings = [reading(type: "claude", name: "Claude", window: "weekly", percent: 100, reset: nil)]
        let alerts = Notifier.pending(readings: readings, todayTotal: 500, settings: settings, notified: [])
        XCTAssertTrue(alerts.isEmpty)
    }
}
