import XCTest
@testable import PerunSQLite

final class SmokeTests: XCTestCase {
    func testValueStorageClass() {
        XCTAssertEqual(SQLiteValue.integer(1).storageClass, .integer)
        XCTAssertTrue(SQLiteValue.null.isNull)
    }

    func testResultCodeRoundTrip() {
        XCTAssertEqual(SQLiteResultCode(code: 2067), .constraintUnique)
        XCTAssertEqual(SQLiteResultCode.constraintUnique.code, 2067)
        XCTAssertTrue(SQLiteResultCode.constraintUnique.isConstraintViolation)
    }
}
