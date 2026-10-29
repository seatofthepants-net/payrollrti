import Foundation

/// Rosetta 2, which HMRC's Intel-only Mac build needs on Apple silicon.
enum Rosetta {
    enum Status: Equatable {
        /// An Intel Mac: HMRC's Mac build runs natively.
        case notNeeded
        case installed
        case missing
    }

    /// Present once Rosetta is installed; what `arch -x86_64` and the kernel's binary loader rely on.
    static let runtimePath = "/Library/Apple/usr/libexec/oah/libRosettaRuntime"

    static func status(fileManager: FileManager = .default) -> Status {
        #if arch(x86_64)
            return .notNeeded
        #else
            return fileManager.fileExists(atPath: runtimePath) ? .installed : .missing
        #endif
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs Apple's installer, the same command Apple document for Terminal. Throws with its output if it fails,
    /// which is what happens once Apple stop offering Rosetta.
    static func install() async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
            process.arguments = ["--install-rosetta", "--agree-to-license"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0, status() == .installed else {
                let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure(
                    message: "Rosetta couldn't be installed"
                        + (detail.isEmpty ? "." : ": \(detail)")
                        + " You can try from Terminal with: softwareupdate --install-rosetta")
            }
        }.value
    }
}
