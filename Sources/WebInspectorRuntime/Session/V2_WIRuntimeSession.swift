import Foundation
import Observation

public enum V2_WIRuntimeLifecycle: String, Sendable {
    case active
    case suspended
    case disconnected
}

@MainActor
@Observable
public final class V2_WIRuntimeSession {
    public let dom: V2_WIDOMRuntime
    public let network: V2_WINetworkRuntime
    public var lifecycle: V2_WIRuntimeLifecycle

    public init(
        dom: V2_WIDOMRuntime = V2_WIDOMRuntime(),
        network: V2_WINetworkRuntime = V2_WINetworkRuntime(),
        lifecycle: V2_WIRuntimeLifecycle = .disconnected
    ) {
        self.dom = dom
        self.network = network
        self.lifecycle = lifecycle
    }
}
