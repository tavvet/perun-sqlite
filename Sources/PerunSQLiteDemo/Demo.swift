import PerunSQLite
import Foundation

// An end-to-end tour of the driver against an in-memory database. Unlike the PostgreSQL demo,
// this needs no server — just `swift run perun-sqlite-demo`.
@main
struct Demo {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("demo failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        print("perun-sqlite demo — an embedded database, no server required\n")

        let connection = try await SQLiteConnection.connect(
            SQLiteConfiguration(path: ":memory:", observeDataChanges: true))

        // 1. Schema + parameterized inserts (values never touch the SQL string).
        try await connection.query("""
            CREATE TABLE users (
                id    INTEGER PRIMARY KEY,
                name  TEXT NOT NULL,
                email TEXT UNIQUE,
                score REAL,
                joined TEXT
            )
            """)

        // Observe row changes as they happen.
        let observer = Task {
            for await change in connection.dataChanges {
                print("  · \(change.operation) on \(change.table) rowid=\(change.rowID)")
            }
        }

        let insert = try await connection.query(
            "INSERT INTO users (name, email, score, joined) VALUES (?, ?, ?, ?)",
            ["Alice", "alice@example.com", 4.5, Date()])
        print("1. inserted rowid \(insert.lastInsertRowID), \(insert.rowsAffected) row changed")

        // 2. Prepared statement, reused for a bulk insert inside a transaction.
        try await connection.withTransaction { tx in
            let statement = try await tx.prepare(
                "INSERT INTO users (name, email, score) VALUES (?, ?, ?)")
            for (name, score) in [("Bob", 9.0), ("Carol", 7.25), ("Dave", 3.0)] {
                _ = try await tx.execute(statement, [name, "\(name.lowercased())@example.com", score])
            }
            try await tx.closePrepared(statement)
        }
        print("2. bulk-inserted 3 users in a transaction")

        // 3. Typed decoding.
        let result = try await connection.query(
            "SELECT id, name, score FROM users ORDER BY score DESC")
        print("3. users by score:")
        for row in result.rows {
            let id = try row.decode("id", as: Int.self)
            let name = try row.decode("name", as: String.self)
            let score = try row.decodeIfPresent("score", as: Double.self) ?? 0
            print("     #\(id) \(name): \(score)")
        }

        // 4. A typed error, with the connection still usable afterward.
        do {
            try await connection.query(
                "INSERT INTO users (name, email) VALUES (?, ?)", ["Eve", "alice@example.com"])
        } catch let error as PerunError {
            let code = error.sqliteError.map { "\($0.resultCode)" } ?? "?"
            print("4. expected failure: \(code) — \(error.sqliteError?.message ?? "")")
        }

        // 5. Streaming a result lazily.
        var streamed = 0
        for try await row in try await connection.queryStream("SELECT id FROM users") {
            _ = try row.decode("id", as: Int.self)
            streamed += 1
        }
        print("5. streamed \(streamed) rows one at a time")

        // 6. A custom SQL function written in Swift.
        try await connection.createFunction("initial", argumentCount: 1, deterministic: true) { args in
            guard case let .text(name) = args[0], let first = name.first else { return .null }
            return .text(String(first))
        }
        let initials = try await connection.query("SELECT initial(name) AS i FROM users ORDER BY id")
        let joined = initials.rows.compactMap { $0["i"]?.string() }.joined()
        print("6. custom function initial(name) → \(joined)")

        // 7. Online backup to a second connection, then count it there.
        let snapshot = try await SQLiteConnection.connect(.memory())
        try await connection.backup(to: snapshot)
        let count = try await snapshot.query("SELECT count(*) AS n FROM users").rows[0].decode("n", as: Int.self)
        print("7. backed up \(count) users to a second database")
        try await snapshot.close()

        observer.cancel()
        try await connection.close()

        // 8. A pool over a temporary file, fanning out concurrent reads.
        let path = NSTemporaryDirectory() + "perun-sqlite-demo-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let pool = SQLiteClient(configuration: .file(path, journalMode: .wal), maxConnections: 4)
        try await pool.query("CREATE TABLE t (v INTEGER)")
        try await pool.withTransaction { tx in
            for value in 1...1000 { try await tx.query("INSERT INTO t (v) VALUES (?)", [value]) }
        }
        let sum = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await pool.query("SELECT sum(v) AS s FROM t").rows[0].decode("s", as: Int.self)
                }
            }
            var total = 0
            for try await value in group { total = value }
            return total
        }
        print("8. pool: 8 concurrent readers each saw sum = \(sum)")
        await pool.shutdown()

        print("\ndone.")
    }
}
