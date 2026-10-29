import Foundation

enum AppImage {
    enum Error: Swift.Error, Equatable {
        case notAnAppImage
        case noSquashFS
    }

    /// Byte offset of the squashfs appended to a type-2 AppImage (ELF64 little-endian): max(section end) over all
    /// section headers, also ≥ end of the section header table. Validates ELF magic, the "AI\u{02}" marker at
    /// offset 8, and the "hsqs" magic at the computed offset.
    static func squashfsOffset(in fileURL: URL) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let header = try handle.read(upToCount: 64) ?? Data()
        guard header.count == 64,
            header[0..<4] == Data([0x7F, 0x45, 0x4C, 0x46]),  // "\u{7F}ELF"
            header[4] == 2,  // ELFCLASS64
            header[5] == 1,  // ELFDATA2LSB
            header[8..<11] == Data([0x41, 0x49, 0x02])  // "AI\u{02}"
        else { throw Error.notAnAppImage }

        let sectionHeaderOffset = header.le(UInt64.self, at: 0x28)
        let entrySize = UInt64(header.le(UInt16.self, at: 0x3A))
        let entryCount = UInt64(header.le(UInt16.self, at: 0x3C))
        guard entrySize >= 0x28 else { throw Error.noSquashFS }
        let tableSize = entrySize * entryCount
        var (end, overflow) = sectionHeaderOffset.addingReportingOverflow(tableSize)
        guard !overflow else { throw Error.noSquashFS }

        try handle.seek(toOffset: sectionHeaderOffset)
        let table = try handle.read(upToCount: Int(tableSize)) ?? Data()
        guard UInt64(table.count) == tableSize else { throw Error.noSquashFS }
        for index in 0..<Int(entryCount) {
            let entry = Int(entrySize) * index
            let (sectionEnd, overflowed) = table.le(UInt64.self, at: entry + 0x18)
                .addingReportingOverflow(table.le(UInt64.self, at: entry + 0x20))
            guard !overflowed else { throw Error.noSquashFS }
            end = max(end, sectionEnd)
        }

        try handle.seek(toOffset: end)
        guard try handle.read(upToCount: 4) == Data([0x68, 0x73, 0x71, 0x73]) else {  // "hsqs"
            throw Error.noSquashFS
        }
        return end
    }
}
