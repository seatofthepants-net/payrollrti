import XCTest

@testable import PayrollRTI

final class BPTBackupTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("BPTBackup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func unzip(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read before waiting: a large entry would fill the pipe and block unzip forever.
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(bytes: output, encoding: .utf8) ?? "")
    }

    func testWritesABackupInBPTsFormat() throws {
        // Compressible content, like a real database, so the deflate path is exercised.
        let contents = Data((0..<200_000).map { UInt8($0 % 7) })
        let database = temp.appendingPathComponent("sqlite3.db")
        try contents.write(to: database)
        let when = try XCTUnwrap(
            Calendar(identifier: .gregorian).date(
                from: DateComponents(year: 2026, month: 10, day: 29, hour: 16, minute: 30, second: 5)))

        let backup = try BPTBackup.write(
            database: database, version: BPTVersion("26.1.26134.173934"), reason: "PRE-UPGRADE",
            to: temp.appendingPathComponent("backups"), now: when)

        XCTAssertEqual(backup.lastPathComponent, "RTI-26-1-26134__2026-10-29_163005_PRE-UPGRADE.bak")
        XCTAssertEqual(try ZipListing.entryNames(of: backup), ["version", "sqlite3.db", "sqlite3.db.sha256"])
        XCTAssertLessThan(
            try FileManager.default.attributesOfItem(atPath: backup.path)[.size] as? Int ?? .max, contents.count / 2,
            "the database entry is deflated, as in BPT's own backups")

        // unzip -t checks every entry's CRC and inflates it: what BPT's zipfile module will do on restore.
        let test = try unzip(["-t", backup.path])
        XCTAssertEqual(test.status, 0, test.output)
        XCTAssertEqual(try unzip(["-p", backup.path, "version"]).output, "26.1.26134")
        XCTAssertEqual(try unzip(["-p", backup.path, "sqlite3.db.sha256"]).output, BPTBackup.sha256Hex(contents))
        XCTAssertEqual(try unzip(["-p", backup.path, "sqlite3.db"]).output.utf8.count, contents.count)
    }

    func testUnknownVersionStillSatisfiesRestoresFormatCheck() throws {
        let database = temp.appendingPathComponent("sqlite3.db")
        try Data("x".utf8).write(to: database)
        let backup = try BPTBackup.write(database: database, version: nil, reason: "PRE-INSTALL", to: temp)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("RTI-2__"))
        XCTAssertEqual(try unzip(["-p", backup.path, "version"]).output, "2", "BPT's restore requires a leading 2")
    }

    func testRefusesAnEmptyDatabase() throws {
        let database = temp.appendingPathComponent("sqlite3.db")
        FileManager.default.createFile(atPath: database.path, contents: nil)
        XCTAssertThrowsError(try BPTBackup.write(database: database, version: nil, reason: "X", to: temp))
    }
}
