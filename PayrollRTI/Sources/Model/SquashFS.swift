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

    private let reader: SquashFSReader
    private let superblock: SquashFSSuperblock

    init(fileURL: URL, offset: UInt64) throws {
        reader = try SquashFSReader(fileURL: fileURL, base: offset)
        let raw = try reader.readRaw(at: 0, count: SquashFSSuperblock.size)
        guard raw.count == SquashFSSuperblock.size, raw.le(UInt32.self, at: 0) == SquashFSSuperblock.magic else {
            throw Error.notSquashFS
        }
        superblock = SquashFSSuperblock(raw)
        guard superblock.versionMajor == 4, superblock.versionMinor == 0 else {
            throw Error.unsupportedVersion(major: superblock.versionMajor, minor: superblock.versionMinor)
        }
        guard superblock.compressionID == SquashFSSuperblock.gzip else {
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
            position += UInt64(sizeWord & SquashFSReader.dataSizeMask)
            remaining -= UInt64(expected)
        }
        if file.fragment != SquashFSInode.noFragment {
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

    private func walk(directory: SquashFSInode, path: String, _ visit: (Entry) throws -> Void) throws {
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

    private func lookup(_ path: String) throws -> SquashFSInode {
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

    /// Inode type codes: basic/extended directory, file, symlink; everything else (devices, fifos, sockets) is skipped.
    private enum InodeType {
        static let directory: UInt16 = 1
        static let file: UInt16 = 2
        static let symlink: UInt16 = 3
        static let extendedDirectory: UInt16 = 8
        static let extendedFile: UInt16 = 9
        static let extendedSymlink: UInt16 = 10
        static let other: Set<UInt16> = [4, 5, 6, 7, 11, 12, 13, 14]
    }

    private func inode(at reference: UInt64) throws -> SquashFSInode {
        var cursor = try SquashFSMetadataCursor(
            reader: reader, block: superblock.inodeTableStart + (reference >> 16), offset: Int(reference & 0xFFFF))
        let type = try cursor.readU16()
        let mode = try cursor.readU16()
        _ = try cursor.readU16()  // uid
        _ = try cursor.readU16()  // gid
        _ = try cursor.readU32()  // mtime
        _ = try cursor.readU32()  // inode number
        let body: SquashFSInode.Body
        switch type {
        case InodeType.directory:
            body = .directory(try basicDirectory(&cursor))
        case InodeType.extendedDirectory:
            body = .directory(try extendedDirectory(&cursor))
        case InodeType.file:
            body = .file(try basicFile(&cursor))
        case InodeType.extendedFile:
            body = .file(try extendedFile(&cursor))
        case InodeType.symlink, InodeType.extendedSymlink:
            body = .symlink(target: try symlinkTarget(&cursor))
        case let other where InodeType.other.contains(other):
            body = .other
        default:
            throw Error.corrupt("unknown inode type \(type)")
        }
        return SquashFSInode(mode: mode, body: body)
    }

    private func basicDirectory(_ cursor: inout SquashFSMetadataCursor) throws -> SquashFSInode.Directory {
        let startBlock = try cursor.readU32()
        _ = try cursor.readU32()  // nlink
        let fileSize = try cursor.readU16()
        let blockOffset = try cursor.readU16()
        return SquashFSInode.Directory(startBlock: startBlock, blockOffset: blockOffset, listingSize: UInt32(fileSize))
    }

    private func extendedDirectory(_ cursor: inout SquashFSMetadataCursor) throws -> SquashFSInode.Directory {
        _ = try cursor.readU32()  // nlink
        let fileSize = try cursor.readU32()
        let startBlock = try cursor.readU32()
        _ = try cursor.readU32()  // parent inode
        _ = try cursor.readU16()  // index count
        let blockOffset = try cursor.readU16()
        return SquashFSInode.Directory(startBlock: startBlock, blockOffset: blockOffset, listingSize: fileSize)
    }

    private func basicFile(_ cursor: inout SquashFSMetadataCursor) throws -> SquashFSInode.File {
        let startBlock = try cursor.readU32()
        let fragment = try cursor.readU32()
        let fragmentOffset = try cursor.readU32()
        let size = try cursor.readU32()
        return try fileBody(
            &cursor, startBlock: UInt64(startBlock), size: UInt64(size), fragment: fragment,
            fragmentOffset: fragmentOffset)
    }

    private func extendedFile(_ cursor: inout SquashFSMetadataCursor) throws -> SquashFSInode.File {
        let startBlock = try cursor.readU64()
        let size = try cursor.readU64()
        _ = try cursor.readU64()  // sparse
        _ = try cursor.readU32()  // nlink
        let fragment = try cursor.readU32()
        let fragmentOffset = try cursor.readU32()
        _ = try cursor.readU32()  // xattr
        return try fileBody(
            &cursor, startBlock: startBlock, size: size, fragment: fragment, fragmentOffset: fragmentOffset)
    }

    private func symlinkTarget(_ cursor: inout SquashFSMetadataCursor) throws -> String {
        _ = try cursor.readU32()  // nlink
        let targetSize = try cursor.readU32()
        guard targetSize <= 65535 else { throw Error.corrupt("symlink target of \(targetSize) bytes") }
        return try cursor.readString(Int(targetSize))
    }

    /// Reads the block size list shared by basic and extended file inodes: one word per full block, plus one for the
    /// tail block unless the tail lives in a fragment.
    private func fileBody(
        _ cursor: inout SquashFSMetadataCursor, startBlock: UInt64, size: UInt64, fragment: UInt32,
        fragmentOffset: UInt32
    ) throws -> SquashFSInode.File {
        let blockSize = UInt64(superblock.blockSize)
        let hasFragment = fragment != SquashFSInode.noFragment
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
        return SquashFSInode.File(
            startBlock: startBlock, size: size, fragment: fragment, fragmentOffset: fragmentOffset,
            blockSizes: blockSizes)
    }

    private func listing(of node: SquashFSInode) throws -> [DirectoryEntry] {
        guard case let .directory(directory) = node.body else { throw Error.corrupt("not a directory") }
        guard directory.listingSize >= 3 else { return [] }
        let length = Int(directory.listingSize) - 3
        var cursor = try SquashFSMetadataCursor(
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
                let name = try cursor.readString(nameSize)
                consumed += 8 + nameSize
                entries.append(DirectoryEntry(name: name, inodeRef: UInt64(start) << 16 | UInt64(offset)))
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
}
