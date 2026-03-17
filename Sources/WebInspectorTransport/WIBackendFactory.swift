import WebInspectorEngine

@MainActor
package enum WIBackendFactory {
    package static func makeNetworkBackend(
        configuration: NetworkConfiguration,
        supportSnapshot: WITransportSupportSnapshot? = nil
    ) -> any WINetworkBackend {
        _ = configuration
        let resolvedSupport = supportSnapshot ?? WITransportSession().supportSnapshot
        return NetworkTransportDriver(
            initialSupport: resolvedSupport.backendSupport
        )
    }
}
