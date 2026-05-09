import WebInspectorEngine

@MainActor
package enum WIBackendFactory {
    package static func makeNetworkBackend(
        configuration: NetworkConfiguration,
        supportSnapshot: WITransportSupportSnapshot? = nil,
        sharedTransport: WISharedInspectorTransport? = nil
    ) -> any WINetworkBackend {
        let resolvedSupport = WIBackendFactoryTesting.networkSupportSnapshotOverride
            ?? supportSnapshot
            ?? WITransportSession().supportSnapshot
        guard resolvedSupport.isSupported else {
            return WINetworkUnsupportedBackend(
                reason: resolvedSupport.failureReason ?? "WebInspectorTransport is unsupported."
            )
        }
        return NetworkTransportDriver(
            sharedTransport: sharedTransport,
            initialSupport: resolvedSupport.backendSupport
        )
    }
}

@MainActor
@_spi(Monocly) public enum WIBackendFactoryTesting {
    @TaskLocal public static var networkSupportSnapshotOverride: WITransportSupportSnapshot?

    public static func withNetworkSupportSnapshotOverride<T>(
        _ supportSnapshot: WITransportSupportSnapshot,
        operation: () throws -> T
    ) rethrows -> T {
        try $networkSupportSnapshotOverride.withValue(supportSnapshot) {
            try operation()
        }
    }
}
