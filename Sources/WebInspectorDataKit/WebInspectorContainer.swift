import Foundation
import WebKit
import WebInspectorProxyKit

public final class WebInspectorContainer: @unchecked Sendable {
    let proxy: WebInspectorProxy
    let domainEnablement: WebInspectorDomainEnablementRegistry

    @MainActor private var _mainContext: WebInspectorContext?

    @MainActor public var mainContext: WebInspectorContext {
        if let context = _mainContext {
            return context
        }
        let context = WebInspectorContext(self, isolation: MainActor.shared)
        _mainContext = context
        context.start()
        return context
    }

    public init(proxy: WebInspectorProxy) {
        self.proxy = proxy
        domainEnablement = WebInspectorDomainEnablementRegistry()
    }

    @MainActor
    public convenience init(
        attachingTo webView: WKWebView,
        configuration: WebInspectorProxy.Configuration = .init()
    ) async throws {
        let proxy = try await WebInspectorProxy(attachingTo: webView, configuration: configuration)
        self.init(proxy: proxy)
    }

    public func close() async {
        await stopMainContext()
        await proxy.close()
    }

    @MainActor
    private func stopMainContext() async {
        await _mainContext?.stop()
    }
}
