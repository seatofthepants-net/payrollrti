import Foundation

/// Compares the installed Basic PAYE Tools version with the latest one HMRC publish, and finds out which builds
/// (Mac installer, Linux) they publish for it.
///
/// The primary source is HMRC's own update feed, the one Basic PAYE Tools itself polls:
/// `realtimepayetools-update-v<major>.xml` under their uploads directory, one per major version, each
/// advertising the latest release of that major; when a new major comes out, its feed appears alongside, so the
/// check walks upwards until a feed is missing. The GOV.UK download page is the fallback.
@MainActor
final class UpdateChecker: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate(BPTVersion)
        case updateAvailable(installed: BPTVersion, latest: BPTVersion)
        /// We know the latest version but not what's installed (BPT missing, or its Info.plist unreadable).
        case latestKnown(BPTVersion)
        case failed(String)
    }

    /// The latest release HMRC publish and which builds exist for it, for telling the user which engine is viable.
    struct Release: Equatable {
        let version: BPTVersion
        /// Where the version number came from, in words for the user.
        let source: String
        let macInstaller: Bool?
        let linuxBuild: Bool?
        let checkedAt: Date
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var release: Release?
    @Published var isBannerDismissed = false

    nonisolated static let uploads = URL(string: "https://www.gov.uk/government/uploads/uploaded/hmrc/")!
    /// The oldest feed worth asking for when nothing is installed; HMRC's major version is the tax year.
    static let earliestMajor = 26

    private let fetchFeed: (Int) async throws -> String?
    private let fetchPage: () async throws -> String
    private let exists: (URL) async -> Bool

    init(
        fetchFeed: @escaping (Int) async throws -> String? = UpdateChecker.fetchFeed,
        fetchPage: @escaping () async throws -> String = UpdateChecker.fetchDownloadPage,
        exists: @escaping (URL) async -> Bool = UpdateChecker.exists
    ) {
        self.fetchFeed = fetchFeed
        self.fetchPage = fetchPage
        self.exists = exists
    }

    var availableUpdate: BPTVersion? {
        if case .updateAvailable(_, let latest) = status { return latest }
        return nil
    }

    var showsBanner: Bool { availableUpdate != nil && !isBannerDismissed }

    func check(installed: BPTVersion?) async {
        status = .checking
        do {
            let (latest, source) = try await latestVersion(installedMajor: installed?.components.first)
            async let mac = exists(Self.uploads.appendingPathComponent("payetools-rti-\(latest)-osx.zip"))
            async let linux = exists(Self.uploads.appendingPathComponent("payetools-rti-\(latest)-linux.zip"))
            release = Release(
                version: latest, source: source, macInstaller: await mac, linuxBuild: await linux, checkedAt: Date())
            if let installed {
                status =
                    installed < latest ? .updateAvailable(installed: installed, latest: latest) : .upToDate(installed)
            } else {
                status = .latestKnown(latest)
            }
            isBannerDismissed = false
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Walks HMRC's feeds from the installed major upwards; falls back to the GOV.UK page.
    private func latestVersion(installedMajor: Int?) async throws -> (BPTVersion, String) {
        var major = max(installedMajor ?? Self.earliestMajor, Self.earliestMajor)
        var newest: BPTVersion?
        while let feed = try await fetchFeed(major), let version = Self.latestVersion(inFeed: feed) {
            newest = max(newest ?? version, version)
            major += 1
        }
        if let newest { return (newest, "HMRC's update feed") }
        guard let fromPage = Self.latestVersion(inPage: try await fetchPage()) else {
            throw URLError(.cannotParseResponse)
        }
        return (fromPage, "the GOV.UK download page")
    }

    /// `<version>26.1.26134.173934</version>` from a feed document.
    nonisolated static func latestVersion(inFeed feed: String) -> BPTVersion? {
        guard let regex = try? NSRegularExpression(pattern: #"<version>\s*(\d+(?:\.\d+)+)\s*</version>"#),
            let match = regex.firstMatch(in: feed, range: NSRange(feed.startIndex..., in: feed)),
            let group = Range(match.range(at: 1), in: feed)
        else { return nil }
        return BPTVersion(String(feed[group]))
    }

    /// Pulls the latest version out of the GOV.UK page. HMRC state it in prose ("The latest version is …") and in the
    /// download file names (`payetools-rti-26.1.26134.173934-osx.zip`, `…-linux.zip`); any will do.
    nonisolated static func latestVersion(inPage page: String) -> BPTVersion? {
        let patterns = [
            #"latest version is\s+(\d+(?:\.\d+)+)"#,
            #"payetools-rti-(\d+(?:\.\d+)+)-(?:osx|linux|win)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(page.startIndex..., in: page)
            let versions = regex.matches(in: page, range: range).compactMap { match -> BPTVersion? in
                guard let group = Range(match.range(at: 1), in: page) else { return nil }
                return BPTVersion(String(page[group]))
            }
            if let newest = versions.max() { return newest }
        }
        return nil
    }

    /// What the user should do, given what HMRC publish and which engine they're on.
    nonisolated static func advice(engine: BPTEngine, release: Release, linuxEngineAvailable: Bool) -> String {
        let version = release.version.description
        switch (engine, release.macInstaller, release.linuxBuild) {
        case (.macInstaller, false, true):
            return "HMRC don't publish a Mac installer for \(version). Switch to the Linux build to get it"
                + (linuxEngineAvailable ? "." : "; that needs an Apple silicon Mac.")
        case (.macInstaller, _, _) where linuxEngineAvailable:
            return "You're on HMRC's Mac installer, which needs Rosetta. Apple are removing Rosetta after macOS 27; "
                + "the Linux build runs natively and uses the same payroll data, so switching is the safer "
                + "long-term choice."
        case (.macInstaller, _, _):
            return "You're on HMRC's Mac installer. Updates come from GOV.UK's download page."
        case (.linuxBuild, _, false):
            return "HMRC haven't published a Linux build for \(version) yet; keep using the version you have."
        case (.linuxBuild, _, _):
            return "You're on the Linux build. New versions are downloaded by PayrollRTI; your data is backed up first."
        }
    }

    // MARK: - Network

    private static func request(_ url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("PayrollRTI (+\(Links.repository.absoluteString))", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The feed for one major version, or nil if HMRC don't have one (404).
    nonisolated static func fetchFeed(major: Int) async throws -> String? {
        let url = uploads.appendingPathComponent("realtimepayetools-update-v\(major).xml")
        let (data, response) = try await URLSession.shared.data(for: request(url))
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    nonisolated static func fetchDownloadPage() async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request(Links.bptDownload))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Whether a download exists, without fetching it.
    nonisolated static func exists(_ url: URL) async -> Bool {
        guard let (_, response) = try? await URLSession.shared.data(for: request(url, method: "HEAD")),
            let http = response as? HTTPURLResponse
        else { return false }
        return (200..<300).contains(http.statusCode)
    }
}
