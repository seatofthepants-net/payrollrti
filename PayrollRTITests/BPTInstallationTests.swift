import XCTest

@testable import PayrollRTI

final class BPTInstallationTests: XCTestCase {
    func testExecutableMatchesHMRCWorkaroundPath() {
        XCTAssertEqual(
            BPTInstallation(appURL: BPTInstallation.defaultAppURL).executableURL.path,
            "/Applications/Basic PAYE Tools.app/Contents/Helpers/rti.app/Contents/MacOS/rti")
    }

    func testLocateReturnsNilWhenMissing() {
        let missing = URL(fileURLWithPath: "/nonexistent/Basic PAYE Tools.app")
        XCTAssertNil(BPTInstallation.locate(at: missing))
    }

    func testLocateFindsInstallAndReadsVersion() throws {
        let fake = try FakeBPT.make(version: "26.1.26134.173934")
        defer { FakeBPT.remove(fake) }
        let found = try XCTUnwrap(BPTInstallation.locate(at: fake.appURL))
        XCTAssertEqual(found.version, BPTVersion("26.1.26134.173934"))
    }
}
