import Foundation
import SQLite3

/// Minimal, dependency-free wrapper over the system SQLite3 already present on macOS.
/// Deliberately tiny: open, exec, prepared statements, transactions. Nothing else.
public final class SQLiteDatabase {

    public struct Error: Swift.Error, CustomStringConvertible {
        public let code: Int32
        public let message: String
        public var description: String { "sqlite error \(code): \(message)" }
    }

    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let db { sqlite3_close_v2(db) }
            throw Error(code: rc, message: msg)
        }
        handle = db
        sqlite3_busy_timeout(db, 3000)
        // WAL keeps readers (the widget, the local API) from blocking the UI writer.
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try exec("PRAGMA temp_store=MEMORY;")
    }

    deinit { if let handle { sqlite3_close_v2(handle) } }

    public func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    private func fail(_ rc: Int32) -> Error {
        Error(code: rc, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database")
    }

    public func exec(_ sql: String) throws {
        guard let handle else { throw Error(code: SQLITE_MISUSE, message: "database closed") }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw Error(code: rc, message: message)
        }
    }

    public var userVersion: Int32 {
        get {
            var v: Int32 = 0
            try? query("PRAGMA user_version;") { v = $0.int(0) }
            return v
        }
        set { try? exec("PRAGMA user_version=\(newValue);") }
    }

    // MARK: Statements

    public final class Row {
        fileprivate let stmt: OpaquePointer
        fileprivate init(_ stmt: OpaquePointer) { self.stmt = stmt }

        public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
        public func int(_ i: Int32) -> Int32 { sqlite3_column_int(stmt, i) }
        public func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        public func doubleOrNil(_ i: Int32) -> Double? { isNull(i) ? nil : sqlite3_column_double(stmt, i) }
        public func string(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: c)
        }
        public func stringOrNil(_ i: Int32) -> String? { isNull(i) ? nil : string(i) }
        public func blobOrNil(_ i: Int32) -> Data? {
            guard !isNull(i), let bytes = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }

    public enum Value {
        case null
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)

        public static func date(_ d: Date?) -> Value { d.map { .double($0.timeIntervalSince1970) } ?? .null }
    }

    /// Runs a query, calling `row` for each result row.
    public func query(_ sql: String, _ binds: [Value] = [], row: (Row) -> Void) throws {
        guard let handle else { throw Error(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw fail(rc) }
        defer { sqlite3_finalize(stmt) }
        try bind(binds, to: stmt)
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW { row(Row(stmt)) }
            else if step == SQLITE_DONE { break }
            else { throw fail(step) }
        }
    }

    @discardableResult
    public func run(_ sql: String, _ binds: [Value] = []) throws -> Int32 {
        guard let handle else { throw Error(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw fail(rc) }
        defer { sqlite3_finalize(stmt) }
        try bind(binds, to: stmt)
        let step = sqlite3_step(stmt)
        guard step == SQLITE_DONE || step == SQLITE_ROW else { throw fail(step) }
        return sqlite3_changes(handle)
    }

    private func bind(_ values: [Value], to stmt: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let i = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(stmt, i)
            case .int(let v): rc = sqlite3_bind_int64(stmt, i, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, i, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, i, v, -1, transient)
            case .blob(let v):
                rc = v.isEmpty
                    ? sqlite3_bind_zeroblob(stmt, i, 0)
                    : v.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32(v.count), transient) }
            }
            if rc != SQLITE_OK { throw fail(rc) }
        }
    }

    /// Single write transaction. Rolls back on any thrown error.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try exec("COMMIT;")
            return result
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }
}
