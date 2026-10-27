import SwiftUI
import WebKit

/// Hosts the BPT web UI served by `rti runserver`.
struct BPTWebView: NSViewRepresentable {
    let url: URL
    let browser: BrowserState

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(home: url, browser: browser)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WebViewCoordinator.printShim)
        configuration.userContentController.addUserScript(WebViewCoordinator.restoreGuard)
        configuration.userContentController.add(context.coordinator, name: WebViewCoordinator.printMessage)
        configuration.preferences.isElementFullscreenEnabled = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.attach(webView)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.load(URLRequest(url: url))
        browser.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        browser.webView = webView
        if context.coordinator.home != url {
            context.coordinator.home = url
            webView.load(URLRequest(url: url))
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: WebViewCoordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: WebViewCoordinator.printMessage)
        coordinator.closePopups()
    }
}
