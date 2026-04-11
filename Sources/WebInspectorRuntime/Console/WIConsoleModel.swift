import Foundation
import Observation
import WebKit
import WebInspectorEngine

@MainActor
@Observable
public final class WIConsoleModel {
    package let session: ConsoleSession

    public private(set) var isAttachedToPage = false

    package init(session: ConsoleSession) {
        self.session = session
    }

    public var store: ConsoleStore {
        session.store
    }

    package var backendSupport: WIBackendSupport {
        session.backendSupport
    }

    func attach(to webView: WKWebView) async {
        await session.attach(pageWebView: webView)
        isAttachedToPage = true
    }

    func suspend() async {
        await session.suspend()
        isAttachedToPage = false
    }

    func detach() async {
        await session.detach()
        isAttachedToPage = false
    }

    public func clear() async {
        await session.clear()
    }

    public func evaluate(_ expression: String) async {
        await session.evaluate(expression)
    }
}
