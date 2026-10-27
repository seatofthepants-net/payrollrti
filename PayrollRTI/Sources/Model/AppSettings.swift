import Foundation

enum SettingsKey {
    static let port = "port"
    static let openMode = "openMode"
    /// Hidden override for the BPT bundle location. Useful for testing with a stub install:
    /// `open PayrollRTI.app --args -bptAppPath /path/to/Basic\ PAYE\ Tools.app`
    static let bptAppPath = "bptAppPath"
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
