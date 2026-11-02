import Foundation
import SQLite3

public enum SQLValue: Equatable, Sendable {
    case null, int(Int64), double(Double), text(String)
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { "SQLite: " + message }
}

public struct Row {
    fileprivate var values: [String: SQLValue]
    public subscript(_ key: String) -> SQLValue { values[key] ?? .null }
    public func string(_ k: String) -> String? { if case .text(let s) = self[k] { return s }; return nil }
    public func int(_ k: String) -> Int64? {
        switch self[k] { case .int(let i): return i; case .double(let d): return Int64(d); default: return nil }
    }
    public func double(_ k: String) -> Double? {
        switch self[k] { case .double(let d): return d; case .int(let i): return Double(i); default: return nil }
    }
    public func bool(_ k: String) -> Bool { (int(k) ?? 0) != 0 }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A tiny serialised wrapper around one SQLite connection.
public final class SQLiteDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw SQLiteError(message: "cannot open \(path)")
        }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
    }

    deinit { sqlite3_close(db) }

    private var lastError: String { String(cString: sqlite3_errmsg(db)) }

    private func withStatement<T>(_ sql: String, _ args: [SQLValue], _ body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(message: "\(lastError) in: \(sql)")
        }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in args.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .double(let d): sqlite3_bind_double(stmt, idx, d)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            }
        }
        return try body(stmt)
    }

    public func execute(_ sql: String, _ args: [SQLValue] = []) throws {
        lock.lock(); defer { lock.unlock() }
        if args.isEmpty && sql.contains(";") {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? lastError
                sqlite3_free(err)
                throw SQLiteError(message: msg)
            }
            return
        }
        try withStatement(sql, args) { stmt in
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError(message: "\(lastError) in: \(sql)") }
        }
    }

    public func query(_ sql: String, _ args: [SQLValue] = []) throws -> [Row] {
        lock.lock(); defer { lock.unlock() }
        return try withStatement(sql, args) { stmt in
            var rows: [Row] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw SQLiteError(message: "\(lastError) in: \(sql)") }
                var values: [String: SQLValue] = [:]
                for c in 0..<sqlite3_column_count(stmt) {
                    let name = String(cString: sqlite3_column_name(stmt, c))
                    switch sqlite3_column_type(stmt, c) {
                    case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(stmt, c))
                    case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(stmt, c))
                    case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                    default: values[name] = .null
                    }
                }
                rows.append(Row(values: values))
            }
            return rows
        }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try execute("COMMIT")
            return r
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

extension SQLValue {
    public init(_ s: String?) { self = s.map { .text($0) } ?? .null }
    public init(_ i: Int?) { self = i.map { .int(Int64($0)) } ?? .null }
    public init(_ i: Int64?) { self = i.map { .int($0) } ?? .null }
    public init(_ d: Double?) { self = d.map { .double($0) } ?? .null }
    public init(_ b: Bool) { self = .int(b ? 1 : 0) }
    public init(_ d: Date?) { self = d.map { .int($0.ms) } ?? .null }
}
