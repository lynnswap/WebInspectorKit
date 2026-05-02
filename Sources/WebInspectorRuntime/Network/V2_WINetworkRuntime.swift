import Observation
import WebKit
import WebInspectorEngine
import WebInspectorTransport

@MainActor
@Observable
public final class V2_WINetworkRuntime {
    @ObservationIgnored package let model: WINetworkModel

    public var entries: [NetworkEntry] {
        model.store.entries
    }

    public convenience init(
        configuration: NetworkConfiguration = .init(),
        dependencies: WIInspectorDependencies = .liveValue
    ) {
        self.init(
            configuration: configuration,
            dependencies: dependencies,
            sharedTransport: dependencies.makeSharedTransport()
        )
    }

    package init(
        configuration: NetworkConfiguration,
        dependencies: WIInspectorDependencies = .liveValue,
        sharedTransport: WISharedInspectorTransport
    ) {
        let backend = WIBackendFactory.makeNetworkBackend(
            configuration: configuration,
            supportSnapshot: dependencies.transport.supportSnapshot(),
            sharedTransport: sharedTransport
        ) {
            NetworkPageAgent(dependencies: dependencies.makeNetworkPageAgentDependencies())
        }
        let session = NetworkSession(
            configuration: configuration,
            backend: backend
        )
        model = WINetworkModel(session: session)
    }

    public func attach(to webView: WKWebView) async {
        await model.attach(to: webView)
        await model.setMode(.active)
    }

    public func detach() async {
        await model.detach()
    }
}
