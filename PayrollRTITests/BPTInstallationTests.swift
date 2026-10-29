import XCTest

@testable import PayrollRTI

final class BPTInstallationTests: XCTestCase {
    func testMacInstallerCommandMatchesHMRCWorkaround() {
        let installation = BPTInstallation.macInstaller(appURL: BPTInstallation.defaultAppURL)
        let command = installation.command(["runserver", "46729"])
        XCTAssertEqual(
            command.executable.path, "/Applications/Basic PAYE Tools.app/Contents/Helpers/rti.app/Contents/MacOS/rti")
        XCTAssertEqual(command.arguments, ["runserver", "46729"])
        XCTAssertEqual(command.workingDirectory, command.executable.deletingLastPathComponent())
        XCTAssertTrue(command.environment.isEmpty)
    }

    func testLocateReturnsNilWhenMissing() {
        let missing = URL(fileURLWithPath: "/nonexistent/Basic PAYE Tools.app")
        XCTAssertNil(BPTInstallation.locate(engine: .macInstaller, appURL: missing))
    }

    func testLocateFindsInstallAndReadsFullVersion() throws {
        // Real BPT: CFBundleShortVersionString "26.1", CFBundleVersion "26.1.26134.173934".
        let fake = try FakeBPT.make(version: "26.1.26134.173934", shortVersion: "26.1")
        defer { FakeBPT.remove(fake) }
        let found = try XCTUnwrap(BPTInstallation.locate(engine: .macInstaller, appURL: fake.location))
        XCTAssertEqual(found.engine, .macInstaller)
        XCTAssertEqual(found.version?.description, "26.1.26134.173934")
    }

    func testLinuxBuildCommandRunsTheLauncherOnTheBundledPython() throws {
        let runtime = LinuxBuildRuntime(directory: URL(fileURLWithPath: "/App/Contents/Resources/LinuxBuildRuntime"))
        let payload = try XCTUnwrap(
            LinuxBuildPayload(directory: URL(fileURLWithPath: "/Store/26.1.26134.173934")))
        let installation = BPTInstallation.linuxBuild(payload: payload, runtime: runtime)
        XCTAssertEqual(installation.version?.description, "26.1.26134.173934")

        let command = installation.command(["startdb"])
        XCTAssertEqual(command.executable.path, "/App/Contents/Resources/LinuxBuildRuntime/bin/python2.7")
        XCTAssertEqual(command.arguments, ["-S", "-B", "/App/Contents/Resources/LinuxBuildRuntime/rti", "startdb"])
        // settings_central's darwin branch wants to sit inside rti.app/Contents/MacOS, three levels under INSTALL_DIR.
        XCTAssertEqual(command.workingDirectory.path, "/Store/26.1.26134.173934/rti.app/Contents/MacOS")
        XCTAssertEqual(command.environment["BPT_REHOST_PAYLOAD"], "/Store/26.1.26134.173934/rti.app/Contents/MacOS")
        XCTAssertEqual(command.environment["PYTHONHOME"], "/App/Contents/Resources/LinuxBuildRuntime")
        XCTAssertNil(command.environment["APPDATA"], "both engines must share ~/HMRC/payetools-rti")
    }

    func testPayloadDirectoryMustBeNamedAfterItsVersion() {
        XCTAssertNil(LinuxBuildPayload(directory: URL(fileURLWithPath: "/Store/tmp-26.1")))
        XCTAssertNotNil(LinuxBuildPayload(directory: URL(fileURLWithPath: "/Store/26.0.26069.145147")))
    }
}
