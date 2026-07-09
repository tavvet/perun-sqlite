import PerunSQLite

func runTransactions() async throws {
    let connection = try await openMemoryConnection()
    try await connection.query("CREATE TABLE accounts (name TEXT PRIMARY KEY, balance INTEGER)")
    try await connection.query("INSERT INTO accounts VALUES ('alice', 100), ('bob', 0)")

    // Everything in the closure commits together, or rolls back together if it throws.
    try await connection.withTransaction { tx in
        try await tx.query("UPDATE accounts SET balance = balance - ? WHERE name = ?", [40, "alice"])
        try await tx.query("UPDATE accounts SET balance = balance + ? WHERE name = ?", [40, "bob"])
    }
    try await printBalances(connection, note: "after a committed transfer")

    struct InsufficientFunds: Error {}
    do {
        try await connection.withTransaction { tx in
            try await tx.query("UPDATE accounts SET balance = balance - ? WHERE name = ?", [1000, "alice"])
            let balance = try await tx.query("SELECT balance FROM accounts WHERE name = 'alice'")
                .rows[0].decode("balance", as: Int.self)
            if balance < 0 { throw InsufficientFunds() }     // triggers ROLLBACK
        }
    } catch is InsufficientFunds {
        print("overdraft rejected — transaction rolled back")
    }
    try await printBalances(connection, note: "after the rejected transfer (unchanged)")

    try await connection.close()
}

private func printBalances(_ connection: SQLiteConnection, note: String) async throws {
    let rows = try await connection.query("SELECT name, balance FROM accounts ORDER BY name").rows
    let summary = try rows.map { "\(try $0.decode("name", as: String.self))=\(try $0.decode("balance", as: Int.self))" }
    print("\(note): \(summary.joined(separator: " "))")
}
