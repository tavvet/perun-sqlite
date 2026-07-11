import XCTest
import Foundation
@testable import PerunSQLite

final class PoolTests: XCTestCase {
    private func tempDatabasePath() -> String {
        NSTemporaryDirectory() + "perun-sqlite-test-\(UUID().uuidString).db"
    }

    private func removeDatabase(_ path: String) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    func testPooledQueriesShareData() async throws {
        let path = tempDatabasePath()
        defer { removeDatabase(path) }
        let pool = SQLiteClient(configuration: .file(path, journalMode: .wal), maxConnections: 4)
        defer { Task { await pool.shutdown() } }

        try await pool.query("CREATE TABLE t (v INTEGER)")
        for value in 1...10 {
            try await pool.query("INSERT INTO t (v) VALUES (?)", [value])
        }
        let sum = try await pool.query("SELECT sum(v) AS s FROM t").rows[0].decode("s", as: Int.self)
        XCTAssertEqual(sum, 55)
    }

    func testConcurrentReads() async throws {
        let path = tempDatabasePath()
        defer { removeDatabase(path) }
        let pool = SQLiteClient(configuration: .file(path, journalMode: .wal), maxConnections: 4)
        defer { Task { await pool.shutdown() } }

        try await pool.query("CREATE TABLE t (v INTEGER)")
        try await pool.withTransaction { tx in
            for value in 1...100 { try await tx.query("INSERT INTO t (v) VALUES (?)", [value]) }
        }

        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try await pool.query("SELECT count(*) AS n FROM t").rows[0].decode("n", as: Int.self)
                }
            }
            var counts: [Int] = []
            for try await count in group { counts.append(count) }
            return counts
        }
        XCTAssertEqual(results.count, 16)
        XCTAssertTrue(results.allSatisfy { $0 == 100 })
    }

    func testTransactionAtomicityThroughPool() async throws {
        let path = tempDatabasePath()
        defer { removeDatabase(path) }
        let pool = SQLiteClient(configuration: .file(path, journalMode: .wal))
        defer { Task { await pool.shutdown() } }

        try await pool.query("CREATE TABLE t (v INTEGER)")
        struct Boom: Error {}
        do {
            try await pool.withTransaction { tx in
                try await tx.query("INSERT INTO t (v) VALUES (1)")
                throw Boom()
            }
            XCTFail("expected throw")
        } catch is Boom {}

        let n = try await pool.query("SELECT count(*) AS n FROM t").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(n, 0)
    }

    func testShutdownFailsFurtherWork() async throws {
        let pool = SQLiteClient(configuration: .file(tempDatabasePath(), journalMode: .wal))
        try await pool.query("CREATE TABLE t (v INTEGER)")
        await pool.shutdown()
        do {
            try await pool.query("SELECT 1")
            XCTFail("expected clientShutdown")
        } catch let error as PerunError {
            guard case .clientShutdown = error else {
                return XCTFail("expected clientShutdown, got \(error)")
            }
        }
    }

    func testLifetimeRecycling() async throws {
        let path = tempDatabasePath()
        defer { removeDatabase(path) }
        let pool = SQLiteClient(configuration: .file(path, journalMode: .wal),
                                maxConnections: 1,
                                maxConnectionLifetime: .milliseconds(50))
        defer { Task { await pool.shutdown() } }

        try await pool.query("CREATE TABLE t (v INTEGER)")
        try await Task.sleep(for: .milliseconds(120))
        // After the lifetime elapses the pooled connection is recycled on the next use; the query
        // still succeeds on a fresh connection.
        let ok = try await pool.query("SELECT 1 AS v").rows[0].decode("v", as: Int.self)
        XCTAssertEqual(ok, 1)
    }

    // A connection a borrower closed inside withConnection must not be handed straight to a parked
    // waiter (the acquire() path vets idle connections, but a direct hand-off skips that). The
    // waiter must get a live replacement.
    func testClosedConnectionNotHandedToWaiter() async throws {
        let path = tempDatabasePath()
        defer { removeDatabase(path) }
        let pool = SQLiteClient(configuration: .file(path, journalMode: .wal), maxConnections: 1)
        defer { Task { await pool.shutdown() } }

        try await pool.query("CREATE TABLE t (v INTEGER)")
        try await pool.query("INSERT INTO t (v) VALUES (42)")

        // Task A holds the only connection, lets B queue as a waiter, then returns it closed.
        let a = Task {
            try await pool.withConnection { conn in
                try await Task.sleep(for: .milliseconds(100))
                try await conn.close()
            }
        }
        try await Task.sleep(for: .milliseconds(20))     // let A acquire the connection first
        let b = Task { try await pool.query("SELECT v FROM t").rows[0].decode("v", as: Int.self) }

        try await a.value
        let v = try await b.value
        XCTAssertEqual(v, 42)                             // B got a live replacement, not the corpse
    }

    // A stream leaked out of withConnection must not ride along to the next borrower: the pool
    // finalizes it on release, so the leaked stream is dead and the connection is clean to reuse.
    func testLingeringStreamFinalizedOnRelease() async throws {
        let path = tempDatabasePath()
        defer { removeDatabase(path) }
        let pool = SQLiteClient(configuration: .file(path, journalMode: .wal), maxConnections: 1)
        defer { Task { await pool.shutdown() } }

        try await pool.query("CREATE TABLE t (v INTEGER)")
        for value in 1...5 { try await pool.query("INSERT INTO t (v) VALUES (?)", [value]) }

        // Misuse: let a stream escape the withConnection scope without draining it.
        let leaked = try await pool.withConnection { conn in
            try await conn.queryStream("SELECT v FROM t ORDER BY v")
        }

        // With one connection, this reuses the same handle — release() must have finalized the
        // leaked stream first. The reuse itself works regardless; the leaked stream being dead is
        // what proves the connection wasn't handed over with an open statement.
        let sum = try await pool.query("SELECT sum(v) AS s FROM t").rows[0].decode("s", as: Int.self)
        XCTAssertEqual(sum, 15)

        var iterator = leaked.makeAsyncIterator()
        let row = try await iterator.next()
        XCTAssertNil(row, "the leaked stream should have been finalized when its connection was released")
    }
}
