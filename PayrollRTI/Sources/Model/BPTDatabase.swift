import Foundation
import SQLite3

/// Basic PAYE Tools' payroll database, read only, for one question: which schema migrations has it had?
/// BPT uses South, which records every applied migration in `south_migrationhistory` as (app_name, migration).
struct BPTDatabase {
    let url: URL

    static let `default` = BPTDatabase(
        url: ServerController.defaultDataDirectory.appendingPathComponent("sqlite3.db"))

    var exists: Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int).map { $0 > 0 } ?? false
    }

    /// Applied migrations as `"app_name/migration"`, e.g. `"employee_nvr_r26/0001_initial"`.
    func appliedMigrations() throws -> Set<String> {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "couldn't open"
            sqlite3_close(handle)
            throw Failure(message: message)
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let sql = "SELECT app_name, migration FROM south_migrationhistory"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var applied: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let app = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1) else {
                continue
            }
            applied.insert("\(String(cString: app))/\(String(cString: name))")
        }
        return applied
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

/// Whether a copy of Basic PAYE Tools can open an existing payroll database.
enum DatabaseCompatibility: Equatable {
    /// No payroll data yet: anything can start.
    case noDatabase
    /// The database has exactly the migrations this copy knows.
    case current
    /// This copy has migrations the database hasn't had: it will upgrade the database when it starts.
    case upgrade(pending: Int)
    /// The database has been used by a newer version. BPT can't go back, and its migration tool would abort.
    case tooOld(String)
    /// The database or the copy couldn't be read.
    case unknown(String)

    var allowsStart: Bool {
        switch self {
        case .noDatabase, .current, .upgrade, .unknown: return true
        case .tooOld: return false
        }
    }

    /// Compares the database's history with the migrations a copy of BPT ships. Apps that have migrations in the
    /// database but none in the copy are ignored: HMRC delete old tax-year apps and South ignores their history.
    static func check(applied: Set<String>, known: Set<String>) -> DatabaseCompatibility {
        let knownApps = Set(known.compactMap { $0.split(separator: "/").first })
        let relevant = applied.filter { knownApps.contains($0.split(separator: "/").first ?? "") }
        let ghosts = relevant.subtracting(known).sorted()
        if !ghosts.isEmpty {
            let examples = ghosts.prefix(3).joined(separator: ", ")
            let plural = ghosts.count == 1 ? "" : "s"
            return .tooOld("It has \(ghosts.count) newer change\(plural) this version doesn't know, e.g. \(examples).")
        }
        let pending = known.subtracting(applied).count
        return pending == 0 ? .current : .upgrade(pending: pending)
    }

    /// For a version that hasn't been downloaded, so its migrations can't be read: BPT's major version is the tax
    /// year, and its per-year apps are suffixed `_r<year>`, so the newest year in the database's history is the
    /// oldest major version that can open it. Within a major version `newestStarted` is the only guide.
    static func check(
        applied: Set<String>, candidate: BPTVersion, newestStarted: BPTVersion?
    ) -> DatabaseCompatibility {
        let years = applied.compactMap { entry -> Int? in
            guard let app = entry.split(separator: "/").first, let range = app.range(of: "_r", options: .backwards)
            else { return nil }
            return Int(app[range.upperBound...])
        }
        if let required = years.max(), let major = candidate.components.first, major < required {
            return .tooOld(
                "Your payroll data has been used by Basic PAYE Tools for 20\(required); version \(candidate) is older.")
        }
        if let newestStarted, candidate < newestStarted {
            return .tooOld("Your payroll data has already been used by version \(newestStarted).")
        }
        return .current
    }

    /// Plain words for the choice screen and Settings.
    var summary: String {
        switch self {
        case .noDatabase: return "You don't have any payroll data yet."
        case .current: return "Works with your existing payroll data."
        case .upgrade(let pending):
            return "Will update your payroll data when it starts (\(pending) change\(pending == 1 ? "" : "s"); "
                + "Basic PAYE Tools backs up first)."
        case .tooOld(let detail): return "Can't open your payroll data: \(detail)"
        case .unknown(let detail): return "Couldn't check your payroll data: \(detail)"
        }
    }
}

extension BPTInstallation {
    /// Every schema migration this copy ships, as `"app_name/migration"`. The Mac installer (py2app) keeps its
    /// bytecode as loose files under `Resources/lib/python2.7`; the Linux build (cx_Freeze) has a zip appended to
    /// `rti.linux`. South's app name is the package's last path component.
    func knownMigrations() throws -> Set<String> {
        let paths: [String]
        switch self {
        case .macInstaller(let appURL):
            let lib = BPTInstallation.serverApp(in: appURL).appendingPathComponent("Contents/Resources/lib/python2.7")
            guard let files = FileManager.default.enumerator(at: lib, includingPropertiesForKeys: nil) else {
                throw BPTDatabase.Failure(message: "no Python library in \(appURL.lastPathComponent)")
            }
            paths = files.compactMap { ($0 as? URL)?.path }
        case .linuxBuild(let payload, _):
            paths = try ZipListing.entryNames(of: payload.baseURL.appendingPathComponent("rti.linux"))
        }
        return Set(paths.compactMap(Self.migration(fromPath:)))
    }

    /// `…/employee_nvr_r26/migrations/0001_initial.pyc` → `employee_nvr_r26/0001_initial`.
    static func migration(fromPath path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count >= 3, parts[parts.count - 2] == "migrations" else { return nil }
        let file = parts[parts.count - 1]
        guard file.hasSuffix(".pyc") || file.hasSuffix(".py"), file.first?.isNumber == true else { return nil }
        let name = file.prefix(while: { $0 != "." })
        return "\(parts[parts.count - 3])/\(name)"
    }

    func databaseCompatibility(with database: BPTDatabase = .default) -> DatabaseCompatibility {
        guard database.exists else { return .noDatabase }
        do {
            return DatabaseCompatibility.check(applied: try database.appliedMigrations(), known: try knownMigrations())
        } catch {
            return .unknown(error.localizedDescription)
        }
    }
}

/// Just enough of the zip format to list the entries of an archive, including one appended to an executable
/// (cx_Freeze's `rti.linux`): the central directory's offsets are relative to the archive, not the file.
enum ZipListing {
    enum Error: Swift.Error, Equatable { case notAZip, corrupt }

    static func entryNames(of url: URL) throws -> [String] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        // End of central directory record: signature, then the record is at least 22 bytes with a comment up to 64 KiB.
        let eocdSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let searchStart = max(0, data.count - 22 - 65_535)
        guard data.count >= 22,
            let eocd = data[searchStart...].lastRange(of: eocdSignature)?.lowerBound
        else { throw Error.notAZip }
        let entryCount = Int(data.le16(at: eocd + 10))
        let directorySize = Int(data.le32(at: eocd + 12))
        let directoryOffset = Int(data.le32(at: eocd + 16))
        let directoryStart = eocd - directorySize
        guard directoryStart >= directoryOffset else { throw Error.corrupt }
        // Bytes before the archive proper (the executable the zip is appended to), as zipimport computes it.
        var position = directoryStart
        var names: [String] = []
        names.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            guard position + 46 <= data.count, data[position..<position + 4].elementsEqual([0x50, 0x4B, 0x01, 0x02])
            else { throw Error.corrupt }
            let nameLength = Int(data.le16(at: position + 28))
            let extraLength = Int(data.le16(at: position + 30))
            let commentLength = Int(data.le16(at: position + 32))
            let nameStart = position + 46
            guard nameStart + nameLength <= data.count else { throw Error.corrupt }
            names.append(String(bytes: data[nameStart..<nameStart + nameLength], encoding: .utf8) ?? "")
            position = nameStart + nameLength + extraLength + commentLength
        }
        return names
    }
}

extension Data {
    fileprivate func le16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    fileprivate func le32(at offset: Int) -> UInt32 {
        UInt32(le16(at: offset)) | UInt32(le16(at: offset + 2)) << 16
    }

    fileprivate func lastRange(of pattern: [UInt8]) -> Range<Int>? {
        guard count >= pattern.count else { return nil }
        var index = endIndex - pattern.count
        while index >= startIndex {
            if self[index..<index + pattern.count].elementsEqual(pattern) { return index..<index + pattern.count }
            index -= 1
        }
        return nil
    }
}
