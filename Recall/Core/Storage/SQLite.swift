import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteError: Error, LocalizedError {
    case open(String)
    case prepare(String)
    case step(String)
    case execute(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): "Could not open the local database: \(message)"
        case .prepare(let message): "Could not prepare a database query: \(message)"
        case .step(let message): "Could not read from the local database: \(message)"
        case .execute(let message): "Could not write to the local database: \(message)"
        }
    }
}

/// A deliberately small SQLite layer. Recall owns its schema, its migrations
/// and its FTS5 queries; hiding them behind a heavy ORM would only make the
/// search path slower and harder to reason about.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let path: String

    init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw SQLiteError.open(message)
        }
        sqlite3_busy_timeout(handle, 1_500)
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA temp_store = MEMORY;")
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw SQLiteError.execute(message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        return SQLiteStatement(statement: statement, database: self)
    }

    func lastInsertedRowID() -> Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    var errorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }

    static func memoryPath() -> String { ":memory:" }
}

final class SQLiteStatement {
    private let statement: OpaquePointer
    private unowned let database: SQLiteDatabase

    init(statement: OpaquePointer, database: SQLiteDatabase) {
        self.statement = statement
        self.database = database
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func bind(_ value: String?, at index: Int32) {
        if let value {
            _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bind(_ value: Int64, at index: Int32) {
        sqlite3_bind_int64(statement, index, value)
    }

    func bind(_ value: Int, at index: Int32) {
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    func bind(_ value: Double, at index: Int32) {
        sqlite3_bind_double(statement, index, value)
    }

    func bind(_ value: Bool, at index: Int32) {
        sqlite3_bind_int(statement, index, value ? 1 : 0)
    }

    func bind(_ value: Data, at index: Int32) {
        _ = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
        }
    }

    @discardableResult
    func step() throws -> Bool {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError.step(database.errorMessage)
        }
    }

    func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    func text(at index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    func optionalText(at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return text(at: index)
    }

    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func int(at index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func bool(at index: Int32) -> Bool {
        sqlite3_column_int(statement, index) == 1
    }

    func data(at index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return Data() }
        return Data(bytes: pointer, count: count)
    }
}
