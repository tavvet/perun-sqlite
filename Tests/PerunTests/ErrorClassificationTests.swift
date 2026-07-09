import XCTest
@testable import PerunSQLite

final class ErrorClassificationTests: XCTestCase {
    func testResultCodeRoundTrips() {
        let codes: [Int32] = [0, 1, 5, 6, 8, 11, 14, 19, 20, 21, 26,
                              275, 787, 1299, 1555, 1811, 2067, 2579, 3091, 261, 517]
        for code in codes {
            XCTAssertEqual(SQLiteResultCode(code: code).code, code, "round trip for \(code)")
        }
        XCTAssertEqual(SQLiteResultCode(code: 999), .other(999))
        XCTAssertEqual(SQLiteResultCode.other(999).code, 999)
    }

    func testPrimaryCodeAndClassHelpers() {
        XCTAssertEqual(SQLiteResultCode.constraintUnique.primaryCode, 19)
        XCTAssertTrue(SQLiteResultCode.constraintUnique.isConstraintViolation)
        XCTAssertTrue(SQLiteResultCode.constraintForeignKey.isConstraintViolation)
        XCTAssertFalse(SQLiteResultCode.busy.isConstraintViolation)
        XCTAssertTrue(SQLiteResultCode.busy.isBusy)
        XCTAssertTrue(SQLiteResultCode.locked.isBusy)
        XCTAssertTrue(SQLiteResultCode.busySnapshot.isBusy)
        XCTAssertFalse(SQLiteResultCode.readonly.isBusy)
    }

    func testShouldDiscardConnection() {
        // Doubtful-handle errors → discard.
        XCTAssertTrue(PerunError.connectionClosed.shouldDiscardConnection)
        XCTAssertTrue(PerunError.connectionFailed("x").shouldDiscardConnection)
        XCTAssertTrue(PerunError.sqlite(SQLiteError(extendedCode: 11, message: "corrupt")).shouldDiscardConnection)
        XCTAssertTrue(PerunError.sqlite(SQLiteError(extendedCode: 10, message: "io")).shouldDiscardConnection)
        XCTAssertTrue(PerunError.sqlite(SQLiteError(extendedCode: 26, message: "notadb")).shouldDiscardConnection)

        // Everyday errors → keep the connection.
        XCTAssertFalse(PerunError.sqlite(SQLiteError(extendedCode: 2067, message: "unique")).shouldDiscardConnection)
        XCTAssertFalse(PerunError.sqlite(SQLiteError(extendedCode: 1, message: "generic")).shouldDiscardConnection)
        XCTAssertFalse(PerunError.unexpectedNull(column: "x").shouldDiscardConnection)
        XCTAssertFalse(PerunError.columnNotFound("x").shouldDiscardConnection)
        XCTAssertFalse(PerunError.decodingFailed(type: "Int", storageClass: "TEXT", reason: "").shouldDiscardConnection)
        XCTAssertFalse(PerunError.parameterCountMismatch(expected: 1, got: 0).shouldDiscardConnection)
        XCTAssertFalse(PerunError.timedOut.shouldDiscardConnection)
        XCTAssertFalse(PerunError.clientShutdown.shouldDiscardConnection)
    }

    func testParameterCountMismatch() async throws {
        let conn = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await conn.close() } }
        try await conn.query("CREATE TABLE t (a, b)")
        do {
            try await conn.query("INSERT INTO t (a, b) VALUES (?, ?)", ["only-one"])
            XCTFail("expected a parameter-count mismatch")
        } catch let error as PerunError {
            guard case let .parameterCountMismatch(expected, got) = error else {
                return XCTFail("expected parameterCountMismatch, got \(error)")
            }
            XCTAssertEqual(expected, 2)
            XCTAssertEqual(got, 1)
        }
    }

    func testPreparedStatementConnectionScoping() async throws {
        let a = try await SQLiteConnection.connect(.memory())
        let b = try await SQLiteConnection.connect(.memory())
        defer { Task { try? await a.close(); try? await b.close() } }
        try await a.query("CREATE TABLE t (v)")
        let stmt = try await a.prepare("INSERT INTO t (v) VALUES (?)")
        do {
            _ = try await b.execute(stmt, [1])          // wrong connection
            XCTFail("expected a connection mismatch")
        } catch let error as PerunError {
            guard case .preparedStatementConnectionMismatch = error else {
                return XCTFail("expected preparedStatementConnectionMismatch, got \(error)")
            }
        }
    }
}
