import WebInspectorEngine

public struct WISessionConfiguration: Sendable {
    public var dom: DOMConfiguration
    public var network: NetworkConfiguration

    public init(dom: DOMConfiguration = .init(), network: NetworkConfiguration = .init()) {
        self.dom = dom
        self.network = network
    }
}
