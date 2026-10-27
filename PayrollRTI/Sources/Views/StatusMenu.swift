import SwiftUI

struct StatusIcon: View {
    @ObservedObject var server: ServerController

    var body: some View {
        Text(server.isRunning ? "🟢" : "🔴")
            .accessibilityLabel(server.isRunning ? "Basic PAYE Tools running" : "Basic PAYE Tools stopped")
    }
}

struct StatusMenu: View {
    @EnvironmentObject private var server: ServerController
    @Environment(\.appActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusText)
        Divider()
        Button("Show Basic PAYE Tools") {
            openWindow(id: WindowID.main)
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Start") { server.start() }
            .disabled(!server.canStart)
        Button("Stop") { Task { await server.stop() } }
            .disabled(!server.canStop)
        Button("Open in Safari") { actions?.openInSafari() }
            .disabled(!server.isRunning)
        Divider()
        Button("Check for Updates…") { actions?.checkForUpdatesInteractively() }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit PayrollRTI") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusText: String {
        switch server.state {
        case .running: return "Running on port \(server.activePort)"
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        case .stopped: return "Stopped"
        case .notInstalled: return "Basic PAYE Tools not installed"
        case .failed: return "Stopped (error)"
        }
    }
}
