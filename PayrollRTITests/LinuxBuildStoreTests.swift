import XCTest

@testable import PayrollRTI

final class LinuxBuildStoreTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("LinuxBuildStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    /// A payload root with the files `installed()` and the launcher look for.
    private func makePayload(_ version: String, complete: Bool = true) throws -> URL {
        let root = temp.appendingPathComponent(version)
        let server = root.appendingPathComponent("bptserver")
        try FileManager.default.createDirectory(
            at: server.appendingPathComponent("django/core/management/commands"), withIntermediateDirectories: true)
        if complete {
            try Data("PK".utf8).write(to: server.appendingPathComponent("rti.linux"))
        }
        try LinuxBuildStore.layOut(root)
        return root
    }

    func testLayoutMatchesWhatHMRCsDarwinBranchExpects() throws {
        let root = try makePayload("26.1.26134.173934")
        let base = root.appendingPathComponent("rti.app/Contents/MacOS")
        // BASE_PATH/../../.. must be the payload root, which holds the loose django tree.
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("rti.linux").path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("django/core/management/commands").path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: base.path), "../../bptserver",
            "relative links keep the payload movable")
    }

    func testInstalledListsCompletePayloadsNewestLast() throws {
        _ = try makePayload("26.1.26134.173934")
        _ = try makePayload("26.0.26069.145147")
        _ = try makePayload("27.0.27100.1", complete: false)
        try FileManager.default.createDirectory(
            at: temp.appendingPathComponent("tmp-download"), withIntermediateDirectories: true)

        let versions = LinuxBuildStore.installed(in: temp).map(\.version.description)
        XCTAssertEqual(versions, ["26.0.26069.145147", "26.1.26134.173934"])
        XCTAssertEqual(LinuxBuildStore.newest(in: temp)?.version.description, "26.1.26134.173934")
        XCTAssertEqual(LinuxBuildStore.installed(in: temp.appendingPathComponent("missing")), [])
    }

    func testMissingModulesIgnoresSharedLibrariesAndKnownModules() throws {
        let runtime = LinuxBuildRuntime(directory: temp)
        try """
            # comment
            _ssl
            Ft.Xml.cDomlettec
            reportlab.lib._rl_accel

            """.write(to: temp.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
        let extensions = [
            "libpython2.7.so.1.0", "libcrypto.so.1.1", "libz-a147dcb0.so.1.2.3",
            "_ssl.so", "Ft.Xml.cDomlettec.so", "reportlab.lib._rl_accel.so",
            "lxml.etree.so", "_brandnew.so",
        ]
        XCTAssertEqual(
            LinuxBuildStore.missingModules(extensions: extensions, runtime: runtime), ["_brandnew", "lxml.etree"])
        XCTAssertEqual(LinuxBuildStore.missingModules(extensions: ["libfoo.so"], runtime: runtime), [])
    }

    func testMissingModulesWithoutManifestReportsEverything() {
        let runtime = LinuxBuildRuntime(directory: temp.appendingPathComponent("no-runtime"))
        XCTAssertEqual(LinuxBuildStore.missingModules(extensions: ["_ssl.so"], runtime: runtime), ["_ssl"])
    }
}
