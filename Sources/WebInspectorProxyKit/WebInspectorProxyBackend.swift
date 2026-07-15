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

    package init(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID,
        domain: WebInspectorProxyDomain,
        method: String,
        payload: Payload
    ) {
        self.targetID = targetID
        self.route = route
        self.domain = domain
        self.method = method
        self.payload = payload
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
    ) async throws -> Result

    nonisolated func events(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain
    ) -> AsyncStream<WebInspectorProxyEvent>

    func waitForEventSubscription(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain
    ) async
}
