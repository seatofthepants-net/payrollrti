import AppKit
import Foundation

/// Logging, database housekeeping and health checks that support `ServerController`'s lifecycle.
extension ServerController {
    /// Running `rti runserver` before BPT has ever set up its database (as HMRC's Terminal workaround does on a fresh
    /// install) leaves a zero-byte `sqlite3.db` that `startdb` then mistakes for a real database. Move it aside so
    /// `startdb` creates a proper one. Only ever touches an empty file.
    func moveEmptyDatabaseAside() {
        let database = dataDirectory.appendingPathComponent("sqlite3.db")
        guard let size = try? FileManager.default.attributesOfItem(atPath: database.path)[.size] as? Int, size == 0
        else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let aside = dataDirectory.appendingPathComponent("sqlite3.db.empty-\(formatter.string(from: Date()))")
        do {
            try FileManager.default.moveItem(at: database, to: aside)
            appendLog("--- moved empty database aside to \(aside.lastPathComponent)")
        } catch {
            appendLog("--- couldn't move empty database aside: \(error.localizedDescription)")
        }
    }

    enum DatabaseGuard: Equatable {
        case ok
        /// This copy can't open the database; the message says why.
        case refused(String)
        case backupFailed(String)
    }

    /// Both engines share the database. A newer BPT migrates it forward; an older one can't go back, and its
    /// migration tool would abort part-way through startup, so refuse before it touches anything. The database's
    /// own migration history is the authority; the version we last started is the fallback. When a migration is
    /// coming, a backup BPT can restore is taken first.
    func guardDatabase(for installation: BPTInstallation) -> DatabaseGuard {
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
            return .refused(
                "This copy of Basic PAYE Tools can't open your payroll data. \(refusal) Basic PAYE Tools can't go "
                    + "back to an older version: switch to the other engine in PayrollRTI Settings, or install a "
                    + "newer version of this one.")
        }
        if case .upgrade(let pending) = compatibility {
            do {
                let backup = try BPTBackup.write(
                    database: database.url, version: AppSettings.newestStartedVersion, reason: "PRE-UPGRADE",
                    to: dataDirectory.appendingPathComponent("backups"))
                appendLog("--- database needs \(pending) migration(s); backed up to \(backup.lastPathComponent)")
            } catch {
                return .backupFailed(
                    "Couldn't back up your payroll data before updating it: \(error.localizedDescription)")
            }
        }
        return .ok
    }

    func appendLog(_ line: String) {
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    func prepareLog(installation: BPTInstallation, port: Int) throws {
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
        let command = installation.command([])
        appendLog(
            "\n=== \(Date()) starting \(installation.engine.label) \(command.executable.path) "
                + "on port \(port) (\(version)) ===")
    }

    /// The last few lines of the server log, for error messages.
    func logTail(lines: Int = 8) -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }

    /// HMRC's own Basic PAYE Tools app shares the database with whichever engine we run, so it must not be open.
    static func isBPTAppRunning() -> Bool {
        let identifiers = [BPTInstallation.outerBundleIdentifier, BPTInstallation.serverBundleIdentifier]
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier.map(identifiers.contains) ?? false
        }
    }

    /// Any HTTP response at all means the server is up. BPT answers `/` with a cheap redirect; following it would make
    /// Django render a full page, which on a cold start under Rosetta can outlast the timeout.
    nonisolated static func httpProbe(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
