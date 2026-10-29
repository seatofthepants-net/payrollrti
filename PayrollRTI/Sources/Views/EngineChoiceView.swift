import SwiftUI

/// PayrollRTI's colours, from the app icon: deep green, cream and one gold accent.
enum Brand {
    static let green = Color(red: 0.07, green: 0.33, blue: 0.24)
    static let greenDeep = Color(red: 0.04, green: 0.22, blue: 0.16)
    static let gold = Color(red: 0.87, green: 0.65, blue: 0.23)
    static let cream = Color(red: 0.96, green: 0.94, blue: 0.87)
}

/// The main window when there is nothing to run yet: explains, in plain terms, the two ways PayrollRTI can run
/// Basic PAYE Tools, says whether each can open the user's existing payroll data, and lets the user pick one.
/// Shown for either engine; the choice is also in Settings.
struct EngineChoiceView: View {
    @EnvironmentObject private var server: ServerController
    @EnvironmentObject private var updates: UpdateChecker
    @EnvironmentObject private var installer: LinuxBuildInstaller
    @AppStorage(SettingsKey.engine) private var engine = BPTEngine.macInstaller

    /// The payroll database's migration history, read once per appearance.
    @State private var applied: Set<String>?
    @State private var databaseError: String?

    private var macInstaller: BPTInstallation? { BPTInstallation.locate(engine: .macInstaller) }
    private var runtime: LinuxBuildRuntime? { LinuxBuildRuntime.bundled }
    private var linuxBuild: BPTInstallation? {
        guard let runtime, let payload = LinuxBuildStore.newest() else { return nil }
        return .linuxBuild(payload: payload, runtime: runtime)
    }

    /// The version GOV.UK currently advertises, from whichever check ran last.
    private var latest: BPTVersion? {
        switch updates.status {
        case .upToDate(let version), .latestKnown(let version): return version
        case .updateAvailable(_, let latest): return latest
        case .idle, .checking, .failed: return nil
        }
    }

    private func compatibility(of installation: BPTInstallation) -> DatabaseCompatibility {
        guard BPTDatabase.default.exists else { return .noDatabase }
        guard let applied else { return .unknown(databaseError ?? "still reading") }
        do {
            return DatabaseCompatibility.check(applied: applied, known: try installation.knownMigrations())
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    private func compatibility(ofDownload version: BPTVersion) -> DatabaseCompatibility {
        guard BPTDatabase.default.exists else { return .noDatabase }
        guard let applied else { return .unknown(databaseError ?? "still reading") }
        return DatabaseCompatibility.check(
            applied: applied, candidate: version, newestStarted: AppSettings.newestStartedVersion)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                HStack(alignment: .top, spacing: 20) {
                    macCard
                    linuxCard
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 820)
                footer
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .background(Brand.cream.opacity(0.35))
        .task {
            if BPTDatabase.default.exists {
                do {
                    applied = try BPTDatabase.default.appliedMigrations()
                } catch {
                    databaseError = error.localizedDescription
                }
            }
            if case .idle = updates.status { await updates.check(installed: nil) }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("How should PayrollRTI run Basic PAYE Tools?")
                .font(.system(size: 26, weight: .semibold))
            Text(
                "Both choices run HMRC's own Basic PAYE Tools on the same payroll data. "
                    + "You can change your mind later in Settings; nothing is lost either way."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 560)
        }
    }

    private var footer: some View {
        Text(
            "Your payroll stays in ~/HMRC/payetools-rti whichever you choose. "
                + "PayrollRTI isn't made or endorsed by HMRC."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    // MARK: - HMRC's Mac app

    private var macCard: some View {
        EngineCard(
            symbol: "shippingbox",
            title: "HMRC's Mac app",
            summary: "The Basic PAYE Tools you install from GOV.UK into your Applications folder.",
            detail: "On newer Macs it runs through Rosetta, Apple's translator for older Intel software. "
                + "Apple are removing Rosetta after macOS 27, so this option has a limited life.",
            badge: nil,
            isCurrent: engine == .macInstaller
        ) {
            if let macInstaller {
                let verdict = compatibility(of: macInstaller)
                EngineStatus(
                    symbol: "checkmark.circle.fill", tint: Brand.green,
                    text: "Installed, version \(macInstaller.version?.description ?? "unknown")")
                CompatibilityLine(verdict: verdict)
                Button("Use the Mac app") {
                    engine = .macInstaller
                    server.start()
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.green)
                .disabled(!verdict.allowsStart)
            } else {
                EngineStatus(symbol: "xmark.circle", tint: .secondary, text: "Not installed")
                HStack {
                    Button("Download from GOV.UK") { NSWorkspace.shared.open(Links.bptDownload) }
                        .buttonStyle(.bordered)
                    Button("Check again") {
                        engine = .macInstaller
                        server.start()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - HMRC's Linux version

    private var linuxCard: some View {
        EngineCard(
            symbol: "bolt.circle",
            title: "HMRC's Linux version, run by PayrollRTI",
            summary: "The same Basic PAYE Tools, from GOV.UK's Linux download. PayrollRTI fetches and runs it itself.",
            detail: "It runs natively, so it doesn't need Rosetta and keeps working after Apple remove it. "
                + "Same screens, same calculations, same submissions to HMRC.",
            badge: runtime == nil ? nil : "Recommended for Apple silicon Macs",
            isCurrent: engine == .linuxBuild
        ) {
            if runtime == nil {
                EngineStatus(symbol: "xmark.circle", tint: .secondary, text: "Not available on this Mac")
                Text("Needs an Apple silicon Mac and a PayrollRTI build that includes the runtime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let linuxBuild {
                let verdict = compatibility(of: linuxBuild)
                EngineStatus(
                    symbol: "checkmark.circle.fill", tint: Brand.green,
                    text: "Downloaded, version \(linuxBuild.version?.description ?? "unknown")")
                CompatibilityLine(verdict: verdict)
                Button("Use the Linux version") {
                    engine = .linuxBuild
                    server.start()
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.green)
                .disabled(!verdict.allowsStart)
            } else {
                linuxDownload
            }
        }
    }

    @ViewBuilder private var linuxDownload: some View {
        switch installer.phase {
        case .downloading(let fraction):
            EngineStatus(symbol: "arrow.down.circle", tint: Brand.green, text: "Downloading from GOV.UK…")
            ProgressView(value: fraction ?? 0).tint(Brand.green)
            Text(fraction.map { "\(Int($0 * 100))% of about 190 MB" } ?? "Starting…")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        case .extracting:
            EngineStatus(symbol: "shippingbox", tint: Brand.green, text: "Unpacking…")
            ProgressView().controlSize(.small)
        case .idle, .installed, .failed:
            EngineStatus(symbol: "arrow.down.circle", tint: .secondary, text: "Not downloaded yet (about 190 MB)")
            if let latest {
                let verdict = compatibility(ofDownload: latest)
                CompatibilityLine(verdict: verdict)
                Button("Download and use version \(latest.description)") {
                    engine = .linuxBuild
                    Task { await installer.install(version: latest) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.green)
                .disabled(!verdict.allowsStart)
            } else if case .failed(let message) = updates.status {
                Text("Couldn't find the latest version on GOV.UK: \(message)")
                    .font(.caption).foregroundStyle(.red)
                Button("Try again") { Task { await updates.check(installed: nil) } }.buttonStyle(.bordered)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding the latest version on GOV.UK…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if case .failed(let message) = installer.phase {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }
}

/// One of the two choices: a fixed top (icon, title, explanation) and a bottom area whose content depends on
/// what's installed, so the two cards' buttons line up.
private struct EngineCard<Actions: View>: View {
    let symbol: String
    let title: String
    let summary: String
    let detail: String
    let badge: String?
    let isCurrent: Bool
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(Brand.green)
                    .frame(width: 40, height: 40)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Brand.gold.opacity(0.22), in: Capsule())
                        .foregroundStyle(Brand.greenDeep)
                }
            }
            Text(title).font(.title3.weight(.semibold))
            Text(summary).font(.body)
            Text(detail).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 12) { actions }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isCurrent ? Brand.green : Color.secondary.opacity(0.25), lineWidth: isCurrent ? 2 : 1)
        )
    }
}

private struct EngineStatus: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.callout)
    }
}

/// Whether this copy can open the user's existing payroll data, in plain words.
struct CompatibilityLine: View {
    let verdict: DatabaseCompatibility

    var body: some View {
        Label {
            Text(verdict.summary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.callout)
        .foregroundStyle(verdict.allowsStart ? .primary : Color.red)
    }

    private var symbol: String {
        switch verdict {
        case .noDatabase: return "doc"
        case .current: return "checkmark.seal.fill"
        case .upgrade: return "arrow.up.doc"
        case .tooOld: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch verdict {
        case .noDatabase, .unknown: return .secondary
        case .current: return Brand.green
        case .upgrade: return Brand.gold
        case .tooOld: return .red
        }
    }
}
