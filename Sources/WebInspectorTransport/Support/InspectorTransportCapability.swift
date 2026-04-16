
@MainActor
package protocol InspectorTransportCapabilityProviding: AnyObject {
    var inspectorTransportCapabilities: Set<InspectorTransportCapability> { get }
    var inspectorTransportSupportSnapshot: WITransportSupportSnapshot? { get }
}

package extension InspectorTransportCapabilityProviding {
    var inspectorTransportSupportSnapshot: WITransportSupportSnapshot? {
        nil
    }
}

package enum InspectorTransportCapability: String, Hashable, Sendable {
    case domDomain
    case networkDomain
    case consoleDomain
    case pageTargetRouting
    case networkBootstrapSnapshot
}
