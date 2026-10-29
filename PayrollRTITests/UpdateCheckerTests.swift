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

    /// HMRC's feed as fetched on 29 October 2026, trimmed.
    private func feed(_ version: String) -> String {
        """
        <installerInformation>
            <versionId>26134</versionId>
            <version>\(version)</version>
            <platformFileList><platformFile><filename/><platform>osx</platform></platformFile></platformFileList>
        </installerInformation>
        """
    }

    /// A checker with HMRC's feeds stubbed: `feeds` maps major version to the version its feed advertises.
    private func checker(
        feeds: [Int: String], page: String? = nil, published: Set<String> = ["osx", "linux"]
    ) -> UpdateChecker {
        UpdateChecker(
            fetchFeed: { major in feeds[major].map(self.feed) },
            fetchPage: { page ?? "" },
            exists: { url in published.contains { url.lastPathComponent.hasSuffix("-\($0).zip") } })
    }

    func testParsesVersionFromFeed() {
        XCTAssertEqual(UpdateChecker.latestVersion(inFeed: feed("26.1.26134.173934")), BPTVersion("26.1.26134.173934"))
        XCTAssertNil(UpdateChecker.latestVersion(inFeed: "<installerInformation/>"))
    }

    func testParsesVersionFromProse() {
        XCTAssertEqual(UpdateChecker.latestVersion(inPage: govUKPage), BPTVersion("26.1.26134.173934"))
    }

    func testFallsBackToDownloadFileName() {
        let page = #"<a href="/x/payetools-rti-27.0.27001.100-linux.zip">Linux</a>"#
        XCTAssertEqual(UpdateChecker.latestVersion(inPage: page), BPTVersion("27.0.27001.100"))
    }

    func testReturnsNilWhenPageChanges() {
        XCTAssertNil(UpdateChecker.latestVersion(inPage: "<p>Nothing to see here</p>"))
    }

    func testWalksFeedsUpToTheNewestMajor() async {
        // The installed major's feed advertises 26.1; a v27 feed exists and advertises 27.0; v28 is missing.
        let checker = checker(feeds: [26: "26.1.26134.173934", 27: "27.0.27100.500"])
        await checker.check(installed: BPTVersion("26.1.26134.173934"))
        XCTAssertEqual(checker.availableUpdate, BPTVersion("27.0.27100.500"))
        XCTAssertEqual(checker.release?.source, "HMRC's update feed")
        XCTAssertEqual(checker.release?.macInstaller, true)
        XCTAssertEqual(checker.release?.linuxBuild, true)
    }

    func testStartsFromTheEarliestMajorWhenNothingIsInstalled() async throws {
        let checker = checker(feeds: [26: "26.1.26134.173934"])
        await checker.check(installed: nil)
        XCTAssertEqual(checker.status, .latestKnown(try XCTUnwrap(BPTVersion("26.1.26134.173934"))))
    }

    func testFallsBackToTheDownloadPageWithoutFeeds() async {
        let checker = checker(feeds: [:], page: govUKPage)
        await checker.check(installed: BPTVersion("25.2.25100.1"))
        XCTAssertEqual(checker.availableUpdate, BPTVersion("26.1.26134.173934"))
        XCTAssertEqual(checker.release?.source, "the GOV.UK download page")
        XCTAssertTrue(checker.showsBanner)
        checker.isBannerDismissed = true
        XCTAssertFalse(checker.showsBanner)
    }

    func testRecordsWhichBuildsHMRCPublish() async {
        let checker = checker(feeds: [26: "26.2.26300.1"], published: ["linux"])
        await checker.check(installed: BPTVersion("26.1.26134.173934"))
        XCTAssertEqual(checker.release?.macInstaller, false)
        XCTAssertEqual(checker.release?.linuxBuild, true)
    }

    func testReportsUpToDate() async throws {
        let installed = try XCTUnwrap(BPTVersion("26.1.26134.173934"))
        let checker = checker(feeds: [26: "26.1.26134.173934"])
        await checker.check(installed: installed)
        XCTAssertEqual(checker.status, .upToDate(installed))
        XCTAssertFalse(checker.showsBanner)
    }

    func testReportsFetchFailure() async {
        let checker = UpdateChecker(
            fetchFeed: { _ in throw URLError(.notConnectedToInternet) },
            fetchPage: { throw URLError(.notConnectedToInternet) },
            exists: { _ in false })
        await checker.check(installed: BPTVersion("26.1"))
        guard case .failed = checker.status else { return XCTFail("expected failure, got \(checker.status)") }
    }

    func testAdviceFollowsWhatHMRCPublish() throws {
        let version = try XCTUnwrap(BPTVersion("26.2.26300.1"))
        let both = UpdateChecker.Release(
            version: version, source: "", macInstaller: true, linuxBuild: true, checkedAt: Date())
        let linuxOnly = UpdateChecker.Release(
            version: version, source: "", macInstaller: false, linuxBuild: true, checkedAt: Date())
        let macOnly = UpdateChecker.Release(
            version: version, source: "", macInstaller: true, linuxBuild: false, checkedAt: Date())

        XCTAssertTrue(
            UpdateChecker.advice(engine: .macInstaller, release: linuxOnly, linuxEngineAvailable: true)
                .contains("don't publish a Mac installer"))
        XCTAssertTrue(
            UpdateChecker.advice(engine: .macInstaller, release: both, linuxEngineAvailable: true)
                .contains("Rosetta"))
        XCTAssertFalse(
            UpdateChecker.advice(engine: .macInstaller, release: both, linuxEngineAvailable: false)
                .contains("Rosetta"), "no point recommending an engine the Mac can't run")
        XCTAssertTrue(
            UpdateChecker.advice(engine: .linuxBuild, release: macOnly, linuxEngineAvailable: true)
                .contains("haven't published a Linux build"))
    }
}
