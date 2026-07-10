import Foundation

package struct DomainEndpoint: Sendable {
    package let proxy: WebInspectorProxy
    package let targetID: WebInspectorTarget.ID
    package let route: RoutingTargetID

    package init(proxy: WebInspectorProxy, targetID: WebInspectorTarget.ID, route: RoutingTargetID) {
        self.proxy = proxy
        self.targetID = targetID
        self.route = route
    }

    package func dispatch<Payload: Sendable, Result: Sendable>(
        domain: WebInspectorProxyDomain,
        method: String,
        payload: Payload,
        returning resultType: Result.Type = Result.self
    ) async throws -> Result {
        _ = resultType
        return try await proxy.dispatchCommand(
            targetID: targetID,
            route: route,
            domain: domain,
            method: method,
            payload: payload
        )
    }

    package func withEvents<Element: Sendable, Output>(
        domain: WebInspectorProxyEventDomain,
        buffering: WebInspectorEventBufferingPolicy,
        isolation: isolated (any Actor)? = #isolation,
        extract: @escaping @Sendable (WebInspectorProxyEvent) -> Element?,
        _ operation: (
            AsyncThrowingStream<WebInspectorPageEvent<Element>, any Error>
        ) async throws -> Output
    ) async throws -> Output {
        guard let backend = proxy.structuredEventBackend else {
            throw unimplementedCommand(domain: domain.rawValue, method: "withEvents")
        }
        return try await withWebInspectorEventScope(
            backend: backend,
            targetID: targetID,
            route: route,
            domain: domain,
            buffering: buffering,
            isolation: isolation,
            extract: extract,
            operation
        )
    }

    package func domEvents() -> AsyncStream<DOM.Event> {
        proxy.domEvents(targetID: targetID, route: route)
    }

    package func cssEvents() -> AsyncStream<CSS.Event> {
        proxy.cssEvents(targetID: targetID, route: route)
    }

    package func networkEvents() -> AsyncStream<Network.Event> {
        proxy.networkEvents(targetID: targetID, route: route)
    }

    package func consoleEvents() -> AsyncStream<Console.Event> {
        proxy.consoleEvents(targetID: targetID, route: route)
    }

    package func runtimeEvents() -> AsyncStream<Runtime.Event> {
        proxy.runtimeEvents(targetID: targetID, route: route)
    }
}

/// Package-owned contract shared by the closed set of Web Inspector domain
/// handles. The protocol is not public because ProxyKit does not support
/// consumer-defined protocol domains.
package protocol WebInspectorDomainHandle: Sendable {
    static var commandDomain: WebInspectorProxyDomain { get }

    var endpoint: DomainEndpoint { get }
}

package extension WebInspectorDomainHandle {
    func dispatch<Payload: Sendable, Result: Sendable>(
        method: String,
        payload: Payload,
        returning resultType: Result.Type = Result.self
    ) async throws -> Result {
        try await endpoint.dispatch(
            domain: Self.commandDomain,
            method: method,
            payload: payload,
            returning: resultType
        )
    }

    func dispatchVoid<Payload: Sendable>(
        method: String,
        payload: Payload
    ) async throws {
        let _: Void = try await dispatch(
            method: method,
            payload: payload,
            returning: Void.self
        )
    }
}

/// Package-owned contract for domain handles that vend structured events.
package protocol WebInspectorEventDomainHandle: WebInspectorDomainHandle {
    associatedtype Event: Sendable

    static var eventDomain: WebInspectorProxyEventDomain { get }

    static func extractEvent(_ event: WebInspectorProxyEvent) -> Event?
}

package extension WebInspectorEventDomainHandle {
    func _withEvents<Output>(
        buffering: WebInspectorEventBufferingPolicy,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: (
            AsyncThrowingStream<WebInspectorPageEvent<Event>, any Error>
        ) async throws -> Output
    ) async throws -> Output {
        try await endpoint.withEvents(
            domain: Self.eventDomain,
            buffering: buffering,
            isolation: isolation,
            extract: Self.extractEvent,
            operation
        )
    }
}
