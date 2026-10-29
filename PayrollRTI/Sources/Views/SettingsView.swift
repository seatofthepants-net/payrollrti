import ServiceManagement
import SwiftUI

/// Preferences, as three short tabs rather than one long list.
struct SettingsView: View {
    @EnvironmentObject private var server: ServerController

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            EngineSettings()
                .tabItem { Label("Engine", systemImage: "bolt") }
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 560)
        .onAppear { server.refreshInstallation() }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var server: ServerController
    @AppStorage(SettingsKey.port) private var port = AppSettings.defaultPort
    @AppStorage(SettingsKey.openMode) private var openMode = OpenMode.embedded
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                TextField("Port", value: $port, format: .number.grouping(.never))
                    .frame(maxWidth: 160)
                if !AppSettings.validPorts.contains(port) {
                    Text("Use a port between 1024 and 65535. HMRC's default is \(String(AppSettings.defaultPort)).")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if server.isRunning, port != server.activePort {
                    HStack {
                        Text("Restart Basic PAYE Tools to use the new port.").font(.caption)
                        Button("Restart Now") { Task { await server.restart() } }
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("Server")
            }

            Section {
                Picker("Open Basic PAYE Tools", selection: $openMode) {
                    ForEach(OpenMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Toggle("Open PayrollRTI at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("General")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't change the login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct EngineSettings: View {
    @EnvironmentObject private var server: ServerController
    @AppStorage(SettingsKey.engine) private var engine = BPTEngine.macInstaller

    var body: some View {
        Form {
            Section {
                Picker("Run", selection: $engine) {
                    ForEach(BPTEngine.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .disabled(LinuxBuildRuntime.bundled == nil)
                .onChange(of: engine) { _, _ in
                    // Same data either way: a stopped server just starts the other engine; a running one restarts.
                    if server.canStart { server.start() }
                }
                Text(engine.detail).font(.caption).foregroundStyle(.secondary)
                if let running = server.installation?.engine, server.isRunning, running != engine {
                    HStack {
                        Text("Restart Basic PAYE Tools to switch.").font(.caption)
                        Button("Restart Now") { Task { await server.restart() } }
                            .controlSize(.small)
                    }
                }
                if engine == .linuxBuild {
                    LinuxBuildDownloadControls()
                }
            } header: {
                Text("Basic PAYE Tools engine")
            }

            Section {
                LabeledContent("Location") {
                    HStack {
                        Text(server.installation?.location.path ?? "Not installed")
                            .textSelection(.enabled)
                        if engine == .macInstaller {
                            Button("Choose…") {
                                if case .chosen = BPTInstallation.chooseMacInstaller() {
                                    server.refreshInstallation()
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
                LabeledContent("Version", value: server.installation?.version?.description ?? "Unknown")
                if let newest = AppSettings.newestStartedVersion {
                    LabeledContent("Payroll database last used by", value: newest.description)
                }
            } header: {
                Text("Basic PAYE Tools")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct UpdateSettings: View {
    @EnvironmentObject private var appUpdates: AppUpdater
    @Environment(\.appActions) private var actions

    var body: some View {
        Form {
            Section {
                BPTUpdatesStatus()
            } header: {
                Text("Basic PAYE Tools")
            }

            Section {
                HStack {
                    Text("PayrollRTI \(SettingsView.appVersion)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    switch appUpdates.status {
                    case .checking:
                        ProgressView().controlSize(.small)
                    case .available, .downloading, .verifying, .readyToInstall:
                        Button("Update available…") { appUpdates.showsDetails = true }
                    case .idle, .upToDate, .failed:
                        Button("Check for Updates") { actions?.checkForAppUpdatesInteractively() }
                    }
                    Link("Releases", destination: Links.releases)
                }
                .font(.callout)
            } header: {
                Text("PayrollRTI")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
