import XCTest
import Foundation
@testable import PerunSQLite

final class TypeTests: XCTestCase {
    // MARK: - Decoding directly from SQLiteValue

    func testIntegerDecoding() throws {
        XCTAssertEqual(try Int.decode(from: .integer(42)), 42)
        XCTAssertEqual(try Int32.decode(from: .integer(-7)), -7)
        XCTAssertEqual(try Int.decode(from: .text("123")), 123)
        XCTAssertEqual(try Int.decode(from: .real(9.0)), 9)
        XCTAssertThrowsError(try Int.decode(from: .real(9.5)))          // not an exact integer
        XCTAssertThrowsError(try Int16.decode(from: .integer(70_000)))  // out of range
        XCTAssertThrowsError(try Int.decode(from: .text("abc")))
        XCTAssertThrowsError(try Int.decode(from: .null))
    }

    func testDoubleAndBool() throws {
        XCTAssertEqual(try Double.decode(from: .real(1.5)), 1.5)
        XCTAssertEqual(try Double.decode(from: .integer(3)), 3.0)
        XCTAssertEqual(try Double.decode(from: .text("2.25")), 2.25)
        XCTAssertEqual(try Bool.decode(from: .integer(1)), true)
        XCTAssertEqual(try Bool.decode(from: .integer(0)), false)
        XCTAssertEqual(try Bool.decode(from: .text("true")), true)
        XCTAssertEqual(try Bool.decode(from: .text("no")), false)
        XCTAssertThrowsError(try Bool.decode(from: .text("maybe")))
    }

    func testStringAndBlob() throws {
        XCTAssertEqual(try String.decode(from: .text("hi")), "hi")
        XCTAssertEqual(try String.decode(from: .integer(5)), "5")
        XCTAssertEqual(try [UInt8].decode(from: .blob([1, 2, 3])), [1, 2, 3])
        XCTAssertEqual(try [UInt8].decode(from: .text("AB")), [0x41, 0x42])
    }

    func testEncoding() {
        XCTAssertEqual(true.encode(), .integer(1))
        XCTAssertEqual(42.encode(), .integer(42))
        XCTAssertEqual(Int64(9).encode(), .integer(9))
        XCTAssertEqual(1.5.encode(), .real(1.5))
        XCTAssertEqual("x".encode(), .text("x"))
        XCTAssertEqual([UInt8]([0xFF]).encode(), .blob([0xFF]))
    }

    // MARK: - Foundation types

    func testUUIDRoundTrip() throws {
        let uuid = UUID()
        let encoded = uuid.encode()
        XCTAssertEqual(encoded, .text(uuid.uuidString))
        XCTAssertEqual(try UUID.decode(from: encoded), uuid)
        // Also decodes from a 16-byte blob.
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        XCTAssertEqual(try UUID.decode(from: .blob(bytes)), uuid)
    }

    func testDecimalRoundTrip() throws {
        let value = Decimal(string: "-12345.6789")!
        XCTAssertEqual(value.encode(), .text("-12345.6789"))
        XCTAssertEqual(try Decimal.decode(from: value.encode()), value)
    }

    func testDateRoundTripAllConventions() throws {
        let date = Date(timeIntervalSince1970: 1_752_062_400.0)   // 2025-07-09 12:00:00 UTC
        // ISO-8601 text (the default encoding) round-trips to within a millisecond.
        let encoded = date.encode()
        let fromText = try Date.decode(from: encoded)
        XCTAssertEqual(fromText.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        // INTEGER Unix seconds.
        let fromInt = try Date.decode(from: .integer(1_752_062_400))
        XCTAssertEqual(fromInt.timeIntervalSince1970, 1_752_062_400, accuracy: 0.001)
        // REAL Julian day (SQLite's julianday of the same instant).
        let julian = 2_440_587.5 + 1_752_062_400.0 / 86_400.0
        let fromReal = try Date.decode(from: .real(julian))
        XCTAssertEqual(fromReal.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }

    func testJSONRoundTrip() throws {
        let json = SQLiteJSON("{\"a\":1}")
        XCTAssertEqual(json.encode(), .text("{\"a\":1}"))
        XCTAssertEqual(try SQLiteJSON.decode(from: json.encode()).text, "{\"a\":1}")
    }

    // MARK: - Round trip through the database

    func testDatabaseRoundTrip() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        try await conn.query("""
            CREATE TABLE t (i INTEGER, d REAL, s TEXT, b BLOB, u TEXT, dt TEXT, dec TEXT)
            """)

        let uuid = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let decimal = Decimal(string: "3.14159")!
        try await conn.query(
            "INSERT INTO t (i, d, s, b, u, dt, dec) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [7, 2.5, "text", [UInt8]([9, 8, 7]), uuid, date, decimal])

        let row = try await conn.query("SELECT * FROM t").rows[0]
        XCTAssertEqual(try row.decode("i", as: Int.self), 7)
        XCTAssertEqual(try row.decode("d", as: Double.self), 2.5)
        XCTAssertEqual(try row.decode("s", as: String.self), "text")
        XCTAssertEqual(try row.decode("b", as: [UInt8].self), [9, 8, 7])
        XCTAssertEqual(try row.decode("u", as: UUID.self), uuid)
        XCTAssertEqual(try row.decode("dt", as: Date.self).timeIntervalSince1970,
                       date.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try row.decode("dec", as: Decimal.self), decimal)
    }

    func testColumnMetadataDeclaredType() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        try await conn.query("CREATE TABLE t (id INTEGER, name VARCHAR(50))")
        let result = try await conn.query("SELECT id, name, id + 1 AS computed FROM t")
        XCTAssertEqual(result.columns[0].declaredType, "INTEGER")
        XCTAssertEqual(result.columns[1].declaredType, "VARCHAR(50)")
        XCTAssertNil(result.columns[2].declaredType)     // an expression has no declared type
    }
}
