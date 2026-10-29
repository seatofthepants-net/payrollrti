import AppKit
import Foundation

/// A runnable copy of HMRC's Basic PAYE Tools: where it is and how to invoke its `rti` management commands
/// (`startdb`, `runserver`, `autobackup`, …). Both engines run the same Django project against the same
/// database in `~/HMRC/payetools-rti`; they differ only in which interpreter runs which copy of the bytecode.
enum BPTInstallation: Equatable {
    /// HMRC's Mac installer: `rti` is their x86_64 cx_Freeze executable.
    case macInstaller(appURL: URL)
    /// HMRC's Linux build, extracted by PayrollRTI and run by the bundled native Python runtime.
    case linuxBuild(payload: LinuxBuildPayload, runtime: LinuxBuildRuntime)

    /// Everything `ChildProcess` needs to run one `rti` command.
    struct Command {
        let executable: URL
        let arguments: [String]
        let workingDirectory: URL
        let environment: [String: String]
    }

    static let defaultAppURL = URL(fileURLWithPath: "/Applications/Basic PAYE Tools.app")

    var engine: BPTEngine {
        switch self {
        case .macInstaller: return .macInstaller
        case .linuxBuild: return .linuxBuild
        }
    }

    /// Where this copy lives, for display.
    var location: URL {
        switch self {
        case .macInstaller(let appURL): return appURL
        case .linuxBuild(let payload, _): return payload.directory
        }
    }

    /// The directory `rti` runs in; also where tests look for the fake `rti`'s call log.
    var workingDirectoryURL: URL { command([]).workingDirectory }

    /// The installed version. The outer app puts "26.1" in CFBundleShortVersionString and the full
    /// "26.1.26134.173934" (the number GOV.UK publishes) in CFBundleVersion; the server app inside has
    /// "26.1.26134". The most specific wins.
    var version: BPTVersion? {
        switch self {
        case .linuxBuild(let payload, _):
            return payload.version
        case .macInstaller(let appURL):
            let plists = [
                appURL.appendingPathComponent("Contents/Info.plist"),
                Self.serverApp(in: appURL).appendingPathComponent("Contents/Info.plist"),
            ]
            for plist in plists {
                guard let info = NSDictionary(contentsOf: plist) else { continue }
                // The server app's CFBundleVersion is a placeholder, 0.0.0; its real number is the short version.
                let versions = ["CFBundleVersion", "CFBundleShortVersionString"].compactMap {
                    (info[$0] as? String).flatMap(BPTVersion.init)
                }.filter { $0.components.contains { $0 != 0 } }
                if let best = versions.max(by: { $0.components.count < $1.components.count }) {
                    return best
                }
            }
            return nil
        }
    }

    func command(_ arguments: [String]) -> Command {
        switch self {
        case .macInstaller(let appURL):
            let executable = Self.macInstallerExecutable(in: appURL)
            return Command(
                executable: executable, arguments: arguments,
                workingDirectory: executable.deletingLastPathComponent(), environment: [:])
        case .linuxBuild(let payload, let runtime):
            // `-S -B`: no site-packages, never write bytecode into the signed bundle. The launcher builds sys.path.
            return Command(
                executable: runtime.python,
                arguments: ["-S", "-B", runtime.launcher.path] + arguments,
                workingDirectory: payload.baseURL,
                environment: [
                    "BPT_REHOST_PAYLOAD": payload.baseURL.path,
                    "PYTHONHOME": runtime.directory.path,
                    "PYTHONNOUSERSITE": "1",
                ])
        }
    }

    /// HMRC's package holds two bundles: `Basic PAYE Tools.app` (`uk.gov.hmrc.bptrti`) and, inside it, the
    /// server `rti.app` (`uk.gov.hmrc.bptserver`). macOS's installer relocates a bundle onto an existing copy with
    /// the same identifier, so on a Mac that once had an older BPT the server app can end up on its own, e.g. at
    /// `/Applications/HMRC/payetools-rti/rti.app`. Either bundle is accepted: `appURL` may be the outer app or the
    /// server app itself.
    static func serverApp(in appURL: URL) -> URL {
        let nested = appURL.appendingPathComponent("Contents/Helpers/rti.app")
        return FileManager.default.fileExists(atPath: nested.path) ? nested : appURL
    }

    static func macInstallerExecutable(in appURL: URL) -> URL {
        serverApp(in: appURL).appendingPathComponent("Contents/MacOS/rti")
    }

    static let outerBundleIdentifier = "uk.gov.hmrc.bptrti"
    static let serverBundleIdentifier = "uk.gov.hmrc.bptserver"
    static let legacyServerAppURL = URL(fileURLWithPath: "/Applications/HMRC/payetools-rti/rti.app")

    /// The user's override, if any: the `bptAppPath` default (settable from the choice screen and Settings).
    static var configuredAppURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: SettingsKey.bptAppPath), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Where to look for HMRC's Mac installer, in order: the user's choice, HMRC's documented location, the
    /// location older installers used, then wherever LaunchServices knows either bundle to be.
    static var macInstallerCandidates: [URL] {
        var candidates = [configuredAppURL, defaultAppURL, legacyServerAppURL].compactMap { $0 }
        for identifier in [outerBundleIdentifier, serverBundleIdentifier] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                candidates.append(url)
            }
        }
        return candidates
    }

    /// The installation for `engine`, if it's usable: the first candidate whose `rti` exists and is executable,
    /// or the newest downloaded Linux build together with the bundled runtime.
    static func locate(
        engine: BPTEngine = AppSettings.engine, candidates: [URL]? = nil, fileManager: FileManager = .default
    ) -> BPTInstallation? {
        #if DEBUG
            // `-debugPretendBPTMissing YES`: show the not-installed screen with the real default path (screenshots).
            if UserDefaults.standard.bool(forKey: "debugPretendBPTMissing") { return nil }
        #endif
        switch engine {
        case .macInstaller:
            return (candidates ?? macInstallerCandidates).lazy
                .filter { fileManager.isExecutableFile(atPath: macInstallerExecutable(in: $0).path) }
                .map { BPTInstallation.macInstaller(appURL: $0) }
                .first
        case .linuxBuild:
            guard let runtime = LinuxBuildRuntime.bundled, let payload = LinuxBuildStore.newest() else { return nil }
            return .linuxBuild(payload: payload, runtime: runtime)
        }
    }
}

extension BPTInstallation {
    enum ChooseResult: Equatable {
        case chosen(URL)
        case cancelled
        case notBasicPAYETools(URL)
    }

    /// Lets the user point PayrollRTI at their copy of Basic PAYE Tools (either bundle) and remembers it in the
    /// `bptAppPath` default.
    @MainActor
    static func chooseMacInstaller() -> ChooseResult {
        let panel = NSOpenPanel()
        panel.title = "Choose Basic PAYE Tools"
        panel.message = "Choose Basic PAYE Tools.app, or the rti.app inside it."
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        guard FileManager.default.isExecutableFile(atPath: macInstallerExecutable(in: url).path) else {
            return .notBasicPAYETools(url)
        }
        UserDefaults.standard.set(url.path, forKey: SettingsKey.bptAppPath)
        return .chosen(url)
    }
}
