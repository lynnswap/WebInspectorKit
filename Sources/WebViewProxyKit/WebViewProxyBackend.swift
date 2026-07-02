import Foundation

package enum WebViewProxyDomain: String, Hashable, Sendable {
    case dom = "DOM"
    case css = "CSS"
    case network = "Network"
    case console = "Console"
    case runtime = "Runtime"
    case page = "Page"
}

package enum WebViewProxyEventDomain: String, Hashable, Sendable {
    case dom = "DOM"
    case css = "CSS"
    case network = "Network"
    case console = "Console"
    case runtime = "Runtime"
}

package struct WebViewProxyCommand<Payload: Sendable, Result: Sendable>: Sendable {
    package let targetID: WebViewTarget.ID
    package let route: RoutingTargetID
    package let domain: WebViewProxyDomain
    package let method: String
    package let payload: Payload

    package init(
        targetID: WebViewTarget.ID,
        route: RoutingTargetID,
        domain: WebViewProxyDomain,
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

package enum WebViewProxyEvent: Sendable {
    case dom(DOM.Event)
    case css(CSS.Event)
    case network(Network.Event)
    case console(Console.Event)
    case runtime(Runtime.Event)
}

package protocol WebViewProxyBackend: Sendable {
    func dispatchCommand<Payload: Sendable, Result: Sendable>(
        _ command: WebViewProxyCommand<Payload, Result>
    ) async throws -> Result

    nonisolated func events(
        route: RoutingTargetID,
        targetID: WebViewTarget.ID,
        domain: WebViewProxyEventDomain
    ) -> AsyncStream<WebViewProxyEvent>
}
