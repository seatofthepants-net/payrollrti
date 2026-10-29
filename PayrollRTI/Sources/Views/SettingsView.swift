import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var server: ServerController
    @AppStorage(SettingsKey.port) private var port = AppSettings.defaultPort
    @AppStorage(SettingsKey.openMode) private var openMode = OpenMode.embedded
    @AppStorage(SettingsKey.engine) private var engine = BPTEngine.macInstaller
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
                LabeledContent("Location", value: server.installation?.location.path ?? "Not installed")
                LabeledContent("Version", value: server.installation?.version?.description ?? "Unknown")
                if let newest = AppSettings.newestStartedVersion {
                    LabeledContent("Payroll database last used by", value: newest.description)
                }
            } header: {
                Text("Basic PAYE Tools")
            }

            Section {
                BPTUpdatesStatus()
            } header: {
                Text("Basic PAYE Tools updates")
            }

            Section {
                HStack {
                    Text("PayrollRTI \(Self.appVersion)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("Check for PayrollRTI updates", destination: Links.releases)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { server.refreshInstallation() }
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

    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
