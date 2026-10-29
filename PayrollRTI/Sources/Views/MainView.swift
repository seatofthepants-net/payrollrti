import SwiftUI

struct MainView: View {
    @EnvironmentObject private var server: ServerController
    @EnvironmentObject private var updates: UpdateChecker
    @EnvironmentObject private var browser: BrowserState
    @AppStorage(SettingsKey.openMode) private var openMode = OpenMode.embedded
    @AppStorage(SettingsKey.engine) private var engine = BPTEngine.macInstaller

    var body: some View {
        VStack(spacing: 0) {
            if updates.showsBanner, let latest = updates.availableUpdate {
                UpdateBanner(version: latest, downloadsInApp: engine == .linuxBuild) {
                    updates.isBannerDismissed = true
                }
                Divider()
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch server.state {
        case .notInstalled:
            EngineChoiceView()
        case .starting:
            StatusPanel(symbol: nil, title: server.progress ?? "Starting Basic PAYE Tools…") {
                if engine == .macInstaller {
                    Text("The first launch on an Apple silicon Mac can take a minute while Rosetta translates it.")
                } else {
                    Text("Basic PAYE Tools is checking its database before it starts.")
                }
            }
        case .stopping:
            StatusPanel(symbol: nil, title: server.progress ?? "Stopping Basic PAYE Tools…") {
                Text("Please wait. Quitting part-way through could damage your payroll data.")
            }
        case .running where openMode == .embedded:
            BPTWebView(url: server.baseURL, browser: browser)
                .overlay(alignment: .top) { LoadingIndicator(isLoading: browser.isLoading && !browser.isRestoring) }
                .overlay {
                    if browser.isRestoring { RestoringOverlay() }
                }
        case .running:
            BrowserModeView()
        case .stopped:
            StoppedView()
        case .failed(let message):
            FailedView(message: message)
        }
    }
}

/// Shown over BPT when a page takes more than a moment. WKWebView has no loading UI of its own, and some BPT
/// actions (restoring a backup takes about a minute) send nothing back until they finish, so without this a
/// click looks like it did nothing.
struct LoadingIndicator: View {
    let isLoading: Bool
    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Working…")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 3)
        .padding(12)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(!isVisible)
        .task(id: isLoading) {
            guard isLoading else {
                withAnimation { isVisible = false }
                return
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { isVisible = true }
        }
    }
}

/// Covers BPT while it restores a backup, which it does inside the form post with no progress of its own. Also
/// swallows clicks, since resubmitting or navigating away mid-restore is what left people on a blank page.
struct RestoringOverlay: View {
    var body: some View {
        StatusPanel(symbol: nil, title: "Restoring your data…") {
            Text(
                "Basic PAYE Tools is replacing your payroll database with the backup. This can take a few minutes; "
                    + "you'll be taken to the home screen when it's done. Please don't quit PayrollRTI.")
        }
        .background(.regularMaterial)
        .contentShape(Rectangle())
        .onTapGesture {}
        .transition(.opacity)
    }
}

/// A centred icon, title and supporting content used by every non-web state.
struct StatusPanel<Detail: View>: View {
    let symbol: String?
    let title: String
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(spacing: 16) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(title).font(.title2.weight(.semibold))
            detail
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StoppedView: View {
    @EnvironmentObject private var server: ServerController

    var body: some View {
        StatusPanel(symbol: "pause.circle", title: "Basic PAYE Tools is stopped") {
            Button("Start") { server.start() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}

struct FailedView: View {
    let message: String
    @EnvironmentObject private var server: ServerController
    @Environment(\.appActions) private var actions

    var body: some View {
        StatusPanel(symbol: "exclamationmark.triangle", title: "Basic PAYE Tools couldn't start") {
            VStack(spacing: 20) {
                ScrollView {
                    Text(message)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                HStack {
                    Button("Try Again") { server.start() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    Button("Show Server Log") { actions?.showServerLog() }
                    Button("HMRC Service Issues") { NSWorkspace.shared.open(Links.hmrcIssues) }
                }
            }
        }
    }
}

struct BrowserModeView: View {
    @EnvironmentObject private var server: ServerController
    @Environment(\.appActions) private var actions

    var body: some View {
        StatusPanel(symbol: "safari", title: "Basic PAYE Tools is running") {
            VStack(spacing: 20) {
                Text(
                    "It's open in your web browser at \(server.baseURL.absoluteString). Keep PayrollRTI running "
                        + "while you work; quitting it stops Basic PAYE Tools.")
                Button("Open in Browser") { actions?.openInDefaultBrowser() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct UpdateBanner: View {
    let version: BPTVersion
    /// With the Linux engine the update is downloaded by PayrollRTI itself; otherwise it's HMRC's installer on GOV.UK.
    let downloadsInApp: Bool
    let dismiss: () -> Void
    @EnvironmentObject private var installer: LinuxBuildInstaller
    @EnvironmentObject private var server: ServerController

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
            Text("A newer version of Basic PAYE Tools (\(version.description)) is available.")
            if downloadsInApp {
                inAppAction
            } else {
                Link("Download", destination: Links.bptDownload).fontWeight(.semibold)
            }
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder private var inAppAction: some View {
        switch installer.phase {
        case .downloading(let fraction):
            ProgressView(value: fraction ?? 0).frame(width: 120)
            Text(fraction.map { "\(Int($0 * 100))%" } ?? "Downloading…").monospacedDigit()
        case .backingUp:
            ProgressView().controlSize(.small)
            Text("Backing up…")
        case .extracting:
            ProgressView().controlSize(.small)
            Text("Unpacking…")
        case .installed(let installed) where installed == version:
            Button("Restart to use it") { Task { await server.restart() } }.fontWeight(.semibold)
        case .idle, .installed, .failed:
            Button("Download") { Task { await installer.install(version: version) } }.fontWeight(.semibold)
            if case .failed(let message) = installer.phase {
                Text(message).foregroundStyle(.red).lineLimit(1).help(message)
            }
        }
    }
}
