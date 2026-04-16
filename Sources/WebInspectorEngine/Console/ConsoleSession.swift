import Foundation
import WebKit

@MainActor
public final class ConsoleSession: PageSession {
    public typealias AttachmentResult = Void

    private let runtime: WIConsoleRuntime

    public var store: ConsoleStore {
        runtime.store
    }

    public private(set) weak var lastPageWebView: WKWebView?

    package var backendSupport: WIBackendSupport {
        runtime.backendSupport
    }

    package var hasAttachedPageWebView: Bool {
        runtime.hasAttachedPageWebView
    }

    package init(runtime: WIConsoleRuntime) {
        self.runtime = runtime
        self.lastPageWebView = runtime.lastPageWebView
    }

    public func attach(pageWebView webView: WKWebView) async {
        await runtime.attach(pageWebView: webView)
        lastPageWebView = runtime.lastPageWebView
    }

    public func suspend() async {
        await runtime.suspend()
        lastPageWebView = runtime.lastPageWebView
    }

    public func detach() async {
        await runtime.detach()
        lastPageWebView = runtime.lastPageWebView
    }

    public func clear() async {
        await runtime.clearConsole()
    }

    public func evaluate(_ expression: String) async {
        await runtime.evaluate(expression)
    }

    package func tearDownForDeinit() {
        runtime.tearDownForDeinit()
        lastPageWebView = runtime.lastPageWebView
    }
}
