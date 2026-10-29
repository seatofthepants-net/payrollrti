import SwiftUI

/// What HMRC currently publish, where PayrollRTI learnt it, and what that means for the engine in use.
struct BPTUpdatesStatus: View {
    @EnvironmentObject private var updates: UpdateChecker
    @EnvironmentObject private var server: ServerController
    @AppStorage(SettingsKey.engine) private var engine = BPTEngine.macInstaller

    var body: some View {
        if let release = updates.release {
            LabeledContent("Latest from HMRC", value: release.version.description)
            LabeledContent("Mac installer", value: Self.published(release.macInstaller))
            LabeledContent("Linux build", value: Self.published(release.linuxBuild))
            Text("Checked \(release.checkedAt.formatted(date: .omitted, time: .shortened)) from \(release.source).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(
                UpdateChecker.advice(
                    engine: engine, release: release, linuxEngineAvailable: LinuxBuildRuntime.bundled != nil)
            )
            .font(.callout)
        } else if case .failed(let message) = updates.status {
            Text("Couldn't check HMRC's feed or GOV.UK: \(message)").font(.callout).foregroundStyle(.red)
        } else if updates.status == .checking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking HMRC's update feed…").font(.callout)
            }
        } else {
            Text("Not checked yet.").font(.callout).foregroundStyle(.secondary)
        }
        HStack {
            Button("Check Now") { Task { await updates.check(installed: server.installation?.version) } }
                .disabled(updates.status == .checking)
            Spacer()
            Link("HMRC's Basic PAYE Tools page", destination: Links.bptDownload).font(.callout)
        }
    }

    private static func published(_ exists: Bool?) -> String {
        switch exists {
        case true?: return "Published by HMRC"
        case false?: return "Not published by HMRC"
        case nil: return "Unknown"
        }
    }
}
