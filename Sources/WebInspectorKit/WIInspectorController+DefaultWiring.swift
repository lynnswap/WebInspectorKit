import WebInspectorCore
import WebInspectorTransport
import WebInspectorUI

public extension WIInspectorController {
    convenience init(configuration: WIInspectorConfiguration = .init()) {
        let domGraphStore = DOMGraphStore()
        let domBackend = WIInspectorBackendFactory.makeDOMBackend(
            configuration: configuration.dom,
            graphStore: domGraphStore
        )
        let domRuntime = WIDOMRuntime(
            configuration: configuration.dom,
            graphStore: domGraphStore,
            backend: domBackend
        )
        let domFrontendBridge = WIDOMFrontendRuntime(session: domRuntime)

        let networkBackend = WIInspectorBackendFactory.makeNetworkBackend(
            configuration: configuration.network
        )
        let networkRuntime = WINetworkRuntime(
            configuration: configuration.network,
            backend: networkBackend
        )

        self.init(
            domSession: domRuntime,
            networkSession: networkRuntime,
            domFrontendBridge: domFrontendBridge
        )
    }
}
