import Observation
import WebKit
import WebInspectorEngine
import WebInspectorTransport

@MainActor
@Observable
public final class V2_WINetworkRuntime {
    @ObservationIgnored private let model: WINetworkModel

    public var entries: [NetworkEntry] {
        model.store.entries
    }

    public convenience init(configuration: NetworkConfiguration = .init()) {
        self.init(
            configuration: configuration,
            sharedTransport: WISharedInspectorTransport()
        )
    }

    package init(
        configuration: NetworkConfiguration,
        sharedTransport: WISharedInspectorTransport
    ) {
        let backend = WIBackendFactory.makeNetworkBackend(
            configuration: configuration,
            sharedTransport: sharedTransport
        )
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
