import Foundation

// A JSON document, stored as TEXT.
//
// SQLite's JSON1 functions keep ordinary `json()` as text, so this is a thin wrapper carrying the
// raw JSON string — the analogue of perun-pgsql's `PostgresJSON`. SQLite ≥ 3.45 also has a binary
// `jsonb()` format stored as a BLOB; that is not JSON text and this type does not decode it (see
// `decode(from:)`). Mapping JSON to and from Swift models is a job for a higher layer, so this
// stays ORM-agnostic.
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
            // A JSON BLOB today is almost certainly SQLite's binary JSONB (≥ 3.45), not UTF-8 JSON
            // text — decoding it as text would yield silent garbage. Accept a blob only if it is
            // valid UTF-8 (JSON text a caller chose to store as a BLOB); reject JSONB with a clear
            // error rather than a mojibake string.
            guard let text = String(bytes: b, encoding: .utf8) else {
                throw sqliteDecodeError("SQLiteJSON", value,
                    "BLOB is not valid UTF-8 (SQLite JSONB binary format is not decodable as JSON text)")
            }
            return SQLiteJSON(text)
        case let .integer(i):
            return SQLiteJSON(String(i))
        case let .real(d):
            return SQLiteJSON(String(d))
        case .null:
            throw sqliteDecodeError("SQLiteJSON", value)
        }
    }
}
