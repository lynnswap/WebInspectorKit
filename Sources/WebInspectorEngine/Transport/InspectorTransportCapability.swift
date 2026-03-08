import WebInspectorTransport

@MainActor
package protocol InspectorTransportCapabilityProviding: AnyObject {
    var inspectorTransportCapabilities: Set<InspectorTransportCapability> { get }
    var inspectorTransportSupportSnapshot: WITransportSupportSnapshot? { get }
}

extension InspectorTransportCapabilityProviding {
    var inspectorTransportSupportSnapshot: WITransportSupportSnapshot? {
        nil
    }
}

package enum InspectorTransportCapability: String, Hashable, Sendable {
    case domDomain
    case networkDomain
    case pageTargetRouting
    case remoteFrontendHosting
}
