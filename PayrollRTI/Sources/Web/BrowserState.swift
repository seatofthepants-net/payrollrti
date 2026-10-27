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
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isLoading = webView.isLoading
                    if !webView.isLoading, self.isRestoring {
                        self.isRestoring = false
                        // Normally a fresh page has replaced the guarded one; if not, let the page work again.
                        webView.evaluateJavaScript("window.payrollrtiRestoring = false")
                    }
                }
            }
        }
    }

    /// True while a page is loading, including form posts BPT takes a long time to answer (restoring a backup).
    @Published private(set) var isLoading = false

    /// True from BPT's restore form being posted until that load ends. BPT answers only once the restore is done
    /// (a minute or more), and anything that cancels the request part-way, such as a second click on Restore,
    /// leaves a blank page, so we cover the page and ignore Reload, Back and Forward until then.
    @Published var isRestoring = false

    private var loadingObservation: NSKeyValueObservation?

    var hasWebView: Bool { webView != nil }

    func reload() {
        guard !isRestoring else { return }
        webView?.reload()
    }

    func goBack() {
        guard !isRestoring else { return }
        webView?.goBack()
    }

    func goForward() {
        guard !isRestoring else { return }
        webView?.goForward()
    }

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
