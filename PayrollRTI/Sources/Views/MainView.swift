import SwiftUI

struct MainView: View {
    @EnvironmentObject private var server: ServerController
    @EnvironmentObject private var updates: UpdateChecker
    @EnvironmentObject private var browser: BrowserState
    @AppStorage(SettingsKey.openMode) private var openMode = OpenMode.embedded

    var body: some View {
        VStack(spacing: 0) {
            if updates.showsBanner, let latest = updates.availableUpdate {
                UpdateBanner(version: latest) { updates.isBannerDismissed = true }
                Divider()
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch server.state {
        case .notInstalled:
            BPTNotFoundView()
        case .starting:
            StatusPanel(symbol: nil, title: server.progress ?? "Starting Basic PAYE Tools…") {
                Text("The first launch on an Apple silicon Mac can take a minute while Rosetta translates it.")
            }
        case .stopping:
            StatusPanel(symbol: nil, title: server.progress ?? "Stopping Basic PAYE Tools…") {
                Text("Please wait. Quitting part-way through could damage your payroll data.")
            }
        case .running where openMode == .embedded:
            BPTWebView(url: server.baseURL, browser: browser)
                .overlay(alignment: .top) { LoadingIndicator(isLoading: browser.isLoading) }
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

struct BPTNotFoundView: View {
    @EnvironmentObject private var server: ServerController

    var body: some View {
        StatusPanel(symbol: "shippingbox", title: "Basic PAYE Tools isn't installed") {
            VStack(spacing: 20) {
                Text(
                    "PayrollRTI runs HMRC's free Basic PAYE Tools for you, so it needs to be installed first. "
                        + "Download it from GOV.UK and run the installer, then come back here.")
                Text("Expected location: \(BPTInstallation.configuredAppURL.path)")
                    .font(.caption)
                    .textSelection(.enabled)
                HStack {
                    Button("Download from GOV.UK") { NSWorkspace.shared.open(Links.bptDownload) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    Button("Check Again") { server.start() }
                }
            }
        }
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
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
            Text("A newer version of Basic PAYE Tools (\(version.description)) is available.")
            Link("Download", destination: Links.bptDownload).fontWeight(.semibold)
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
}
