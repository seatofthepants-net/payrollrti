import Foundation

@testable import PayrollRTI

/// Builds a throwaway "Basic PAYE Tools.app" whose `rti` is a shell script, so the launch flow can be
/// exercised without HMRC's software installed.
enum FakeBPT {
    enum Behaviour {
        /// Serves HTTP on the requested port via a child process (exercises process-group signalling).
        case serve
        /// Serves HTTP but ignores SIGTERM, so only SIGKILL stops it.
        case ignoreTerm
        /// `runserver` exits immediately with an error.
        case crash
        /// `startdb` fails, as it does when the database can't be opened.
        case startdbFails
    }

    /// Commands the fake `rti` has been asked to run, in order (e.g. `["startdb", "updatecheck", "runserver 1234"]`).
    static func calls(_ installation: BPTInstallation) -> [String] {
        let log = installation.workingDirectoryURL.appendingPathComponent("calls.log")
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    /// Mirrors real BPT: CFBundleShortVersionString is just "26.1"; CFBundleVersion has the full number.
    static func make(
        version: String = "26.1.26134.173934", shortVersion: String = "26.1", behaviour: Behaviour = .serve
    ) throws -> BPTInstallation {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeBPT-\(UUID().uuidString)")
            .appendingPathComponent("Basic PAYE Tools.app")
        let installation = BPTInstallation.macInstaller(appURL: root)
        let executable = BPTInstallation.macInstallerExecutable(in: root)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)

        let plist: NSDictionary = [
            "CFBundleShortVersionString": shortVersion, "CFBundleVersion": version,
            "CFBundleIdentifier": "test.fake.bpt",
        ]
        plist.write(to: root.appendingPathComponent("Contents/Info.plist"), atomically: true)

        let serve = "/usr/bin/python3 -m http.server \"$2\" --bind 127.0.0.1 --directory \"$(dirname \"$0\")\""
        let runserver: String
        switch behaviour {
        case .serve, .startdbFails: runserver = "\(serve) &\n  wait"
        case .ignoreTerm: runserver = "trap '' TERM\n  \(serve) &\n  wait"
        case .crash: runserver = "echo 'fake rti: boom' >&2\n  exit 3"
        }
        let startdb =
            behaviour == .startdbFails ? "echo 'CommandError: Failed to start up the database' >&2\n  exit 1" : "exit 0"
        let script = """
            #!/bin/sh
            echo "$*" >> "$(dirname "$0")/calls.log"
            case "$1" in
            startdb)
              \(startdb) ;;
            updatecheck|autobackup)
              exit 0 ;;
            runserver)
              \(runserver) ;;
            esac

            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return installation
    }

    static func remove(_ installation: BPTInstallation) {
        try? FileManager.default.removeItem(at: installation.location.deletingLastPathComponent())
    }

    /// Asks the kernel for an unused TCP port.
    static func freePort() -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(sock, $0, length)
                _ = getsockname(sock, $0, &length)
            }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
