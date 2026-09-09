import Foundation

enum PrintMode {
    static func runAndExit() -> Never {
        Task.detached {
            let config = ConfigStore.load()
            let types = Set(config.providers.filter(\.enabled).map(\.type))
            let daily = await CostScan.dailyTotals(days: 1, types: types, pricing: await Pricing.load())
            var readings = await Providers.fetchAll(config.providers)
            readings = Providers.attachLocalCosts(
                readings, enabled: config.providers.filter(\.enabled),
                today: daily.mapValues { $0.first ?? 0 })
            print(render(config: config, readings: readings))
            exit(0)
        }
        // block until the task above terminates the process
        dispatchMain()
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
}
