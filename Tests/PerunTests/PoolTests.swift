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
}
