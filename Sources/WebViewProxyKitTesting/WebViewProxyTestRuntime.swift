import Foundation
import WebViewProxyKit

public struct WebViewProxyTestRuntime: Sendable {
    public var proxy: WebViewProxy
    public var backend: WebViewTestBackend

    public init(proxy: WebViewProxy, backend: WebViewTestBackend) {
        self.proxy = proxy
        self.backend = backend
    }

    public static func start() async throws -> WebViewProxyTestRuntime {
        let backend = WebViewTestBackend()
        let proxy = WebViewProxy(backend: backend)
        _ = await proxy.installTargetForTesting(kind: .page)
        return WebViewProxyTestRuntime(proxy: proxy, backend: backend)
    }
}
