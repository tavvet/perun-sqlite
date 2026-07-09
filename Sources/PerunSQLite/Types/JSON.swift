// A JSON document, stored as TEXT.
//
// SQLite keeps JSON as ordinary text (the JSON1 functions parse it on demand), so this is a thin
// wrapper carrying the raw JSON string — the analogue of perun-pgsql's `PostgresJSON`, minus the
// json/jsonb distinction SQLite doesn't have. Mapping JSON to and from Swift models is a job for a
// higher layer, so this stays ORM-agnostic.
public struct SQLiteJSON: Sendable, Equatable {
    /// The raw JSON text.
    public var text: String

    public init(_ text: String) {
        self.text = text
    }
}

extension SQLiteJSON: SQLiteEncodable {
    public func encode() -> SQLiteValue { .text(text) }
}

extension SQLiteJSON: SQLiteDecodable {
    public static func decode(from value: SQLiteValue) throws -> SQLiteJSON {
        switch value {
        case let .text(s):
            return SQLiteJSON(s)
        case let .blob(b):
            return SQLiteJSON(String(decoding: b, as: UTF8.self))
        case let .integer(i):
            return SQLiteJSON(String(i))
        case let .real(d):
            return SQLiteJSON(String(d))
        case .null:
            throw sqliteDecodeError("SQLiteJSON", value)
        }
    }
}
