import Observation
import WebKit
import WebInspectorTransport

@MainActor
@Observable
public final class WIRuntimeSession {
    public let dom: WIDOMRuntime
    public let network: WINetworkRuntime

    public convenience init(
        configuration: WIModelConfiguration = .init(),
        dependencies: WIInspectorDependencies = .liveValue
    ) {
        let sharedTransport = dependencies.makeSharedTransport()
        self.init(
            dom: WIDOMRuntime(
                configuration: configuration.dom,
                dependencies: dependencies,
                sharedTransport: sharedTransport
            ),
            network: WINetworkRuntime(
                configuration: configuration.network,
                dependencies: dependencies,
                sharedTransport: sharedTransport
            )
        )
    }

    public init(dom: WIDOMRuntime, network: WINetworkRuntime) {
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
