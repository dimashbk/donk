import DonkJSON
import Foundation
import SQLite3

enum SQLiteValue: Hashable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var typeName: String {
        switch self {
        case .null: return "NULL"
        case .integer: return "INTEGER"
        case .real: return "REAL"
        case .text: return "TEXT"
        case .blob: return "BLOB"
        }
    }

    var displayText: String {
        switch self {
        case .null: return "NULL"
        case let .integer(value): return "\(value)"
        case let .real(value): return "\(value)"
        case let .text(value): return value
        case let .blob(data): return "BLOB · \(data.count) bytes"
        }
    }

    var fullText: String {
        switch self {
        case let .blob(data):
            return data.isEmpty ? "BLOB · 0 bytes" : "BLOB · \(data.count) bytes\n" + HexDump.hex(data, limit: 512)
        default:
            return displayText
        }
    }

    var jsonFragment: String {
        switch self {
        case .null: return "null"
        case let .integer(value): return "\(value)"
        case let .real(value): return value.isFinite ? "\(value)" : "null"
        case let .text(value): return JSONFormatting.escape(value)
        case let .blob(data): return JSONFormatting.escape(data.base64EncodedString())
        }
    }
}

struct SQLiteColumn: Hashable, Sendable {
    let name: String
    let declaredType: String
    let isPrimaryKey: Bool
    let isNotNull: Bool
}

struct SQLiteTable: Hashable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        case table
        case view
    }

    let name: String
    let kind: Kind
    let rowCount: Int?

    var id: String { name }
}

struct SQLiteRow: Identifiable, Hashable, Sendable {
    let id: Int
    let values: [SQLiteValue]
}

struct SQLiteError: LocalizedError, Sendable {
    let code: Int32
    let message: String

    var errorDescription: String? { message }
}

final class SQLiteReader: @unchecked Sendable {
    static let pageSize = 200

    let url: URL
    private let lock = NSLock()
    private var handle: OpaquePointer?

    init(url: URL) throws {
        self.url = url
        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(status))
            sqlite3_close(database)
            throw SQLiteError(code: status, message: message)
        }
        sqlite3_busy_timeout(database, 500)
        handle = database
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    static func isSQLiteHeader(_ data: Data) -> Bool {
        data.starts(with: Array("SQLite format 3".utf8) + [0])
    }

    static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    var sqliteVersion: String {
        String(cString: sqlite3_libversion())
    }

    func tables(includeCounts: Bool = true) throws -> [SQLiteTable] {
        var found: [(String, SQLiteTable.Kind)] = []
        try query(
            "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name COLLATE NOCASE"
        ) { statement in
            let name = Self.text(statement, 0) ?? ""
            let kind = SQLiteTable.Kind(rawValue: Self.text(statement, 1) ?? "table") ?? .table
            found.append((name, kind))
        }
        return found.map { name, kind in
            SQLiteTable(name: name, kind: kind, rowCount: includeCounts ? try? rowCount(of: name) : nil)
        }
    }

    func rowCount(of table: String) throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM " + Self.quoted(table)) { statement in
            count = Int(sqlite3_column_int64(statement, 0))
        }
        return count
    }

    func columns(of table: String) throws -> [SQLiteColumn] {
        var columns: [SQLiteColumn] = []
        try query("PRAGMA table_info(" + Self.quoted(table) + ")") { statement in
            columns.append(
                SQLiteColumn(
                    name: Self.text(statement, 1) ?? "",
                    declaredType: Self.text(statement, 2) ?? "",
                    isPrimaryKey: sqlite3_column_int(statement, 5) > 0,
                    isNotNull: sqlite3_column_int(statement, 3) != 0
                )
            )
        }
        return columns
    }

    func rows(of table: String, limit: Int = SQLiteReader.pageSize, offset: Int = 0) throws -> [SQLiteRow] {
        var rows: [SQLiteRow] = []
        let sql = "SELECT * FROM " + Self.quoted(table) + " LIMIT \(max(0, limit)) OFFSET \(max(0, offset))"
        try query(sql) { statement in
            let count = sqlite3_column_count(statement)
            var values: [SQLiteValue] = []
            values.reserveCapacity(Int(count))
            for index in 0..<count {
                values.append(Self.value(statement, index))
            }
            rows.append(SQLiteRow(id: offset + rows.count, values: values))
        }
        return rows
    }

    func columnNames(ofQuery table: String) throws -> [String] {
        try withHandle { database in
            var statement: OpaquePointer?
            let sql = "SELECT * FROM " + Self.quoted(table) + " LIMIT 0"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.error(database)
            }
            defer { sqlite3_finalize(statement) }
            return (0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_name(statement, index).map { String(cString: $0) } ?? "column \(index)"
            }
        }
    }

    // MARK: - Private

    private func withHandle<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "Database is closed") }
        return try body(handle)
    }

    private func query(_ sql: String, row: (OpaquePointer) throws -> Void) throws {
        try withHandle { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.error(database)
            }
            defer { sqlite3_finalize(statement) }
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_ROW {
                    try row(statement)
                } else if status == SQLITE_DONE {
                    break
                } else {
                    throw Self.error(database)
                }
            }
        }
    }

    private static func error(_ database: OpaquePointer) -> SQLiteError {
        SQLiteError(code: sqlite3_errcode(database), message: String(cString: sqlite3_errmsg(database)))
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, index))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    private static func value(_ statement: OpaquePointer, _ index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            return .text(text(statement, index) ?? "")
        case SQLITE_BLOB:
            let length = Int(sqlite3_column_bytes(statement, index))
            guard length > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: length))
        default:
            return .null
        }
    }
}
