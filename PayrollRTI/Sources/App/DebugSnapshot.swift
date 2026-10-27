#if DEBUG
    import AppKit
    import Combine
    import WebKit

    /// Debug builds only: `-debugSnapshotDir <dir>` writes a PNG of the main window each time the server state
    /// changes, so the launch flow can be checked (and README screenshots taken) without screen-recording access.
    @MainActor
    enum DebugSnapshot {
        private static var cancellable: AnyCancellable?
        private static var counter = 0

        static func startIfRequested(server: ServerController) {
            guard let path = UserDefaults.standard.string(forKey: "debugSnapshotDir") else { return }
            let directory = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            cancellable = server.$state.removeDuplicates().sink { state in
                counter += 1
                let name = String(format: "%02d-%@.png", counter, label(for: state))
                Task {
                    // Give SwiftUI and the web view time to settle.
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    await capture(to: directory.appendingPathComponent(name))
                }
            }
        }

        static func capture(to url: URL) async {
            guard
                let window = NSApp.windows.filter({ $0.isVisible && $0.title == "Basic PAYE Tools" })
                    .max(by: { $0.frame.width < $1.frame.width }),
                let view = window.contentView,
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
