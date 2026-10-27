import XCTest

@testable import PayrollRTI

@MainActor
final class ServerControllerTests: XCTestCase {
    private var installations: [BPTInstallation] = []

    override func tearDown() async throws {
        installations.forEach(FakeBPT.remove)
        try await super.tearDown()
    }

    private func makeController(
        _ installation: BPTInstallation?, port: Int, grace: TimeInterval = 5, dataDirectory: URL? = nil
    ) -> ServerController {
        if let installation { installations.append(installation) }
        let temp = FileManager.default.temporaryDirectory
        return ServerController(
            locate: { installation },
            port: { port },
            startupTimeout: 20,
            terminationGrace: grace,
            maintenanceTimeout: 20,
            logURL: temp.appendingPathComponent("rti-test-\(UUID().uuidString).log"),
            dataDirectory: dataDirectory ?? temp.appendingPathComponent("bpt-data-\(UUID().uuidString)"))
    }

    private func waitFor(
        _ controller: ServerController, timeout: TimeInterval = 20, until predicate: (ServerController.State) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !predicate(controller.state) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func testReportsNotInstalled() {
        let controller = makeController(nil, port: FakeBPT.freePort())
        controller.start()
        XCTAssertEqual(controller.state, .notInstalled)
        XCTAssertNil(controller.installation)
    }

    func testStartsServesAndStopsCleanly() async throws {
        let port = FakeBPT.freePort()
        let controller = makeController(try FakeBPT.make(), port: port)
        controller.start()
        XCTAssertEqual(controller.state, .starting)
        await waitFor(controller) { $0 == .running }
        XCTAssertEqual(controller.state, .running)
        XCTAssertFalse(controller.isExternal)
        XCTAssertEqual(controller.baseURL.absoluteString, "http://127.0.0.1:\(port)/")
        let served = await ServerController.httpProbe(controller.baseURL)
        XCTAssertTrue(served)

        await controller.stop()
        XCTAssertEqual(controller.state, .stopped)
        let stillServing = await ServerController.httpProbe(controller.baseURL)
        XCTAssertFalse(stillServing, "server (including its child process) should be gone")
    }

    func testRunsTheSameLifecycleAsBPTsOwnLauncher() async throws {
        let port = FakeBPT.freePort()
        let fake = try FakeBPT.make()
        let controller = makeController(fake, port: port)
        controller.start()
        await waitFor(controller) { $0 == .running }
        XCTAssertEqual(FakeBPT.calls(fake), ["startdb", "updatecheck", "runserver \(port)"])

        await controller.stop()
        XCTAssertEqual(FakeBPT.calls(fake), ["startdb", "updatecheck", "runserver \(port)", "autobackup"])
    }

    func testDoesNotStartServerWhenStartdbFails() async throws {
        let fake = try FakeBPT.make(behaviour: .startdbFails)
        let controller = makeController(fake, port: FakeBPT.freePort())
        controller.start()
        await waitFor(controller) {
            if case .failed = $0 { return true }
            return false
        }
        guard case .failed(let message) = controller.state else {
            return XCTFail("expected failure, got \(controller.state)")
        }
        XCTAssertTrue(message.contains("couldn't prepare its database"), message)
        XCTAssertTrue(message.contains("Failed to start up the database"), message)
        XCTAssertEqual(FakeBPT.calls(fake), ["startdb"])
    }

    func testMovesEmptyDatabaseAsideButLeavesRealOnesAlone() async throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("bpt-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: data) }
        let database = data.appendingPathComponent("sqlite3.db")
        FileManager.default.createFile(atPath: database.path, contents: Data())

        let controller = makeController(try FakeBPT.make(), port: FakeBPT.freePort(), dataDirectory: data)
        controller.start()
        await waitFor(controller) { $0 == .running }
        await controller.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        let contents = try FileManager.default.contentsOfDirectory(atPath: data.path)
        XCTAssertTrue(contents.contains { $0.hasPrefix("sqlite3.db.empty-") }, "\(contents)")

        // A database with data in it must never be touched.
        try Data("SQLite format 3".utf8).write(to: database)
        controller.start()
        await waitFor(controller) { $0 == .running }
        await controller.stop()
        XCTAssertEqual(try Data(contentsOf: database), Data("SQLite format 3".utf8))
    }

    func testEscalatesToSIGKILLWhenTermIsIgnored() async throws {
        let port = FakeBPT.freePort()
        let controller = makeController(try FakeBPT.make(behaviour: .ignoreTerm), port: port, grace: 1)
        controller.start()
        await waitFor(controller) { $0 == .running }
        XCTAssertEqual(controller.state, .running)

        let started = Date()
        await controller.stop()
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 1, "should have waited out the grace period")
        let stillServing = await ServerController.httpProbe(controller.baseURL)
        XCTAssertFalse(stillServing)
    }

    func testReportsCrashWithLogTail() async throws {
        let controller = makeController(try FakeBPT.make(behaviour: .crash), port: FakeBPT.freePort())
        controller.start()
        await waitFor(controller) {
            if case .failed = $0 { return true }
            return false
        }
        guard case .failed(let message) = controller.state else {
            return XCTFail("expected failure, got \(controller.state)")
        }
        XCTAssertTrue(message.contains("exit code 3"), message)
        XCTAssertTrue(message.contains("fake rti: boom"), message)
    }

    func testAttachesToServerAlreadyRunningOnPort() async throws {
        let port = FakeBPT.freePort()
        let first = makeController(try FakeBPT.make(), port: port)
        first.start()
        await waitFor(first) { $0 == .running }

        let second = makeController(try FakeBPT.make(), port: port)
        second.start()
        await waitFor(second) { $0 == .running }
        XCTAssertTrue(second.isExternal)
        XCTAssertFalse(second.ownsRunningProcess)

        await first.stop()
    }
}
