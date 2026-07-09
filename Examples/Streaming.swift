import PerunSQLite

func runStreaming() async throws {
    let connection = try await openMemoryConnection()
    try await connection.query("CREATE TABLE events (id INTEGER PRIMARY KEY, weight INTEGER)")
    try await connection.withTransaction { tx in
        for value in 1...10_000 {
            try await tx.query("INSERT INTO events (weight) VALUES (?)", [value])
        }
    }

    // Rows arrive one at a time; the whole result never lives in memory at once.
    var total = 0
    var counted = 0
    for try await row in try await connection.queryStream("SELECT weight FROM events") {
        total += try row.decode("weight", as: Int.self)
        counted += 1
    }
    print("streamed \(counted) rows; total weight = \(total)")

    // Stopping early frees the statement immediately — the connection is reusable.
    var firstFew: [Int] = []
    for try await row in try await connection.queryStream("SELECT weight FROM events ORDER BY weight") {
        firstFew.append(try row.decode("weight", as: Int.self))
        if firstFew.count == 5 { break }
    }
    print("first five weights: \(firstFew)")

    try await connection.close()
}
