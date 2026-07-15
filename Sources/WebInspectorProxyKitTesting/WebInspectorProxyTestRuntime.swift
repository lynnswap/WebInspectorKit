import WebInspectorProxyKit

/// A production-path ProxyKit runtime controlled by a raw WebKit test peer.
///
/// The runtime is the explicit resource owner for tests. Call ``close()`` and
/// await its completion before releasing the runtime.
public struct WebInspectorProxyTestRuntime: Sendable {
    /// The real ProxyKit connection driven through `ConnectionCore`.
    public let proxy: WebInspectorProxy

    /// The raw-wire WebKit peer attached below `ConnectionCore`.
    public let peer: WebInspectorTestPeer

    /// The stable logical page created by the proxy.
    public let page: WebInspectorPage

    /// Starts a production-path proxy and installs one initial physical page
    /// target through a raw `Target.targetCreated` event.
    public static func start(
        configuration: WebInspectorProxy.Configuration = .init(),
        initialTarget: WebInspectorTestPeer.Target = .initialPage
    ) async throws -> WebInspectorProxyTestRuntime {
        try await start(
            configuration: configuration,
            initialTarget: initialTarget,
            protocolProfile: .latest
        )
    }

    package static func start(
        configuration: WebInspectorProxy.Configuration = .init(),
        initialTarget: WebInspectorTestPeer.Target = .initialPage,
        protocolProfile: WebInspectorProtocolProfile
    ) async throws -> WebInspectorProxyTestRuntime {
        let peer = WebInspectorTestPeer()
        let core = await peer.makeConnection(
            configuration: configuration,
            protocolProfile: protocolProfile
        )
        do {
            try await peer.createTarget(initialTarget)
            let proxy = try await WebInspectorProxy(
                connection: core,
                configuration: configuration
            )
            return WebInspectorProxyTestRuntime(
                proxy: proxy,
                peer: peer,
                page: proxy.page
            )
        } catch {
            await core.close()
            throw error
        }
    }

    /// Closes the owned proxy connection and waits for peer detachment.
    public func close() async {
        await proxy.close()
    }

    private init(
        proxy: WebInspectorProxy,
        peer: WebInspectorTestPeer,
        page: WebInspectorPage
    ) {
        self.proxy = proxy
        self.peer = peer
        self.page = page
    }
}
