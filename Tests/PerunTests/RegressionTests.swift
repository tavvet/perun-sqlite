import XCTest
import Foundation
@testable import PerunSQLite

/// Regression tests for the issues found in the full code review.
final class RegressionTests: XCTestCase {
    // E — an empty [UInt8] must bind as a zero-length BLOB, not SQL NULL.
    func testEmptyBlobBindsAsEmptyBlobNotNull() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        try await conn.query("CREATE TABLE t (b BLOB)")
        try await conn.query("INSERT INTO t (b) VALUES (?)", [[UInt8]()])

        let row = try await conn.query("SELECT b, typeof(b) AS ty FROM t").first!
        XCTAssertFalse(row["b"]!.isNull)
        XCTAssertEqual(row["b"]!.value.storageClass, .blob)
        XCTAssertEqual(try row.decode("b", as: [UInt8].self), [])
        XCTAssertEqual(try row.decode("ty", as: String.self), "blob")
    }

    // F — single-statement APIs reject SQL that contains more than one statement.
    func testMultipleStatementsRejected() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        try await conn.query("CREATE TABLE t (v INTEGER)")

        do {
            try await conn.query("INSERT INTO t VALUES (1); INSERT INTO t VALUES (2)", [])
            XCTFail("expected multipleStatements")
        } catch let error as PerunError {
            XCTAssertEqual(error, .multipleStatements)          // uses new Equatable conformance
        }
        do {
            _ = try await conn.prepare("SELECT 1; SELECT 2")
            XCTFail("expected multipleStatements")
        } catch let error as PerunError {
            XCTAssertEqual(error, .multipleStatements)
        }
        do {
            _ = try await conn.queryStream("SELECT 1; SELECT 2")
            XCTFail("expected multipleStatements")
        } catch let error as PerunError {
            XCTAssertEqual(error, .multipleStatements)
        }

        // The rejected statements did not run.
        let n = try await conn.query("SELECT count(*) AS n FROM t").first!.decode("n", as: Int.self)
        XCTAssertEqual(n, 0)

        // A trailing comment / whitespace is not a second statement — still fine.
        let ok = try await conn.query("SELECT 1 AS v; -- trailing comment\n", []).first!
            .decode("v", as: Int.self)
        XCTAssertEqual(ok, 1)
    }

    // API — the `.uri` factory sets URI filenames, enabling a shared-cache in-memory database.
    func testURIFactory() async throws {
        let config = SQLiteConfiguration.uri("file::memory:?cache=shared")
        XCTAssertTrue(config.enableURIFilenames)
        XCTAssertEqual(config.path, "file::memory:?cache=shared")

        // A shared-cache in-memory DB is visible across connections opened with the same URI, as
        // long as one stays open. Drive it sequentially through a pool.
        let pool = SQLiteClient(configuration: config, maxConnections: 3)
        try await pool.withConnection { keepAlive in
            try await keepAlive.query("CREATE TABLE t (v INTEGER)")
            try await pool.query("INSERT INTO t VALUES (1)")   // a different pooled connection
            try await pool.query("INSERT INTO t VALUES (2)")
            let n = try await pool.query("SELECT count(*) AS n FROM t").first!.decode("n", as: Int.self)
            XCTAssertEqual(n, 2)
        }
        await pool.shutdown()
    }

    // C — a connection dropped without close() must clean up (deinit safety net); the database
    // stays consistent and reusable.
    func testConnectionDroppedWithoutCloseStaysConsistent() async throws {
        let path = NSTemporaryDirectory() + "perun-deinit-\(UUID().uuidString).db"
        defer { for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        } }

        do {
            let conn = try await SQLiteConnection.connect(.file(path))
            try await conn.query("CREATE TABLE t (v INTEGER)")
            try await conn.query("INSERT INTO t VALUES (42)")
            _ = conn   // dropped here without close() — deinit must finalize + close the handle
        }

        let reopened = try await SQLiteConnection.connect(.file(path))
        let value = try await reopened.query("SELECT v FROM t").first!.decode("v", as: Int.self)
        XCTAssertEqual(value, 42)
        try await reopened.close()
    }

    // Date parser accepts external forms SQLite's own datetime() can produce.
    func testDateParserAcceptsExternalForms() throws {
        func seconds(_ text: String) throws -> Double {
            try Date.decode(from: .text(text)).timeIntervalSince1970
        }
        // HH:MM without seconds == HH:MM:SS.
        XCTAssertEqual(try seconds("2025-07-09 12:30"),
                       try seconds("2025-07-09 12:30:00"), accuracy: 0.0005)
        // Compact offset ±HHMM == ±HH:MM, and the offset is actually applied.
        XCTAssertEqual(try seconds("2025-07-09 12:00:00+0530"),
                       try seconds("2025-07-09 12:00:00+05:30"), accuracy: 0.0005)
        XCTAssertEqual(try seconds("2025-07-09 12:00:00+0530"),
                       try seconds("2025-07-09 06:30:00Z"), accuracy: 0.0005)
        // More than 9 fractional digits: excess ignored, not rejected.
        XCTAssertEqual(try seconds("2025-07-09 12:00:00.123456789123"),
                       try seconds("2025-07-09 12:00:00.123456789"), accuracy: 0.0005)
    }

    // rowsAffected is 0 for a read-only statement (SELECT), but correct for INSERT … RETURNING.
    func testRowsAffectedReadonlyVsReturning() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        try await conn.query("CREATE TABLE t (v INTEGER)")

        let insert = try await conn.query("INSERT INTO t VALUES (?), (?), (?)", [1, 2, 3])
        XCTAssertEqual(insert.rowsAffected, 3)

        let select = try await conn.query("SELECT * FROM t")
        XCTAssertEqual(select.rowsAffected, 0)          // was reporting the prior INSERT's 3

        let returning = try await conn.query("INSERT INTO t VALUES (99) RETURNING v")
        XCTAssertEqual(returning.rowsAffected, 1)       // RETURNING is not read-only
        XCTAssertEqual(try returning.first?.decode("v", as: Int.self), 99)
    }

    // A nested withTransaction fails (SQLite has no nested transactions) but leaves the outer
    // transaction usable — its context is saved and restored.
    func testNestedTransactionLeavesOuterUsable() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        try await conn.query("CREATE TABLE t (v INTEGER)")

        try await conn.withTransaction { tx in
            try await tx.query("INSERT INTO t VALUES (1)")
            do {
                try await conn.withTransaction { inner in
                    try await inner.query("INSERT INTO t VALUES (2)")
                }
                XCTFail("a nested transaction should fail")
            } catch {
                // expected: SQLite rejects a transaction within a transaction
            }
            try await tx.query("INSERT INTO t VALUES (3)")   // outer still works after the nested failure
        }

        let values = try await conn.query("SELECT v FROM t ORDER BY v").rows
            .map { try $0.decode("v", as: Int.self) }
        XCTAssertEqual(values, [1, 3])
    }

    // Result types are Equatable.
    func testResultTypesEquatable() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        try await conn.query("CREATE TABLE t (v INTEGER, name TEXT)")
        try await conn.query("INSERT INTO t VALUES (1, 'a')")

        let a = try await conn.query("SELECT v, name FROM t")
        let b = try await conn.query("SELECT v, name FROM t")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.first, b.first)
        XCTAssertEqual(a.columns, b.columns)
        XCTAssertEqual(a.first?["v"], b.first?["v"])
    }
}
