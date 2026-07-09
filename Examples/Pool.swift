import PerunSQLite
import Foundation

func runPool() async throws {
    let path = temporaryDatabasePath()
    defer { removeDatabase(at: path) }

    // WAL mode lets several pooled connections read while one writes.
    let pool = SQLiteClient(configuration: .file(path, journalMode: .wal), maxConnections: 4)

    try await pool.query("CREATE TABLE t (v INTEGER)")
    try await pool.withTransaction { tx in
        for value in 1...1000 { try await tx.query("INSERT INTO t (v) VALUES (?)", [value]) }
    }

    // Fan out concurrent reads; the pool hands each task its own connection.
    try await withThrowingTaskGroup(of: (Int, Int).self) { group in
        for worker in 1...4 {
            group.addTask {
                let sum = try await pool.query("SELECT sum(v) AS s FROM t").rows[0].decode("s", as: Int.self)
                return (worker, sum)
            }
        }
        for try await (worker, sum) in group {
            print("worker \(worker) saw sum = \(sum)")
        }
    }

    print("connections opened: \(await pool.connectionCount)")
    await pool.shutdown()
}
