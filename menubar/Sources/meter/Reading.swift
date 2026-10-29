import Foundation

struct UsageWindow: Identifiable, Codable {
    let id: String
    let label: String
    var usedPercent: Double?
    var resetsAt: Date?
    var note: String?

    var resetsIn: String? {
        guard let resetsAt else { return nil }
        let secs = Int(resetsAt.timeIntervalSinceNow.rounded())
        if secs <= 0 { return "now" }
        let h = secs / 3600, m = (secs % 3600) / 60
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    var barColor: BarColor {
        switch usedPercent {
        case .some(let p) where p >= 85: return .red
        case .some(let p) where p >= 60: return .orange
        default: return .green
        }
    }
}

enum BarColor {
    case green, orange, red
}

struct InstanceReading: Identifiable, Codable {
    let id: String
    let type: String
    let name: String
    var windows: [UsageWindow] = []
    var balanceNote: String?
    var spendToday: Double?
    var error: String?
    var fetchedAt: Date = Date()
}

extension Array where Element == InstanceReading {
    var totalToday: Double { reduce(0) { $0 + ($1.spendToday ?? 0) } }
}
