import WebInspectorEngine

@MainActor
package enum WIBackendFactory {
    package static func makeNetworkBackend(
        configuration: NetworkConfiguration,
        supportSnapshot: WITransportSupportSnapshot? = nil
    ) -> any WINetworkBackend {
        let resolvedSupport = supportSnapshot ?? WITransportSession().supportSnapshot
        _ = configuration
        guard resolvedSupport.isSupported else {
            return NetworkPageAgent()
        }
        return NetworkTransportDriver(
            initialSupport: resolvedSupport.backendSupport
        )
    }
}
