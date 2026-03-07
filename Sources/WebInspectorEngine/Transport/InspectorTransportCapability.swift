@MainActor
package protocol InspectorTransportCapabilityProviding: AnyObject {
    var inspectorTransportCapabilities: Set<InspectorTransportCapability> { get }
}

package enum InspectorTransportCapability: String, Hashable, Sendable {
    case domDomain
    case networkDomain
    case pageTargetRouting
    case remoteFrontendHosting
}
