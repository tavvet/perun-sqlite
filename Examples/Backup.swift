import PerunSQLite
import Foundation

func runBackup() async throws {
    // Build a database in memory…
    let memory = try await openMemoryConnection()
    try await memory.query("CREATE TABLE t (v INTEGER)")
    try await memory.withTransaction { tx in
        for value in 1...500 { try await tx.query("INSERT INTO t (v) VALUES (?)", [value]) }
    }

    // …then snapshot it to a file with the online backup API.
    let path = temporaryDatabasePath()
    defer { removeDatabase(at: path) }
    let file = try await SQLiteConnection.connect(.file(path))
    try await memory.backup(to: file)
    try await memory.close()

    // Reopen the file independently and confirm the data survived.
    let reopened = try await SQLiteConnection.connect(.file(path, readonly: true))
    let sum = try await reopened.query("SELECT sum(v) AS s FROM t").rows[0].decode("s", as: Int.self)
    print("backed up to \(path) — sum of restored rows = \(sum)")
    try await file.close()
    try await reopened.close()
}
