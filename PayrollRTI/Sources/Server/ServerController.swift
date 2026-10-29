import AppKit
import Foundation

/// Runs Basic PAYE Tools' server on the user's behalf. HMRC's Terminal workaround only runs `rti runserver <port>`,
/// but BPT's own launcher wraps that in a lifecycle we mirror here:
///
/// 1. `rti startdb`: create the database on first run, apply migrations after a BPT upgrade, take a startup backup.
/// 2. `rti updatecheck`: record whether HMRC have a newer release, for BPT's own in-app notice (best effort).
/// 3. `rti runserver <port>`: the web UI.
/// 4. `rti autobackup` after the server stops: the backup-on-exit the user configures in BPT's settings.
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
    /// What's happening while starting or stopping, for display.
    @Published private(set) var progress: String?

    let logURL: URL
    /// BPT's user data folder, which holds `sqlite3.db`.
    let dataDirectory: URL
    let startupTimeout: TimeInterval
    let terminationGrace: TimeInterval
    /// How long `startdb` and `autobackup` may take. Migrations after an upgrade, under Rosetta, can be slow.
    let maintenanceTimeout: TimeInterval

    private let locate: () -> BPTInstallation?
    private let portProvider: () -> Int
    private let probe: (URL) async -> Bool
    private var child: ChildProcess?
    /// A one-shot `rti` command (startdb, updatecheck, autobackup) that's currently running.
    private var helper: ChildProcess?
    private var startTask: Task<Void, Never>?

    /// BPT's Python output is buffered without this, which scrambles the log. BPT's own launcher sets it too.
    private static let childEnvironment = ["PYTHONUNBUFFERED": "1"]

    init(
        locate: @escaping () -> BPTInstallation? = { BPTInstallation.locate() },
        port: @escaping () -> Int = { AppSettings.port },
        startupTimeout: TimeInterval = 120,
        terminationGrace: TimeInterval = 5,
        maintenanceTimeout: TimeInterval = 600,
        logURL: URL = ServerController.defaultLogURL,
        dataDirectory: URL = ServerController.defaultDataDirectory,
        probe: @escaping (URL) async -> Bool = ServerController.httpProbe
    ) {
        self.locate = locate
        self.portProvider = port
        self.startupTimeout = startupTimeout
        self.terminationGrace = terminationGrace
        self.maintenanceTimeout = maintenanceTimeout
        self.logURL = logURL
        self.dataDirectory = dataDirectory
        self.probe = probe
        self.activePort = port()
    }

    nonisolated static let defaultLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/PayrollRTI/rti.log")

    /// BPT's default user data folder (an `rti.cfg` can move it, in which case the empty-database repair is skipped).
    nonisolated static let defaultDataDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("HMRC/payetools-rti")

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
    var ownsRunningProcess: Bool { child != nil || helper != nil }

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
        if let helper {
            // Never interrupt startdb: killing it mid-migration could leave the payroll database half-upgraded.
            state = .stopping
            progress = "Waiting for Basic PAYE Tools to finish updating its database…"
            if await helper.waitForExit(timeout: maintenanceTimeout) == nil {
                await helper.terminate(grace: terminationGrace)
            }
        }
        if let child {
            state = .stopping
            progress = "Stopping Basic PAYE Tools…"
            await child.terminate(grace: terminationGrace)
            if self.child === child { self.child = nil }
            if let installation {
                progress = "Backing up payroll data…"
                _ = try? await runMaintenance("autobackup", installation: installation)
            }
        } else if isExternal, state == .running {
            state = .stopping
            await ExternalServer.stop(listeningOn: activePort, grace: terminationGrace)
        }
        isExternal = false
        progress = nil
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
        if Self.isBPTAppRunning() {
            state = .failed(
                "The Basic PAYE Tools app is already open. HMRC advise not to run it alongside the server. "
                    + "Quit it (check the crown icon in the menu bar), then try again.")
            return
        }

        do {
            guard try await prepare(installation, port: port), !Task.isCancelled else { return }
            progress = "Starting Basic PAYE Tools…"
            appendLog("--- rti runserver \(port)")
            let child = try run(installation, ["runserver", String(port)])
            adopt(child)
            await waitUntilServing(child, at: url)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Steps BPT's own launcher runs before the server. Returns false (having set a failure state) if BPT can't start.
    private func prepare(_ installation: BPTInstallation, port: Int) async throws -> Bool {
        try prepareLog(installation: installation, port: port)
        moveEmptyDatabaseAside()

        // Both engines share the database. A newer BPT migrates it forward; an older one can't go back, and
        // its migration tool would abort part-way through startup, so refuse before it touches anything.
        // The database's own migration history is the authority; the version we last started is the fallback.
        let database = BPTDatabase(url: dataDirectory.appendingPathComponent("sqlite3.db"))
        let compatibility = installation.databaseCompatibility(with: database)
        var refusal: String?
        if case .tooOld(let detail) = compatibility {
            refusal = detail
        } else if case .unknown = compatibility, let version = installation.version,
            let newest = AppSettings.newestStartedVersion, version < newest
        {
            refusal = "Your payroll database has already been used by version \(newest); this is \(version)."
        }
        if let refusal {
            progress = nil
            state = .failed(
                "This copy of Basic PAYE Tools can't open your payroll data. \(refusal) Basic PAYE Tools can't go "
                    + "back to an older version: switch to the other engine in PayrollRTI Settings, or install a "
                    + "newer version of this one.")
            return false
        }
        if case .upgrade(let pending) = compatibility {
            appendLog("--- database needs \(pending) migration(s); startdb will apply them")
        }

        progress = "Preparing the payroll database…"
        switch try await runMaintenance("startdb", installation: installation) {
        case 0?:
            if let version = installation.version, AppSettings.newestStartedVersion.map({ version > $0 }) ?? true {
                AppSettings.newestStartedVersion = version
            }
        case nil:
            fail("Basic PAYE Tools took too long to prepare its database.")
            return false
        case let code?:
            fail("Basic PAYE Tools couldn't prepare its database (exit code \(code)).")
            return false
        }
        guard !Task.isCancelled else { return false }

        progress = "Checking for Basic PAYE Tools updates…"
        _ = try await runMaintenance("updatecheck", installation: installation, timeout: 30)
        return true
    }

    private func adopt(_ child: ChildProcess) {
        self.child = child
        isExternal = false
        child.onExit { [weak self, weak child] code in
            MainActor.assumeIsolated {
                guard let self, let child else { return }
                self.childExited(child, code: code)
            }
        }
    }

    private func waitUntilServing(_ child: ChildProcess, at url: URL) async {
        let deadline = Date().addingTimeInterval(startupTimeout)
        while Date() < deadline {
            if Task.isCancelled || child.hasExited { return }
            if await probe(url) {
                if state == .starting, self.child === child {
                    progress = nil
                    state = .running
                }
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard !Task.isCancelled, self.child === child else { return }
        state = .stopping
        await child.terminate(grace: terminationGrace)
        self.child = nil
        fail("Basic PAYE Tools didn't respond within \(Int(startupTimeout)) seconds.")
    }

    private func fail(_ message: String) {
        progress = nil
        state = .failed("\(message)\n\n\(logTail())")
    }

    /// Runs a one-shot `rti` management command to completion. Returns its exit code, or `nil` if it timed out.
    private func runMaintenance(
        _ command: String, installation: BPTInstallation, timeout: TimeInterval? = nil
    ) async throws -> Int32? {
        appendLog("--- rti \(command)")
        let process = try run(installation, [command])
        helper = process
        defer { if helper === process { helper = nil } }
        if let code = await process.waitForExit(timeout: timeout ?? maintenanceTimeout) {
            if code != 0 { appendLog("--- rti \(command) exited with code \(code)") }
            return code
        }
        appendLog("--- rti \(command) timed out; stopping it")
        await process.terminate(grace: terminationGrace)
        return nil
    }

    private func run(_ installation: BPTInstallation, _ arguments: [String]) throws -> ChildProcess {
        let command = installation.command(arguments)
        return try ChildProcess(
            executable: command.executable,
            arguments: command.arguments,
            workingDirectory: command.workingDirectory,
            logURL: logURL,
            environment: Self.childEnvironment.merging(command.environment) { _, new in new })
    }

    private func childExited(_ exited: ChildProcess, code: Int32) {
        guard exited === child else { return }
        child = nil
        startTask?.cancel()
        startTask = nil
        guard state == .starting || state == .running else { return }
        if logTail(lines: 40).contains("That port is already in use") {
            fail(
                "Port \(activePort) is already in use by another program. Quit it, or choose a different port in "
                    + "PayrollRTI Settings.")
        } else {
            fail("Basic PAYE Tools stopped unexpectedly (exit code \(code)).")
        }
    }
}
