// Decoders for the fundamental scalar types. SQLite is loosely typed, so each decoder accepts the
// storage classes that can sensibly represent the Swift type (mirroring SQLite's own coercions),
// and rejects the rest with a decode error rather than returning a lossy value.

extension Bool: SQLiteDecodable {
    public static func decode(from value: SQLiteValue) throws -> Bool {
        switch value {
        case let .integer(i):
            return i != 0
        case let .real(d):
            return d != 0
        case let .text(s):
            switch s.lowercased() {
            case "1", "t", "true", "y", "yes", "on": return true
            case "0", "f", "false", "n", "no", "off": return false
            default: throw sqliteDecodeError("Bool", value, "\"\(s)\" is not a boolean")
            }
        case .blob, .null:
            throw sqliteDecodeError("Bool", value)
        }
    }
}

extension Int: SQLiteDecodable {
    public static func decode(from value: SQLiteValue) throws -> Int {
        try decodeSQLiteInteger(value, "Int")
    }
}

extension Int16: SQLiteDecodable {
    public static func decode(from value: SQLiteValue) throws -> Int16 {
        try decodeSQLiteInteger(value, "Int16")
    }
}

extension Int32: SQLiteDecodable {
    public static func decode(from value: SQLiteValue) throws -> Int32 {
        try decodeSQLiteInteger(value, "Int32")
    }
}

extension Int64: SQLiteDecodable {
    public static func decode(from value: SQLiteValue) throws -> Int64 {
        try decodeSQLiteInteger(value, "Int64")
    }
}

extension Double: SQLiteDecodable {
    public static func decode(from value: SQLiteValue) throws -> Double {
        switch value {
        case let .real(d):
            return d
        case let .integer(i):
            return Double(i)
        case let .text(s):
            guard let d = Double(s) else {
                throw sqliteDecodeError("Double", value, "\"\(s)\" is not a number")
            }
            return d
        case .blob, .null:
            throw sqliteDecodeError("Double", value)
        }
    }
}

extension Float: SQLiteDecodable {
    public static func decode(from value: SQLiteValue) throws -> Float {
        switch value {
        case let .real(d):
            // Allow rounding to the nearest Float, but not silent overflow: a finite REAL that
            // doesn't fit Float must error rather than become ±infinity (the integer path already
            // rejects out-of-range via T(exactly:)).
            let f = Float(d)
            guard f.isFinite || !d.isFinite else {
                throw sqliteDecodeError("Float", value, "\(d) is out of range for Float")
            }
            return f
        case let .integer(i):
            guard let f = Float(exactly: i) else {
                throw sqliteDecodeError("Float", value, "\(i) is not exactly representable as Float")
            }
            return f
        case let .text(s):
            guard let f = Float(s) else {
                throw sqliteDecodeError("Float", value, "\"\(s)\" is not a number")
            }
            return f
        case .blob, .null:
            throw sqliteDecodeError("Float", value)
        }
    }
}

extension String: SQLiteDecodable {
    public static func decode(from value: SQLiteValue) throws -> String {
        switch value {
        case let .text(s):
            return s
        case let .integer(i):
            return String(i)
        case let .real(d):
            return String(d)
        case let .blob(b):
            return String(decoding: b, as: UTF8.self)
        case .null:
            throw sqliteDecodeError("String", value)
        }
    }
}

extension Array: SQLiteDecodable where Element == UInt8 {
    /// A BLOB decodes to its raw bytes; TEXT decodes to its UTF-8 bytes.
    public static func decode(from value: SQLiteValue) throws -> [UInt8] {
        switch value {
        case let .blob(b):
            return b
        case let .text(s):
            return Array(s.utf8)
        case .integer, .real, .null:
            throw sqliteDecodeError("[UInt8]", value)
        }
    }
}
