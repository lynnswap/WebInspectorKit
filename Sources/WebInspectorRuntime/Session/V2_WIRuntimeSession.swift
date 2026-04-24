import Observation
import WebKit
import WebInspectorTransport

@MainActor
@Observable
public final class V2_WIRuntimeSession {
    public let dom: V2_WIDOMRuntime
    public let network: V2_WINetworkRuntime

    public convenience init(configuration: WIModelConfiguration = .init()) {
        let sharedTransport = WISharedInspectorTransport()
        self.init(
            dom: V2_WIDOMRuntime(
                configuration: configuration.dom,
                sharedTransport: sharedTransport
            ),
            network: V2_WINetworkRuntime(
                configuration: configuration.network,
                sharedTransport: sharedTransport
            )
        )
    }

    public init(dom: V2_WIDOMRuntime, network: V2_WINetworkRuntime) {
        self.dom = dom
        self.network = network
    }

    public func attach(to webView: WKWebView) async {
        await dom.attach(to: webView)
        await network.attach(to: webView)
    }

    public func detach() async {
        await dom.detach()
        await network.detach()
    }
}
