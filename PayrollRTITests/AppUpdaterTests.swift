import XCTest

@testable import PayrollRTI

@MainActor
final class AppUpdaterTests: XCTestCase {
    private func version(_ string: String) throws -> AppVersion { try XCTUnwrap(AppVersion(string)) }

    func testVersionsOrderWithPreReleasesBeforeTheirRelease() throws {
        let ordered = try [
            "0.1.0", "0.2.0-beta.1", "0.2.0-beta.2", "0.2.0-beta.10", "0.2.0-rc.1", "0.2.0", "0.2.1", "1.0.0",
        ]
            .map(version)
        for (earlier, later) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(earlier, later, "\(earlier) < \(later)")
        }
        XCTAssertEqual(try version("v0.2.0"), try version("0.2.0"), "GitHub tags carry a v")
        XCTAssertEqual(try version("0.2"), try version("0.2.0"))
        XCTAssertNil(AppVersion("latest"))
        XCTAssertEqual(try version("0.2.0-beta.1").description, "0.2.0-beta.1")
    }

    private func release(
        _ tag: String, prerelease: Bool = false, draft: Bool = false, dmg: Bool = true
    ) -> AppRelease {
        var assets: [AppRelease.Asset] = []
        if dmg {
            assets = [
                .init(name: "PayrollRTI-\(tag.dropFirst()).dmg", browserDownloadURL: URL(string: "https://x/d")!),
                .init(name: "PayrollRTI-\(tag.dropFirst()).dmg.sha256", browserDownloadURL: URL(string: "https://x/s")!),
            ]
        }
        return AppRelease(
            tagName: tag, name: nil, body: "notes", prerelease: prerelease, draft: draft,
            htmlURL: URL(string: "https://github.com/x")!, assets: assets)
    }

    func testReleaseBuildsOnlySeeReleases() throws {
        let releases = [release("v0.2.0-beta.3", prerelease: true), release("v0.2.0"), release("v0.1.0")]
        XCTAssertEqual(AppRelease.newest(in: releases, after: try version("0.1.0"))?.tagName, "v0.2.0")
        XCTAssertNil(AppRelease.newest(in: [release("v0.3.0-beta.1", prerelease: true)], after: try version("0.2.0")))
    }

    func testPreReleaseBuildsSeeLaterPreReleasesAndReleases() throws {
        let releases = [
            release("v0.2.0-beta.1", prerelease: true), release("v0.2.0-beta.2", prerelease: true), release("v0.1.0"),
        ]
        XCTAssertEqual(AppRelease.newest(in: releases, after: try version("0.2.0-beta.1"))?.tagName, "v0.2.0-beta.2")
        XCTAssertEqual(
            AppRelease.newest(in: releases + [release("v0.2.0")], after: try version("0.2.0-beta.2"))?.tagName,
            "v0.2.0")
    }

    func testDraftsAndReleasesWithoutADMGAreSkipped() throws {
        let releases = [release("v9.0.0", draft: true), release("v8.0.0", dmg: false), release("v0.2.0")]
        XCTAssertEqual(AppRelease.newest(in: releases, after: try version("0.1.0"))?.tagName, "v0.2.0")
    }

    func testDecodesGitHubReleaseJSON() throws {
        let json = """
            [{"tag_name":"v0.2.0-beta.1","name":"PayrollRTI 0.2.0-beta.1","body":"## What's changed\\n- A thing",
              "draft":false,"prerelease":true,
              "html_url":"https://github.com/seatofthepants-net/payrollrti/releases/tag/v0.2.0-beta.1",
              "assets":[{"name":"PayrollRTI-0.2.0-beta.1.dmg","browser_download_url":"https://example.com/a.dmg"},
                        {"name":"PayrollRTI-0.2.0-beta.1.dmg.sha256",
                         "browser_download_url":"https://example.com/a.sha256"}]}]
            """
        let releases = try JSONDecoder().decode([AppRelease].self, from: Data(json.utf8))
        XCTAssertEqual(releases.first?.dmg?.name, "PayrollRTI-0.2.0-beta.1.dmg")
        XCTAssertEqual(releases.first?.checksum?.name, "PayrollRTI-0.2.0-beta.1.dmg.sha256")
        XCTAssertEqual(releases.first?.version, try version("0.2.0-beta.1"))
    }

    func testCheckReportsAvailableOrUpToDateOrFailure() async throws {
        let available = AppUpdater(current: try version("0.1.0"), fetchReleases: { [self.release("v0.2.0")] })
        await available.check()
        XCTAssertEqual(available.available?.tagName, "v0.2.0")
        XCTAssertTrue(available.showsBanner)

        let current = AppUpdater(current: try version("0.2.0"), fetchReleases: { [self.release("v0.2.0")] })
        await current.check()
        XCTAssertEqual(current.status, .upToDate)

        let offline = AppUpdater(
            current: try version("0.2.0"), fetchReleases: { throw URLError(.notConnectedToInternet) })
        await offline.check()
        guard case .failed = offline.status else { return XCTFail("expected failure") }
    }

    func testChecksumVerificationUsesThePublishedDigest() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("AppUpdater-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let dmg = temp.appendingPathComponent("PayrollRTI-0.2.0.dmg")
        try Data("not really a disk image".utf8).write(to: dmg)
        let good = temp.appendingPathComponent("good.sha256")
        // release.sh writes shasum's "<hex>  PayrollRTI-0.2.0.dmg" line.
        try "\(BPTBackup.sha256Hex(Data("not really a disk image".utf8)))  PayrollRTI-0.2.0.dmg\n"
            .write(to: good, atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try AppUpdater.verify(dmg, against: good))
        let bad = temp.appendingPathComponent("bad.sha256")
        try "0000  PayrollRTI-0.2.0.dmg\n".write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AppUpdater.verify(dmg, against: bad))
    }

    func testNotesStripHeadingsAndKeepLines() {
        let notes = AppUpdateSheet.notes("## What's changed\n\n- One\n- Two **bold**")
        XCTAssertTrue(String(notes.characters).hasPrefix("What's changed"))
        XCTAssertTrue(String(notes.characters).contains("- Two bold"))
    }
}
