import PerunSQLite

func runHooks() async throws {
    // Opt into data-change observation; row changes flow into `dataChanges`.
    let connection = try await SQLiteConnection.connect(
        SQLiteConfiguration(path: ":memory:", observeDataChanges: true))
    try await connection.query("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")

    let observer = Task {
        for await change in connection.dataChanges {
            print("change: \(change.operation) on \(change.table) rowid=\(change.rowID)")
        }
    }

    try await connection.query("INSERT INTO t (id, v) VALUES (1, 10)")
    try await connection.query("INSERT INTO t (id, v) VALUES (2, 20)")
    try await connection.query("UPDATE t SET v = 99 WHERE id = 1")
    try await connection.query("DELETE FROM t WHERE id = 2")

    // Let the observer drain the buffered events, then finish.
    try await Task.sleep(for: .milliseconds(50))
    observer.cancel()
    try await connection.close()
}
