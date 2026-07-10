import Foundation

package struct Inspector: Sendable, WebInspectorDomainHandle {
    package static let commandDomain = WebInspectorProxyDomain.inspector

    package let endpoint: DomainEndpoint

    package init(endpoint: DomainEndpoint) {
        self.endpoint = endpoint
    }

    package func enable() async throws {
        try await dispatchVoid(
            method: "enable",
            payload: EnablePayload()
        )
    }

    package func disable() async throws {
        try await dispatchVoid(
            method: "disable",
            payload: DisablePayload()
        )
    }

    package func initialized() async throws {
        try await dispatchVoid(
            method: "initialized",
            payload: InitializedPayload()
        )
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

    package struct EventOrigin: Sendable {
        package let targetID: WebInspectorTarget.ID
        package let route: RoutingTargetID

        package init(targetID: WebInspectorTarget.ID, route: RoutingTargetID) {
            self.targetID = targetID
            self.route = route
        }
    }

    package enum Event: Sendable {
        case inspect(Runtime.RemoteObject, hints: Runtime.JSONValue?, origin: EventOrigin?)
        case unknown(RawEvent)
    }
}
