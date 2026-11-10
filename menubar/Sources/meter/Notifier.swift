import Foundation
import UserNotifications

/// Threshold alerts for quota windows and daily spend. Decisions are computed
/// separately from posting so they can be tested without the notification center.
enum Notifier {
    struct Alert {
        let id: String
        let title: String
        let body: String
    }

    /// Which alerts are due, given what has already been sent. One alert per
    /// window per reset cycle (a crossing does not repeat every refresh), and one
    /// per local day for spend.
    nonisolated static func pending(readings: [InstanceReading],
                                    todayTotal: Double,
                                    settings: NotificationSettings,
                                    notified: Set<String>,
                                    now: Date = Date()) -> [Alert] {
        guard settings.enabled else { return [] }
        var alerts: [Alert] = []

        for reading in readings where reading.error == nil {
            for window in reading.windows {
                guard let used = window.usedPercent, used >= settings.windowPercent else { continue }
                let resets = window.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "noreset"
                let id = "notified|window|\(reading.type)|\(window.id)|\(resets)|\(Int(settings.windowPercent))"
                guard !notified.contains(id) else { continue }
                let title = "\(reading.name) \(window.label) at \(String(format: "%.0f%%", used))"
                let body = window.resetsIn.map { "Resets in \($0)" } ?? "Reset time unknown"
                alerts.append(Alert(id: id, title: title, body: body))
            }
        }

        if let threshold = settings.dailySpend, todayTotal > threshold {
            let day = localDay(now)
            let id = "notified|spend|\(day)|\(Int(threshold))"
            if !notified.contains(id) {
                alerts.append(Alert(id: id,
                                    title: String(format: "Today's spend $%.2f", todayTotal),
                                    body: String(format: "Over your $%.0f threshold", threshold)))
            }
        }
        return alerts
    }

    private nonisolated static func localDay(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    /// Sent-alert keys, so a crossing does not repeat every refresh.
    enum NotificationLog {
        private static let key = "notified.keys"
        private static let limit = 400

        static func keys() -> Set<String> {
            Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        }

        static func add(_ ids: [String]) {
            var all = UserDefaults.standard.stringArray(forKey: key) ?? []
            all.append(contentsOf: ids)
            if all.count > limit { all = Array(all.suffix(limit)) }
            UserDefaults.standard.set(all, forKey: key)
        }
    }

    // MARK: - posting

    static func check(readings: [InstanceReading], todayTotal: Double, settings: NotificationSettings) {
        guard settings.enabled else { return }
        let notified = NotificationLog.keys()
        let alerts = pending(readings: readings, todayTotal: todayTotal,
                             settings: settings, notified: notified)
        guard !alerts.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { current in
            if current.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    post(alerts, center: center)
                }
            } else if current.authorizationStatus == .authorized {
                post(alerts, center: center)
            }
        }
    }

    /// One-shot `meter --test-notify`, so authorization can be granted on demand.
    /// Prints what macOS reports, because a silent failure here is indistinguishable
    /// from a threshold that never fired.
    static func sendTest() {
        let center = UNUserNotificationCenter.current()
        func report(_ status: UNAuthorizationStatus, _ granted: Bool, _ error: Error?) {
            if let error { print("request failed: \(error.localizedDescription)") }
            let name = switch status {
            case .notDetermined: "not determined"
            case .denied: "denied"
            case .authorized: "authorized"
            case .provisional: "provisional"
            case .ephemeral: "ephemeral"
            @unknown default: "unknown"
            }
            print("authorization: \(name)")
            guard granted else {
                print("enable meter in System Settings → Notifications, then run this again")
                exit(1)
            }
            let content = UNMutableNotificationContent()
            content.title = "meter notifications are on"
            content.body = "You'll hear about quota crossings and spend thresholds."
            center.add(UNNotificationRequest(identifier: "meter-test-\(UUID().uuidString)",
                                             content: content, trigger: nil)) { error in
                if let error { print("post failed: \(error.localizedDescription)") }
                else { print("test notification sent") }
                exit(error == nil ? 0 : 1)
            }
        }
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    report(settings.authorizationStatus, granted, error)
                }
            } else {
                report(settings.authorizationStatus,
                       settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
                       nil)
            }
        }
    }

    private static func post(_ alerts: [Alert], center: UNUserNotificationCenter) {
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
            NotificationLog.add([alert.id])
        }
    }
}
