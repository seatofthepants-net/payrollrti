import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let server = ServerController()
    let updates = UpdateChecker()
    let browser = BrowserState()
    let linuxBuild = LinuxBuildInstaller()
    let appUpdates = AppUpdater()

    private var cancellables: Set<AnyCancellable> = []
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests use the app as their host; don't start a real BPT server underneath them.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        UserDefaults.standard.register(defaults: [
            SettingsKey.port: AppSettings.defaultPort,
            SettingsKey.openMode: OpenMode.embedded.rawValue,
            SettingsKey.engine: BPTEngine.macInstaller.rawValue,
        ])

        handleTerminationSignals()

        server.$state
            .removeDuplicates()
            .sink { [weak self] state in
                if state == .running, AppSettings.openMode == .browser {
                    self?.openInDefaultBrowser()
                }
            }
            .store(in: &cancellables)

        // A freshly downloaded Linux build is the installation the Linux engine was waiting for.
        linuxBuild.$phase
            .sink { [weak self] phase in
                guard let self, case .installed = phase else { return }
                server.refreshInstallation()
                if AppSettings.engine == .linuxBuild, server.canStart { server.start() }
            }
            .store(in: &cancellables)

        #if DEBUG
            DebugSnapshot.startIfRequested(server: server)
        #endif
        server.start()
        Task { await updates.check(installed: server.installation?.version) }
        Task { await appUpdates.check() }
    }

    /// Closing the window leaves the server running behind the menu-bar icon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard server.ownsRunningProcess else { return .terminateNow }
        // Stopping the server mid-restore could leave BPT with its old database deleted and the new one half
        // written.
        if browser.isRestoring {
            let alert = NSAlert()
            alert.messageText = "A restore is in progress"
            alert.informativeText =
                "Basic PAYE Tools is still restoring your backup. Quit once it has finished and you're back "
                + "on the home screen."
            alert.runModal()
            return .terminateCancel
        }
        Task {
            await server.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// `kill`, logout scripts and Ctrl+C in Terminal send signals that would end the app without
    /// `applicationShouldTerminate`, orphaning the rti server. Route them through a normal quit instead.
    private func handleTerminationSignals() {
        for signalNumber in [SIGTERM, SIGHUP, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            // Not NSApp.terminate directly: from inside a main-queue block, its wait for our async shutdown would
            // deadlock, because that shutdown also needs the main queue. A run-loop perform runs outside the block.
            source.setEventHandler {
                RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
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

    /// Menu-driven check for a new PayrollRTI: opens the notes-and-install sheet, or says it's up to date.
    func checkForAppUpdatesInteractively() {
        Task {
            await appUpdates.check()
            NSApp.activate(ignoringOtherApps: true)
            if appUpdates.available != nil {
                showMainWindow()
                appUpdates.showsDetails = true
                return
            }
            let alert = NSAlert()
            if case .failed(let message) = appUpdates.status {
                alert.messageText = "Couldn't check for PayrollRTI updates"
                alert.informativeText = message
            } else {
                alert.messageText = "PayrollRTI is up to date"
                alert.informativeText = "You have \(appUpdates.current.description)."
            }
            alert.runModal()
        }
    }

    private func showMainWindow() {
        if let window = NSApp.windows.first(where: { $0.title == "Basic PAYE Tools" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Installs a staged PayrollRTI update: stop Basic PAYE Tools (with its backup-on-exit, as a normal quit
    /// does), start the watcher that swaps the bundle once we're gone, and exit. Not `NSApp.terminate`: the
    /// async shutdown and AppKit's wait for it both need the main queue, and from a button action they deadlock.
    func installAppUpdate() {
        Task {
            await server.stop()
            do {
                try appUpdates.launchInstaller()
            } catch {
                appUpdates.reportInstallFailure(error.localizedDescription)
                return
            }
            exit(0)
        }
    }

    /// Menu-driven check: always reports the outcome, unlike the silent check at launch.
    func checkForUpdatesInteractively() {
        Task {
            server.refreshInstallation()
            await updates.check(installed: server.installation?.version)
            guard let (alert, downloadable) = bptUpdateAlert() else { return }
            if let release = updates.release {
                let mac = release.macInstaller == true ? "published" : "not published"
                let linux = release.linuxBuild == true ? "published" : "not published"
                alert.informativeText +=
                    "\n\nHMRC publish for \(release.version): Mac installer \(mac), Linux build \(linux) "
                    + "(from \(release.source)).\n\n"
                    + UpdateChecker.advice(
                        engine: AppSettings.engine, release: release,
                        linuxEngineAvailable: LinuxBuildRuntime.bundled != nil)
            }
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn, alert.buttons.count > 1 {
                if AppSettings.engine == .linuxBuild, let downloadable {
                    await linuxBuild.install(version: downloadable)
                } else {
                    NSWorkspace.shared.open(Links.bptDownload)
                }
            }
        }
    }

    /// The alert for the current BPT update status and, when there's something to get, the version to download.
    private func bptUpdateAlert() -> (NSAlert, BPTVersion?)? {
        let alert = NSAlert()
        var downloadable: BPTVersion?
        switch updates.status {
        case .updateAvailable(let installed, let latest):
            alert.messageText = "Basic PAYE Tools \(latest) is available"
            if AppSettings.engine == .linuxBuild {
                alert.informativeText =
                    "You have \(installed). PayrollRTI can download the Linux build of the new version from "
                    + "GOV.UK and switch to it the next time Basic PAYE Tools starts."
            } else {
                alert.informativeText =
                    "You have \(installed). Download the new version from GOV.UK and run HMRC's installer. "
                    + "Quit PayrollRTI first so the installer can replace the running copy."
            }
            downloadable = latest
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
        case .upToDate(let installed):
            alert.messageText = "Basic PAYE Tools is up to date"
            alert.informativeText = "You have the latest version, \(installed)."
        case .latestKnown(let latest):
            alert.messageText = "The latest Basic PAYE Tools is \(latest)"
            alert.informativeText = "PayrollRTI couldn't tell which version you have installed."
            downloadable = latest
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Close")
        case .failed(let message):
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = message
        case .idle, .checking:
            return nil
        }
        return (alert, downloadable)
    }
}
