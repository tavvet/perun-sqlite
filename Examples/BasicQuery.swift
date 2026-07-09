import PerunSQLite
import Foundation

func runBasicQuery() async throws {
    let connection = try await openMemoryConnection()

    try await connection.query("""
        CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, created TEXT)
        """)

    // Parameters bind positionally to `?` — values never touch the SQL string (injection-safe).
    try await connection.query(
        "INSERT INTO users (name, created) VALUES (?, ?)", ["Ada", Date()])
    try await connection.query(
        "INSERT INTO users (name, created) VALUES (?, ?)", ["Grace", Date()])

    let result = try await connection.query("SELECT id, name, created FROM users ORDER BY id")
    for row in result.rows {
        let id = try row.decode("id", as: Int.self)
        let name = try row.decode("name", as: String.self)
        let created = try row.decode("created", as: Date.self)
        print("#\(id) \(name) — joined \(created)")
    }

    try await connection.close()
}
