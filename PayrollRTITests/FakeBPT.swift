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
        /// Exits immediately with an error.
        case crash
    }

    static func make(version: String = "26.1.26134.173934", behaviour: Behaviour = .serve) throws -> BPTInstallation {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeBPT-\(UUID().uuidString)")
            .appendingPathComponent("Basic PAYE Tools.app")
        let installation = BPTInstallation(appURL: root)
        let macOS = installation.workingDirectoryURL
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        let plist: NSDictionary = ["CFBundleShortVersionString": version, "CFBundleIdentifier": "test.fake.bpt"]
        plist.write(to: root.appendingPathComponent("Contents/Info.plist"), atomically: true)

        let serve = "/usr/bin/python3 -m http.server \"$2\" --bind 127.0.0.1 --directory \"$(dirname \"$0\")\""
        let body: String
        switch behaviour {
        case .serve: body = "\(serve) &\nwait"
        case .ignoreTerm: body = "trap '' TERM\n\(serve) &\nwait"
        case .crash: body = "echo 'fake rti: boom' >&2\nexit 3"
        }
        let script = "#!/bin/sh\n\(body)\n"
        try script.write(to: installation.executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installation.executableURL.path)
        return installation
    }

    static func remove(_ installation: BPTInstallation) {
        try? FileManager.default.removeItem(at: installation.appURL.deletingLastPathComponent())
    }

    /// Asks the kernel for an unused TCP port.
    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(fd, $0, length)
                _ = getsockname(fd, $0, &length)
            }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
