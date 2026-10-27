#if DEBUG
    import AppKit
    import Combine
    import WebKit

    /// Debug builds only. Renders the app's own windows to PNG (at the display's Retina scale) without needing
    /// screen-recording access:
    ///
    /// - `-debugSnapshotDir <dir>`: a PNG of the main window each time the server state changes.
    /// - `-debugShotsDir <dir>`: once BPT is running, a scripted set of shots: the main window, then each page in
    ///   `-debugShotPages "name=/path/,…"`. Writes `<dir>/.done` when finished. (SwiftUI forms such as Settings
    ///   don't render this way, and nor do menus; those need a real screen capture.)
    /// - `-debugWindowSize 1440x900`: main window content size, in points.
    /// - `-debugAppearance light|dark`: force the app's appearance.
    @MainActor
    enum DebugSnapshot {
        private static var cancellable: AnyCancellable?
        private static var shotsCancellable: AnyCancellable?
        private static var counter = 0

        static func startIfRequested(server: ServerController) {
            let defaults = UserDefaults.standard
            switch defaults.string(forKey: "debugAppearance") {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: break
            }
            if let dir = defaults.string(forKey: "debugShotsDir") {
                shotsCancellable = server.$state.first { $0 == .running }.sink { _ in
                    Task { await takeShots(in: URL(fileURLWithPath: dir), server: server) }
                }
            }
            guard let path = defaults.string(forKey: "debugSnapshotDir") else { return }
            let directory = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            cancellable = server.$state.removeDuplicates().sink { state in
                counter += 1
                let name = String(format: "%02d-%@.png", counter, label(for: state))
                prepareMainWindow()
                Task {
                    // Give SwiftUI and the web view time to settle.
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    await capture(to: directory.appendingPathComponent(name), includingFrame: true)
                }
            }
        }

        private static var mainWebView: WKWebView? {
            mainWindow?.contentView.flatMap { webViews(in: $0).first }
        }

        private static var mainWindow: NSWindow? {
            NSApp.windows.filter { $0.isVisible && $0.title == "Basic PAYE Tools" }
                .max { $0.frame.width < $1.frame.width }
        }

        private static func takeShots(in directory: URL, server: ServerController) async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let settle: UInt64 = 3_000_000_000
            prepareMainWindow()
            try? await Task.sleep(nanoseconds: settle)
            await capture(to: directory.appendingPathComponent("main.png"), includingFrame: true)

            let pages = (UserDefaults.standard.string(forKey: "debugShotPages") ?? "").split(separator: ",")
            for page in pages {
                let parts = page.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, let webView = mainWebView,
                    let url = URL(string: parts[1], relativeTo: server.baseURL)
                else { continue }
                webView.load(URLRequest(url: url))
                try? await Task.sleep(nanoseconds: settle)
                await capture(to: directory.appendingPathComponent("\(parts[0]).png"), includingFrame: true)
            }
            if !pages.isEmpty, let webView = mainWebView {
                webView.load(URLRequest(url: server.baseURL))
            }

            FileManager.default.createFile(atPath: directory.appendingPathComponent(".done").path, contents: nil)
        }

        /// Applies `-debugWindowSize` and makes the window key, so shots show active-window chrome.
        private static func prepareMainWindow() {
            guard let window = mainWindow else { return }
            if let size = UserDefaults.standard.string(forKey: "debugWindowSize")?.split(separator: "x")
                .compactMap({ Double($0) }), size.count == 2,
                window.contentView?.bounds.size != NSSize(width: size[0], height: size[1])
            {
                window.setContentSize(NSSize(width: size[0], height: size[1]))
                window.center()
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }

        static func capture(to url: URL, includingFrame: Bool = false) async {
            guard let window = mainWindow else { return }
            await capture(window, to: url, includingFrame: includingFrame)
        }

        /// `includingFrame` renders the window's frame view, so the title bar and window buttons are included.
        static func capture(_ window: NSWindow, to url: URL, includingFrame: Bool) async {
            guard
                let content = window.contentView,
                case let view = includingFrame ? (content.superview ?? content) : content,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: rep)

            // WKWebView renders out of process, so cacheDisplay leaves it blank; paint its own snapshot on top.
            for webView in webViews(in: view) {
                guard let snapshot = try? await webView.takeSnapshot(configuration: nil) else { continue }
                var rect = webView.convert(webView.bounds, to: view)
                if view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                snapshot.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
            }
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("DebugSnapshot: wrote \(url.path)")
        }

        private static func webViews(in view: NSView) -> [WKWebView] {
            view.subviews.flatMap { ($0 as? WKWebView).map { [$0] } ?? webViews(in: $0) }
        }

        private static func label(for state: ServerController.State) -> String {
            switch state {
            case .notInstalled: return "not-installed"
            case .stopped: return "stopped"
            case .starting: return "starting"
            case .running: return "running"
            case .stopping: return "stopping"
            case .failed: return "failed"
            }
        }
    }
#endif
