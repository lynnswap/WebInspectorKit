import WebInspectorCore

@MainActor
package enum WIBackendFactory {
    package static func makeDOMBackend(
        configuration: DOMConfiguration,
        graphStore: DOMGraphStore,
        supportSnapshot: WITransportSupportSnapshot? = nil
    ) -> any WIDOMBackend {
        let resolvedSupport = supportSnapshot ?? WITransportSession().supportSnapshot
        return DOMTransportDriver(
            configuration: configuration,
            graphStore: graphStore,
            initialSupport: resolvedSupport.backendSupport
        )
    }

    package static func makeNetworkBackend(
        configuration: NetworkConfiguration,
        supportSnapshot: WITransportSupportSnapshot? = nil
    ) -> any WINetworkBackend {
        let resolvedSupport = supportSnapshot ?? WITransportSession().supportSnapshot
        return NetworkTransportDriver(
            initialSupport: resolvedSupport.backendSupport
        )
    }
}
