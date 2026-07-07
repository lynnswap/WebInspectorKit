import Foundation
import WebInspectorProxyKit

public struct WebInspectorProxyTestRuntime: Sendable {
    public var proxy: WebInspectorProxy
    public var backend: WebInspectorTestBackend

    public init(proxy: WebInspectorProxy, backend: WebInspectorTestBackend) {
        self.proxy = proxy
        self.backend = backend
    }

    public static func start() async throws -> WebInspectorProxyTestRuntime {
        let backend = WebInspectorTestBackend()
        let proxy = WebInspectorProxy(backend: backend)
        _ = await proxy.installTargetForTesting(kind: .page)
        return WebInspectorProxyTestRuntime(proxy: proxy, backend: backend)
    }
}
