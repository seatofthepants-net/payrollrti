import XCTest

@testable import PayrollRTI

/// Exercises `PayrollRTITests/Fixtures/sample.squashfs`, built with
/// `mksquashfs tree sample.squashfs -comp gzip -b 4096 -noappend -all-root -always-use-fragments -no-xattrs`
/// from a tree whose contents `SquashFSFixture` regenerates. `xz.squashfs` is the same tree with `-comp xz`.
final class SquashFSTests: XCTestCase {
    private var scratch: URL = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SquashFSTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: scratch)
    }

    func testWalkListsEntriesDepthFirstInStoredOrder() throws {
        let image = try SquashFSImage(fileURL: SquashFSFixture.url("sample"), offset: 0)
        var entries: [SquashFSImage.Entry] = []
        try image.walk { entries.append($0) }
        XCTAssertEqual(
            entries,
            [
                .init(path: "big.bin", kind: .file(size: 10000), mode: 0o644),
                .init(path: "dir", kind: .directory, mode: 0o755),
                .init(path: "dir/small.txt", kind: .file(size: 15), mode: 0o644),
                .init(path: "dir/sub", kind: .directory, mode: 0o755),
                .init(path: "dir/sub/deep.txt", kind: .file(size: 5), mode: 0o644),
                .init(path: "empty.txt", kind: .file(size: 0), mode: 0o644),
                .init(path: "link", kind: .symlink(target: "dir/small.txt"), mode: 0o755),
                .init(path: "zeros.bin", kind: .file(size: 8192), mode: 0o644),
            ])
    }

    func testExtractedFilesMatchOriginals() throws {
        let image = try SquashFSImage(fileURL: SquashFSFixture.url("sample"), offset: 0)
        var extracted: [String: Data] = [:]
        try image.walk { entry in
            guard case .file = entry.kind else { return }
            let destination = scratch.appendingPathComponent(entry.path.replacingOccurrences(of: "/", with: "_"))
            try image.extract(entry, to: destination)
            extracted[entry.path] = try Data(contentsOf: destination)
        }
        XCTAssertEqual(extracted, SquashFSFixture.files)
    }

    func testExtractTruncatesExistingDestination() throws {
        let image = try SquashFSImage(fileURL: SquashFSFixture.url("sample"), offset: 0)
        let destination = scratch.appendingPathComponent("deep.txt")
        try Data(repeating: 0xAA, count: 100).write(to: destination)
        try image.extract(.init(path: "dir/sub/deep.txt", kind: .file(size: 5), mode: 0o644), to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), SquashFSFixture.files["dir/sub/deep.txt"])
    }

    func testExtractRejectsNonFiles() throws {
        let image = try SquashFSImage(fileURL: SquashFSFixture.url("sample"), offset: 0)
        XCTAssertThrowsError(
            try image.extract(.init(path: "dir", kind: .directory, mode: 0o755), to: scratch.appendingPathComponent("x"))
        )
    }

    func testWalkPropagatesVisitorErrors() throws {
        struct Stop: Error {}
        let image = try SquashFSImage(fileURL: SquashFSFixture.url("sample"), offset: 0)
        var seen = 0
        XCTAssertThrowsError(
            try image.walk { _ in
                seen += 1
                throw Stop()
            }
        ) { XCTAssertTrue($0 is Stop) }
        XCTAssertEqual(seen, 1)
    }

    func testImageAtNonZeroOffset() throws {
        let embedded = scratch.appendingPathComponent("embedded.bin")
        var bytes = Data(repeating: 0x5A, count: 1234)
        bytes.append(try Data(contentsOf: SquashFSFixture.url("sample")))
        try bytes.write(to: embedded)
        let image = try SquashFSImage(fileURL: embedded, offset: 1234)
        var paths: [String] = []
        try image.walk { paths.append($0.path) }
        XCTAssertEqual(paths.count, 8)
        let destination = scratch.appendingPathComponent("big.bin")
        try image.extract(.init(path: "big.bin", kind: .file(size: 10000), mode: 0o644), to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), SquashFSFixture.files["big.bin"])
    }

    func testGarbageIsNotSquashFS() throws {
        let garbage = scratch.appendingPathComponent("garbage.bin")
        try Data((0..<200).map { UInt8($0 & 0xFF) }).write(to: garbage)
        XCTAssertThrowsError(try SquashFSImage(fileURL: garbage, offset: 0)) {
            XCTAssertEqual($0 as? SquashFSImage.Error, .notSquashFS)
        }
        let short = scratch.appendingPathComponent("short.bin")
        try Data("hsqs".utf8).write(to: short)
        XCTAssertThrowsError(try SquashFSImage(fileURL: short, offset: 0)) {
            XCTAssertEqual($0 as? SquashFSImage.Error, .notSquashFS)
        }
    }

    func testXZImageIsUnsupportedCompression() throws {
        XCTAssertThrowsError(try SquashFSImage(fileURL: SquashFSFixture.url("xz"), offset: 0)) {
            XCTAssertEqual($0 as? SquashFSImage.Error, .unsupportedCompression(4))
        }
    }
}

/// The tree the fixtures were built from, regenerated deterministically.
enum SquashFSFixture {
    static func url(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: SquashFSTests.self).url(forResource: name, withExtension: "squashfs"))
    }

    static let files: [String: Data] = [
        "big.bin": pseudoRandom(count: 10000),
        "dir/small.txt": Data("hello squashfs\n".utf8),
        "dir/sub/deep.txt": Data("deep\n".utf8),
        "empty.txt": Data(),
        "zeros.bin": Data(count: 8192),
    ]

    /// Linear congruential generator matching the Python used to build the fixture: seed 1, take bits 16-23.
    private static func pseudoRandom(count: Int) -> Data {
        var state: UInt32 = 1
        var out = Data(capacity: count)
        for _ in 0..<count {
            state = state &* 1_103_515_245 &+ 12345
            out.append(UInt8((state >> 16) & 0xFF))
        }
        return out
    }
}
