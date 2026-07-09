import PerunSQLite
import Foundation

/// A fresh, private in-memory database — the simplest thing that needs no cleanup.
func openMemoryConnection() async throws -> SQLiteConnection {
    try await SQLiteConnection.connect(.memory())
}

/// A unique temporary file path for the file-backed examples (pool, backup).
func temporaryDatabasePath() -> String {
    NSTemporaryDirectory() + "perun-example-\(UUID().uuidString).db"
}

/// Remove a database file and its WAL/SHM sidecars.
func removeDatabase(at path: String) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
    }
}
