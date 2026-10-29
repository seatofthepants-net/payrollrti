import XCTest

@testable import PayrollRTI

final class AppImageTests: XCTestCase {
    private var scratch: URL = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("AppImageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: scratch)
    }

    func testFindsSquashFSAfterLastSection() throws {
        let squashfs = try Data(contentsOf: SquashFSFixture.url("sample"))
        // Section header table at 64; three sections, the last of which ends past the table.
        let tableOffset: UInt64 = 64
        let sections: [(offset: UInt64, size: UInt64)] = [(0, 0), (300, 100), (500, 700)]
        let payloadOffset: UInt64 = 1200
        var file = elfHeader(sectionHeaderOffset: tableOffset, sectionCount: UInt16(sections.count))
        for section in sections {
            file.append(sectionHeader(offset: section.offset, size: section.size))
        }
        file.append(Data(repeating: 0xEE, count: Int(payloadOffset) - file.count))
        file.append(squashfs)
        let url = scratch.appendingPathComponent("fake.AppImage")
        try file.write(to: url)

        XCTAssertEqual(try AppImage.squashfsOffset(in: url), payloadOffset)
        let image = try SquashFSImage(fileURL: url, offset: payloadOffset)
        var paths: [String] = []
        try image.walk { paths.append($0.path) }
        XCTAssertEqual(paths.first, "big.bin")
        XCTAssertEqual(paths.count, 8)
    }

    func testSquashFSDirectlyAfterSectionHeaderTable() throws {
        // No section extends beyond the table itself, so the payload starts right after it.
        var file = elfHeader(sectionHeaderOffset: 64, sectionCount: 1)
        file.append(sectionHeader(offset: 0, size: 0))
        let payloadOffset = UInt64(file.count)
        file.append(try Data(contentsOf: SquashFSFixture.url("sample")))
        let url = scratch.appendingPathComponent("tight.AppImage")
        try file.write(to: url)
        XCTAssertEqual(try AppImage.squashfsOffset(in: url), payloadOffset)
    }

    func testRejectsNonELF() throws {
        let url = scratch.appendingPathComponent("notelf.bin")
        try Data("PK\u{03}\u{04}definitely a zip, not an ELF".utf8).write(to: url)
        XCTAssertThrowsError(try AppImage.squashfsOffset(in: url)) {
            XCTAssertEqual($0 as? AppImage.Error, .notAnAppImage)
        }
    }

    func testRejectsELFWithoutAppImageMarker() throws {
        var file = elfHeader(sectionHeaderOffset: 64, sectionCount: 0)
        file[8] = 0
        file[9] = 0
        file[10] = 0
        let url = scratch.appendingPathComponent("plain.elf")
        try file.write(to: url)
        XCTAssertThrowsError(try AppImage.squashfsOffset(in: url)) {
            XCTAssertEqual($0 as? AppImage.Error, .notAnAppImage)
        }
    }

    func testRejectsAppImageWithoutSquashFS() throws {
        var file = elfHeader(sectionHeaderOffset: 64, sectionCount: 1)
        file.append(sectionHeader(offset: 0, size: 0))
        file.append(Data(repeating: 0, count: 64))
        let url = scratch.appendingPathComponent("empty.AppImage")
        try file.write(to: url)
        XCTAssertThrowsError(try AppImage.squashfsOffset(in: url)) {
            XCTAssertEqual($0 as? AppImage.Error, .noSquashFS)
        }
    }

    // MARK: - Synthetic ELF64

    private func elfHeader(sectionHeaderOffset: UInt64, sectionCount: UInt16) -> Data {
        var header = Data(count: 64)
        header.replaceSubrange(0..<4, with: [0x7F, 0x45, 0x4C, 0x46])
        header[4] = 2  // ELFCLASS64
        header[5] = 1  // ELFDATA2LSB
        header[6] = 1  // EV_CURRENT
        header.replaceSubrange(8..<11, with: [0x41, 0x49, 0x02])  // AppImage type 2 marker
        header.put(UInt16(2), at: 0x10)  // ET_EXEC
        header.put(UInt16(0x3E), at: 0x12)  // EM_X86_64
        header.put(UInt32(1), at: 0x14)
        header.put(sectionHeaderOffset, at: 0x28)
        header.put(UInt16(64), at: 0x34)  // e_ehsize
        header.put(UInt16(64), at: 0x3A)  // e_shentsize
        header.put(sectionCount, at: 0x3C)  // e_shnum
        return header
    }

    private func sectionHeader(offset: UInt64, size: UInt64) -> Data {
        var header = Data(count: 64)
        header.put(UInt32(1), at: 0x04)  // SHT_PROGBITS
        header.put(offset, at: 0x18)
        header.put(size, at: 0x20)
        return header
    }
}

extension Data {
    fileprivate mutating func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        Swift.withUnsafeBytes(of: value.littleEndian) { replaceSubrange(offset..<offset + $0.count, with: $0) }
    }
}
