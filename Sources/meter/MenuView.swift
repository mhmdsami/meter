import SwiftUI

struct MenuContent: View {
    @ObservedObject var store = Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let err = store.config.configError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(store.readings) { Row($0) }
                if store.readings.isEmpty {
                    Text("no providers enabled — open config").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !store.history.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.history) { line in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(line.label).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(line.total).font(.caption).monospacedDigit()
                            }
                            HStack(alignment: .bottom, spacing: 2) {
                                ForEach(line.spark.indices, id: \.self) { i in
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.primary.opacity(0.3))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: max(2, line.spark[i] * 22))
                                }
                            }
                            .frame(height: 22, alignment: .bottom)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Refresh") { Task { await Store.shared.refreshAll(force: true) } }
                Spacer()
                Button("Config") { NSWorkspace.shared.open(ConfigStore.url) }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            if let d = store.lastRefresh {
                Text("updated \(d.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}

private struct Row: View {
    let reading: InstanceReading

    init(_ reading: InstanceReading) { self.reading = reading }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(reading.name).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let balance = reading.balanceNote {
                    Text(balance).font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
                if let spend = reading.spendToday {
                    Text(String(format: "$%.2f", spend)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let err = reading.error {
                Text(err).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            ForEach(reading.windows) { win in
                HStack(spacing: 6) {
                    Text(win.label).font(.caption2).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    ProgressView(value: (win.usedPercent ?? 0) / 100)
                        .tint(win.barColor.color)
                        .frame(width: 110)
                    Text(win.percentText).font(.caption2).monospacedDigit().frame(width: 38, alignment: .trailing)
                    Spacer()
                    Text(win.resetsIn ?? "").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

}

extension BarColor {
    var color: Color {
        switch self {
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        }
    }
}

extension UsageWindow {
    var percentText: String {
        guard let p = usedPercent else { return note ?? "—" }
        return String(format: "%.0f%%", p)
    }
}
