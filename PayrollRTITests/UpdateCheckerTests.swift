import XCTest

@testable import PayrollRTI

@MainActor
final class UpdateCheckerTests: XCTestCase {
    /// Trimmed from https://www.gov.uk/basic-paye-tools as published in October 2026.
    private let govUKPage = """
        <div class="form-download">
        <p><a href="/government/uploads/uploaded/hmrc/payetools-rti-26.1.26134.173934-win.zip">Download (Windows)</a>
        <a href="/government/uploads/uploaded/hmrc/payetools-rti-26.1.26134.173934-osx.zip">Download (Mac)</a></p>
        </div>
        <h3 id="updating-the-software">Updating the software</h3>
        <p>The latest version is 26.1.26134.173934. The number displays within ‘Settings’.</p>
        """

    func testParsesVersionFromProse() {
        XCTAssertEqual(UpdateChecker.latestVersion(inPage: govUKPage), BPTVersion("26.1.26134.173934"))
    }

    func testFallsBackToDownloadFileName() {
        let page = #"<a href="/x/payetools-rti-27.0.27001.100-osx.zip">Mac</a>"#
        XCTAssertEqual(UpdateChecker.latestVersion(inPage: page), BPTVersion("27.0.27001.100"))
    }

    func testReturnsNilWhenPageChanges() {
        XCTAssertNil(UpdateChecker.latestVersion(inPage: "<p>Nothing to see here</p>"))
    }

    func testReportsUpdateAvailable() async {
        let checker = UpdateChecker(fetchPage: { self.govUKPage })
        await checker.check(installed: BPTVersion("25.2.25100.1"))
        XCTAssertEqual(checker.availableUpdate, BPTVersion("26.1.26134.173934"))
        XCTAssertTrue(checker.showsBanner)
        checker.isBannerDismissed = true
        XCTAssertFalse(checker.showsBanner)
    }

    func testReportsUpToDate() async throws {
        let installed = try XCTUnwrap(BPTVersion("26.1.26134.173934"))
        let checker = UpdateChecker(fetchPage: { self.govUKPage })
        await checker.check(installed: installed)
        XCTAssertEqual(checker.status, .upToDate(installed))
        XCTAssertFalse(checker.showsBanner)
    }

    func testReportsFetchFailure() async {
        let checker = UpdateChecker(fetchPage: { throw URLError(.notConnectedToInternet) })
        await checker.check(installed: BPTVersion("26.1"))
        guard case .failed = checker.status else { return XCTFail("expected failure, got \(checker.status)") }
    }
}
