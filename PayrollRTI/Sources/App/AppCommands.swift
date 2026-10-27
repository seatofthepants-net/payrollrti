import SwiftUI

struct AppCommands: Commands {
    @ObservedObject var server: ServerController
    let browser: BrowserState
    let actions: AppDelegate

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Basic PAYE Tools Updates…") { actions.checkForUpdatesInteractively() }
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") { browser.print() }
                .keyboardShortcut("p")
                .disabled(!server.isRunning)
        }

        CommandGroup(before: .toolbar) {
            Button("Reload Page") { browser.reload() }
                .keyboardShortcut("r")
                .disabled(!server.isRunning)
            Button("Back") { browser.goBack() }
                .keyboardShortcut("[")
            Button("Forward") { browser.goForward() }
                .keyboardShortcut("]")
            Divider()
            Button("Actual Size") { browser.resetZoom() }
                .keyboardShortcut("0")
            Button("Zoom In") { browser.zoomIn() }
                .keyboardShortcut("+")
            Button("Zoom Out") { browser.zoomOut() }
                .keyboardShortcut("-")
            Divider()
        }

        CommandMenu("Server") {
            Button("Start") { server.start() }
                .disabled(!server.canStart)
            Button("Stop") { Task { await server.stop() } }
                .disabled(!server.canStop)
            Button("Restart") { Task { await server.restart() } }
                .disabled(!server.isRunning)
            Divider()
            Button("Open in Safari") { actions.openInSafari() }
                .disabled(!server.isRunning)
            Button("Open in Default Browser") { actions.openInDefaultBrowser() }
                .disabled(!server.isRunning)
            Divider()
            Button("Show Server Log") { actions.showServerLog() }
        }

        CommandGroup(replacing: .help) {
            Link("HMRC Basic PAYE Tools Service Issues", destination: Links.hmrcIssues)
            Link("Download Basic PAYE Tools", destination: Links.bptDownload)
            Divider()
            Link("PayrollRTI on GitHub", destination: Links.repository)
        }
    }
}
