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
    /// BPT puts only "26.1" in CFBundleShortVersionString and the full "26.1.26134.173934" (the number GOV.UK
    /// publishes) in CFBundleVersion, so the most specific of the two wins.
    var version: BPTVersion? {
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

    /// Where we expect BPT to be: `/Applications`, unless overridden by the `bptAppPath` default.
    static var configuredAppURL: URL {
        if let path = UserDefaults.standard.string(forKey: SettingsKey.bptAppPath), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return defaultAppURL
    }

    /// Returns the installation at `appURL` if its `rti` binary exists and is executable.
    static func locate(at appURL: URL = configuredAppURL, fileManager: FileManager = .default) -> BPTInstallation? {
        #if DEBUG
            // `-debugPretendBPTMissing YES`: show the not-installed screen with the real default path (screenshots).
            if UserDefaults.standard.bool(forKey: "debugPretendBPTMissing") { return nil }
        #endif
        let candidate = BPTInstallation(appURL: appURL)
        return fileManager.isExecutableFile(atPath: candidate.executableURL.path) ? candidate : nil
    }
}
