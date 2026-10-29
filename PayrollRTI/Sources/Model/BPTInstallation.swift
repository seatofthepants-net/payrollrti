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
    static let macInstallerExecutableSubpath = "Contents/Helpers/rti.app/Contents/MacOS/rti"

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

    /// The installed version. The Mac installer puts "26.1" in CFBundleShortVersionString and the full
    /// "26.1.26134.173934" (the number GOV.UK publishes) in CFBundleVersion, so the most specific wins.
    var version: BPTVersion? {
        switch self {
        case .linuxBuild(let payload, _):
            return payload.version
        case .macInstaller(let appURL):
            let plists = [
                appURL.appendingPathComponent("Contents/Info.plist"),
                appURL.appendingPathComponent("Contents/Helpers/rti.app/Contents/Info.plist"),
            ]
            for plist in plists {
                guard let info = NSDictionary(contentsOf: plist) else { continue }
                let versions = ["CFBundleVersion", "CFBundleShortVersionString"].compactMap {
                    (info[$0] as? String).flatMap(BPTVersion.init)
                }
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

    static func macInstallerExecutable(in appURL: URL) -> URL {
        appURL.appendingPathComponent(macInstallerExecutableSubpath)
    }

    /// Where we expect HMRC's Mac installer to be: `/Applications`, unless overridden by the `bptAppPath` default.
    static var configuredAppURL: URL {
        if let path = UserDefaults.standard.string(forKey: SettingsKey.bptAppPath), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return defaultAppURL
    }

    /// The installation for `engine`, if it's usable: the Mac installer's `rti` exists and is executable, or the
    /// newest downloaded Linux build together with the bundled runtime.
    static func locate(
        engine: BPTEngine = AppSettings.engine, appURL: URL = configuredAppURL,
        fileManager: FileManager = .default
    ) -> BPTInstallation? {
        #if DEBUG
            // `-debugPretendBPTMissing YES`: show the not-installed screen with the real default path (screenshots).
            if UserDefaults.standard.bool(forKey: "debugPretendBPTMissing") { return nil }
        #endif
        switch engine {
        case .macInstaller:
            let executable = macInstallerExecutable(in: appURL)
            return fileManager.isExecutableFile(atPath: executable.path) ? .macInstaller(appURL: appURL) : nil
        case .linuxBuild:
            guard let runtime = LinuxBuildRuntime.bundled, let payload = LinuxBuildStore.newest() else { return nil }
            return .linuxBuild(payload: payload, runtime: runtime)
        }
    }
}
