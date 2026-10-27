import Foundation

/// Compares the installed Basic PAYE Tools version with the latest one GOV.UK advertises.
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

    @Published private(set) var status: Status = .idle
    @Published var isBannerDismissed = false

    private let fetchPage: () async throws -> String

    init(fetchPage: @escaping () async throws -> String = UpdateChecker.fetchDownloadPage) {
        self.fetchPage = fetchPage
    }

    var availableUpdate: BPTVersion? {
        if case .updateAvailable(_, let latest) = status { return latest }
        return nil
    }

    var showsBanner: Bool { availableUpdate != nil && !isBannerDismissed }

    func check(installed: BPTVersion?) async {
        status = .checking
        do {
            let page = try await fetchPage()
            guard let latest = Self.latestVersion(inPage: page) else {
                status = .failed("Couldn't find a version number on the GOV.UK download page.")
                return
            }
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

    /// Pulls the latest version out of the GOV.UK page. HMRC state it in prose ("The latest version is …") and in the
    /// download file names (`payetools-rti-26.1.26134.173934-osx.zip`); either will do.
    nonisolated static func latestVersion(inPage page: String) -> BPTVersion? {
        let patterns = [
            #"latest version is\s+(\d+(?:\.\d+)+)"#,
            #"payetools-rti-(\d+(?:\.\d+)+)-osx"#,
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

    nonisolated static func fetchDownloadPage() async throws -> String {
        var request = URLRequest(url: Links.bptDownload, timeoutInterval: 20)
        request.setValue("PayrollRTI (+\(Links.repository.absoluteString))", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}
