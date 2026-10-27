import Foundation

/// An installed copy of HMRC's Basic PAYE Tools.
struct BPTInstallation: Equatable {
    static let defaultAppURL = URL(fileURLWithPath: "/Applications/Basic PAYE Tools.app")
    static let executableSubpath = "Contents/Helpers/rti.app/Contents/MacOS/rti"

    let appURL: URL

    /// The `rti` server binary HMRC's workaround tells people to run from Terminal.
    var executableURL: URL { appURL.appendingPathComponent(Self.executableSubpath) }

    var workingDirectoryURL: URL { executableURL.deletingLastPathComponent() }

    /// The installed version, read from the outer bundle's Info.plist (falling back to the inner `rti.app`).
    var version: BPTVersion? {
        let plists = [
            appURL.appendingPathComponent("Contents/Info.plist"),
            appURL.appendingPathComponent("Contents/Helpers/rti.app/Contents/Info.plist"),
        ]
        for plist in plists {
            guard let info = NSDictionary(contentsOf: plist) else { continue }
            for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
                if let string = info[key] as? String, let version = BPTVersion(string) {
                    return version
                }
            }
        }
        return nil
    }

    /// Where we expect BPT to be: `/Applications`, unless overridden by the `bptAppPath` default.
    static var configuredAppURL: URL {
        if let path = UserDefaults.standard.string(forKey: SettingsKey.bptAppPath), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return defaultAppURL
    }

    /// Returns the installation at `appURL` if its `rti` binary exists and is executable.
    static func locate(at appURL: URL = configuredAppURL, fileManager: FileManager = .default) -> BPTInstallation? {
        let candidate = BPTInstallation(appURL: appURL)
        return fileManager.isExecutableFile(atPath: candidate.executableURL.path) ? candidate : nil
    }
}
