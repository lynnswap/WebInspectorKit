import Foundation

package enum WebInspectorProxyDomain: String, Hashable, Sendable {
    case dom = "DOM"
    case css = "CSS"
    case network = "Network"
    case console = "Console"
    case runtime = "Runtime"
    case page = "Page"
    case inspector = "Inspector"
}

package enum WebInspectorProxyEventDomain: String, Hashable, Sendable {
    case target = "Target"
    case dom = "DOM"
    case inspector = "Inspector"
    case css = "CSS"
    case network = "Network"
    case console = "Console"
    case runtime = "Runtime"
    case page = "Page"
}

package struct WebInspectorProxyCommand<Payload: Sendable, Result: Sendable>: Sendable {
    package let targetID: WebInspectorTarget.ID
    package let route: RoutingTargetID
    package let domain: WebInspectorProxyDomain
    package let method: String
    package let payload: Payload
    package let authority: WebInspectorCommandAuthority

    package init(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID,
        domain: WebInspectorProxyDomain,
        method: String,
        payload: Payload,
        authority: WebInspectorCommandAuthority = .direct
    ) {
        self.targetID = targetID
        self.route = route
        self.domain = domain
        self.method = method
        self.payload = payload
        self.authority = authority
    }
}

package struct WebInspectorProxyCommandResult<Value: Sendable>: Sendable {
    package let value: Value
    package let receivedSequence: UInt64
    package let receivedDomainSequences: [WebInspectorProxyDomain: UInt64]

    package func receivedSequence(
        for domain: WebInspectorProxyDomain
    ) -> UInt64 {
        receivedDomainSequences[domain] ?? 0
    }
}

package enum WebInspectorProxyEvent: Sendable {
    case targetLifecycle(WebInspectorTargetLifecycleEvent)
    case dom(DOM.Event)
    case inspector(Inspector.Event)
    case css(CSS.Event)
    case network(Network.Event)
    case console(Console.TargetedEvent)
    case runtime(Runtime.Event)
}

package protocol WebInspectorProxyBackend: Sendable {
    func dispatchCommand<Payload: Sendable, Result: Sendable>(
        _ command: WebInspectorProxyCommand<Payload, Result>
    ) async throws -> WebInspectorProxyCommandResult<Result>

    func acquireEventScope<Element: Sendable>(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain,
        buffering: WebInspectorEventBufferingPolicy,
        extract: @escaping @Sendable (WebInspectorProxyEvent) -> Element?
    ) async throws -> WebInspectorProxyEventScope<Element>

    func releaseEventScope(_ id: WebInspectorProxyEventScopeID) async throws
}

package extension WebInspectorProxyBackend {
    func acquireEventScope<Element: Sendable>(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain,
        buffering: WebInspectorEventBufferingPolicy,
        extract: @escaping @Sendable (WebInspectorProxyEvent) -> Element?
    ) async throws -> WebInspectorProxyEventScope<Element> {
        _ = route
        _ = targetID
        _ = buffering
        _ = extract
        throw WebInspectorProxyError.commandFailed(
            domain: domain.rawValue,
            method: "withEvents",
            message: "This backend does not implement structured event scopes."
        )
    }

    func releaseEventScope(_ id: WebInspectorProxyEventScopeID) async throws {
        _ = id
    }
}
