import Foundation

package struct Inspector: Sendable, WebInspectorEventDomainHandle {
    package static let commandDomain = WebInspectorProxyDomain.inspector
    package static let eventDomain = WebInspectorProxyEventDomain.inspector

    package let endpoint: DomainEndpoint

    package init(endpoint: DomainEndpoint) {
        self.endpoint = endpoint
    }

    package static func extractEvent(
        _ event: WebInspectorProxyEvent
    ) -> Event? {
        guard case let .inspector(value) = event else {
            return nil
        }
        return value
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

    package enum Event: Sendable {
        case inspect(Runtime.RemoteObject, hints: Runtime.JSONValue?)
        case unknown(RawEvent)
    }
}
