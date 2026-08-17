import XCTest
@testable import PerunSQLite

final class ExtrasTests: XCTestCase {
    func testCustomScalarFunction() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }

        try await conn.createFunction("triple", argumentCount: 1, deterministic: true) { args in
            guard case let .integer(n) = args[0] else { return .null }
            return .integer(n * 3)
        }
        try await conn.createFunction("shout", argumentCount: 1) { args in
            guard case let .text(s) = args[0] else { return .null }
            return .text(s.uppercased() + "!")
        }

        let tripled = try await conn.query("SELECT triple(7) AS v").rows[0].decode("v", as: Int.self)
        XCTAssertEqual(tripled, 21)
        let shouted = try await conn.query("SELECT shout('hi') AS v").rows[0].decode("v", as: String.self)
        XCTAssertEqual(shouted, "HI!")

        // Usable from a WHERE clause, over a table.
        try await conn.query("CREATE TABLE t (v INTEGER)")
        for value in 1...5 { try await conn.query("INSERT INTO t (v) VALUES (?)", [value]) }
        let matches = try await conn.query("SELECT count(*) AS n FROM t WHERE triple(v) > 9")
            .rows[0].decode("n", as: Int.self)
        XCTAssertEqual(matches, 2)   // triple(v) > 9 ⇒ v > 3 ⇒ v ∈ {4, 5}
    }

    // A custom function returning Double.nan must surface a SQL error, not a silent NULL (matching
    // the bind path). ±Infinity stays a REAL.
    func testCustomFunctionNaNResultSurfacesError() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        try await conn.createFunction("nan_fn", argumentCount: 0) { _ in .real(.nan) }
        try await conn.createFunction("inf_fn", argumentCount: 0) { _ in .real(.infinity) }

        do {
            _ = try await conn.query("SELECT nan_fn() AS v")
            XCTFail("expected NaN function result to surface an error")
        } catch let error as PerunError {
            XCTAssertNotNil(error.sqliteError)
        }
        let ty = try await conn.query("SELECT typeof(inf_fn()) AS ty").rows[0].decode("ty", as: String.self)
        XCTAssertEqual(ty, "real")
    }

    func testDirectOnlyFunctionRejectedInSchema() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        // Default (directOnly: true): callable from top-level SQL, but not from a view.
        try await conn.createFunction("double_it", argumentCount: 1) { args in
            guard case let .integer(n) = args[0] else { return .null }
            return .integer(n * 2)
        }
        let v = try await conn.query("SELECT double_it(21) AS v").rows[0].decode("v", as: Int.self)
        XCTAssertEqual(v, 42)

        try await conn.query("CREATE VIEW v_direct AS SELECT double_it(1) AS v")
        do {
            _ = try await conn.query("SELECT v FROM v_direct")
            XCTFail("expected a directOnly function to be rejected inside a view")
        } catch let error as PerunError {
            XCTAssertNotNil(error.sqliteError)
        }

        // Opting out (directOnly: false) allows use inside a view.
        try await conn.createFunction("triple_it", argumentCount: 1, directOnly: false) { args in
            guard case let .integer(n) = args[0] else { return .null }
            return .integer(n * 3)
        }
        try await conn.query("CREATE VIEW v_ok AS SELECT triple_it(2) AS v")
        let w = try await conn.query("SELECT v FROM v_ok").rows[0].decode("v", as: Int.self)
        XCTAssertEqual(w, 6)
    }

    func testCustomFunctionThrowSurfacesAsError() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        struct Boom: Error {}
        try await conn.createFunction("boom", argumentCount: 0) { _ in throw Boom() }

        do {
            _ = try await conn.query("SELECT boom()")
            XCTFail("expected the function error to surface")
        } catch let error as PerunError {
            XCTAssertNotNil(error.sqliteError)
        }
    }

    func testDataChangeHooks() async throws {
        let conn = try await SQLiteConnection.connect(
            SQLiteConfiguration(path: ":memory:", observeDataChanges: true))
        defer { Task { try? await conn.close() } }
        try await conn.query("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")

        let collector = Task { () -> [SQLiteChange] in
            var changes: [SQLiteChange] = []
            for await change in conn.dataChanges {
                changes.append(change)
                if changes.count == 3 { break }
            }
            return changes
        }

        // Events are buffered, so writes can happen before the collector drains them.
        try await conn.query("INSERT INTO t (id, v) VALUES (1, 10)")
        try await conn.query("UPDATE t SET v = 20 WHERE id = 1")
        try await conn.query("DELETE FROM t WHERE id = 1")

        let changes = await collector.value
        XCTAssertEqual(changes.map(\.operation), [.insert, .update, .delete])
        XCTAssertTrue(changes.allSatisfy { $0.table == "t" })
        XCTAssertEqual(changes[0].rowID, 1)
    }

    func testOnlineBackup() async throws {
        let source = try await SQLiteConnection.connect(.memory())
        let destination = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await source.close(); try? await destination.close() } }

        try await source.query("CREATE TABLE t (v INTEGER)")
        try await source.withTransaction { tx in
            for value in 1...20 { try await tx.query("INSERT INTO t (v) VALUES (?)", [value]) }
        }

        try await source.backup(to: destination)

        let count = try await destination.query("SELECT count(*) AS n FROM t").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(count, 20)
        let sum = try await destination.query("SELECT sum(v) AS s FROM t").rows[0].decode("s", as: Int.self)
        XCTAssertEqual(sum, 210)
    }

    // The flagship guarantee: a transaction that times out mid-flight rolls back cleanly, leaves
    // no partial writes, and the connection is reusable and not stuck in a transaction.
    func testTimeoutDuringTransactionRollsBack() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        try await conn.query("CREATE TABLE t (v INTEGER)")

        do {
            try await withTimeout(.milliseconds(100)) {
                try await conn.withTransaction { tx in
                    try await tx.query("INSERT INTO t (v) VALUES (1)")
                    try await tx.query("""
                        WITH RECURSIVE c(x) AS (
                            SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1000000000
                        )
                        INSERT INTO t (v) SELECT count(*) FROM c
                        """)
                }
            }
            XCTFail("expected the transaction to time out")
        } catch let error as PerunError {
            guard case .timedOut = error else { return XCTFail("expected timedOut, got \(error)") }
        }

        // Rolled back: the INSERT of 1 did not persist.
        let count = try await conn.query("SELECT count(*) AS n FROM t").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(count, 0)
        // Not left inside a transaction, and reusable.
        let inTx = await conn.isInTransaction
        XCTAssertFalse(inTx)
        try await conn.query("INSERT INTO t (v) VALUES (99)")
        let after = try await conn.query("SELECT count(*) AS n FROM t").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(after, 1)
    }

    // Even if the transaction body swallows the cancellation (e.g. `try? await Task.sleep`), a
    // timed-out transaction must still roll back — not reach the uninterruptible COMMIT.
    func testTimeoutRollsBackEvenWhenBodySwallowsCancellation() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        try await conn.query("CREATE TABLE t (v INTEGER)")

        do {
            try await withTimeout(.milliseconds(100)) {
                try await conn.withTransaction { tx in
                    try await tx.query("INSERT INTO t (v) VALUES (1)")
                    try? await Task.sleep(for: .seconds(10))   // swallows the timeout's cancellation
                }
            }
            XCTFail("expected the transaction to time out")
        } catch let error as PerunError where error == .timedOut {
        } catch is CancellationError {
        }

        let count = try await conn.query("SELECT count(*) AS n FROM t").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(count, 0, "a timed-out transaction must roll back even if body swallowed the cancel")
    }

    func testTimeoutInterruptsQuery() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }

        do {
            _ = try await withTimeout(.milliseconds(100)) {
                try await conn.query("""
                    WITH RECURSIVE c(x) AS (
                        SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1000000000
                    )
                    SELECT count(*) AS n FROM c
                    """)
            }
            XCTFail("expected the query to time out")
        } catch let error as PerunError {
            guard case .timedOut = error else {
                return XCTFail("expected timedOut, got \(error)")
            }
        }

        // The connection is still usable after the interrupt.
        let ok = try await conn.query("SELECT 1 AS v").rows[0].decode("v", as: Int.self)
        XCTAssertEqual(ok, 1)
    }
}
