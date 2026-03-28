import WebInspectorEngine

@MainActor
package enum WIBackendFactory {
    package static func makeNetworkBackend(
        configuration: NetworkConfiguration,
        supportSnapshot: WITransportSupportSnapshot? = nil
    ) -> any WINetworkBackend {
        let resolvedSupport = WIBackendFactoryTesting.networkSupportSnapshotOverride
            ?? supportSnapshot
            ?? WITransportSession().supportSnapshot
        _ = configuration
        guard resolvedSupport.isSupported else {
            return NetworkPageAgent()
        }
        return NetworkTransportDriver(
            initialSupport: resolvedSupport.backendSupport
        )
    }
}

@MainActor
@_spi(Monocly) public enum WIBackendFactoryTesting {
    @TaskLocal public static var networkSupportSnapshotOverride: WITransportSupportSnapshot?

    public static func withPageAgentFallback<T>(
        reason: String = "test override",
        operation: () throws -> T
    ) rethrows -> T {
        try $networkSupportSnapshotOverride.withValue(.unsupported(reason: reason)) {
            try operation()
        }
    }
}
