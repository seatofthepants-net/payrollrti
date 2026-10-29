import CommonCrypto
import Compression
import Foundation
import zlib

/// Writes a backup of the payroll database in Basic PAYE Tools' own format, so BPT's **Restore your data** can
/// read it: a zip holding `version` (BPT's three-part version), `sqlite3.db` (deflated) and `sqlite3.db.sha256`
/// (hex digest), named like BPT's automatic backups, `RTI-26-1-26134__2026-10-29_163000_<reason>.bak`.
///
/// Used before anything PayrollRTI does that could change the database: installing a Linux build and starting
/// a copy of BPT that will migrate the schema. Taken while no BPT server is running, so the copy is consistent.
enum BPTBackup {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Returns the backup's URL. `version` is the BPT version the database was last used by; the restore code
    /// only requires it to start with "2" (older formats started "12"), so an unknown version is written as the
    /// major alone.
    static func write(
        database: URL, version: BPTVersion?, reason: String, to directory: URL, now: Date = Date()
    ) throws -> URL {
        let contents = try Data(contentsOf: database)
        guard !contents.isEmpty else { throw Failure(message: "the payroll database is empty") }

        let official = (version?.components.prefix(3) ?? [2]).map(String.init).joined(separator: ".")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = formatter.string(from: now)
        let name = "RTI-\(official.replacingOccurrences(of: ".", with: "-"))__\(stamp)_\(reason).bak"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)

        var zip = ZipWriter(date: now)
        zip.add(name: "version", data: Data(official.utf8), compress: false)
        zip.add(name: database.lastPathComponent, data: contents, compress: true)
        zip.add(name: "\(database.lastPathComponent).sha256", data: Data(sha256Hex(contents).utf8), compress: true)
        try zip.finish().write(to: url, options: .atomic)
        return url
    }

    static func sha256Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// A minimal zip writer: stored or deflated entries, no zip64, no extras. Enough for a backup BPT's `zipfile`
/// module (and `unzip`) will open.
struct ZipWriter {
    private var body = Data()
    private var directory = Data()
    private var entries: UInt16 = 0
    private let dosDate: UInt16
    private let dosTime: UInt16

    init(date: Date) {
        let parts = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = max(0, (parts.year ?? 1980) - 1980)
        let month: Int = parts.month ?? 1
        let day: Int = parts.day ?? 1
        dosDate = UInt16((year << 9) | (month << 5) | day)
        let hour: Int = parts.hour ?? 0
        let minute: Int = parts.minute ?? 0
        let second: Int = (parts.second ?? 0) / 2
        dosTime = UInt16((hour << 11) | (minute << 5) | second)
    }

    mutating func add(name: String, data: Data, compress: Bool) {
        let crc = data.withUnsafeBytes {
            UInt32(crc32(0, $0.baseAddress?.assumingMemoryBound(to: UInt8.self), uInt(data.count)))
        }
        var method: UInt16 = 0
        var payload = data
        if compress, let deflated = Self.deflate(data), deflated.count < data.count {
            method = 8
            payload = deflated
        }
        let nameBytes = Data(name.utf8)
        let offset = UInt32(body.count)

        var local = Data()
        local.append(le32: 0x0403_4B50)
        local.append(le16: 20)
        local.append(le16: 0)
        local.append(le16: method)
        local.append(le16: dosTime)
        local.append(le16: dosDate)
        local.append(le32: crc)
        local.append(le32: UInt32(payload.count))
        local.append(le32: UInt32(data.count))
        local.append(le16: UInt16(nameBytes.count))
        local.append(le16: 0)
        local.append(nameBytes)
        body.append(local)
        body.append(payload)

        var central = Data()
        central.append(le32: 0x0201_4B50)
        central.append(le16: 20)
        central.append(le16: 20)
        central.append(le16: 0)
        central.append(le16: method)
        central.append(le16: dosTime)
        central.append(le16: dosDate)
        central.append(le32: crc)
        central.append(le32: UInt32(payload.count))
        central.append(le32: UInt32(data.count))
        central.append(le16: UInt16(nameBytes.count))
        central.append(le16: 0)
        central.append(le16: 0)
        central.append(le16: 0)
        central.append(le16: 0)
        central.append(le32: 0)
        central.append(le32: offset)
        central.append(nameBytes)
        directory.append(central)
        entries += 1
    }

    func finish() -> Data {
        var out = body
        out.append(directory)
        out.append(le32: 0x0605_4B50)
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le16: entries)
        out.append(le16: entries)
        out.append(le32: UInt32(directory.count))
        out.append(le32: UInt32(body.count))
        out.append(le16: 0)
        return out
    }

    /// Raw DEFLATE, which is what zip method 8 stores (no zlib header).
    private static func deflate(_ data: Data) -> Data? {
        let capacity = data.count + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.baseAddress, let sourceBase = source.baseAddress else {
                    return 0
                }
                return compression_encode_buffer(
                    destinationBase.assumingMemoryBound(to: UInt8.self), capacity,
                    sourceBase.assumingMemoryBound(to: UInt8.self), data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
    }
}

extension Data {
    fileprivate mutating func append(le16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    fileprivate mutating func append(le32 value: UInt32) {
        append(le16: UInt16(value & 0xFFFF))
        append(le16: UInt16(value >> 16))
    }
}
