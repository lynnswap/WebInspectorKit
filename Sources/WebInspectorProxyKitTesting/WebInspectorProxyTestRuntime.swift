import Foundation
import WebInspectorProxyKit

/// In-memory proxy runtime for tests.
public struct WebInspectorProxyTestRuntime: Sendable {
    /// The proxy under test.
    public var proxy: WebInspectorProxy

    /// The controllable backend attached to the proxy.
    public var backend: WebInspectorTestBackend

    /// Creates a test runtime from an existing proxy and backend.
    public init(proxy: WebInspectorProxy, backend: WebInspectorTestBackend) {
        self.proxy = proxy
        self.backend = backend
    }

    /// Starts a proxy backed by ``WebInspectorTestBackend`` and installs a page target.
    public static func start() async throws -> WebInspectorProxyTestRuntime {
        let backend = WebInspectorTestBackend()
        let proxy = WebInspectorProxy(backend: backend)
        _ = await proxy.installTargetForTesting(kind: .page)
        return WebInspectorProxyTestRuntime(proxy: proxy, backend: backend)
    }
}
