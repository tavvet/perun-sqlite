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
}
