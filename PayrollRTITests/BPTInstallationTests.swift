import XCTest

@testable import PayrollRTI

final class BPTInstallationTests: XCTestCase {
    func testMacInstallerCommandMatchesHMRCWorkaround() throws {
        let fake = try FakeBPT.make()
        defer { FakeBPT.remove(fake) }
        let command = fake.command(["runserver", "46729"])
        XCTAssertEqual(
            command.executable.path,
            fake.location.appendingPathComponent("Contents/Helpers/rti.app/Contents/MacOS/rti").path,
            "HMRC's workaround path, inside the outer app")
        XCTAssertEqual(command.arguments, ["runserver", "46729"])
        XCTAssertEqual(command.workingDirectory, command.executable.deletingLastPathComponent())
        XCTAssertTrue(command.environment.isEmpty)
    }

    func testRelocatedServerAppIsAcceptedOnItsOwn() throws {
        // macOS's installer can put the server app on its own (e.g. /Applications/HMRC/payetools-rti/rti.app).
        let fake = try FakeBPT.make(version: "0.0.0", shortVersion: "26.1.26134", serverAppOnly: true)
        defer { FakeBPT.remove(fake) }
        let found = try XCTUnwrap(BPTInstallation.locate(engine: .macInstaller, candidates: [fake.location]))
        XCTAssertEqual(
            found.command([]).executable.path, fake.location.appendingPathComponent("Contents/MacOS/rti").path)
        XCTAssertEqual(found.version?.description, "26.1.26134", "the server app's plist carries the version")
    }

    func testLocateTakesTheFirstUsableCandidate() throws {
        let first = try FakeBPT.make(version: "26.0.26069.145147")
        let second = try FakeBPT.make(version: "26.1.26134.173934")
        defer {
            FakeBPT.remove(first)
            FakeBPT.remove(second)
        }
        let missing = URL(fileURLWithPath: "/nonexistent/Basic PAYE Tools.app")
        let found = BPTInstallation.locate(
            engine: .macInstaller, candidates: [missing, first.location, second.location])
        XCTAssertEqual(found?.version?.description, "26.0.26069.145147")
    }

    func testLocateReturnsNilWhenMissing() {
        let missing = URL(fileURLWithPath: "/nonexistent/Basic PAYE Tools.app")
        XCTAssertNil(BPTInstallation.locate(engine: .macInstaller, candidates: [missing]))
    }

    func testLocateFindsInstallAndReadsFullVersion() throws {
        // Real BPT: CFBundleShortVersionString "26.1", CFBundleVersion "26.1.26134.173934".
        let fake = try FakeBPT.make(version: "26.1.26134.173934", shortVersion: "26.1")
        defer { FakeBPT.remove(fake) }
        let found = try XCTUnwrap(BPTInstallation.locate(engine: .macInstaller, candidates: [fake.location]))
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
