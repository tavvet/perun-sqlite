import XCTest
@testable import PerunSQLite

final class ConnectionTests: XCTestCase {
    private func openMemory() async throws -> SQLiteConnection {
        try await SQLiteConnection.connect(.memory())
    }

    func testCreateInsertSelect() async throws {
        let conn = try await openMemory()
        defer { Task { try? await conn.close() } }

        try await conn.query("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, score REAL)")
        let insert = try await conn.query(
            "INSERT INTO users (name, score) VALUES (?, ?)", ["Alice", 4.5])
        XCTAssertEqual(insert.rowsAffected, 1)
        XCTAssertEqual(insert.lastInsertRowID, 1)

        _ = try await conn.query("INSERT INTO users (name, score) VALUES (?, ?)", ["Bob", 9.0])

        let result = try await conn.query("SELECT id, name, score FROM users ORDER BY id")
        XCTAssertEqual(result.rowCount, 2)
        XCTAssertEqual(try result.rows[0].decode("name", as: String.self), "Alice")
        XCTAssertEqual(try result.rows[0].decode("id", as: Int.self), 1)
        XCTAssertEqual(try result.rows[0].decode("score", as: Double.self), 4.5)
        XCTAssertEqual(try result.rows[1].decode("name", as: String.self), "Bob")
    }

    func testNullAndDecodeIfPresent() async throws {
        let conn = try await openMemory()
        defer { Task { try? await conn.close() } }

        try await conn.query("CREATE TABLE t (a TEXT, b TEXT)")
        try await conn.query("INSERT INTO t (a, b) VALUES (?, ?)", ["x", nil])
        let row = try await conn.query("SELECT a, b FROM t").rows[0]

        XCTAssertEqual(try row.decodeIfPresent("a", as: String.self), "x")
        XCTAssertNil(try row.decodeIfPresent("b", as: String.self))
        XCTAssertTrue(row["b"]!.isNull)
        XCTAssertThrowsError(try row.decode("b", as: String.self)) { error in
            guard case PerunError.unexpectedNull = error else {
                return XCTFail("expected unexpectedNull, got \(error)")
            }
        }
    }

    func testConstraintErrorIsTyped() async throws {
        let conn = try await openMemory()
        defer { Task { try? await conn.close() } }

        try await conn.query("CREATE TABLE u (id INTEGER PRIMARY KEY, email TEXT UNIQUE)")
        try await conn.query("INSERT INTO u (email) VALUES (?)", ["a@b.c"])

        do {
            try await conn.query("INSERT INTO u (email) VALUES (?)", ["a@b.c"])
            XCTFail("expected a unique-constraint failure")
        } catch let error as PerunError {
            XCTAssertEqual(error.sqliteError?.resultCode, .constraintUnique)
            XCTAssertTrue(error.sqliteError?.resultCode.isConstraintViolation ?? false)
        }

        // The connection is still usable after a constraint error.
        let count = try await conn.query("SELECT count(*) AS n FROM u").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(count, 1)
    }

    func testPreparedStatement() async throws {
        let conn = try await openMemory()
        defer { Task { try? await conn.close() } }

        try await conn.query("CREATE TABLE nums (v INTEGER)")
        let stmt = try await conn.prepare("INSERT INTO nums (v) VALUES (?)")
        XCTAssertEqual(stmt.parameterCount, 1)
        for value in 1...5 {
            _ = try await conn.execute(stmt, [value])
        }
        try await conn.closePrepared(stmt)

        let sum = try await conn.query("SELECT sum(v) AS s FROM nums").rows[0].decode("s", as: Int.self)
        XCTAssertEqual(sum, 15)
    }

    func testTransactionCommitAndRollback() async throws {
        let conn = try await openMemory()
        defer { Task { try? await conn.close() } }
        try await conn.query("CREATE TABLE t (v INTEGER)")

        try await conn.withTransaction { tx in
            try await tx.query("INSERT INTO t (v) VALUES (?)", [1])
            try await tx.query("INSERT INTO t (v) VALUES (?)", [2])
        }
        var count = try await conn.query("SELECT count(*) AS n FROM t").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(count, 2)

        struct Boom: Error {}
        do {
            try await conn.withTransaction { tx in
                try await tx.query("INSERT INTO t (v) VALUES (?)", [3])
                throw Boom()
            }
            XCTFail("expected the transaction body to throw")
        } catch is Boom {
            // expected
        }
        count = try await conn.query("SELECT count(*) AS n FROM t").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(count, 2, "the rolled-back insert must not persist")
    }

    func testStreaming() async throws {
        let conn = try await openMemory()
        defer { Task { try? await conn.close() } }
        try await conn.query("CREATE TABLE t (v INTEGER)")
        try await conn.withTransaction { tx in
            for value in 1...100 {
                try await tx.query("INSERT INTO t (v) VALUES (?)", [value])
            }
        }

        var seen: [Int] = []
        for try await row in try await conn.queryStream("SELECT v FROM t ORDER BY v") {
            seen.append(try row.decode("v", as: Int.self))
        }
        XCTAssertEqual(seen, Array(1...100))

        // The connection is reusable after the stream is exhausted.
        let n = try await conn.query("SELECT count(*) AS n FROM t").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(n, 100)
    }

    func testStreamingEarlyBreak() async throws {
        let conn = try await openMemory()
        defer { Task { try? await conn.close() } }
        try await conn.query("CREATE TABLE t (v INTEGER)")
        try await conn.withTransaction { tx in
            for value in 1...50 { try await tx.query("INSERT INTO t (v) VALUES (?)", [value]) }
        }

        var count = 0
        for try await _ in try await conn.queryStream("SELECT v FROM t") {
            count += 1
            if count == 5 { break }
        }
        XCTAssertEqual(count, 5)
        // Give the stream cleanup a moment, then confirm the connection still works.
        let n = try await conn.query("SELECT count(*) AS n FROM t").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(n, 50)
    }

    func testTypedRoundTrips() async throws {
        let conn = try await openMemory()
        defer { Task { try? await conn.close() } }
        try await conn.query("CREATE TABLE t (b BLOB, flag INTEGER, d TEXT)")

        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        try await conn.query("INSERT INTO t (b, flag, d) VALUES (?, ?, ?)",
                             [bytes, true, "2026-07-09 12:00:00"])
        let row = try await conn.query("SELECT b, flag, d FROM t").rows[0]
        XCTAssertEqual(try row.decode("b", as: [UInt8].self), bytes)
        XCTAssertEqual(try row.decode("flag", as: Bool.self), true)
        XCTAssertNoThrow(try row.decode("d", as: Date.self))
    }
}
