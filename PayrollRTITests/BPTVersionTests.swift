import XCTest

@testable import PayrollRTI

final class BPTVersionTests: XCTestCase {
    func testParsesDottedVersions() {
        XCTAssertEqual(BPTVersion("26.1.26134.173934")?.components, [26, 1, 26134, 173934])
        XCTAssertEqual(BPTVersion(" 25.2 ")?.description, "25.2")
    }

    func testRejectsNonNumericVersions() {
        XCTAssertNil(BPTVersion(""))
        XCTAssertNil(BPTVersion("26.1.beta"))
        XCTAssertNil(BPTVersion("26..1"))
    }

    func testOrdersComponentByComponent() throws {
        let older = try XCTUnwrap(BPTVersion("26.1.26134.173934"))
        let newer = try XCTUnwrap(BPTVersion("26.1.26200.1"))
        XCTAssertLessThan(older, newer)
        XCTAssertLessThan(try XCTUnwrap(BPTVersion("25.9")), try XCTUnwrap(BPTVersion("26.0")))
        XCTAssertLessThan(try XCTUnwrap(BPTVersion("26.1.9")), try XCTUnwrap(BPTVersion("26.1.10")))
    }

    func testTrailingZerosAreEqual() {
        XCTAssertEqual(BPTVersion("26.1"), BPTVersion("26.1.0"))
    }
}
