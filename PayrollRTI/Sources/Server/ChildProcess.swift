import Darwin
import Foundation

/// A child process spawned in its own process group, so the whole tree (`rti runserver` re-executes
/// itself under Django's autoreloader) can be signalled together and nothing is left orphaned.
final class ChildProcess {
    enum SpawnError: LocalizedError, Equatable {
        case rosettaMissing
        case failed(Int32)

        var errorDescription: String? {
            switch self {
            case .rosettaMissing:
                return "Basic PAYE Tools needs Rosetta to run on this Mac. "
                    + "Open Terminal and run: softwareupdate --install-rosetta"
            case .failed(let code):
                return "Couldn't start Basic PAYE Tools: \(String(cString: strerror(code)))."
            }
        }
    }

    let pid: pid_t

    private let lock = NSLock()
    private var status: Int32?
    private var exitHandlers: [(Int32) -> Void] = []

    /// Spawns `executable` with stdin from /dev/null and stdout/stderr appended to `logURL`.
    init(executable: URL, arguments: [String], workingDirectory: URL, logURL: URL) throws {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)
        guard result == 0 else {
            throw result == EBADARCH ? SpawnError.rosettaMissing : SpawnError.failed(result)
        }
        self.pid = pid

        Thread.detachNewThread { [self] in
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
            // Decode WEXITSTATUS / WTERMSIG by hand; the macros aren't imported into Swift.
            let signal = raw & 0x7f
            let code = signal == 0 ? (raw >> 8) & 0xff : -signal
            self.lock.lock()
            self.status = code
            let handlers = self.exitHandlers
            self.exitHandlers = []
            self.lock.unlock()
            DispatchQueue.main.async { handlers.forEach { $0(code) } }
        }
    }

    /// The exit code, or the negated signal number if it was killed. `nil` while running.
    var exitStatus: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    var hasExited: Bool { exitStatus != nil }

    /// True while any process in the child's group is still alive.
    var isGroupAlive: Bool { killpg(pid, 0) == 0 || errno == EPERM }

    /// Registers a handler called on the main queue when the process exits.
    func onExit(_ handler: @escaping (Int32) -> Void) {
        lock.lock()
        if let status {
            lock.unlock()
            DispatchQueue.main.async { handler(status) }
        } else {
            exitHandlers.append(handler)
            lock.unlock()
        }
    }

    func signalGroup(_ signal: Int32) {
        if killpg(pid, signal) != 0, !hasExited {
            kill(pid, signal)
        }
    }

    /// Sends SIGTERM to the process group, escalating to SIGKILL if anything is still alive after `grace`.
    /// Returns `true` if everything exited without needing SIGKILL.
    @discardableResult
    func terminate(grace: TimeInterval) async -> Bool {
        signalGroup(SIGTERM)
        if await waitUntilGone(timeout: grace) { return true }
        signalGroup(SIGKILL)
        _ = await waitUntilGone(timeout: 2)
        return false
    }

    private func waitUntilGone(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasExited && !isGroupAlive { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return hasExited && !isGroupAlive
    }
}
