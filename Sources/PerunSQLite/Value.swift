/// A value in one of SQLite's five storage classes.
///
/// SQLite is dynamically typed: the engine hands back an already-typed value, so — unlike a
/// wire protocol that delivers raw bytes tagged with a type OID — this driver carries values
/// *typed* all the way to decoding. `SQLiteValue` is that carrier, and the analogue of
/// perun-pgsql's "raw bytes + OID + text/binary format": one representation, no format split.
///
/// A `SQLiteCell` wraps one of these; decode it into a Swift type with `decode(_:)` /
/// `decodeIfPresent(_:)`.
public enum SQLiteValue: Sendable, Equatable {
    /// SQL NULL.
    case null
    /// A 64-bit signed integer (`sqlite3_column_int64`).
    case integer(Int64)
    /// An IEEE-754 double (`sqlite3_column_double`).
    case real(Double)
    /// UTF-8 text (`sqlite3_column_text`).
    case text(String)
    /// A byte blob (`sqlite3_column_blob`).
    case blob([UInt8])

    /// The storage class of this value — matches `sqlite3_column_type`'s `SQLITE_NULL` /
    /// `SQLITE_INTEGER` / `SQLITE_FLOAT` / `SQLITE_TEXT` / `SQLITE_BLOB`.
    public var storageClass: SQLiteStorageClass {
        switch self {
        case .null: return .null
        case .integer: return .integer
        case .real: return .real
        case .text: return .text
        case .blob: return .blob
        }
    }

    /// Whether this value is SQL NULL.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// SQLite's five storage classes (see <https://sqlite.org/datatype3.html>).
public enum SQLiteStorageClass: Sendable, Equatable, CustomStringConvertible {
    case null
    case integer
    case real
    case text
    case blob

    public var description: String {
        switch self {
        case .null: return "NULL"
        case .integer: return "INTEGER"
        case .real: return "REAL"
        case .text: return "TEXT"
        case .blob: return "BLOB"
        }
    }
}
