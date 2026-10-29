import SwiftUI

/// Across the top of the main window when a newer PayrollRTI is on GitHub.
struct AppUpdateBanner: View {
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        if let release = updater.available {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("PayrollRTI \(release.version?.description ?? release.tagName) is available.")
                Button("What's new and install…") { updater.showsDetails = true }.fontWeight(.semibold)
                Spacer()
                Button(action: { updater.isBannerDismissed = true }) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

/// The release notes and the install flow: download, verify, stage, then quit and relaunch into the new version.
struct AppUpdateSheet: View {
    @EnvironmentObject private var updater: AppUpdater
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appActions) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let release = updater.available {
                Text("PayrollRTI \(release.version?.description ?? release.tagName) is available")
                    .font(.title2.weight(.semibold))
                Text("You have \(updater.current.description).").foregroundStyle(.secondary)
                ScrollView {
                    Text(Self.notes(release.body))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 160, maxHeight: 320)
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                Link("View on GitHub", destination: release.htmlURL).font(.callout)
                Divider()
                actions
            } else {
                Text("PayrollRTI is up to date.").font(.title3)
                HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    @ViewBuilder private var actions: some View {
        switch updater.status {
        case .downloading(_, let fraction):
            HStack(spacing: 10) {
                ProgressView(value: fraction ?? 0)
                Text(fraction.map { "\(Int($0 * 100))%" } ?? "Starting…").monospacedDigit().frame(width: 60)
            }
            Text("Downloading the disk image from GitHub…").font(.callout).foregroundStyle(.secondary)
        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the download against its published checksum…").font(.callout)
            }
        case .readyToInstall:
            Text(
                "Ready. Quitting PayrollRTI will stop Basic PAYE Tools, back up as usual, replace the app and "
                    + "open the new version. The current version goes to the Trash."
            )
            .font(.callout)
            if let installError = updater.installError {
                Text(installError).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Quit and Install") { app?.installAppUpdate() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Try Again") { Task { await updater.check() } }
            }
        case .available, .idle, .checking, .upToDate:
            HStack {
                Spacer()
                Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Download and Install") { Task { await updater.downloadAndStage() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// GitHub release bodies are Markdown; headings and lists come through as plain lines, inline styles are kept.
    static func notes(_ body: String?) -> AttributedString {
        let text = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return AttributedString("No release notes.") }
        let cleaned = text.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
        return (try? AttributedString(
            markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
