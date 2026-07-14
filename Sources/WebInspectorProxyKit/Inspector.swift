import Foundation

package struct Inspector: Sendable, WebInspectorEventDomainHandle {
    package static let eventDecoder = InspectorWireCoding.eventDecoder
    package static let eventCapability = InspectorWireCoding.capability

    package let endpoint: DomainEndpoint

    package init(endpoint: DomainEndpoint) {
        self.endpoint = endpoint
    }

    package func enable() async throws {
        try await endpoint.dispatch(InspectorWireCoding.enable)
    }

    package func disable() async throws {
        try await endpoint.dispatch(InspectorWireCoding.disable)
    }

    package func initialized() async throws {
        try await endpoint.dispatch(InspectorWireCoding.initialized)
    }

    package struct EnablePayload: Sendable {
        package init() {}
    }

    package struct DisablePayload: Sendable {
        package init() {}
    }

    package struct InitializedPayload: Sendable {
        package init() {}
    }

    package enum Event: Sendable {
        case inspect(Runtime.RemoteObject, hints: Runtime.JSONValue?)
        case unknown(RawEvent)
    }
}
