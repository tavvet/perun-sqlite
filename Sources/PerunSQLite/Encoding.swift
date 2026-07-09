/// A Swift value that can be bound as a query parameter.
///
/// Where perun-pgsql's `PostgresEncodable` renders a value as text (and optionally binary) for the
/// wire, SQLite takes typed values directly, so a value just maps itself onto one of the five
/// storage classes as a `SQLiteValue`. The driver then binds it with the matching
/// `sqlite3_bind_*` call.
///
/// SQL NULL is signalled separately, by a `nil` element in the parameter array — not by this
/// protocol.
public protocol SQLiteEncodable: Sendable {
    func encode() -> SQLiteValue
}

extension Bool: SQLiteEncodable {
    public func encode() -> SQLiteValue { .integer(self ? 1 : 0) }
}

extension Int: SQLiteEncodable {
    public func encode() -> SQLiteValue { .integer(Int64(self)) }
}

extension Int16: SQLiteEncodable {
    public func encode() -> SQLiteValue { .integer(Int64(self)) }
}

extension Int32: SQLiteEncodable {
    public func encode() -> SQLiteValue { .integer(Int64(self)) }
}

extension Int64: SQLiteEncodable {
    public func encode() -> SQLiteValue { .integer(self) }
}

extension Double: SQLiteEncodable {
    public func encode() -> SQLiteValue { .real(self) }
}

extension Float: SQLiteEncodable {
    public func encode() -> SQLiteValue { .real(Double(self)) }
}

extension String: SQLiteEncodable {
    public func encode() -> SQLiteValue { .text(self) }
}

extension Array: SQLiteEncodable where Element == UInt8 {
    public func encode() -> SQLiteValue { .blob(self) }
}

extension SQLiteValue: SQLiteEncodable {
    /// A `SQLiteValue` binds as itself — the escape hatch for controlling the exact storage class.
    public func encode() -> SQLiteValue { self }
}
