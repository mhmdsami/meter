import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Durable day-to-day usage. The scans are the backfill mechanism; this is the
/// source of truth once written, so pruned logs stop rewriting the past.
final class Ledger {
    static let shared = Ledger(url: Ledger.defaultURL)

    private var handle: OpaquePointer?
    private let url: URL
    private let lock = NSLock()

    /// ~/.local/share/meter/usage.db — user data, not disposable cache.
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/meter/usage.db")
    }

    init(url: URL) {
        self.url = url
        let path = url.path
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return
        }
        handle = db
        // WAL so the app and a dashboard render never block each other
        exec("PRAGMA journal_mode=WAL")
        exec("""
            CREATE TABLE IF NOT EXISTS daily (
                day TEXT NOT NULL,
                provider TEXT NOT NULL,
                account TEXT NOT NULL DEFAULT '',
                spent REAL NOT NULL DEFAULT 0,
                source TEXT NOT NULL DEFAULT 'estimated',
                pricing_gen TEXT NOT NULL DEFAULT '',
                final INTEGER NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (day, provider)
            )
            """)
        exec("""
            CREATE TABLE IF NOT EXISTS quota_snapshots (
                captured_at TEXT NOT NULL,
                provider TEXT NOT NULL,
                window_id TEXT NOT NULL,
                used_percent REAL,
                resets_at TEXT,
                PRIMARY KEY (captured_at, provider, window_id)
            )
            """)
        exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
    }

    deinit { sqlite3_close(handle) }

    // MARK: - writes

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Upsert one day's spend. Idempotent: a refresh can never double-count.
    func record(day: String, provider: String, account: String, spent: Double,
                source: String, pricingGen: String, final: Bool) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO daily (day, provider, account, spent, source, pricing_gen, final, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(day, provider) DO UPDATE SET
                account = excluded.account,
                spent = excluded.spent,
                source = excluded.source,
                pricing_gen = excluded.pricing_gen,
                final = max(daily.final, excluded.final),
                updated_at = excluded.updated_at
            """
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let now = ISO8601DateFormatter().string(from: Date())
        sqlite3_bind_text(stmt, 1, day, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, provider, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 3, account, -1, sqliteTransient)
        sqlite3_bind_double(stmt, 4, spent)
        sqlite3_bind_text(stmt, 5, source, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 6, pricingGen, -1, sqliteTransient)
        sqlite3_bind_int(stmt, 7, final ? 1 : 0)
        sqlite3_bind_text(stmt, 8, now, -1, sqliteTransient)
        sqlite3_step(stmt)
    }

    func recordSnapshot(provider: String, windowID: String, usedPercent: Double?, resetsAt: Date?) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = """
            INSERT OR IGNORE INTO quota_snapshots
                (captured_at, provider, window_id, used_percent, resets_at)
            VALUES (?, ?, ?, ?, ?)
            """
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let now = ISO8601DateFormatter().string(from: Date())
        sqlite3_bind_text(stmt, 1, now, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, provider, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 3, windowID, -1, sqliteTransient)
        if let usedPercent {
            sqlite3_bind_double(stmt, 4, usedPercent)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        if let resetsAt {
            sqlite3_bind_text(stmt, 5, ISO8601DateFormatter().string(from: resetsAt), -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_step(stmt)
    }

    func meta(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT value FROM meta WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    func setMeta(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle,
                                 "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                                 -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, value, -1, sqliteTransient)
        sqlite3_step(stmt)
    }

    /// Record per-day totals from the scans. `daily` is indexed 0 = today;
    /// only days with spend are stored, and days before today are marked final
    /// so later price-table changes cannot rewrite them.
    func recordDaily(_ daily: [String: [Double]], targetNames: [String: String],
                     pricingGen: Date, reported: Set<String>) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        for (provider, values) in daily {
            for (offset, spent) in values.enumerated() where spent > 0.004 {
                guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
                record(day: fmt.string(from: day),
                       provider: provider,
                       account: targetNames[provider] ?? "",
                       spent: spent,
                       source: reported.contains(provider) ? "reported" : "estimated",
                       pricingGen: ISO8601DateFormatter().string(from: pricingGen),
                       final: offset > 0)
            }
        }
    }

    /// Quota snapshots feed pace/run-out estimates later; one row per window per
    /// capture, deduped by timestamp.
    func recordQuotaSnapshots(_ readings: [InstanceReading]) {
        for reading in readings where reading.error == nil {
            for window in reading.windows {
                recordSnapshot(provider: reading.type,
                               windowID: window.id,
                               usedPercent: window.usedPercent,
                               resetsAt: window.resetsAt)
            }
        }
    }

    struct Pace {
        let provider: String
        let window: String
        let usedPercent: Double
        let perHour: Double
        let outHours: Double?
    }

    /// Burn rate per window from recent snapshots — the run-out estimate the
    /// menu deliberately does not show (pace belongs in the dashboard).
    func pace(hours: Int = 6) -> [Pace] {
        let db = ReadOnlyDB(path: url.path)
        guard let db else { return [] }
        let iso = ISO8601DateFormatter()
        guard let cutoff = Calendar.current.date(byAdding: .hour, value: -hours, to: Date()) else { return [] }
        let rows = db.rows("""
            SELECT provider, window_id, captured_at, used_percent FROM quota_snapshots
            WHERE captured_at >= '\(iso.string(from: cutoff))' AND used_percent IS NOT NULL
            ORDER BY captured_at
            """)
        struct Sample { let at: Date; let pct: Double }
        var byKey: [String: [Sample]] = [:]
        for row in rows {
            guard let provider = ReadOnlyDB.text(row["provider"]),
                  let window = ReadOnlyDB.text(row["window_id"]),
                  let atText = ReadOnlyDB.text(row["captured_at"]),
                  let at = iso.date(from: atText),
                  let pct = ReadOnlyDB.num(row["used_percent"]) else { continue }
            byKey[provider + "|" + window, default: []].append(Sample(at: at, pct: pct))
        }
        return byKey.compactMap { key, samples -> Pace? in
            guard let first = samples.first, let last = samples.last else { return nil }
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let hoursElapsed = last.at.timeIntervalSince(first.at) / 3600
            guard hoursElapsed >= 0.05 else { return nil }
            let rate = (last.pct - first.pct) / hoursElapsed
            let out = rate > 0.5 ? (100 - last.pct) / rate : nil
            return Pace(provider: parts[0], window: parts.count > 1 ? parts[1] : "",
                        usedPercent: last.pct, perHour: rate, outHours: out)
        }.sorted { $0.provider < $1.provider }
    }

    // MARK: - reads

    struct DayRow {        let day: String
        let provider: String
        let account: String
        let spent: Double
        let source: String
        let final: Bool
    }

    func days(from: String, to: String) -> [DayRow] {
        let db = ReadOnlyDB(path: url.path)
        guard let db else { return [] }
        return db.rows("""
            SELECT day, provider, account, spent, source, final FROM daily
            WHERE day >= '\(from)' AND day <= '\(to)'
            ORDER BY day, provider
            """).compactMap { row in
            guard let day = ReadOnlyDB.text(row["day"]),
                  let provider = ReadOnlyDB.text(row["provider"]),
                  let spent = ReadOnlyDB.num(row["spent"]) else { return nil }
            return DayRow(day: day,
                          provider: provider,
                          account: ReadOnlyDB.text(row["account"]) ?? "",
                          spent: spent,
                          source: ReadOnlyDB.text(row["source"]) ?? "estimated",
                          final: (ReadOnlyDB.num(row["final"]) ?? 0) == 1)
        }
    }
}
