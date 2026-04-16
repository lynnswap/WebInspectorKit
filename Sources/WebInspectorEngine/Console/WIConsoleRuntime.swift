import Foundation
import WebKit

@MainActor
package final class WIConsoleRuntime {
    package let store: ConsoleStore
    package private(set) weak var lastPageWebView: WKWebView?
    private var lastPageURL: String?

    private let backend: any WIConsoleBackend

    package init(backend: any WIConsoleBackend) {
        self.backend = backend
        self.store = backend.store
    }

    package var hasAttachedPageWebView: Bool {
        backend.webView != nil
    }

    package var backendSupport: WIBackendSupport {
        backend.support
    }

    package func attach(pageWebView webView: WKWebView) async {
        if lastPageWebView === webView,
           lastPageURL != webView.url?.absoluteString {
            await backend.clearConsole()
        }
        await backend.attachPageWebView(webView)
        lastPageWebView = webView
        lastPageURL = webView.url?.absoluteString
    }

    package func suspend() async {
        await backend.detachPageWebView(clearsStoreOnNextAttach: false)
    }

    package func detach() async {
        await backend.detachPageWebView(clearsStoreOnNextAttach: true)
        lastPageWebView = nil
        lastPageURL = nil
    }

    package func clearConsole() async {
        await backend.clearConsole()
    }

    package func evaluate(_ expression: String) async {
        await backend.evaluate(expression)
    }

    package func tearDownForDeinit() {
        backend.tearDownForDeinit()
        lastPageWebView = nil
        lastPageURL = nil
    }
}
