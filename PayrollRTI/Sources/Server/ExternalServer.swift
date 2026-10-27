import Darwin
import Foundation

/// Stops an `rti` server we didn't start ourselves (a leftover Terminal session, or one orphaned by a crash).
enum ExternalServer {
    /// Finds the process listening on `port` and, only if it's HMRC's `rti` binary, terminates it.
    static func stop(listeningOn port: Int, grace: TimeInterval) async {
        for pid in await listeningPIDs(port: port) where executablePath(of: pid)?.hasSuffix("/rti") == true {
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(grace)
            while Date() < deadline, kill(pid, 0) == 0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    static func listeningPIDs(port: Int) async -> [pid_t] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
                process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: [])
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let pids = (String(bytes: data, encoding: .utf8) ?? "").split(separator: "\n").compactMap { pid_t($0) }
                continuation.resume(returning: pids)
            }
        }
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
