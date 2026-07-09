/// A Swift type that can be decoded from a `SQLiteValue`.
///
/// SQLite hands back already-typed values (the five storage classes), so — unlike perun-pgsql's
/// `PostgresDecodable`, which receives raw bytes plus an OID and a text/binary format — a decoder
/// here just switches over `SQLiteValue`. NULL is handled one level up (in `SQLiteCell`), so a
/// decoder never sees `.null` unless it opts to.
public protocol SQLiteDecodable: Sendable {
    static func decode(from value: SQLiteValue) throws -> Self
}

// MARK: - Typed access on a cell

public extension SQLiteCell {
    /// Decode this cell into `T`. Throws `PerunError.unexpectedNull` if the cell is SQL NULL —
    /// use `decodeIfPresent` for nullable columns.
    func decode<T: SQLiteDecodable>(_ type: T.Type = T.self) throws -> T {
        if value.isNull {
            throw PerunError.unexpectedNull(column: column.name)
        }
        return try T.decode(from: value)
    }

    /// Decode this cell into `T`, or `nil` if it is SQL NULL.
    func decodeIfPresent<T: SQLiteDecodable>(_ type: T.Type = T.self) throws -> T? {
        value.isNull ? nil : try decode(type)
    }
}

// MARK: - Shared helpers for decoders

/// Build a decode error, tagging the Swift type and the value's storage class.
func sqliteDecodeError(_ type: String,
                       _ value: SQLiteValue,
                       _ reason: String = "unsupported storage class") -> PerunError {
    .decodingFailed(type: type, storageClass: value.storageClass.description, reason: reason)
}

/// Decode any fixed-width integer from an INTEGER (range-checked), a REAL (must be an exact
/// integer in range) or TEXT (base-10 parse). BLOB and NULL are rejected.
func decodeSQLiteInteger<T: FixedWidthInteger>(_ value: SQLiteValue, _ typeName: String) throws -> T {
    switch value {
    case let .integer(i):
        guard let v = T(exactly: i) else {
            throw sqliteDecodeError(typeName, value, "value \(i) is out of range for \(typeName)")
        }
        return v
    case let .real(d):
        guard let v = T(exactly: d) else {
            throw sqliteDecodeError(typeName, value, "\(d) is not an integer in range for \(typeName)")
        }
        return v
    case let .text(s):
        guard let v = T(s, radix: 10) else {
            throw sqliteDecodeError(typeName, value, "\"\(s)\" is not an integer")
        }
        return v
    case .blob, .null:
        throw sqliteDecodeError(typeName, value)
    }
}
