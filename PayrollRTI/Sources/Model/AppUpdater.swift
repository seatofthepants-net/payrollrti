import AppKit
import Foundation

/// A PayrollRTI version such as `0.2.0` or `0.2.0-beta.1`: numeric components, then an optional pre-release
/// suffix. A pre-release sorts before the release it precedes (`0.2.0-beta.2 < 0.2.0`), and pre-release
/// identifiers compare numerically where they're numbers.
struct AppVersion: Comparable, CustomStringConvertible, Equatable {
    let components: [Int]
    let preRelease: [String]

    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") { text.removeFirst() }
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        components = numbers.compactMap { $0 }
        preRelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
    }

    var isPreRelease: Bool { !preRelease.isEmpty }

    var description: String {
        let base = components.map(String.init).joined(separator: ".")
        return preRelease.isEmpty ? base : base + "-" + preRelease.joined(separator: ".")
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.preRelease.isEmpty, rhs.preRelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (left, right) in zip(lhs.preRelease, rhs.preRelease) where left != right {
            if let leftNumber = Int(left), let rightNumber = Int(right) { return leftNumber < rightNumber }
            return left < right
        }
        return lhs.preRelease.count < rhs.preRelease.count
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// A PayrollRTI release on GitHub, as the Releases API describes it.
struct AppRelease: Equatable, Decodable {
    struct Asset: Equatable, Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let prerelease: Bool
    let draft: Bool
    let htmlURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, prerelease, draft, assets
        case htmlURL = "html_url"
    }

    var version: AppVersion? { AppVersion(tagName) }
    var dmg: Asset? { assets.first { $0.name.hasSuffix(".dmg") } }
    var checksum: Asset? { assets.first { $0.name.hasSuffix(".dmg.sha256") } }

    /// The newest release newer than `current` that it makes sense to offer: a pre-release build takes later
    /// pre-releases and releases, a release build takes releases only. Drafts and releases without a DMG are skipped.
    static func newest(in releases: [AppRelease], after current: AppVersion) -> AppRelease? {
        releases
            .filter { !$0.draft && $0.dmg != nil && (current.isPreRelease || !$0.prerelease) }
            .compactMap { release in release.version.map { ($0, release) } }
            .filter { $0.0 > current }
            .max { $0.0 < $1.0 }?.1
    }
}

/// Checks GitHub for a newer PayrollRTI, shows what it contains, and installs it: download the DMG, verify the
/// published checksum, copy the app out, then swap it in and relaunch once the app has quit normally (so Basic
/// PAYE Tools is stopped and backed up as usual).
@MainActor
final class AppUpdater: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        /// Fraction complete, or nil before the size is known.
        case downloading(AppRelease, Double?)
        case verifying(AppRelease)
        /// The new app is staged at the URL; quitting installs it.
        case readyToInstall(AppRelease, URL)
        case failed(String)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Published private(set) var status: Status = .idle
    @Published var isBannerDismissed = false
    /// The notes-and-install sheet is wanted (from the banner or the menu).
    @Published var showsDetails = false
    /// Why the last install attempt didn't start, shown in the sheet; the update stays staged.
    @Published private(set) var installError: String?

    func reportInstallFailure(_ message: String) {
        installError = message
    }

    nonisolated static let releasesAPI = URL(
        string: "https://api.github.com/repos/seatofthepants-net/payrollrti/releases?per_page=20")!

    let current: AppVersion
    private let fetchReleases: () async throws -> [AppRelease]
    private let download: (URL, URL, @escaping (Double?) -> Void) async throws -> Void

    init(
        current: AppVersion = AppUpdater.runningVersion,
        fetchReleases: @escaping () async throws -> [AppRelease] = AppUpdater.fetchReleases,
        download: @escaping (URL, URL, @escaping (Double?) -> Void) async throws -> Void = Download.file
    ) {
        self.current = current
        self.fetchReleases = fetchReleases
        self.download = download
    }

    nonisolated static var runningVersion: AppVersion {
        let info = Bundle.main.infoDictionary ?? [:]
        return AppVersion(info["CFBundleShortVersionString"] as? String ?? "") ?? AppVersion("0")!
    }

    var available: AppRelease? {
        switch status {
        case .available(let release), .downloading(let release, _), .verifying(let release),
            .readyToInstall(let release, _):
            return release
        case .idle, .checking, .upToDate, .failed:
            return nil
        }
    }

    var showsBanner: Bool { available != nil && !isBannerDismissed }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .verifying: return true
        case .idle, .upToDate, .available, .readyToInstall, .failed: return false
        }
    }

    func check() async {
        guard !isBusy, available == nil else { return }
        status = .checking
        do {
            let releases = try await fetchReleases()
            if let release = AppRelease.newest(in: releases, after: current) {
                status = .available(release)
                isBannerDismissed = false
            } else {
                status = .upToDate
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Downloads and stages the update. On success the status is `.readyToInstall`; `installAndRelaunch`
    /// finishes the job when the user is ready.
    func downloadAndStage() async {
        guard case .available(let release) = status, let dmg = release.dmg else { return }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("PayrollRTI-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            status = .downloading(release, nil)
            let dmgFile = work.appendingPathComponent(dmg.name)
            try await download(dmg.browserDownloadURL, dmgFile) { [weak self] fraction in
                Task { @MainActor in
                    if case .downloading = self?.status { self?.status = .downloading(release, fraction) }
                }
            }
            status = .verifying(release)
            if let checksum = release.checksum {
                let expected = work.appendingPathComponent(checksum.name)
                try await download(checksum.browserDownloadURL, expected) { _ in }
                try Self.verify(dmgFile, against: expected)
            }
            let staged = try await Task.detached(priority: .userInitiated) {
                try Self.extractApp(from: dmgFile, into: work)
            }.value
            status = .readyToInstall(release, staged)
        } catch {
            try? FileManager.default.removeItem(at: work)
            status = .failed(error.localizedDescription)
        }
    }

    /// Starts the detached shell script that waits for this process to exit, replaces the app bundle and opens
    /// the new one. The caller then stops Basic PAYE Tools and exits; see `AppDelegate.installAppUpdate`.
    func launchInstaller() throws {
        guard case .readyToInstall(_, let staged) = status else { return }
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw Failure(
                message: "PayrollRTI can't replace itself in \(target.deletingLastPathComponent().path). "
                    + "Open the downloaded disk image and drag the new PayrollRTI over this one instead.")
        }
        let script = staged.deletingLastPathComponent().appendingPathComponent("install.sh")
        try Self.installScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, target.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        showsDetails = false
    }

    /// Waits for the old process, moves the old app to the Trash, moves the new one in, opens it.
    static let installScript = """
        #!/bin/sh
        pid="$1"; staged="$2"; target="$3"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.5; done
        trash="$HOME/.Trash/$(basename "$target") $(date +%Y-%m-%d-%H%M%S)"
        mv "$target" "$trash" || exit 1
        if ! mv "$staged" "$target"; then mv "$trash" "$target"; exit 1; fi
        rm -rf "$(dirname "$staged")"
        open "$target"
        """

    // MARK: - Pieces

    nonisolated static func verify(_ dmg: URL, against checksumFile: URL) throws {
        let published = try String(contentsOf: checksumFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").first.map(String.init) ?? ""
        let actual = BPTBackup.sha256Hex(try Data(contentsOf: dmg, options: .alwaysMapped))
        guard published.lowercased() == actual else {
            throw Failure(message: "The downloaded disk image doesn't match its published checksum.")
        }
    }

    /// Mounts the DMG read-only, copies the app out, unmounts. Returns the staged app.
    nonisolated static func extractApp(from dmg: URL, into directory: URL) throws -> URL {
        let mount = directory.appendingPathComponent("mount")
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) }
        let apps = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else {
            throw Failure(message: "The disk image doesn't contain one app as expected.")
        }
        let staged = directory.appendingPathComponent(app.lastPathComponent)
        try run("/usr/bin/ditto", [app.path, staged.path])
        return staged
    }

    private nonisolated static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(message: "\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(text)")
        }
    }

    // MARK: - Network

    /// GitHub's releases list. Debug builds honour `-debugReleasesURL <url>` so the whole update flow can be
    /// exercised against a local JSON file and DMG.
    nonisolated static func fetchReleases() async throws -> [AppRelease] {
        var url = releasesAPI
        #if DEBUG
            if let override = UserDefaults.standard.string(forKey: "debugReleasesURL"),
                let local = URL(string: override)
            {
                url = local
            }
        #endif
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PayrollRTI (+\(Links.repository.absoluteString))", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure(message: "GitHub answered HTTP \(http.statusCode).")
        }
        return try JSONDecoder().decode([AppRelease].self, from: data)
    }
}
