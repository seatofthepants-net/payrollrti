import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let server = ServerController()
    let updates = UpdateChecker()
    let browser = BrowserState()

    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            SettingsKey.port: AppSettings.defaultPort,
            SettingsKey.openMode: OpenMode.embedded.rawValue,
        ])

        server.$state
            .removeDuplicates()
            .sink { [weak self] state in
                if state == .running, AppSettings.openMode == .browser {
                    self?.openInDefaultBrowser()
                }
            }
            .store(in: &cancellables)

        #if DEBUG
            DebugSnapshot.startIfRequested(server: server)
        #endif
        server.start()
        Task { await updates.check(installed: server.installation?.version) }
    }

    /// Closing the window leaves the server running behind the menu-bar icon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard server.ownsRunningProcess else { return .terminateNow }
        Task {
            await server.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Actions shared by the menu bar, main menu and views

    func openInDefaultBrowser() {
        NSWorkspace.shared.open(server.baseURL)
    }

    func openInSafari() {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            return openInDefaultBrowser()
        }
        NSWorkspace.shared.open(
            [server.baseURL], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
    }

    func showServerLog() {
        if FileManager.default.fileExists(atPath: server.logURL.path) {
            NSWorkspace.shared.open(server.logURL)
        } else {
            NSWorkspace.shared.open(server.logURL.deletingLastPathComponent())
        }
    }

    /// Menu-driven check: always reports the outcome, unlike the silent check at launch.
    func checkForUpdatesInteractively() {
        Task {
            server.refreshInstallation()
            await updates.check(installed: server.installation?.version)
            let alert = NSAlert()
            switch updates.status {
            case .updateAvailable(let installed, let latest):
                alert.messageText = "Basic PAYE Tools \(latest) is available"
                alert.informativeText =
                    "You have \(installed). Download the new version from GOV.UK and run HMRC's installer. "
                    + "Quit PayrollRTI first so the installer can replace the running copy."
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Later")
            case .upToDate(let installed):
                alert.messageText = "Basic PAYE Tools is up to date"
                alert.informativeText = "You have the latest version, \(installed)."
            case .latestKnown(let latest):
                alert.messageText = "The latest Basic PAYE Tools is \(latest)"
                alert.informativeText = "PayrollRTI couldn't tell which version you have installed."
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Close")
            case .failed(let message):
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = message
            case .idle, .checking:
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn, alert.buttons.count > 1 {
                NSWorkspace.shared.open(Links.bptDownload)
            }
        }
    }
}
