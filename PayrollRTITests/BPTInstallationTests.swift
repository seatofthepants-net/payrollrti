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

    func testLocateFindsInstallAndReadsFullVersion() throws {
        // Real BPT: CFBundleShortVersionString "26.1", CFBundleVersion "26.1.26134.173934".
        let fake = try FakeBPT.make(version: "26.1.26134.173934", shortVersion: "26.1")
        defer { FakeBPT.remove(fake) }
        let found = try XCTUnwrap(BPTInstallation.locate(at: fake.appURL))
        XCTAssertEqual(found.version?.description, "26.1.26134.173934")
    }
}
