import Foundation

// Codecs for common Foundation value types. SQLite has no native uuid / date / decimal type, so
// each maps onto a storage class by a documented convention (and decodes leniently from the
// others). This is the only part of the driver that leans on Foundation.

extension Data: SQLiteDecodable {
    public static func decode(from value: SQLiteValue) throws -> Data {
        switch value {
        case let .blob(b):
            return Data(b)
        case let .text(s):
            return Data(s.utf8)
        case .integer, .real, .null:
            throw sqliteDecodeError("Data", value)
        }
    }
}

extension UUID: SQLiteDecodable {
    public static func decode(from value: SQLiteValue) throws -> UUID {
        switch value {
        case let .text(s):
            guard let uuid = UUID(uuidString: s) else {
                throw sqliteDecodeError("UUID", value, "\"\(s)\" is not a UUID string")
            }
            return uuid
        case let .blob(b):
            guard b.count == 16 else {
                throw sqliteDecodeError("UUID", value, "expected 16 bytes, got \(b.count)")
            }
            return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                               b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        case .integer, .real, .null:
            throw sqliteDecodeError("UUID", value)
        }
    }
}

extension Date: SQLiteDecodable {
    /// Decode a `Date` from any of SQLite's three common date conventions: TEXT (ISO-8601),
    /// INTEGER (Unix epoch seconds), or REAL (Julian day, as `julianday()` produces).
    public static func decode(from value: SQLiteValue) throws -> Date {
        switch value {
        case let .text(s):
            guard let date = parseSQLiteDate(s) else {
                throw sqliteDecodeError("Date", value, "\"\(s)\" is not a recognized date/time")
            }
            return date
        case let .integer(i):
            return Date(timeIntervalSince1970: Double(i))
        case let .real(d):
            return dateFromJulianDay(d)
        case .blob, .null:
            throw sqliteDecodeError("Date", value)
        }
    }
}

extension Decimal: SQLiteDecodable {
    public static func decode(from value: SQLiteValue) throws -> Decimal {
        switch value {
        case let .text(s):
            guard let dec = Decimal(string: s) else {
                throw sqliteDecodeError("Decimal", value, "\"\(s)\" is not a decimal")
            }
            return dec
        case let .integer(i):
            return Decimal(i)
        case let .real(d):
            return Decimal(d)
        case .blob, .null:
            throw sqliteDecodeError("Decimal", value)
        }
    }
}

// MARK: - Parameter encoding (Foundation)

extension Data: SQLiteEncodable {
    public func encode() -> SQLiteValue { .blob(Array(self)) }
}

extension UUID: SQLiteEncodable {
    /// Stored as TEXT (the common SQLite convention); a 16-byte BLOB also decodes.
    public func encode() -> SQLiteValue { .text(uuidString) }
}

extension Date: SQLiteEncodable {
    /// Stored as ISO-8601 TEXT — human-readable, sortable, and compatible with SQLite's built-in
    /// `datetime()` functions. The decoder still accepts INTEGER (Unix) and REAL (Julian) forms.
    public func encode() -> SQLiteValue { .text(sqliteISO8601Text(self)) }
}

extension Decimal: SQLiteEncodable {
    /// Stored as TEXT to preserve exact precision — a REAL would round it to a binary double.
    public func encode() -> SQLiteValue { .text(description) }
}

// MARK: - Date helpers

/// Days between the Julian day epoch (noon, 24 Nov 4714 BC) and the Unix epoch (1970-01-01).
private let julianDayUnixEpoch = 2_440_587.5

/// A `Date` from a SQLite Julian day number, matching `julianday()`.
func dateFromJulianDay(_ jd: Double) -> Date {
    Date(timeIntervalSince1970: (jd - julianDayUnixEpoch) * 86_400)
}

/// Render a `Date` as ISO-8601 UTC text with microsecond precision: `YYYY-MM-DD HH:MM:SS.ffffff`.
/// Uses a space separator (SQLite's `datetime()` style); the time is UTC.
func sqliteISO8601Text(_ date: Date) -> String {
    let totalMicros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    var seconds = totalMicros / 1_000_000
    var micros = totalMicros - seconds * 1_000_000
    if micros < 0 { micros += 1_000_000; seconds -= 1 }          // floor toward negative infinity
    let days = Int((Double(seconds) / 86_400).rounded(.down))
    let secondOfDay = Int(seconds - Int64(days) * 86_400)
    let (year, month, day) = civilFromDays(days)
    return String(format: "%04d-%02d-%02d %02d:%02d:%02d.%06d",
                  year, month, day,
                  secondOfDay / 3600, (secondOfDay % 3600) / 60, secondOfDay % 60,
                  Int(micros))
}

/// Parse ISO-8601 / SQLite text dates: `YYYY-MM-DD`, `YYYY-MM-DD HH:MM:SS`, with optional `T`
/// separator, fractional seconds, and a `±HH[:MM]` / `Z` offset. Returns nil if it doesn't match.
/// Ported from perun-pgsql's timestamp parser.
func parseSQLiteDate(_ string: String) -> Date? {
    let scalars = Array(string.utf8)
    var index = 0

    func readInt(maxDigits: Int) -> Int? {
        var value = 0
        var count = 0
        while index < scalars.count, scalars[index] >= 0x30, scalars[index] <= 0x39, count < maxDigits {
            value = value * 10 + Int(scalars[index] - 0x30)
            index += 1
            count += 1
        }
        return count > 0 ? value : nil
    }
    func expect(_ ascii: UInt8) -> Bool {
        guard index < scalars.count, scalars[index] == ascii else { return false }
        index += 1
        return true
    }
    func isDigit(_ ascii: UInt8) -> Bool { ascii >= 0x30 && ascii <= 0x39 }

    guard let year = readInt(maxDigits: 9), expect(0x2d),           // '-'
          let month = readInt(maxDigits: 2), expect(0x2d),
          let day = readInt(maxDigits: 2) else { return nil }

    var hour = 0, minute = 0, second = 0
    var fractional = 0.0
    var offsetSeconds = 0

    // Optional time part, after a space or 'T'.
    if index < scalars.count,
       scalars[index] == 0x54
        || (scalars[index] == 0x20 && index + 1 < scalars.count && isDigit(scalars[index + 1])) {
        index += 1
        guard let h = readInt(maxDigits: 2), expect(0x3a),          // ':'
              let m = readInt(maxDigits: 2) else { return nil }
        hour = h; minute = m
        if expect(0x3a) {                                           // ':SS' is optional (SQLite allows HH:MM)
            guard let s = readInt(maxDigits: 2) else { return nil }
            second = s
        }

        if expect(0x2e) {                                           // '.frac'
            let start = index
            guard let frac = readInt(maxDigits: 9) else { return nil }
            let digits = index - start
            fractional = Double(frac) / pow(10.0, Double(digits))
            while index < scalars.count, isDigit(scalars[index]) { index += 1 }   // ignore sub-ns excess
        }

        // Optional timezone offset: ±HH[[:]MM[[:]SS]] or 'Z' — the colons are optional (e.g. +0530).
        if index < scalars.count, scalars[index] == 0x2b || scalars[index] == 0x2d {
            let negative = scalars[index] == 0x2d
            index += 1
            guard let oh = readInt(maxDigits: 2) else { return nil }
            _ = expect(0x3a)
            let om = readInt(maxDigits: 2) ?? 0
            _ = expect(0x3a)
            let os = readInt(maxDigits: 2) ?? 0
            let magnitude = oh * 3600 + om * 60 + os
            offsetSeconds = negative ? -magnitude : magnitude
        } else if index < scalars.count, scalars[index] == 0x5a {  // 'Z'
            index += 1
        }
    }

    guard index == scalars.count else { return nil }

    let days = daysFromCivil(year: year, month: month, day: day)
    let epochSeconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second)
        + fractional - Double(offsetSeconds)
    return Date(timeIntervalSince1970: epochSeconds)
}

/// Days from the Unix epoch (1970-01-01) to the given proleptic Gregorian date.
/// Howard Hinnant's `days_from_civil`.
private func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yearOfEra = y - era * 400                                   // [0, 399]
    let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
}

/// Inverse of `daysFromCivil`: the proleptic Gregorian date for a day count since 1970-01-01.
/// Howard Hinnant's `civil_from_days`.
private func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let dayOfEra = z - era * 146_097                                              // [0, 146096]
    let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let year = yearOfEra + era * 400
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)  // [0, 365]
    let monthPortion = (5 * dayOfYear + 2) / 153                                  // [0, 11]
    let day = dayOfYear - (153 * monthPortion + 2) / 5 + 1                        // [1, 31]
    let month = monthPortion < 10 ? monthPortion + 3 : monthPortion - 9          // [1, 12]
    return (month <= 2 ? year + 1 : year, month, day)
}
