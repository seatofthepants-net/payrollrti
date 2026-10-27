import AppKit
import WebKit

/// Gives the embedded BPT the browser behaviour it expects: JavaScript dialogs, file pickers, downloads,
/// `window.print()`, pop-up windows, and external links opening in the user's browser.
@MainActor
final class WebViewCoordinator: NSObject {
    static let printMessage = "payrollrtiPrint"

    /// WKWebView ignores `window.print()` on macOS, so route it to a native print sheet instead.
    static let printShim = WKUserScript(
        source: "window.print = function () { window.webkit.messageHandlers.\(printMessage).postMessage(null); };",
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false)

    /// BPT's "Restore your data" form posts back to this page.
    static let restorePath = "/bptrti/restore"

    /// Once the restore form is submitted, swallows further clicks and submissions on the page. A second click on
    /// Restore makes WebKit drop the first request (BPT logs a broken pipe, though its restore carries on) and the
    /// "restore in progress" reply to the second ends up as a blank page. This has to happen in the page: by the
    /// time the navigation delegate hears about the second submission, the first has already been cancelled.
    /// Cleared by `BrowserState` when the load ends; a new page starts afresh anyway.
    static let restoreGuard = WKUserScript(
        source: """
            (function () {
              var busy = function (e) {
                if (window.payrollrtiRestoring) { e.preventDefault(); e.stopImmediatePropagation(); }
              };
              document.addEventListener('click', busy, true);
              document.addEventListener('submit', busy, true);
              window.addEventListener('submit', function (e) {
                var form = e.target;
                if (e.defaultPrevented || !form || (form.method || '').toLowerCase() !== 'post') { return; }
                var path = new URL(form.action || location.href, location.href).pathname.replace(/\\/$/, '');
                if (path === '\(restorePath)') { window.payrollrtiRestoring = true; }
              });
            })();
            """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true)

    var home: URL
    private weak var browser: BrowserState?
    private var popups: [NSWindow] = []
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    init(home: URL, browser: BrowserState? = nil) {
        self.home = home
        self.browser = browser
    }

    static func isRestoreSubmission(_ request: URLRequest) -> Bool {
        request.httpMethod?.uppercased() == "POST" && request.url?.path == restorePath
    }

    func attach(_ webView: WKWebView) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func closePopups() {
        popups.forEach { $0.close() }
        popups.removeAll()
    }

    /// Anything that isn't the local BPT server opens in the user's real browser (HMRC guidance links etc.).
    func isLocal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        switch scheme {
        case "http", "https":
            return ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
        case "about", "blob", "data":
            return true
        default:
            return false
        }
    }

    private func present(
        _ alert: NSAlert, for webView: WKWebView, completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func makeAlert(_ message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Basic PAYE Tools"
        alert.informativeText = message
        return alert
    }
}

// MARK: - Navigation

extension WebViewCoordinator: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            return decisionHandler(.download)
        }
        if let browser, webView === browser.webView, Self.isRestoreSubmission(navigationAction.request) {
            browser.isRestoring = true
            // The overlay blocks the mouse; this stops Return or Space re-pressing the focused button.
            webView.window?.makeFirstResponder(nil)
        }
        if let url = navigationAction.request.url, !isLocal(url) {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let disposition =
            (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if !navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment") {
            return decisionHandler(.download)
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        report(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error, in: webView)
    }

    /// WKWebView otherwise leaves the old page up with no sign that anything went wrong (e.g. the server stopped
    /// part-way through a form post).
    private func report(_ error: Error, in webView: WKWebView) {
        let error = error as NSError
        // Superseded loads, and responses we turned into downloads, aren't failures.
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain" && error.code == 102 { return }  // frame load interrupted by policy
        let alert = NSAlert(error: error)
        present(alert, for: webView) { _ in }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
}

// MARK: - Downloads (reports, exported PDFs, backups)

extension WebViewCoordinator: WKDownloadDelegate {
    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return completionHandler(nil) }
            // The panel has already confirmed any overwrite; WebKit refuses to replace an existing file.
            try? FileManager.default.removeItem(at: url)
            self?.downloadDestinations[ObjectIdentifier(download)] = url
            completionHandler(url)
        }
        if let window = download.webView?.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        NSAlert(error: error).runModal()
    }
}

// MARK: - UI (dialogs, file pickers, pop-ups)

extension WebViewCoordinator: WKUIDelegate {
    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
    ) {
        let alert = makeAlert(message)
        alert.addButton(withTitle: "OK")
        present(alert, for: webView) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = makeAlert(message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, for: webView) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void
    ) {
        let alert = makeAlert(prompt)
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, for: webView) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let finish: (NSApplication.ModalResponse) -> Void = { completionHandler($0 == .OK ? panel.urls : nil) }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// `target="_blank"` and `window.open()`: external links go to the browser, local ones get their own window
    /// (BPT opens printable forms this way).
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, !isLocal(url) {
            NSWorkspace.shared.open(url)
            return nil
        }
        let width = windowFeatures.width?.doubleValue ?? 900
        let height = windowFeatures.height?.doubleValue ?? 700
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        attach(popup)
        popup.isInspectable = true

        let window = NSWindow(
            contentRect: popup.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Basic PAYE Tools"
        window.contentView = popup
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.popups.removeAll { $0 === note.object as? NSWindow }
            }
        }
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        webView.window?.close()
    }
}

// MARK: - window.print()

extension WebViewCoordinator: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.printMessage, let webView = message.webView else { return }
        BrowserState.print(webView)
    }
}
