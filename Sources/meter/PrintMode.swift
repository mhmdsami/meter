import Foundation

enum PrintMode {
    /// One-shot CLI modes; any of these skips the menu bar app entirely.
    static var requested: Bool {
        CommandLine.arguments.contains { ["--print", "--json", "--dashboard"].contains($0) }
    }

    static func runAndExit() -> Never {
        let args = CommandLine.arguments
        let json = args.contains("--json")
        let dashboard = args.contains("--dashboard")
        Task.detached {
            if dashboard {
                Dashboard.writeAndOpen(days: intArg("--days") ?? 90)
                exit(0)
            }
            let config = ConfigStore.load()
            let types = Set(config.providers.filter(\.enabled).map(\.type))
            let daily = await CostScan.dailyTotals(days: 30, types: types, pricing: await Pricing.load())
            var readings = await Providers.fetchAll(config.providers)
            readings = Providers.attachLocalCosts(
                readings, enabled: config.providers.filter(\.enabled),
                today: daily.mapValues { $0.first ?? 0 })
            let history = Store.historyLines(daily)
            print(json ? encode(config: config, readings: readings, history: history)
                       : render(config: config, readings: readings))
            exit(0)
        }
        // block until the task above terminates the process
        dispatchMain()
    }

    private static func intArg(_ name: String) -> Int? {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
        return Int(args[idx + 1])
    }

    static func render(config: Config, readings: [InstanceReading]) -> String {
        var lines: [String] = []
        if let err = config.configError { lines.append("!! \(err)") }
        let today = readings.totalToday
        lines.append(String(format: "today $%.2f", today))
        for r in readings {
            var head = "\(r.name) [\(r.type)]"
            if let spend = r.spendToday { head += String(format: "  $%.2f today", spend) }
            if let bal = r.balanceNote { head += "  \(bal)" }
            lines.append(head)
            if let err = r.error { lines.append("   !! \(err)") }
            for w in r.windows {
                let pct = w.usedPercent.map { String(format: "%.0f%%", $0) } ?? (w.note ?? "—")
                let reset = w.resetsIn.map { " (\($0))" } ?? ""
                lines.append("   \(w.label.padding(toLength: 9, withPad: " ", startingAt: 0)) \(pct)\(reset)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Machine-readable snapshot for scripts and the dashboard.
    static func encode(config: Config, readings: [InstanceReading], history: [Store.HistoryLine]) -> String {
        let iso = ISO8601DateFormatter()
        var root: [String: Any] = [
            "generated_at": iso.string(from: Date()),
            "today_total": readings.totalToday,
        ]
        if let err = config.configError { root["config_error"] = err }
        root["instances"] = readings.map { r -> [String: Any] in
            var out: [String: Any] = ["name": r.name, "type": r.type]
            if let spend = r.spendToday { out["spend_today"] = spend }
            if let bal = r.balanceNote { out["balance_note"] = bal }
            if let err = r.error { out["error"] = err }
            out["windows"] = r.windows.map { w -> [String: Any] in
                var win: [String: Any] = ["id": w.id, "label": w.label]
                if let pct = w.usedPercent { win["used_percent"] = pct }
                if let reset = w.resetsAt { win["resets_at"] = iso.string(from: reset) }
                if let note = w.note { win["note"] = note }
                return win
            }
            return out
        }
        root["history"] = history.map {
            ["id": $0.id, "label": $0.label, "total": $0.total, "spark": $0.spark]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root,
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
