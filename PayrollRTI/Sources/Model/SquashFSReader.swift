import Compression
import Foundation

// On-disk structures and low-level block access for `SquashFSImage`. Everything here is squashfs 4.0 as laid out
// by mksquashfs with gzip compression; offsets are relative to the superblock unless noted.

// MARK: - On-disk structures

struct SquashFSSuperblock {
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

struct SquashFSInode {
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
struct SquashFSMetadataCursor {
    private let reader: SquashFSReader
    private var block: Data
    private var next: UInt64
    private var position: Int

    init(reader: SquashFSReader, block start: UInt64, offset: Int) throws {
        self.reader = reader
        let decoded = try reader.metadataBlock(at: start)
        block = decoded.data
        next = decoded.next
        position = offset
        guard offset <= block.count else {
            throw SquashFSImage.Error.corrupt("metadata offset \(offset) beyond block")
        }
    }

    mutating func read(_ count: Int) throws -> Data {
        var out = Data(capacity: count)
        while out.count < count {
            if position == block.count {
                let decoded = try reader.metadataBlock(at: next)
                guard !decoded.data.isEmpty else { throw SquashFSImage.Error.corrupt("empty metadata block") }
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

    /// Reads `count` bytes as a UTF-8 string (names and symlink targets are UTF-8 in squashfs).
    mutating func readString(_ count: Int) throws -> String {
        guard let string = String(bytes: try read(count), encoding: .utf8) else {
            throw SquashFSImage.Error.corrupt("name is not valid UTF-8")
        }
        return string
    }

    mutating func readU16() throws -> UInt16 { try read(2).le(UInt16.self, at: 0) }
    mutating func readU32() throws -> UInt32 { try read(4).le(UInt32.self, at: 0) }
    mutating func readU64() throws -> UInt64 { try read(8).le(UInt64.self, at: 0) }
}

// MARK: - File access and decompression

/// Random access to the image file plus caches of decoded metadata and fragment blocks.
final class SquashFSReader {
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
        guard !overflow, absolute <= UInt64(Int64.max) else {
            throw SquashFSImage.Error.corrupt("offset \(offset) overflows")
        }
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
        guard header.count == 2 else { throw SquashFSImage.Error.corrupt("truncated metadata block at \(offset)") }
        let word = header.le(UInt16.self, at: 0)
        let size = Int(word & Self.metadataSizeMask)
        let raw = try readRaw(at: offset + 2, count: size)
        guard raw.count == size else { throw SquashFSImage.Error.corrupt("truncated metadata block at \(offset)") }
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
            throw SquashFSImage.Error.corrupt(
                "data block at \(offset) decoded to \(data.count) bytes, expected \(expected)")
        }
        return data
    }

    func fragmentBlock(at offset: UInt64, sizeWord: UInt32) throws -> Data {
        if let cached = fragmentCache[offset] { return cached }
        let size = Int(sizeWord & Self.dataSizeMask)
        guard size > 0 else { throw SquashFSImage.Error.corrupt("empty fragment block at \(offset)") }
        let data = try decodeBlock(at: offset, size: size, uncompressed: sizeWord & Self.dataUncompressed != 0)
        if fragmentCache.count >= Self.fragmentCacheLimit { fragmentCache.removeAll(keepingCapacity: true) }
        fragmentCache[offset] = data
        return data
    }

    private func decodeBlock(at offset: UInt64, size: Int, uncompressed: Bool) throws -> Data {
        guard size <= blockSize else {
            throw SquashFSImage.Error.corrupt("data block at \(offset) larger than block size")
        }
        let raw = try readRaw(at: offset, count: size)
        guard raw.count == size else { throw SquashFSImage.Error.corrupt("truncated data block at \(offset)") }
        if uncompressed { return raw }
        return try inflate(raw, capacity: blockSize, context: "data block at \(offset)")
    }

    /// Inflates one zlib-wrapped block: skips the 2-byte zlib header and lets the raw DEFLATE decoder stop at the
    /// end of the stream, ignoring the Adler-32 trailer.
    private func inflate(_ zlib: Data, capacity: Int, context: String) throws -> Data {
        guard zlib.count > 2 else { throw SquashFSImage.Error.corrupt("\(context) is too short to be zlib") }
        var output = Data(count: capacity)
        let produced = output.withUnsafeMutableBytes { destination -> Int in
            zlib.withUnsafeBytes { source -> Int in
                guard let dst = destination.baseAddress, let src = source.baseAddress else { return 0 }
                return compression_decode_buffer(
                    dst.assumingMemoryBound(to: UInt8.self), capacity,
                    src.assumingMemoryBound(to: UInt8.self) + 2, zlib.count - 2, nil, COMPRESSION_ZLIB)
            }
        }
        guard produced > 0 else { throw SquashFSImage.Error.corrupt("\(context) failed to decompress") }
        output.count = produced
        return output
    }
}

extension Data {
    /// Little-endian fixed-width integer at a byte offset relative to the start of this data.
    func le<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}
