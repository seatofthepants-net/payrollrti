import Compression
import Foundation

/// Read-only access to a squashfs 4.0 image embedded in a larger file (an AppImage). Gzip compression only.
///
/// Every offset inside the image is relative to the squashfs superblock; `offset` is added when touching the file.
/// Decoded metadata blocks and fragment blocks are cached by offset. Not safe for concurrent use from several threads.
struct SquashFSImage {
    enum Kind: Equatable {
        case directory
        case file(size: UInt64)
        case symlink(target: String)
    }

    struct Entry: Equatable {
        /// Relative, "/"-separated, no leading slash.
        let path: String
        let kind: Kind
        let mode: UInt16
    }

    enum Error: Swift.Error, Equatable {
        case notSquashFS
        case unsupportedCompression(UInt16)
        case unsupportedVersion(major: UInt16, minor: UInt16)
        case corrupt(String)
    }

    private let reader: Reader
    private let superblock: Superblock

    init(fileURL: URL, offset: UInt64) throws {
        reader = try Reader(fileURL: fileURL, base: offset)
        let raw = try reader.readRaw(at: 0, count: Superblock.size)
        guard raw.count == Superblock.size, raw.le(UInt32.self, at: 0) == Superblock.magic else {
            throw Error.notSquashFS
        }
        superblock = Superblock(raw)
        guard superblock.versionMajor == 4, superblock.versionMinor == 0 else {
            throw Error.unsupportedVersion(major: superblock.versionMajor, minor: superblock.versionMinor)
        }
        guard superblock.compressionID == Superblock.gzip else {
            throw Error.unsupportedCompression(superblock.compressionID)
        }
        guard superblock.blockLog < 32, superblock.blockSize == 1 << superblock.blockLog else {
            throw Error.corrupt("block size \(superblock.blockSize) does not match block log \(superblock.blockLog)")
        }
        reader.blockSize = Int(superblock.blockSize)
    }

    /// Depth-first, parents before children, directory entries sorted by name as stored. Throws from `visit` propagate.
    func walk(_ visit: (Entry) throws -> Void) throws {
        let root = try inode(at: superblock.rootInodeRef)
        guard case .directory = root.body else { throw Error.corrupt("root inode is not a directory") }
        try walk(directory: root, path: "", visit)
    }

    /// Writes a regular file's contents to `destination` (creating/truncating it). Only valid for `.file` entries.
    func extract(_ entry: Entry, to destination: URL) throws {
        guard case .file = entry.kind else { throw Error.corrupt("\(entry.path) is not a regular file") }
        let node = try lookup(entry.path)
        guard case let .file(file) = node.body else { throw Error.corrupt("\(entry.path) is not a regular file") }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.truncate(atOffset: 0)

        let blockSize = UInt64(superblock.blockSize)
        var remaining = file.size
        var position = file.startBlock
        for sizeWord in file.blockSizes {
            let expected = Int(min(blockSize, remaining))
            let block = try reader.dataBlock(at: position, sizeWord: sizeWord, expected: expected)
            try output.write(contentsOf: block)
            position += UInt64(sizeWord & Reader.dataSizeMask)
            remaining -= UInt64(expected)
        }
        if file.fragment != Inode.noFragment {
            let location = try fragmentLocation(file.fragment)
            let fragment = try reader.fragmentBlock(at: location.start, sizeWord: location.sizeWord)
            let start = Int(file.fragmentOffset)
            let end = start + Int(remaining)
            guard end <= fragment.count else {
                throw Error.corrupt("fragment \(file.fragment) too short for \(entry.path)")
            }
            try output.write(contentsOf: fragment.subdata(in: start..<end))
            remaining = 0
        }
        guard remaining == 0 else { throw Error.corrupt("\(entry.path) is missing \(remaining) bytes") }
    }

    // MARK: - Walking

    private func walk(directory: Inode, path: String, _ visit: (Entry) throws -> Void) throws {
        for child in try listing(of: directory) {
            let node = try inode(at: child.inodeRef)
            let childPath = path.isEmpty ? child.name : path + "/" + child.name
            let kind: Kind
            switch node.body {
            case .directory: kind = .directory
            case let .file(file): kind = .file(size: file.size)
            case let .symlink(target): kind = .symlink(target: target)
            case .other: continue
            }
            try visit(Entry(path: childPath, kind: kind, mode: node.mode))
            if case .directory = node.body {
                try walk(directory: node, path: childPath, visit)
            }
        }
    }

    private func lookup(_ path: String) throws -> Inode {
        var node = try inode(at: superblock.rootInodeRef)
        for component in path.split(separator: "/") {
            guard case .directory = node.body,
                let child = try listing(of: node).first(where: { $0.name == component })
            else { throw Error.corrupt("no such entry: \(path)") }
            node = try inode(at: child.inodeRef)
        }
        return node
    }

    // MARK: - Inodes and directories

    private struct DirectoryEntry {
        let name: String
        let inodeRef: UInt64
    }

    private func inode(at reference: UInt64) throws -> Inode {
        var cursor = try MetadataCursor(
            reader: reader, block: superblock.inodeTableStart + (reference >> 16), offset: Int(reference & 0xFFFF))
        let type = try cursor.readU16()
        let mode = try cursor.readU16()
        _ = try cursor.readU16()  // uid
        _ = try cursor.readU16()  // gid
        _ = try cursor.readU32()  // mtime
        _ = try cursor.readU32()  // inode number
        let body: Inode.Body
        switch type {
        case 1:
            let startBlock = try cursor.readU32()
            _ = try cursor.readU32()  // nlink
            let fileSize = try cursor.readU16()
            let blockOffset = try cursor.readU16()
            body = .directory(
                Inode.Directory(startBlock: startBlock, blockOffset: blockOffset, listingSize: UInt32(fileSize)))
        case 8:
            _ = try cursor.readU32()  // nlink
            let fileSize = try cursor.readU32()
            let startBlock = try cursor.readU32()
            _ = try cursor.readU32()  // parent inode
            _ = try cursor.readU16()  // index count
            let blockOffset = try cursor.readU16()
            body = .directory(Inode.Directory(startBlock: startBlock, blockOffset: blockOffset, listingSize: fileSize))
        case 2:
            let startBlock = try cursor.readU32()
            let fragment = try cursor.readU32()
            let fragmentOffset = try cursor.readU32()
            let size = try cursor.readU32()
            body = .file(
                try fileBody(
                    &cursor, startBlock: UInt64(startBlock), size: UInt64(size), fragment: fragment,
                    fragmentOffset: fragmentOffset))
        case 9:
            let startBlock = try cursor.readU64()
            let size = try cursor.readU64()
            _ = try cursor.readU64()  // sparse
            _ = try cursor.readU32()  // nlink
            let fragment = try cursor.readU32()
            let fragmentOffset = try cursor.readU32()
            _ = try cursor.readU32()  // xattr
            body = .file(
                try fileBody(
                    &cursor, startBlock: startBlock, size: size, fragment: fragment, fragmentOffset: fragmentOffset))
        case 3, 10:
            _ = try cursor.readU32()  // nlink
            let targetSize = try cursor.readU32()
            guard targetSize <= 65535 else { throw Error.corrupt("symlink target of \(targetSize) bytes") }
            let target = try cursor.read(Int(targetSize))
            body = .symlink(target: String(decoding: target, as: UTF8.self))
        case 4, 5, 6, 7, 11, 12, 13, 14:
            body = .other
        default:
            throw Error.corrupt("unknown inode type \(type)")
        }
        return Inode(mode: mode, body: body)
    }

    private func fileBody(
        _ cursor: inout MetadataCursor, startBlock: UInt64, size: UInt64, fragment: UInt32, fragmentOffset: UInt32
    ) throws -> Inode.File {
        let blockSize = UInt64(superblock.blockSize)
        let hasFragment = fragment != Inode.noFragment
        let blockCount = hasFragment ? size / blockSize : (size + blockSize - 1) / blockSize
        guard blockCount <= 1 << 24 else { throw Error.corrupt("file of \(size) bytes has too many blocks") }
        var blockSizes: [UInt32] = []
        blockSizes.reserveCapacity(Int(blockCount))
        for _ in 0..<blockCount {
            blockSizes.append(try cursor.readU32())
        }
        if hasFragment, fragment >= superblock.fragmentCount {
            throw Error.corrupt("fragment \(fragment) out of range")
        }
        return Inode.File(
            startBlock: startBlock, size: size, fragment: fragment, fragmentOffset: fragmentOffset,
            blockSizes: blockSizes)
    }

    private func listing(of node: Inode) throws -> [DirectoryEntry] {
        guard case let .directory(directory) = node.body else { throw Error.corrupt("not a directory") }
        guard directory.listingSize >= 3 else { return [] }
        let length = Int(directory.listingSize) - 3
        var cursor = try MetadataCursor(
            reader: reader, block: superblock.directoryTableStart + UInt64(directory.startBlock),
            offset: Int(directory.blockOffset))
        var entries: [DirectoryEntry] = []
        var consumed = 0
        while consumed < length {
            let count = try cursor.readU32()
            let start = try cursor.readU32()
            _ = try cursor.readU32()  // inode number
            consumed += 12
            guard count < 256 else { throw Error.corrupt("directory header with \(count + 1) entries") }
            for _ in 0...count {
                let offset = try cursor.readU16()
                _ = try cursor.readU16()  // inode number delta
                _ = try cursor.readU16()  // type
                let nameSize = Int(try cursor.readU16()) + 1
                let name = try cursor.read(nameSize)
                consumed += 8 + nameSize
                entries.append(
                    DirectoryEntry(
                        name: String(decoding: name, as: UTF8.self), inodeRef: UInt64(start) << 16 | UInt64(offset)))
            }
        }
        guard consumed == length else { throw Error.corrupt("directory listing overran its size") }
        return entries
    }

    // MARK: - Fragments

    private struct FragmentLocation {
        let start: UInt64
        let sizeWord: UInt32
    }

    private func fragmentLocation(_ index: UInt32) throws -> FragmentLocation {
        guard index < superblock.fragmentCount else { throw Error.corrupt("fragment \(index) out of range") }
        let pointer = try reader.readRaw(at: superblock.fragmentTableStart + UInt64(index / 512) * 8, count: 8)
        guard pointer.count == 8 else { throw Error.corrupt("truncated fragment table") }
        let block = try reader.metadataBlock(at: pointer.le(UInt64.self, at: 0)).data
        let entryOffset = Int(index % 512) * 16
        guard entryOffset + 16 <= block.count else { throw Error.corrupt("truncated fragment table block") }
        return FragmentLocation(
            start: block.le(UInt64.self, at: entryOffset), sizeWord: block.le(UInt32.self, at: entryOffset + 8))
    }

    // MARK: - On-disk structures

    private struct Superblock {
        static let size = 96
        static let magic: UInt32 = 0x7371_7368  // "hsqs"
        static let gzip: UInt16 = 1

        let blockSize: UInt32
        let fragmentCount: UInt32
        let compressionID: UInt16
        let blockLog: UInt16
        let versionMajor: UInt16
        let versionMinor: UInt16
        let rootInodeRef: UInt64
        let inodeTableStart: UInt64
        let directoryTableStart: UInt64
        let fragmentTableStart: UInt64

        init(_ raw: Data) {
            blockSize = raw.le(UInt32.self, at: 12)
            fragmentCount = raw.le(UInt32.self, at: 16)
            compressionID = raw.le(UInt16.self, at: 20)
            blockLog = raw.le(UInt16.self, at: 22)
            versionMajor = raw.le(UInt16.self, at: 28)
            versionMinor = raw.le(UInt16.self, at: 30)
            rootInodeRef = raw.le(UInt64.self, at: 32)
            inodeTableStart = raw.le(UInt64.self, at: 64)
            directoryTableStart = raw.le(UInt64.self, at: 72)
            fragmentTableStart = raw.le(UInt64.self, at: 80)
        }
    }

    private struct Inode {
        static let noFragment: UInt32 = 0xFFFF_FFFF

        struct Directory {
            let startBlock: UInt32
            let blockOffset: UInt16
            let listingSize: UInt32
        }

        struct File {
            let startBlock: UInt64
            let size: UInt64
            let fragment: UInt32
            let fragmentOffset: UInt32
            let blockSizes: [UInt32]
        }

        enum Body {
            case directory(Directory)
            case file(File)
            case symlink(target: String)
            case other
        }

        let mode: UInt16
        let body: Body
    }

    /// Sequential reader over the metadata block stream starting at a given block, following into the next block
    /// (which begins right after the current block's compressed bytes) as needed.
    private struct MetadataCursor {
        private let reader: Reader
        private var block: Data
        private var next: UInt64
        private var position: Int

        init(reader: Reader, block start: UInt64, offset: Int) throws {
            self.reader = reader
            let decoded = try reader.metadataBlock(at: start)
            block = decoded.data
            next = decoded.next
            position = offset
            guard offset <= block.count else { throw Error.corrupt("metadata offset \(offset) beyond block") }
        }

        mutating func read(_ count: Int) throws -> Data {
            var out = Data(capacity: count)
            while out.count < count {
                if position == block.count {
                    let decoded = try reader.metadataBlock(at: next)
                    guard !decoded.data.isEmpty else { throw Error.corrupt("empty metadata block") }
                    block = decoded.data
                    next = decoded.next
                    position = 0
                }
                let chunk = min(count - out.count, block.count - position)
                out.append(block.subdata(in: position..<position + chunk))
                position += chunk
            }
            return out
        }

        mutating func readU16() throws -> UInt16 { try read(2).le(UInt16.self, at: 0) }
        mutating func readU32() throws -> UInt32 { try read(4).le(UInt32.self, at: 0) }
        mutating func readU64() throws -> UInt64 { try read(8).le(UInt64.self, at: 0) }
    }

    // MARK: - File access and decompression

    /// Random access to the image file plus caches of decoded metadata and fragment blocks.
    private final class Reader {
        static let dataSizeMask: UInt32 = 0x00FF_FFFF
        static let dataUncompressed: UInt32 = 0x0100_0000
        static let metadataUncompressed: UInt16 = 0x8000
        static let metadataSizeMask: UInt16 = 0x7FFF
        static let metadataBlockSize = 8192
        private static let fragmentCacheLimit = 64

        struct MetadataBlock {
            let data: Data
            let next: UInt64
        }

        var blockSize = 0
        private let handle: FileHandle
        private let base: UInt64
        private var metadataCache: [UInt64: MetadataBlock] = [:]
        private var fragmentCache: [UInt64: Data] = [:]

        init(fileURL: URL, base: UInt64) throws {
            handle = try FileHandle(forReadingFrom: fileURL)
            self.base = base
        }

        deinit {
            try? handle.close()
        }

        /// Reads up to `count` bytes at an image-relative offset; shorter at end of file.
        func readRaw(at offset: UInt64, count: Int) throws -> Data {
            let (absolute, overflow) = base.addingReportingOverflow(offset)
            guard !overflow, absolute <= UInt64(Int64.max) else { throw Error.corrupt("offset \(offset) overflows") }
            var data = Data(count: count)
            var filled = 0
            while filled < count {
                let got = data.withUnsafeMutableBytes { buffer -> Int in
                    guard let bytes = buffer.baseAddress else { return 0 }
                    return pread(handle.fileDescriptor, bytes + filled, count - filled, off_t(absolute) + off_t(filled))
                }
                if got < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                if got == 0 { break }
                filled += got
            }
            data.count = filled
            return data
        }

        func metadataBlock(at offset: UInt64) throws -> MetadataBlock {
            if let cached = metadataCache[offset] { return cached }
            let header = try readRaw(at: offset, count: 2)
            guard header.count == 2 else { throw Error.corrupt("truncated metadata block at \(offset)") }
            let word = header.le(UInt16.self, at: 0)
            let size = Int(word & Self.metadataSizeMask)
            let raw = try readRaw(at: offset + 2, count: size)
            guard raw.count == size else { throw Error.corrupt("truncated metadata block at \(offset)") }
            let data: Data
            if word & Self.metadataUncompressed != 0 {
                data = raw
            } else {
                data = try inflate(raw, capacity: Self.metadataBlockSize, context: "metadata block at \(offset)")
            }
            let block = MetadataBlock(data: data, next: offset + 2 + UInt64(size))
            metadataCache[offset] = block
            return block
        }

        /// A file data block; `expected` is its decoded length (the block size except for a short final block).
        func dataBlock(at offset: UInt64, sizeWord: UInt32, expected: Int) throws -> Data {
            let size = Int(sizeWord & Self.dataSizeMask)
            if size == 0 { return Data(count: expected) }
            let data = try decodeBlock(at: offset, size: size, uncompressed: sizeWord & Self.dataUncompressed != 0)
            guard data.count == expected else {
                throw Error.corrupt("data block at \(offset) decoded to \(data.count) bytes, expected \(expected)")
            }
            return data
        }

        func fragmentBlock(at offset: UInt64, sizeWord: UInt32) throws -> Data {
            if let cached = fragmentCache[offset] { return cached }
            let size = Int(sizeWord & Self.dataSizeMask)
            guard size > 0 else { throw Error.corrupt("empty fragment block at \(offset)") }
            let data = try decodeBlock(at: offset, size: size, uncompressed: sizeWord & Self.dataUncompressed != 0)
            if fragmentCache.count >= Self.fragmentCacheLimit { fragmentCache.removeAll(keepingCapacity: true) }
            fragmentCache[offset] = data
            return data
        }

        private func decodeBlock(at offset: UInt64, size: Int, uncompressed: Bool) throws -> Data {
            guard size <= blockSize else { throw Error.corrupt("data block at \(offset) larger than block size") }
            let raw = try readRaw(at: offset, count: size)
            guard raw.count == size else { throw Error.corrupt("truncated data block at \(offset)") }
            if uncompressed { return raw }
            return try inflate(raw, capacity: blockSize, context: "data block at \(offset)")
        }

        /// Inflates one zlib-wrapped block: skips the 2-byte zlib header and lets the raw DEFLATE decoder stop at the
        /// end of the stream, ignoring the Adler-32 trailer.
        private func inflate(_ zlib: Data, capacity: Int, context: String) throws -> Data {
            guard zlib.count > 2 else { throw Error.corrupt("\(context) is too short to be zlib") }
            var output = Data(count: capacity)
            let produced = output.withUnsafeMutableBytes { destination -> Int in
                zlib.withUnsafeBytes { source -> Int in
                    guard let dst = destination.baseAddress, let src = source.baseAddress else { return 0 }
                    return compression_decode_buffer(
                        dst.assumingMemoryBound(to: UInt8.self), capacity,
                        src.assumingMemoryBound(to: UInt8.self) + 2, zlib.count - 2, nil, COMPRESSION_ZLIB)
                }
            }
            guard produced > 0 else { throw Error.corrupt("\(context) failed to decompress") }
            output.count = produced
            return output
        }
    }
}

extension Data {
    /// Little-endian fixed-width integer at a byte offset relative to the start of this data.
    func le<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}
