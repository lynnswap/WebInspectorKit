import Observation

@MainActor
@Observable
public final class V2_WIRuntimeSession {
    public let dom: V2_WIDOMRuntime
    public let network: V2_WINetworkRuntime

    public init(
        dom: V2_WIDOMRuntime = V2_WIDOMRuntime(),
        network: V2_WINetworkRuntime = V2_WINetworkRuntime()
    ) {
        self.dom = dom
        self.network = network
    }
}
