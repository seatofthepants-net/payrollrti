import SwiftUI

/// The state of HMRC's Linux build on this Mac and the button that downloads or updates it. Shared by Settings
/// and the screen shown when the Linux engine is selected but nothing has been downloaded yet.
struct LinuxBuildDownloadControls: View {
    @EnvironmentObject private var installer: LinuxBuildInstaller
    @EnvironmentObject private var updates: UpdateChecker
    @EnvironmentObject private var server: ServerController

    private var installed: BPTVersion? { LinuxBuildStore.newest()?.version }

    /// The version GOV.UK currently advertises, from whichever check ran last.
    private var latest: BPTVersion? {
        switch updates.status {
        case .upToDate(let version), .latestKnown(let version): return version
        case .updateAvailable(_, let latest): return latest
        case .idle, .checking, .failed: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if LinuxBuildRuntime.bundled == nil {
                Text("This build of PayrollRTI doesn't include the native runtime, so the Linux build can't be used.")
                    .foregroundStyle(.red)
            } else {
                statusLine
                actionRow
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var statusLine: some View {
        if let installed {
            Text("Downloaded: Basic PAYE Tools \(installed.description)")
        } else {
            Text("Not downloaded yet. The download from GOV.UK is about 190 MB.")
        }
    }

    @ViewBuilder private var actionRow: some View {
        switch installer.phase {
        case .downloading(let fraction):
            HStack {
                if let fraction {
                    ProgressView(value: fraction).frame(maxWidth: 220)
                    Text("\(Int(fraction * 100))%").monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("Downloading from GOV.UK…")
            }
        case .extracting:
            HStack {
                ProgressView().controlSize(.small)
                Text("Unpacking…")
            }
        case .idle, .installed, .failed:
            HStack(spacing: 12) {
                if let latest, installed.map({ $0 < latest }) ?? true {
                    Button(installed == nil ? "Download \(latest.description)" : "Update to \(latest.description)") {
                        Task { await installer.install(version: latest) }
                    }
                    .buttonStyle(.borderedProminent)
                } else if updates.status == .checking {
                    ProgressView().controlSize(.small)
                    Text("Finding the latest version on GOV.UK…")
                } else if latest == nil {
                    Button("Check GOV.UK for the latest version") {
                        Task { await updates.check(installed: server.installation?.version) }
                    }
                }
                let runningLinux = server.isRunning && server.installation?.engine == .linuxBuild
                if let installed, let payload = LinuxBuildStore.newest(), !runningLinux {
                    Button("Remove \(installed.description)") {
                        try? LinuxBuildStore.remove(payload)
                        server.refreshInstallation()
                    }
                }
            }
            if case .failed(let message) = installer.phase {
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            }
            if case .failed(let message) = updates.status, latest == nil {
                Text(message).foregroundStyle(.red)
            }
        }
    }
}

/// The main window when the Linux engine is selected and no Linux build has been downloaded.
struct LinuxBuildNotDownloadedView: View {
    @EnvironmentObject private var server: ServerController
    @EnvironmentObject private var updates: UpdateChecker
    @AppStorage(SettingsKey.engine) private var engine = BPTEngine.macInstaller

    var body: some View {
        StatusPanel(symbol: "arrow.down.circle", title: "HMRC's Linux build isn't downloaded yet") {
            VStack(spacing: 20) {
                Text(
                    "PayrollRTI is set to run the Linux build of Basic PAYE Tools natively. It downloads the release "
                        + "from GOV.UK and runs it against your existing payroll data in ~/HMRC/payetools-rti.")
                LinuxBuildDownloadControls()
                if BPTInstallation.locate(engine: .macInstaller) != nil {
                    Button("Use HMRC's Mac installer instead") {
                        engine = .macInstaller
                        server.start()
                    }
                }
            }
        }
        .task {
            if case .idle = updates.status { await updates.check(installed: nil) }
        }
    }
}
