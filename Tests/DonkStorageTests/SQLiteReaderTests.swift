import SQLite3
import XCTest
@testable import DonkStorage

final class SQLiteReaderTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("donk-sqlite-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("test.sqlite")
        try createDatabase()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testHeaderDetection() throws {
        let header = FileKind.readHeader(databaseURL, length: 100)
        XCTAssertTrue(SQLiteReader.isSQLiteHeader(header))
        XCTAssertEqual(FileKind.detect(url: databaseURL), .sqlite)
        let renamed = directory.appendingPathComponent("no-extension")
        try FileManager.default.copyItem(at: databaseURL, to: renamed)
        XCTAssertEqual(FileKind.detect(url: renamed), .sqlite)
    }

    func testTablesWithRowCounts() throws {
        let reader = try SQLiteReader(url: databaseURL)
        let tables = try reader.tables()
        XCTAssertEqual(tables.map(\.name), ["notes", "recent_users", "users"])
        XCTAssertEqual(tables.first { $0.name == "users" }?.rowCount, 500)
        XCTAssertEqual(tables.first { $0.name == "notes" }?.rowCount, 3)
        XCTAssertEqual(tables.first { $0.name == "recent_users" }?.kind, .view)
        XCTAssertEqual(tables.first { $0.name == "recent_users" }?.rowCount, 10)
    }

    func testColumnsAndPaging() throws {
        let reader = try SQLiteReader(url: databaseURL)
        let columns = try reader.columns(of: "users")
        XCTAssertEqual(columns.map(\.name), ["id", "name", "score", "avatar", "note"])
        XCTAssertEqual(columns.first?.isPrimaryKey, true)
        XCTAssertEqual(columns[1].declaredType, "TEXT")
        XCTAssertEqual(columns[1].isNotNull, true)

        let first = try reader.rows(of: "users", limit: SQLiteReader.pageSize, offset: 0)
        XCTAssertEqual(first.count, 200)
        XCTAssertEqual(first.first?.id, 0)
        XCTAssertEqual(first.first?.values[0], .integer(1))
        XCTAssertEqual(first.first?.values[1], .text("user 1"))
        XCTAssertEqual(first.first?.values[2], .real(0.5))
        XCTAssertEqual(first.first?.values[3], .blob(Data([0xCA, 0xFE])))
        XCTAssertEqual(first.first?.values[4], .null)

        let last = try reader.rows(of: "users", limit: SQLiteReader.pageSize, offset: 400)
        XCTAssertEqual(last.count, 100)
        XCTAssertEqual(last.first?.id, 400)
        XCTAssertEqual(last.last?.values[0], .integer(500))
        XCTAssertTrue(try reader.rows(of: "users", limit: 200, offset: 500).isEmpty)
        XCTAssertEqual(try reader.columnNames(ofQuery: "recent_users"), ["id", "name"])
    }

    func testValueFormattingAndQuoting() {
        XCTAssertEqual(SQLiteReader.quoted("we\"ird"), "\"we\"\"ird\"")
        XCTAssertEqual(SQLiteValue.null.displayText, "NULL")
        XCTAssertEqual(SQLiteValue.blob(Data([1, 2, 3])).displayText, "BLOB · 3 bytes")
        XCTAssertEqual(SQLiteValue.text("a\"b").jsonFragment, "\"a\\\"b\"")
    }

    func testOpeningMissingFileFails() {
        XCTAssertThrowsError(try SQLiteReader(url: directory.appendingPathComponent("missing.db")))
    }

    func testReaderIsReadOnly() throws {
        let reader = try SQLiteReader(url: databaseURL)
        XCTAssertEqual(try reader.rowCount(of: "notes"), 3)
        let before = try Data(contentsOf: databaseURL)
        _ = try reader.rows(of: "notes")
        XCTAssertEqual(try Data(contentsOf: databaseURL), before)
    }

    private func createDatabase() throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw XCTSkip("Could not create a SQLite database")
        }
        defer { sqlite3_close(database) }
        func exec(_ sql: String) throws {
            var message: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(database, sql, nil, nil, &message) != SQLITE_OK {
                let text = message.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(message)
                XCTFail(text)
            }
        }
        try exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL, avatar BLOB, note TEXT)")
        try exec("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)")
        try exec("BEGIN")
        for index in 1...500 {
            try exec("INSERT INTO users (id, name, score, avatar, note) VALUES (\(index), 'user \(index)', \(Double(index) * 0.5), x'CAFE', NULL)")
        }
        try exec("COMMIT")
        try exec("INSERT INTO notes (body) VALUES ('one'), ('two'), ('three')")
        try exec("CREATE VIEW recent_users AS SELECT id, name FROM users ORDER BY id DESC LIMIT 10")
    }
}
