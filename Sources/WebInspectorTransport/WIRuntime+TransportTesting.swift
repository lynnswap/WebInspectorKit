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
            backend: WIInspectorBackendFactory.makeDOMBackend(
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
            backend: WIInspectorBackendFactory.makeNetworkBackend(
                configuration: configuration,
                supportSnapshot: defaultTransportSupportSnapshot
            )
        )
    }

    convenience init(
        configuration: NetworkConfiguration = .init(),
        bodyFetcher: any NetworkBodyFetching,
        defaultTransportSupportSnapshot: WITransportSupportSnapshot
    ) {
        if defaultTransportSupportSnapshot.isSupported {
            self.init(
                configuration: configuration,
                backend: WIInspectorBackendFactory.makeNetworkBackend(
                    configuration: configuration,
                    supportSnapshot: defaultTransportSupportSnapshot
                )
            )
        } else {
            self.init(configuration: configuration, bodyFetcher: bodyFetcher)
        }
    }
}
