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
        _ installation: BPTInstallation?, port: Int, grace: TimeInterval = 5
    ) -> ServerController {
        if let installation { installations.append(installation) }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("rti-test-\(UUID().uuidString).log")
        return ServerController(
            locate: { installation },
            port: { port },
            startupTimeout: 20,
            terminationGrace: grace,
            logURL: log)
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
