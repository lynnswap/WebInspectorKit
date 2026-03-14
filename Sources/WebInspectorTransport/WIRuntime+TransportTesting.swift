import WebInspectorCore

package extension WIDOMRuntime {
    convenience init(
        configuration: DOMConfiguration = .init(),
        graphStore: DOMGraphStore = DOMGraphStore(),
        defaultTransportSupportSnapshot: WITransportSupportSnapshot
    ) {
        self.init(
            configuration: configuration,
            graphStore: graphStore,
            backend: WIBackendFactory.makeDOMBackend(
                configuration: configuration,
                graphStore: graphStore,
                supportSnapshot: defaultTransportSupportSnapshot
            )
        )
    }
}

package extension WINetworkRuntime {
    convenience init(
        configuration: NetworkConfiguration = .init(),
        defaultTransportSupportSnapshot: WITransportSupportSnapshot
    ) {
        self.init(
            configuration: configuration,
            backend: WIBackendFactory.makeNetworkBackend(
                configuration: configuration,
                supportSnapshot: defaultTransportSupportSnapshot
            )
        )
    }
}
