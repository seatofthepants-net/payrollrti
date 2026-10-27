import AppKit
import Foundation

/// Runs `rti runserver <port>` on the user's behalf: the same thing HMRC's Terminal workaround does by hand.
@MainActor
final class ServerController: ObservableObject {
    enum State: Equatable {
        case notInstalled
        case stopped
        case starting
        case running
        case stopping
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var installation: BPTInstallation?
    @Published private(set) var activePort: Int
    /// True when something was already serving on the port before we started (e.g. a Terminal session).
    @Published private(set) var isExternal = false

    let logURL: URL
    let startupTimeout: TimeInterval
    let terminationGrace: TimeInterval

    private let locate: () -> BPTInstallation?
    private let portProvider: () -> Int
    private let probe: (URL) async -> Bool
    private var child: ChildProcess?
    private var startTask: Task<Void, Never>?

    init(
        locate: @escaping () -> BPTInstallation? = { BPTInstallation.locate() },
        port: @escaping () -> Int = { AppSettings.port },
        startupTimeout: TimeInterval = 120,
        terminationGrace: TimeInterval = 5,
        logURL: URL = ServerController.defaultLogURL,
        probe: @escaping (URL) async -> Bool = ServerController.httpProbe
    ) {
        self.locate = locate
        self.portProvider = port
        self.startupTimeout = startupTimeout
        self.terminationGrace = terminationGrace
        self.logURL = logURL
        self.probe = probe
        self.activePort = port()
    }

    nonisolated static let defaultLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/PayrollRTI/rti.log")

    // swiftlint:disable:next force_unwrapping
    var baseURL: URL { URL(string: "http://127.0.0.1:\(activePort)/")! }

    var isRunning: Bool { state == .running }

    var canStart: Bool {
        switch state {
        case .stopped, .failed, .notInstalled: return true
        case .starting, .running, .stopping: return false
        }
    }

    var canStop: Bool { state == .starting || state == .running }

    /// Whether quitting needs to wait for `stop()`.
    var ownsRunningProcess: Bool { child != nil }

    /// Re-checks whether BPT is installed (e.g. after the user installs it while we're open).
    func refreshInstallation() {
        installation = locate()
        if installation == nil, canStart {
            state = .notInstalled
        } else if installation != nil, state == .notInstalled {
            state = .stopped
        }
    }

    func start() {
        guard canStart else { return }
        guard let installation = locate() else {
            self.installation = nil
            state = .notInstalled
            return
        }
        self.installation = installation
        activePort = portProvider()
        state = .starting
        startTask = Task { await launch(installation, port: activePort) }
    }

    func stop() async {
        startTask?.cancel()
        startTask = nil
        if let child {
            state = .stopping
            await child.terminate(grace: terminationGrace)
            if self.child === child { self.child = nil }
        } else if isExternal, state == .running {
            state = .stopping
            await ExternalServer.stop(listeningOn: activePort, grace: terminationGrace)
        }
        isExternal = false
        state = locate() == nil ? .notInstalled : .stopped
    }

    func restart() async {
        await stop()
        start()
    }

    // MARK: - Launching

    private func launch(_ installation: BPTInstallation, port: Int) async {
        let url = baseURL
        if await probe(url) {
            // Already being served, most likely via HMRC's Terminal workaround. Use it rather than fight for the port.
            guard !Task.isCancelled else { return }
            isExternal = true
            state = .running
            return
        }
        if Self.isBPTAppRunning(installation) {
            state = .failed(
                "The Basic PAYE Tools app is already open. HMRC advise not to run it alongside the server. "
                    + "Quit it (check the crown icon in the menu bar), then try again.")
            return
        }

        let child: ChildProcess
        do {
            try prepareLog(installation: installation, port: port)
            child = try ChildProcess(
                executable: installation.executableURL,
                arguments: ["runserver", String(port)],
                workingDirectory: installation.workingDirectoryURL,
                logURL: logURL)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        self.child = child
        isExternal = false
        child.onExit { [weak self, weak child] code in
            MainActor.assumeIsolated {
                guard let self, let child else { return }
                self.childExited(child, code: code)
            }
        }

        let deadline = Date().addingTimeInterval(startupTimeout)
        while Date() < deadline {
            if Task.isCancelled || child.hasExited { return }
            if await probe(url) {
                if state == .starting, self.child === child { state = .running }
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard !Task.isCancelled, self.child === child else { return }
        state = .stopping
        await child.terminate(grace: terminationGrace)
        self.child = nil
        state = .failed("Basic PAYE Tools didn't respond within \(Int(startupTimeout)) seconds.\n\n\(logTail())")
    }

    private func childExited(_ exited: ChildProcess, code: Int32) {
        guard exited === child else { return }
        child = nil
        startTask?.cancel()
        startTask = nil
        if state == .starting || state == .running {
            state = .failed("Basic PAYE Tools stopped unexpectedly (exit code \(code)).\n\n\(logTail())")
        }
    }

    private func prepareLog(installation: BPTInstallation, port: Int) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the log from growing forever: start fresh once it passes 5 MB.
        if let size = try? fileManager.attributesOfItem(atPath: logURL.path)[.size] as? Int, size > 5_000_000 {
            try? fileManager.removeItem(at: logURL)
        }
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let version = installation.version?.description ?? "unknown version"
        let header = "\n=== \(Date()) starting \(installation.executableURL.path) runserver \(port) (\(version)) ===\n"
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(header.utf8))
    }

    /// The last few lines of the server log, for error messages.
    func logTail(lines: Int = 8) -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }

    private static func isBPTAppRunning(_ installation: BPTInstallation) -> Bool {
        let bptPath = installation.appURL.standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL.path == bptPath
        }
    }

    /// Any HTTP response at all means the server is up.
    nonisolated static func httpProbe(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.httpMethod = "HEAD"
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }
}
