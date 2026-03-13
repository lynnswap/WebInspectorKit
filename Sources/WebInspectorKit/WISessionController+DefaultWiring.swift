import WebInspectorCore
import WebInspectorTransport
import WebInspectorUI

public extension WISessionController {
    convenience init(configuration: WISessionConfiguration = .init()) {
        let domGraphStore = DOMGraphStore()
        let domBackend = WIBackendFactory.makeDOMBackend(
            configuration: configuration.dom,
            graphStore: domGraphStore
        )
        let domRuntime = WIDOMRuntime(
            configuration: configuration.dom,
            graphStore: domGraphStore,
            backend: domBackend
        )
        let domFrontendBridge = WIDOMFrontendRuntime(session: domRuntime)

        let networkBackend = WIBackendFactory.makeNetworkBackend(
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
