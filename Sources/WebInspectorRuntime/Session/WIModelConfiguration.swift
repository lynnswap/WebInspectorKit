import WebInspectorEngine

public struct WIModelConfiguration: Sendable {
    public var network: NetworkConfiguration

    public init(network: NetworkConfiguration = .init()) {
        self.network = network
    }
}
