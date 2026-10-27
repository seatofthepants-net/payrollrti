import AppKit
import WebKit

/// Lets menu commands reach whichever web view is currently showing BPT.
@MainActor
final class BrowserState: ObservableObject {
    weak var webView: WKWebView? {
        didSet {
            guard webView !== oldValue else { return }
            loadingObservation = webView?.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                // Hop off the KVO callout so we never publish in the middle of a SwiftUI view update.
                DispatchQueue.main.async { self?.isLoading = webView.isLoading }
            }
        }
    }

    /// True while a page is loading, including form posts BPT takes a long time to answer (restoring a backup).
    @Published private(set) var isLoading = false

    private var loadingObservation: NSKeyValueObservation?

    var hasWebView: Bool { webView != nil }

    func reload() { webView?.reload() }

    func goBack() { webView?.goBack() }

    func goForward() { webView?.goForward() }

    func zoomIn() { webView.map { $0.pageZoom = min($0.pageZoom + 0.1, 3) } }

    func zoomOut() { webView.map { $0.pageZoom = max($0.pageZoom - 0.1, 0.5) } }

    func resetZoom() { webView?.pageZoom = 1 }

    func print() {
        if let webView { Self.print(webView) }
    }

    /// Shows the standard print sheet, which also offers "Save as PDF". HMRC note BPT can't print directly
    /// to a printer, so PDF is how P45s, P60s and payslips get out of it.
    static func print(_ webView: WKWebView) {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.view?.frame = webView.bounds
        if let window = webView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}
