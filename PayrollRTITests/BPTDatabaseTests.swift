import SQLite3
import XCTest

@testable import PayrollRTI

final class BPTDatabaseTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("BPTDatabase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    /// A payroll database with only the table that matters, as South lays it out.
    private func makeDatabase(applied: [(String, String)]) throws -> BPTDatabase {
        let url = temp.appendingPathComponent("sqlite3.db")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let schema = """
            CREATE TABLE south_migrationhistory (
                id INTEGER PRIMARY KEY, app_name VARCHAR(255), migration VARCHAR(255), applied DATETIME)
            """
        XCTAssertEqual(sqlite3_exec(handle, schema, nil, nil, nil), SQLITE_OK)
        for (app, migration) in applied {
            let insert =
                "INSERT INTO south_migrationhistory (app_name, migration, applied) "
                + "VALUES ('\(app)', '\(migration)', '2026-01-01')"
            XCTAssertEqual(sqlite3_exec(handle, insert, nil, nil, nil), SQLITE_OK)
        }
        return BPTDatabase(url: url)
    }

    func testReadsAppliedMigrations() throws {
        let database = try makeDatabase(applied: [("bptrti", "0001_initial"), ("employee_nvr_r26", "0001_initial")])
        XCTAssertTrue(database.exists)
        XCTAssertEqual(try database.appliedMigrations(), ["bptrti/0001_initial", "employee_nvr_r26/0001_initial"])
    }

    func testMissingOrEmptyDatabaseDoesNotExist() {
        XCTAssertFalse(BPTDatabase(url: temp.appendingPathComponent("none.db")).exists)
        let empty = temp.appendingPathComponent("empty.db")
        FileManager.default.createFile(atPath: empty.path, contents: nil)
        XCTAssertFalse(BPTDatabase(url: empty).exists, "HMRC's workaround leaves zero-byte files; they aren't data")
    }

    func testUnreadableDatabaseThrows() {
        let junk = temp.appendingPathComponent("junk.db")
        FileManager.default.createFile(atPath: junk.path, contents: Data("not sqlite".utf8))
        XCTAssertThrowsError(try BPTDatabase(url: junk).appliedMigrations())
    }

    // MARK: - Verdicts

    func testSameMigrationsIsCurrent() {
        let known: Set<String> = ["bptrti/0001_initial", "bptrti/0002_x", "employee_nvr_r26/0001_initial"]
        XCTAssertEqual(DatabaseCompatibility.check(applied: known, known: known), .current)
    }

    func testEngineWithExtraMigrationsUpgrades() {
        let applied: Set<String> = ["bptrti/0001_initial"]
        let known: Set<String> = ["bptrti/0001_initial", "bptrti/0002_x", "employee_nvr_r27/0001_initial"]
        XCTAssertEqual(DatabaseCompatibility.check(applied: applied, known: known), .upgrade(pending: 2))
    }

    func testDatabaseWithMigrationsTheEngineLacksIsTooOld() {
        let applied: Set<String> = ["bptrti/0001_initial", "bptrti/0002_x"]
        let known: Set<String> = ["bptrti/0001_initial"]
        guard case .tooOld(let detail) = DatabaseCompatibility.check(applied: applied, known: known) else {
            return XCTFail("expected tooOld")
        }
        XCTAssertTrue(detail.contains("bptrti/0002_x"))
    }

    func testHistoryOfAppsTheEngineNoLongerShipsIsIgnored() {
        // HMRC delete old tax-year apps; South ignores their history, so this must not read as "too old".
        let applied: Set<String> = ["bptrti/0001_initial", "employee_forms_r15/0001_initial"]
        let known: Set<String> = ["bptrti/0001_initial"]
        XCTAssertEqual(DatabaseCompatibility.check(applied: applied, known: known), .current)
    }

    func testDownloadCandidateIsJudgedByTaxYearThenByNewestStarted() throws {
        let applied: Set<String> = [
            "bptrti/0001_initial", "employee_nvr_r26/0001_initial", "bptrti_pct_r25/0001_initial",
        ]
        let v25 = try XCTUnwrap(BPTVersion("25.1.25092.226"))
        let v26dot0 = try XCTUnwrap(BPTVersion("26.0.26069.145147"))
        let v26dot1 = try XCTUnwrap(BPTVersion("26.1.26134.173934"))
        let v27 = try XCTUnwrap(BPTVersion("27.0.27100.1"))

        guard case .tooOld = DatabaseCompatibility.check(applied: applied, candidate: v25, newestStarted: nil) else {
            return XCTFail("25.x can't open data that has 2026 apps")
        }
        XCTAssertEqual(DatabaseCompatibility.check(applied: applied, candidate: v26dot1, newestStarted: nil), .current)
        XCTAssertEqual(DatabaseCompatibility.check(applied: applied, candidate: v27, newestStarted: v26dot1), .current)
        let within = DatabaseCompatibility.check(applied: applied, candidate: v26dot0, newestStarted: v26dot1)
        guard case .tooOld = within else {
            return XCTFail("within a year, the version we last started decides")
        }
    }

    func testVerdictsRefuseOnlyTooOld() {
        XCTAssertTrue(DatabaseCompatibility.noDatabase.allowsStart)
        XCTAssertTrue(DatabaseCompatibility.current.allowsStart)
        XCTAssertTrue(DatabaseCompatibility.upgrade(pending: 1).allowsStart)
        XCTAssertTrue(DatabaseCompatibility.unknown("x").allowsStart)
        XCTAssertFalse(DatabaseCompatibility.tooOld("x").allowsStart)
    }

    // MARK: - Where an engine's migrations come from

    func testMigrationNamesFromPathsUseSouthsAppLabel() {
        XCTAssertEqual(
            BPTInstallation.migration(fromPath: "r26/employee_nvr_r26/migrations/0001_initial.pyc"),
            "employee_nvr_r26/0001_initial")
        XCTAssertEqual(
            BPTInstallation.migration(
                fromPath: "/Applications/B.app/Contents/Resources/lib/python2.7/bptrti/migrations/0025_add.pyc"),
            "bptrti/0025_add")
        XCTAssertNil(BPTInstallation.migration(fromPath: "bptrti/migrations/__init__.pyc"))
        XCTAssertNil(BPTInstallation.migration(fromPath: "bptrti/models/0001_initial.pyc"))
    }

    func testZipListingReadsAnArchiveAppendedToAnExecutable() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "prefixed", withExtension: "zip"))
        let names = try ZipListing.entryNames(of: fixture)
        XCTAssertEqual(names.count, 7)
        XCTAssertTrue(names.contains("r26/employee_nvr_r26/migrations/0001_initial.pyc"))
        XCTAssertEqual(
            Set(names.compactMap(BPTInstallation.migration(fromPath:))),
            ["bptrti/0001_initial", "bptrti/0025_add_pcd_submissions_fields", "employee_nvr_r26/0001_initial"])
    }

    func testZipListingRejectsNonZips() {
        let junk = temp.appendingPathComponent("junk.bin")
        FileManager.default.createFile(atPath: junk.path, contents: Data(repeating: 0x41, count: 100))
        XCTAssertThrowsError(try ZipListing.entryNames(of: junk)) { error in
            XCTAssertEqual(error as? ZipListing.Error, .notAZip)
        }
    }

    func testMacInstallerMigrationsComeFromItsLooseLibrary() throws {
        let fake = try FakeBPT.make()
        defer { FakeBPT.remove(fake) }
        let lib = fake.location.appendingPathComponent("Contents/Helpers/rti.app/Contents/Resources/lib/python2.7")
        try FileManager.default.createDirectory(
            at: lib.appendingPathComponent("employers_r26/migrations"), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: lib.appendingPathComponent("employers_r26/migrations/0001_initial.pyc").path, contents: Data())
        XCTAssertEqual(try fake.knownMigrations(), ["employers_r26/0001_initial"])
    }
}
