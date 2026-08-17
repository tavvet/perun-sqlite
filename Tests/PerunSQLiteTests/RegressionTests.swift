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
                _ = try await conn.withTransaction { inner in
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

    // createFunction validates the argument count (SQLite requires nil or 0…127; larger values are
    // UB in C and could even trap Int32.init).
    func testCreateFunctionArgumentCountValidation() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }

        for badCount in [128, 200, Int(Int32.max) + 1] {
            do {
                try await conn.createFunction("bad", argumentCount: badCount) { _ in .null }
                XCTFail("expected invalidArgumentCount for \(badCount)")
            } catch let error as PerunError {
                XCTAssertEqual(error, .invalidArgumentCount(badCount))
            }
        }

        // Boundary and variadic values are accepted.
        try await conn.createFunction("zero", argumentCount: 0) { _ in .integer(1) }
        try await conn.createFunction("max127", argumentCount: 127) { _ in .integer(1) }
        try await conn.createFunction("variadic", argumentCount: nil) { _ in .integer(1) }
        let value = try await conn.query("SELECT zero() AS v").first!.decode("v", as: Int.self)
        XCTAssertEqual(value, 1)
    }

    // A custom function returning an empty blob must yield an empty BLOB, not SQL NULL.
    func testCustomFunctionEmptyBlobResult() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        try await conn.createFunction("emptyblob", argumentCount: 0) { _ in .blob([]) }

        let row = try await conn.query("SELECT emptyblob() AS b, typeof(emptyblob()) AS ty").first!
        XCTAssertFalse(row["b"]!.isNull)
        XCTAssertEqual(row["b"]!.value.storageClass, .blob)
        XCTAssertEqual(try row.decode("ty", as: String.self), "blob")
        XCTAssertEqual(try row.decode("b", as: [UInt8].self), [])
    }

    // Malformed SQL after the first statement surfaces its error instead of being silently dropped.
    func testMalformedTrailingStatementSurfacesError() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        try await conn.query("CREATE TABLE t (v INTEGER)")

        do {
            try await conn.query("SELECT 1; this is not valid sql", [])
            XCTFail("expected the malformed trailing statement to surface an error")
        } catch let error as PerunError {
            XCTAssertNotNil(error.sqliteError)      // a real SQLite parse error, not multipleStatements
        }

        // A well-formed second statement still reports multipleStatements.
        do {
            try await conn.query("SELECT 1; SELECT 2", [])
            XCTFail("expected multipleStatements")
        } catch let error as PerunError {
            XCTAssertEqual(error, .multipleStatements)
        }
    }

    // A transaction SQLite auto-rolls-back mid-body (ON CONFLICT ROLLBACK) must not let the
    // statements after the rollback commit one at a time: the next statement fails loudly and no
    // change from the transaction survives.
    func testAutoRollbackMidTransactionIsSurfaced() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        try await conn.query("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
        try await conn.query("INSERT INTO t (id, v) VALUES (1, 100)")

        do {
            try await conn.withTransaction { tx in
                try await tx.query("INSERT INTO t (id, v) VALUES (2, 200)")          // part of the tx
                // Violates the primary key with OR ROLLBACK, aborting the whole transaction.
                _ = try? await tx.query("INSERT OR ROLLBACK INTO t (id, v) VALUES (1, 999)")
                // Body swallowed the error and keeps writing — this must be rejected, not committed.
                try await tx.query("INSERT INTO t (id, v) VALUES (3, 300)")
                XCTFail("expected transactionRolledBack once the transaction was aborted")
            }
            XCTFail("expected withTransaction to throw transactionRolledBack")
        } catch let error as PerunError {
            XCTAssertEqual(error, .transactionRolledBack)
        }

        // Atomicity held: neither id=2 (written before the abort) nor id=3 (after) persisted.
        let count = try await conn.query("SELECT count(*) AS n FROM t").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(count, 1)
    }

    // Empty / comment-only SQL through a single-statement API reports emptyStatement, not the
    // nonsensical "SQLite error 0 (ok): not an error". query(_:) treats it as a no-op.
    func testEmptyStatementRejected() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }

        for sql in ["", "   ", "-- just a comment"] {
            do {
                _ = try await conn.query(sql, [])
                XCTFail("expected emptyStatement for \(sql.debugDescription)")
            } catch let error as PerunError {
                XCTAssertEqual(error, .emptyStatement)
            }
        }
        let result = try await conn.query("-- nothing here")   // multi-statement path: no-op
        XCTAssertEqual(result.rowCount, 0)
    }

    // Double.nan can't be stored as a REAL (SQLite would silently write NULL); binding it must
    // throw rather than corrupt the row. ±Infinity is representable and round-trips.
    func testBindingNaNThrowsButInfinityRoundTrips() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        try await conn.query("CREATE TABLE t (v REAL)")

        do {
            try await conn.query("INSERT INTO t (v) VALUES (?)", [Double.nan])
            XCTFail("expected NaN binding to throw")
        } catch let error as PerunError {
            guard case .invalidParameter = error else {
                return XCTFail("expected invalidParameter, got \(error)")
            }
        }

        try await conn.query("INSERT INTO t (v) VALUES (?)", [Double.infinity])
        let v = try await conn.query("SELECT v FROM t").rows[0].decode("v", as: Double.self)
        XCTAssertEqual(v, .infinity)
    }

    // A write cancelled while still queued behind another operation must NOT run: cancellation
    // reaches it before it starts, so its side effects must not happen and withTimeout/cancellation
    // must not report a timeout for a write that actually committed.
    func testCancelledQueuedWriteDoesNotCommit() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        try await conn.createFunction("perun_block_ms", argumentCount: 1) { args in
            guard case let .integer(ms) = args[0] else { return .null }
            Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
            return .integer(ms)
        }
        try await conn.query("CREATE TABLE t (v INTEGER)")

        // A occupies the connection's queue for ~300ms.
        async let occupier: Int = conn.query("SELECT perun_block_ms(300) AS v")
            .rows[0].decode("v", as: Int.self)
        try await Task.sleep(for: .milliseconds(50))

        // B: an INSERT queued behind A, cancelled while it is still queued (long before A frees the
        // queue). It must be skipped, not run once the queue drains.
        let b = Task { try await conn.query("INSERT INTO t (v) VALUES (42)") }
        try await Task.sleep(for: .milliseconds(10))
        b.cancel()
        _ = try? await b.value

        _ = try await occupier
        let count = try await conn.query("SELECT count(*) AS n FROM t").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(count, 0, "a queued write cancelled before it ran must not commit")
    }

    // Cancelling one operation must interrupt only that operation — never a different one running
    // concurrently on the same connection. Regression: a single scalar "running" marker let a
    // queued operation's cancellation misfire sqlite3_interrupt at whatever was actually running.
    func testCancellingOneOperationDoesNotInterruptAnother() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        // A scalar function that occupies the connection's serial queue for a set time.
        try await conn.createFunction("perun_block_ms", argumentCount: 1) { args in
            guard case let .integer(ms) = args[0] else { return .null }
            Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
            return .integer(ms)
        }

        // A: occupies the connection for ~300ms. It is never cancelled and must succeed.
        async let longResult: Int = conn.query("SELECT perun_block_ms(300) AS v")
            .rows[0].decode("v", as: Int.self)

        try await Task.sleep(for: .milliseconds(50))     // let A start running on the ioQueue

        // B: queued behind A on the same connection, then cancelled. Its cancellation must not
        // interrupt A.
        let b = Task { try await conn.query("SELECT perun_block_ms(1) AS v") }
        try await Task.sleep(for: .milliseconds(10))
        b.cancel()
        _ = try? await b.value

        let v = try await longResult
        XCTAssertEqual(v, 300)                            // A completed uninterrupted
    }

    // PRAGMA journal_mode returns the mode actually in effect rather than erroring; a request that
    // can't be honored must surface instead of silently running in the wrong mode.
    func testJournalModeMismatchIsSurfaced() async throws {
        // WAL is honored on a file database — connect succeeds and the mode sticks.
        let path = NSTemporaryDirectory() + "perun-jm-\(UUID().uuidString).db"
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        let fileConn = try await SQLiteConnection.connect(.file(path, journalMode: .wal))
        let mode = try await fileConn.query("PRAGMA journal_mode").rows[0][0].string()
        XCTAssertEqual(mode?.lowercased(), "wal")
        try? await fileConn.close()

        // WAL cannot apply to a private :memory: database; connect must fail rather than quietly
        // fall back to rollback-journal mode.
        do {
            _ = try await SQLiteConnection.connect(
                SQLiteConfiguration(path: ":memory:", journalMode: .wal))
            XCTFail("expected connect to fail when journal_mode can't be honored")
        } catch let error as PerunError {
            guard case .connectionFailed = error else {
                return XCTFail("expected connectionFailed, got \(error)")
            }
        }
    }

    // The auto-rollback guard must not disturb an ordinary transaction: commit and rollback both
    // behave, and the connection stays usable afterwards.
    func testNormalTransactionsStillCommitAndRollback() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        try await conn.query("CREATE TABLE t (v INTEGER)")

        try await conn.withTransaction { tx in
            for value in 1...3 { try await tx.query("INSERT INTO t (v) VALUES (?)", [value]) }
        }
        var count = try await conn.query("SELECT count(*) AS n FROM t").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(count, 3)

        struct Boom: Error {}
        do {
            try await conn.withTransaction { tx in
                try await tx.query("INSERT INTO t (v) VALUES (99)")
                throw Boom()
            }
            XCTFail("expected the body error to propagate")
        } catch is Boom {}
        count = try await conn.query("SELECT count(*) AS n FROM t").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(count, 3)          // the rolled-back INSERT left no trace
    }
}
