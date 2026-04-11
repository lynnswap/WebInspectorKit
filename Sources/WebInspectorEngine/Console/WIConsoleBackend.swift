import WebKit

@MainActor
package protocol WIConsoleBackend: AnyObject {
    var webView: WKWebView? { get }
    var store: ConsoleStore { get }
    var support: WIBackendSupport { get }

    func attachPageWebView(_ newWebView: WKWebView?) async
    func detachPageWebView() async
    func clearConsole() async
    func evaluate(_ expression: String) async
    func tearDownForDeinit()
}
