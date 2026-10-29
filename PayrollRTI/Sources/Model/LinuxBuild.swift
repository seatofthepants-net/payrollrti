import Foundation

/// The native Python 2.7 runtime PayrollRTI ships in `Contents/Resources/LinuxBuildRuntime`, built by
/// `rehost/build-runtime.sh`. It runs HMRC's Linux bytecode unmodified; the C extension modules HMRC's Linux
/// build carries as x86_64 `.so` files are rebuilt for the Mac and listed in `manifest.txt`.
struct LinuxBuildRuntime: Equatable {
    let directory: URL

    var python: URL { directory.appendingPathComponent("bin/python2.7") }
    var launcher: URL { directory.appendingPathComponent("rti") }

    /// Names of the extension modules the runtime provides, for checking a payload before it's installed.
    func providedModules() -> Set<String> {
        let manifest = directory.appendingPathComponent("manifest.txt")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return [] }
        let names = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return Set(names.filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    /// The runtime in this build of PayrollRTI, if the build included one. The runtime is built for Apple silicon
    /// only: Intel Macs run HMRC's Mac installer natively and stop at macOS 26, before Rosetta is withdrawn.
    static var bundled: LinuxBuildRuntime? {
        #if arch(x86_64)
            return nil
        #else
            guard let resources = Bundle.main.resourceURL else { return nil }
            let runtime = LinuxBuildRuntime(directory: resources.appendingPathComponent("LinuxBuildRuntime"))
            return FileManager.default.isExecutableFile(atPath: runtime.python.path) ? runtime : nil
        #endif
    }
}

/// One extracted Linux build of Basic PAYE Tools, laid out the way `settings_central.py`'s darwin branch
/// expects (it derives its install directory from `BASE_PATH/../../..`, as inside HMRC's Mac app):
///
///     <directory>/
///         bptserver/                      usr/bptserver from the AppImage, minus its x86_64 .so files
///         django -> bptserver/django      the loose tree HMRC list management commands from in frozen builds
///         rti.app/Contents/MacOS -> ../../bptserver   BPT_BASE_PATH
///         linux-extensions.txt            the .so files that were left out, for the record
struct LinuxBuildPayload: Equatable {
    let directory: URL
    let version: BPTVersion

    var baseURL: URL { directory.appendingPathComponent("rti.app/Contents/MacOS") }

    init?(directory: URL) {
        guard let version = BPTVersion(directory.lastPathComponent) else { return nil }
        self.directory = directory
        self.version = version
    }
}

/// Downloaded Linux builds, one directory per version.
enum LinuxBuildStore {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/PayrollRTI/LinuxBuild")

    static func installed(in directory: URL = directory, fileManager: FileManager = .default) -> [LinuxBuildPayload] {
        let entries = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap(LinuxBuildPayload.init)
            .filter { fileManager.fileExists(atPath: $0.baseURL.appendingPathComponent("rti.linux").path) }
            .sorted { $0.version < $1.version }
    }

    static func newest(in directory: URL = directory) -> LinuxBuildPayload? {
        installed(in: directory).last
    }

    static func remove(_ payload: LinuxBuildPayload) throws {
        try FileManager.default.removeItem(at: payload.directory)
    }

    /// Adds the symlinks that make an extracted `bptserver` directory a payload. See `LinuxBuildPayload`.
    static func layOut(_ root: URL, fileManager: FileManager = .default) throws {
        // Path-based: the URL variant would make these absolute, and they must stay relative so the payload can move.
        try fileManager.createSymbolicLink(
            atPath: root.appendingPathComponent("django").path, withDestinationPath: "bptserver/django")
        let contents = root.appendingPathComponent("rti.app/Contents")
        try fileManager.createDirectory(at: contents, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            atPath: contents.appendingPathComponent("MacOS").path, withDestinationPath: "../../bptserver")
    }

    /// The extension modules a payload needs that `runtime` doesn't provide. Shared libraries (`lib*.so*`) are
    /// not Python modules and are ignored; everything else must be in the runtime's manifest.
    static func missingModules(extensions: [String], runtime: LinuxBuildRuntime) -> [String] {
        let provided = runtime.providedModules()
        let needed = extensions.compactMap { name -> String? in
            guard !name.hasPrefix("lib"), let range = name.range(of: ".so") else { return nil }
            return String(name[..<range.lowerBound])
        }
        return needed.filter { !provided.contains($0) }.sorted()
    }
}

/// Downloads a Basic PAYE Tools Linux release from GOV.UK and turns it into a `LinuxBuildPayload`.
@MainActor
final class LinuxBuildInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// A copy of the payroll database in BPT's own backup format, before anything else happens.
        case backingUp
        /// Fraction complete, or nil before the size is known.
        case downloading(Double?)
        case extracting
        case installed(BPTVersion)
        case failed(String)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Published private(set) var phase: Phase = .idle

    static let downloadBase = URL(string: "https://www.gov.uk/government/uploads/uploaded/hmrc/")!

    var isBusy: Bool {
        switch phase {
        case .backingUp, .downloading, .extracting: return true
        case .idle, .installed, .failed: return false
        }
    }

    /// Downloads and installs `version`. If there is payroll data, it's backed up first (into BPT's own backups
    /// folder, in BPT's format) so that whatever happens next is recoverable with BPT's Restore.
    func install(version: BPTVersion, database: BPTDatabase = .default) async {
        guard !isBusy else { return }
        guard let runtime = LinuxBuildRuntime.bundled else {
            phase = .failed("This build of PayrollRTI doesn't include the runtime for HMRC's Linux build.")
            return
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("PayrollRTI-linux-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            if database.exists {
                phase = .backingUp
                let current = BPTInstallation.locate(engine: AppSettings.engine)?.version
                _ = try BPTBackup.write(
                    database: database.url, version: current ?? AppSettings.newestStartedVersion,
                    reason: "PRE-INSTALL",
                    to: database.url.deletingLastPathComponent().appendingPathComponent("backups"))
            }
            phase = .downloading(nil)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("payetools-rti-\(version)-linux.zip")
            try await Download.file(Self.downloadURL(for: version), to: zip) { [weak self] fraction in
                Task { @MainActor in
                    if case .downloading = self?.phase { self?.phase = .downloading(fraction) }
                }
            }
            phase = .extracting
            let staged = work.appendingPathComponent("payload")
            try await Task.detached(priority: .userInitiated) {
                try Self.extract(zip: zip, into: staged, version: version, runtime: runtime)
            }.value
            let destination = LinuxBuildStore.directory.appendingPathComponent(version.description)
            try FileManager.default.createDirectory(at: LinuxBuildStore.directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staged, to: destination)
            phase = .installed(version)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    static func downloadURL(for version: BPTVersion) -> URL {
        downloadBase.appendingPathComponent("payetools-rti-\(version)-linux.zip")
    }

    /// zip → AppImage → squashfs → `usr/bptserver` without its x86_64 `.so` files, checked against the runtime.
    nonisolated static func extract(zip: URL, into root: URL, version: BPTVersion, runtime: LinuxBuildRuntime) throws {
        let fileManager = FileManager.default
        let unzipped = zip.deletingLastPathComponent().appendingPathComponent("unzipped")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path])
        let appImages = try fileManager.contentsOfDirectory(at: unzipped, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "AppImage" }
        guard appImages.count == 1, let appImage = appImages.first else {
            throw Failure(message: "The download didn't contain one AppImage as expected.")
        }
        guard appImage.lastPathComponent.contains(version.description) else {
            throw Failure(message: "The download was \(appImage.lastPathComponent), not version \(version).")
        }

        let image = try SquashFSImage(fileURL: appImage, offset: try AppImage.squashfsOffset(in: appImage))
        let server = root.appendingPathComponent("bptserver")
        try fileManager.createDirectory(at: server, withIntermediateDirectories: true)
        let prefix = "usr/bptserver/"
        var extensions: [String] = []
        try image.walk { entry in
            guard entry.path.hasPrefix(prefix) else { return }
            let relative = String(entry.path.dropFirst(prefix.count))
            let target = server.appendingPathComponent(relative)
            switch entry.kind {
            case .directory:
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            case .file:
                let name = target.lastPathComponent
                if name.hasSuffix(".so") || name.contains(".so.") {
                    extensions.append(name)
                } else {
                    try image.extract(entry, to: target)
                }
            case .symlink(let destination):
                try fileManager.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
            }
        }
        guard fileManager.fileExists(atPath: server.appendingPathComponent("rti.linux").path) else {
            throw Failure(message: "The AppImage didn't contain usr/bptserver/rti.linux.")
        }
        let missing = LinuxBuildStore.missingModules(extensions: extensions, runtime: runtime)
        guard missing.isEmpty else {
            throw Failure(
                message: "Basic PAYE Tools \(version) needs modules this version of PayrollRTI can't provide: "
                    + missing.joined(separator: ", ") + ". A PayrollRTI update is needed before it can run it.")
        }
        try (extensions.sorted().joined(separator: "\n") + "\n")
            .write(to: root.appendingPathComponent("linux-extensions.txt"), atomically: true, encoding: .utf8)
        try LinuxBuildStore.layOut(root)
        try? fileManager.removeItem(at: unzipped)
    }

    private nonisolated static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure(message: "\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(text)")
        }
    }
}
