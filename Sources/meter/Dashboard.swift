import Foundation

/// Self-contained HTML dashboard rendered from the ledger: no CDN, no server,
/// works offline. Opened in the default browser.
enum Dashboard {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/meter/dashboard.html")
    }

    static func writeAndOpen(days: Int) {
        let html = render(days: days)
        let url = defaultURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? html.data(using: .utf8)?.write(to: url, options: .atomic)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [url.path]
        try? proc.run()
    }

    static func render(days: Int, ledger: Ledger = .shared, now: Date = Date()) -> String {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let today = cal.startOfDay(for: now)
        let from = fmt.string(from: cal.date(byAdding: .day, value: -(days - 1), to: today)!)

        let rows = ledger.days(from: from, to: fmt.string(from: today))
        var byDay: [String: [String: Double]] = [:]
        var providers = Set<String>()
        for row in rows {
            byDay[row.day, default: [:]][row.provider] = row.spent
            providers.insert(row.provider)
        }

        // continuous day axis, oldest first
        var axis: [String] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            axis.append(fmt.string(from: d))
        }

        let ordered = providers.sorted()
        let totalsByProv = ordered.map { p in (p, rows.filter { $0.provider == p }.reduce(0) { $0 + $1.spent }) }
        let grand = totalsByProv.reduce(0) { $0 + $1.1 }
        func window(_ n: Int) -> Double {
            rows.filter { row in
                guard let d = fmt.date(from: row.day) else { return false }
                return cal.dateComponents([.day], from: d, to: today).day ?? Int.max < n
            }.reduce(0) { $0 + $1.spent }
        }
        let colors = ["#5b8def", "#e0705f", "#5fbf8f", "#c98be0", "#e0b35f", "#7fd0e0", "#b0b0b0"]

        var bars = ""
        for day in axis {
            let dayTotals = byDay[day] ?? [:]
            let total = dayTotals.values.reduce(0, +)
            bars += "<div class=\"col\" title=\"\(day) · $\(fmt2(total))\">"
            for (i, p) in ordered.enumerated() {
                let v = dayTotals[p] ?? 0
                guard v > 0 else { continue }
                bars += "<div class=\"seg\" style=\"height:\(pct(v, grand))%;background:\(colors[i % colors.count])\"></div>"
            }
            bars += "</div>"
        }

        var legend = ""
        for (i, entry) in totalsByProv.enumerated() {
            legend += "<li><span class=\"dot\" style=\"background:\(colors[i % colors.count])\"></span>"
            legend += "<b>\(entry.0)</b> $\(fmt2(entry.1)) <span class=\"muted\">(\(pctStr(entry.1, grand)))</span></li>"
        }

        var table = ""
        for day in axis.reversed() {
            let dayTotals = byDay[day] ?? [:]
            let total = dayTotals.values.reduce(0, +)
            guard total > 0 else { continue }
            let cells = ordered.map { p -> String in
                let v = dayTotals[p] ?? 0
                return "<td>\(v > 0 ? "$" + fmt2(v) : "—")</td>"
            }.joined()
            table += "<tr><td>\(day)</td>\(cells)<td class=\"num\"><b>$\(fmt2(total))</b></td></tr>"
        }
        let heads = ordered.map { "<th>\($0)</th>" }.joined()

        // burn-rate estimates from recent quota snapshots
        let paces = ledger.pace()
        var paceSection = ""
        if !paces.isEmpty {
            var rows = ""
            for pace in paces {
                let rate = pace.perHour > 0 ? String(format: "%.1f%%/h", pace.perHour)
                                            : (pace.perHour < 0 ? "cooling" : "idle")
                let out = pace.outHours.map { String(format: "%.1fh", $0) } ?? "—"
                rows += "<tr><td>\(pace.provider)</td><td>\(pace.window)</td>"
                rows += "<td class=\"num\">\(String(format: "%.0f%%", pace.usedPercent))</td>"
                rows += "<td class=\"num\">\(rate)</td><td class=\"num\">\(out)</td></tr>"
            }
            paceSection = """
            <h2 style="font-size:15px;margin:28px 0 0">Pace</h2>
            <div class="muted">Burn rate over recent refreshes; run-out is capped by the window reset.</div>
            <table><thead><tr><th>Provider</th><th>Window</th><th class="num">Used</th><th class="num">Rate</th><th class="num">Hits 100% in</th></tr></thead>
            <tbody>\(rows)</tbody></table>
            """
        }

        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>meter</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 14px -apple-system, system-ui, sans-serif; margin: 32px auto; max-width: 900px; padding: 0 16px; }
        h1 { font-size: 20px; margin: 0 0 4px; }
        .muted { opacity: .55; font-weight: 400; }
        .cards { display: flex; gap: 12px; margin: 20px 0; flex-wrap: wrap; }
        .card { border: 1px solid #8883; border-radius: 10px; padding: 12px 16px; min-width: 130px; }
        .card b { display: block; font-size: 20px; margin-top: 4px; }
        .chart { display: flex; align-items: flex-end; gap: 2px; height: 180px; margin: 24px 0; }
        .col { flex: 1; display: flex; flex-direction: column-reverse; height: 100%; }
        .seg { width: 100%; }
        ul { list-style: none; padding: 0; display: flex; gap: 18px; flex-wrap: wrap; }
        .dot { display: inline-block; width: 9px; height: 9px; border-radius: 3px; margin-right: 6px; }
        table { border-collapse: collapse; width: 100%; margin-top: 12px; }
        th, td { text-align: left; padding: 5px 8px; border-bottom: 1px solid #8882; }
        .num { text-align: right; }
        </style></head><body>
        <h1>meter</h1>
        <div class="muted">\(days) days ending \(fmt.string(from: today)) · costs are list-price estimates unless the provider reports spend</div>
        <div class="cards">
          <div class="card"><span class="muted">Today</span><b>$\(fmt2(window(1)))</b></div>
          <div class="card"><span class="muted">Last 7 days</span><b>$\(fmt2(window(7)))</b></div>
          <div class="card"><span class="muted">Last 30 days</span><b>$\(fmt2(window(30)))</b></div>
          <div class="card"><span class="muted">Last \(days) days</span><b>$\(fmt2(grand))</b></div>
        </div>
        <div class="chart">\(bars)</div>
        \(paceSection)
        <ul>\(legend)</ul>
        <table><thead><tr><th>Day</th>\(heads)<th class="num">Total</th></tr></thead>
        <tbody>\(table)</tbody></table>
        </body></html>
        """
    }

    private static func fmt2(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func pct(_ value: Double, _ total: Double) -> String {
        guard total > 0 else { return "0" }
        return String(format: "%.2f", value / total * 100)
    }

    private static func pctStr(_ value: Double, _ total: Double) -> String {
        String(format: "%.0f%%", value / max(total, 0.0001) * 100)
    }
}
