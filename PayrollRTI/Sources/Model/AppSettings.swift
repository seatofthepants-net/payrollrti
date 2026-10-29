import Foundation

enum SettingsKey {
    static let port = "port"
    static let openMode = "openMode"
    static let engine = "engine"
    /// The newest Basic PAYE Tools version that has prepared the payroll database, per `ServerController`. Starting
    /// an older version against a newer database is a downgrade BPT's migrations can't do, so it's refused up front.
    static let newestStartedVersion = "newestStartedVersion"
    /// Hidden override for the BPT bundle location. Useful for testing with a stub install:
    /// `open PayrollRTI.app --args -bptAppPath /path/to/Basic\ PAYE\ Tools.app`
    static let bptAppPath = "bptAppPath"
}

/// Which copy of Basic PAYE Tools PayrollRTI runs. Both keep their data in `~/HMRC/payetools-rti` and share the
/// same database schema, so switching between engines of the same version is just a restart.
enum BPTEngine: String, CaseIterable, Identifiable {
    /// HMRC's Mac installer in `/Applications`. Intel-only, so it needs Rosetta on Apple silicon.
    case macInstaller
    /// HMRC's Linux build, downloaded by PayrollRTI and run on the native Python runtime it bundles.
    case linuxBuild

    var id: String { rawValue }

    var label: String {
        switch self {
        case .macInstaller: return "HMRC's Mac installer"
        case .linuxBuild: return "HMRC's Linux build, run natively"
        }
    }

    var detail: String {
        switch self {
        case .macInstaller:
            return "The copy in /Applications. Runs under Rosetta on Apple silicon, which Apple are withdrawing."
        case .linuxBuild:
            return "The same software from GOV.UK's Linux download, run by PayrollRTI without Rosetta. "
                + "Uses the same payroll data."
        }
    }
}

enum OpenMode: String, CaseIterable, Identifiable {
    case embedded
    case browser

    var id: String { rawValue }

    var label: String {
        switch self {
        case .embedded: return "In the PayrollRTI window"
        case .browser: return "In my default web browser"
        }
    }
}

enum AppSettings {
    static let defaultPort = 46729
    static let validPorts = 1024...65535

    static var port: Int {
        let value = UserDefaults.standard.integer(forKey: SettingsKey.port)
        return validPorts.contains(value) ? value : defaultPort
    }

    static var openMode: OpenMode {
        UserDefaults.standard.string(forKey: SettingsKey.openMode).flatMap(OpenMode.init) ?? .embedded
    }

    static var engine: BPTEngine {
        UserDefaults.standard.string(forKey: SettingsKey.engine).flatMap(BPTEngine.init) ?? .macInstaller
    }

    static var newestStartedVersion: BPTVersion? {
        get { UserDefaults.standard.string(forKey: SettingsKey.newestStartedVersion).flatMap(BPTVersion.init) }
        set { UserDefaults.standard.set(newValue?.description, forKey: SettingsKey.newestStartedVersion) }
    }
}

enum Links {
    static let bptDownload = URL(string: "https://www.gov.uk/basic-paye-tools")!
    static let hmrcIssues = URL(
        string:
            // swiftlint:disable:next line_length
            "https://www.gov.uk/government/publications/basic-paye-tools-service-availability-and-issues/basic-paye-service-availability-and-issues"
    )!
    static let releases = URL(string: "https://github.com/seatofthepants-net/payrollrti/releases")!
    static let repository = URL(string: "https://github.com/seatofthepants-net/payrollrti")!
}
