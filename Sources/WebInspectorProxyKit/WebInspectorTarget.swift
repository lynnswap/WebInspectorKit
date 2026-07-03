import Foundation

public struct FrameID: Hashable, Sendable {
    package let rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

package struct RoutingTargetID: Hashable, Sendable {
    package let rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct WebInspectorTarget: Identifiable, Sendable {
    public struct ID: Hashable, Sendable {
        package let rawValue: String

        package init(_ rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public enum Kind: Sendable {
        case page
        case frame
        case worker
        case serviceWorker
    }

    public let id: ID
    public let kind: Kind
    public let frameID: FrameID?
    public let isProvisional: Bool

    package let proxy: WebInspectorProxy
    package let route: RoutingTargetID

    package init(
        id: ID,
        kind: Kind,
        frameID: FrameID?,
        isProvisional: Bool,
        proxy: WebInspectorProxy,
        route: RoutingTargetID
    ) {
        self.id = id
        self.kind = kind
        self.frameID = frameID
        self.isProvisional = isProvisional
        self.proxy = proxy
        self.route = route
    }

    public var dom: DOM.Client {
        DOM.Client(context: DomainClientContext(proxy: proxy, targetID: id, route: route))
    }

    public var css: CSS.Client {
        CSS.Client(context: DomainClientContext(proxy: proxy, targetID: id, route: route))
    }

    public var network: Network.Client {
        Network.Client(context: DomainClientContext(proxy: proxy, targetID: id, route: route))
    }

    public var console: Console.Client {
        Console.Client(context: DomainClientContext(proxy: proxy, targetID: id, route: route))
    }

    public var runtime: Runtime.Client {
        Runtime.Client(context: DomainClientContext(proxy: proxy, targetID: id, route: route))
    }

    public var page: Page.Client {
        Page.Client(context: DomainClientContext(proxy: proxy, targetID: id, route: route))
    }

    package func waitForModelEventSubscriptions() async {
        for domain in [WebInspectorProxyEventDomain.dom, .inspector, .css, .network, .console, .runtime] {
            await proxy.waitForEventSubscription(targetID: id, route: route, domain: domain)
        }
    }
}

package struct DomainClientContext: Sendable {
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

    package func dispatchVoid<Payload: Sendable>(
        domain: WebInspectorProxyDomain,
        method: String,
        payload: Payload
    ) async throws {
        let _: Void = try await dispatch(
            domain: domain,
            method: method,
            payload: payload,
            returning: Void.self
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
