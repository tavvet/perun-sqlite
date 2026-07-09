import PerunSQLite

func runErrorHandling() async throws {
    let connection = try await openMemoryConnection()
    try await connection.query("""
        CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT UNIQUE NOT NULL)
        """)
    try await connection.query("INSERT INTO users (email) VALUES (?)", ["a@b.c"])

    // Branch on the typed result code, never on the message text.
    do {
        try await connection.query("INSERT INTO users (email) VALUES (?)", ["a@b.c"])
    } catch let error as PerunError {
        switch error.sqliteError?.resultCode {
        case .constraintUnique:
            print("that email is already taken")
        case .constraintNotNull:
            print("email is required")
        case let other?:
            print("database error: \(other) — \(error.sqliteError?.message ?? "")")
        case nil:
            print("driver error: \(error)")
        }
    }

    // A SQL error leaves the connection perfectly usable.
    let count = try await connection.query("SELECT count(*) AS n FROM users").rows[0].decode("n", as: Int.self)
    print("users after the failed insert: \(count)")

    try await connection.close()
}
