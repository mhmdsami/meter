import Foundation
import SQLite3

/// Minimal read-only SQLite access via the system libsqlite3.
final class ReadOnlyDB {
    private var handle: OpaquePointer?

    init?(path: String) {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        handle = db
    }

    deinit { sqlite3_close(handle) }

    enum Value {
        case text(String)
        case double(Double)
        case int(Int64)
        case null
    }

    func rows(_ sql: String) -> [[String: Value]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var out: [[String: Value]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Value] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, i))
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, i))
                default: row[name] = .null
                }
            }
            out.append(row)
        }
        return out
    }

    static func num(_ v: Value?) -> Double? {
        switch v {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    static func text(_ v: Value?) -> String? {
        if case .text(let s) = v { return s }
        return nil
    }
}
