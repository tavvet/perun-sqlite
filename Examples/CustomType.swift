import PerunSQLite

// A custom Swift type can join the type system by conforming to `SQLiteEncodable` and
// `SQLiteDecodable` — here an enum stored as TEXT.
enum Priority: String, Sendable, SQLiteEncodable, SQLiteDecodable {
    case low, medium, high

    func encode() -> SQLiteValue { .text(rawValue) }

    static func decode(from value: SQLiteValue) throws -> Priority {
        guard case let .text(raw) = value, let priority = Priority(rawValue: raw) else {
            throw PerunError.decodingFailed(
                type: "Priority", storageClass: value.storageClass.description,
                reason: "not one of low/medium/high")
        }
        return priority
    }
}

func runCustomType() async throws {
    let connection = try await openMemoryConnection()
    try await connection.query("CREATE TABLE tasks (title TEXT, priority TEXT)")

    try await connection.query("INSERT INTO tasks VALUES (?, ?)", ["ship it", Priority.high])
    try await connection.query("INSERT INTO tasks VALUES (?, ?)", ["tidy up", Priority.low])

    let rows = try await connection.query("SELECT title, priority FROM tasks ORDER BY title").rows
    for row in rows {
        let title = try row.decode("title", as: String.self)
        let priority = try row.decode("priority", as: Priority.self)
        print("\(title): \(priority)")
    }

    try await connection.close()
}
