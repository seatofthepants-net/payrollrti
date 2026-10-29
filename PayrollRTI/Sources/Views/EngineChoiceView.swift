import SwiftUI

/// The choice screen's palette, light / dark, from the design.
enum Brand {
    static let windowBackground = Color(light: 0xF6F4EE, dark: 0x1C1F1E)
    static let recommendedCard = Color(light: 0xEEF6F1, dark: 0x1F2C26)
    static let recommendedBorder = Color(light: 0x2E7D5B, dark: 0x2F7A5C)
    static let card = Color(light: 0xFFFFFF, dark: 0x252827)
    static let cardBorder = Color(light: 0xE1DCCF, dark: 0xFFFFFF, darkOpacity: 0.09)
    static let text = Color(light: 0x1B1F1D, dark: 0xF2F4F3)
    static let secondaryText = Color(light: 0x5A625E, dark: 0x9DA7A2)
    static let badgeText = Color(light: 0x7A4F08, dark: 0xEDBE62)
    static let badgeBackground = Color(light: 0xFBEBCB, dark: 0xEDBE62, darkOpacity: 0.14)
    static let primaryButton = Color(light: 0x2E7D5B, dark: 0x2E7D5B)
    static let tick = Color(light: 0x1F7A53, dark: 0x5CC497)
    static let iconTileRecommended = Color(light: 0x2E7D5B, dark: 0x5CC497, lightOpacity: 0.12, darkOpacity: 0.14)
    static let iconTile = Color(light: 0x1B1F1D, dark: 0xFFFFFF, lightOpacity: 0.06, darkOpacity: 0.08)
}

extension Color {
    /// A colour that follows the window's appearance.
    init(light: UInt32, dark: UInt32, lightOpacity: Double = 1, darkOpacity: Double = 1) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(rgb: isDark ? dark : light, alpha: isDark ? darkOpacity : lightOpacity)
            })
    }
}

extension NSColor {
    fileprivate convenience init(rgb: UInt32, alpha: Double) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
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
    @State private var rosetta = Rosetta.status()
    @State private var installingRosetta = false
    @State private var rosettaError: String?

    private func installRosetta() {
        installingRosetta = true
        rosettaError = nil
        Task {
            do {
                try await Rosetta.install()
            } catch {
                rosettaError = error.localizedDescription
            }
            installingRosetta = false
            rosetta = Rosetta.status()
        }
    }

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
            VStack(spacing: 30) {
                header
                HStack(alignment: .top, spacing: 18) {
                    linuxCard
                    macCard
                }
                .fixedSize(horizontal: false, vertical: true)
                footer
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 36)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Brand.windowBackground)
        .foregroundStyle(Brand.text)
        .task {
            rosetta = Rosetta.status()
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
                .padding(.bottom, 6)
            Text("How should PayrollRTI run Basic PAYE Tools?")
                .font(.system(size: 26, weight: .bold))
            Text(
                "Both choices run HMRC's own Basic PAYE Tools on the same payroll data. "
                    + "You can change this later in Settings, and nothing is lost either way."
            )
            .font(.system(size: 14))
            .foregroundStyle(Brand.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)
        }
    }

    private var footer: some View {
        Label {
            Text(
                "Your payroll stays in ~/HMRC/payetools-rti whichever you choose. "
                    + "PayrollRTI isn't made or endorsed by HMRC.")
        } icon: {
            Image(systemName: "lock")
        }
        .font(.system(size: 12))
        .foregroundStyle(Brand.secondaryText)
        .multilineTextAlignment(.center)
    }

    // MARK: - HMRC's Linux version

    private var linuxCard: some View {
        EngineCard(
            symbol: "bolt",
            title: "HMRC's Linux version, run by PayrollRTI",
            summary: "The same Basic PAYE Tools from GOV.UK. PayrollRTI downloads it and runs it for you.",
            detail: "It runs natively, so it keeps working after Apple remove Rosetta. "
                + "Same screens, same calculations, same submissions to HMRC.",
            badge: runtime == nil ? nil : "Recommended for Apple silicon Macs",
            recommended: runtime != nil
        ) {
            if runtime == nil {
                StatusRow(symbol: "xmark.circle", tint: Brand.secondaryText, text: "Not available on this Mac",
                    detail: "Needs an Apple silicon Mac and a PayrollRTI build that includes the runtime")
            } else if let linuxBuild {
                let verdict = compatibility(of: linuxBuild)
                StatusRow(symbol: "checkmark.circle", tint: Brand.tick, text: "Downloaded",
                    detail: "Version \(linuxBuild.version?.description ?? "unknown")")
                CompatibilityLine(verdict: verdict)
                PrimaryButton("Use the Linux version", enabled: verdict.allowsStart) {
                    engine = .linuxBuild
                    server.start()
                }
            } else {
                linuxDownload
            }
        }
    }

    @ViewBuilder private var linuxDownload: some View {
        switch installer.phase {
        case .backingUp:
            StatusRow(
                symbol: "externaldrive", tint: Brand.tick, text: "Backing up your payroll data first…", detail: nil)
            ProgressView().controlSize(.small)
        case .downloading(let fraction):
            StatusRow(symbol: "arrow.down.circle", tint: Brand.tick, text: "Downloading from GOV.UK…",
                detail: fraction.map { "\(Int($0 * 100))% of about 190 MB" } ?? "Starting…")
            ProgressView(value: fraction ?? 0).tint(Brand.primaryButton)
        case .extracting:
            StatusRow(symbol: "shippingbox", tint: Brand.tick, text: "Unpacking…", detail: nil)
            ProgressView().controlSize(.small)
        case .idle, .installed, .failed:
            StatusRow(
                symbol: "arrow.down.circle", tint: Brand.secondaryText, text: "Not downloaded yet · about 190 MB",
                detail: latest.map { "Version \($0.description)" } ?? "Finding the latest version on GOV.UK…")
            if let latest {
                let verdict = compatibility(ofDownload: latest)
                CompatibilityLine(verdict: verdict)
                PrimaryButton("Download and use", enabled: verdict.allowsStart) {
                    engine = .linuxBuild
                    Task { await installer.install(version: latest) }
                }
            } else if case .failed(let message) = updates.status {
                Text("Couldn't find the latest version on GOV.UK: \(message)")
                    .font(.system(size: 12)).foregroundStyle(.red)
                SecondaryButton("Try again") { Task { await updates.check(installed: nil) } }
            }
            if case .failed(let message) = installer.phase {
                Text(message).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    // MARK: - HMRC's Mac app

    private var macCard: some View {
        EngineCard(
            symbol: "shippingbox",
            title: "HMRC's Mac app",
            summary: "The Basic PAYE Tools you installed from GOV.UK in your Applications folder.",
            detail: "It runs through Rosetta, Apple's translator for older Intel software. "
                + "Apple are removing Rosetta after macOS 27, so this option has a limited life.",
            badge: nil,
            recommended: false
        ) {
            if let macInstaller {
                let verdict = compatibility(of: macInstaller)
                StatusRow(symbol: "checkmark.circle", tint: Brand.tick, text: "Installed",
                    detail: "Version \(macInstaller.version?.description ?? "unknown")")
                CompatibilityLine(verdict: verdict)
                switch rosetta {
                case .installed, .notNeeded:
                    SecondaryButton("Use the Mac app", enabled: verdict.allowsStart) {
                        engine = .macInstaller
                        server.start()
                    }
                case .missing:
                    StatusRow(
                        symbol: "exclamationmark.triangle", tint: Brand.badgeText,
                        text: "Needs Rosetta, which isn't installed",
                        detail: "Apple's translator for Intel software. PayrollRTI can install it for you.")
                    if installingRosetta {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Installing Rosetta…").font(.system(size: 13)).foregroundStyle(Brand.secondaryText)
                        }
                    } else {
                        SecondaryButton("Install Rosetta…") { installRosetta() }
                    }
                    if let rosettaError {
                        Text(rosettaError).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            } else {
                StatusRow(symbol: "xmark.circle", tint: Brand.secondaryText, text: "Not installed",
                    detail: "Install it from GOV.UK, then check again")
                HStack(spacing: 10) {
                    SecondaryButton("Download from GOV.UK") { NSWorkspace.shared.open(Links.bptDownload) }
                    SecondaryButton("Check again") {
                        engine = .macInstaller
                        server.start()
                    }
                }
            }
        }
    }
}

/// One of the two choices: a fixed top (icon tile, badge, title, explanation) and a bottom area whose content
/// depends on what's installed, so the two cards' buttons line up.
private struct EngineCard<Actions: View>: View {
    let symbol: String
    let title: String
    let summary: String
    let detail: String
    let badge: String?
    let recommended: Bool
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(recommended ? Brand.tick : Brand.text)
                    .frame(width: 44, height: 44)
                    .background(
                        recommended ? Brand.iconTileRecommended : Brand.iconTile,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Brand.badgeBackground, in: Capsule())
                        .foregroundStyle(Brand.badgeText)
                }
            }
            .padding(.bottom, 22)
            Text(title).font(.system(size: 17, weight: .semibold)).padding(.bottom, 10)
            Text(summary).font(.system(size: 14)).padding(.bottom, 14)
            Text(detail).font(.system(size: 14)).foregroundStyle(Brand.secondaryText)
            Spacer(minLength: 22)
            VStack(alignment: .leading, spacing: 12) { actions }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            recommended ? Brand.recommendedCard : Brand.card,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    recommended ? Brand.recommendedBorder : Brand.cardBorder, lineWidth: recommended ? 1.5 : 1)
        )
    }
}

/// A status line with an icon and an optional second, secondary line (the version, the progress).
private struct StatusRow: View {
    let symbol: String
    let tint: Color
    let text: String
    let detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 14))
                if let detail {
                    Text(detail).font(.system(size: 13)).foregroundStyle(Brand.secondaryText)
                }
            }
        }
    }
}

/// Whether this copy can open the user's existing payroll data, in plain words.
struct CompatibilityLine: View {
    let verdict: DatabaseCompatibility

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(text).font(.system(size: 14)).foregroundStyle(verdict.allowsStart ? Brand.text : Color.red)
        }
    }

    private var text: String {
        switch verdict {
        case .noDatabase: return "No payroll data yet"
        case .current: return "Works with your existing payroll data"
        case .upgrade(let pending):
            return "Will update your payroll data when it starts (\(pending) change\(pending == 1 ? "" : "s"), "
                + "backed up first)"
        case .tooOld(let detail): return "Can't open your payroll data: \(detail)"
        case .unknown(let detail): return "Couldn't check your payroll data: \(detail)"
        }
    }

    private var symbol: String {
        switch verdict {
        case .noDatabase: return "doc"
        case .current: return "checkmark.circle"
        case .upgrade: return "arrow.up.circle"
        case .tooOld: return "exclamationmark.triangle"
        case .unknown: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch verdict {
        case .noDatabase, .unknown: return Brand.secondaryText
        case .current: return Brand.tick
        case .upgrade: return Brand.badgeText
        case .tooOld: return .red
        }
    }
}

/// The filled green button from the design.
private struct PrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Brand.primaryButton, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .padding(.top, 8)
    }
}

/// The outlined button from the design: the card's colour with the card's border.
private struct SecondaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.text)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Brand.cardBorder))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .padding(.top, 8)
    }
}
