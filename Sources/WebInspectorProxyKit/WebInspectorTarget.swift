import Foundation

/// A WebKit frame identifier reported by the inspector protocol.
public struct FrameID: Hashable, Sendable {
    package let rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

package struct RoutingTargetID: Hashable, Sendable {
    package enum Storage: Hashable, Sendable {
        case target(String)
        case currentPage
    }

    package let storage: Storage

    package static let currentPage = RoutingTargetID(storage: .currentPage)

    package init(_ rawValue: String) {
        storage = .target(rawValue)
    }

    private init(storage: Storage) {
        self.storage = storage
    }

    package var rawValue: String {
        switch storage {
        case let .target(rawValue):
            rawValue
        case .currentPage:
            preconditionFailure("The current-page route has no fixed target identifier.")
        }
    }
}

/// A typed handle for a Web Inspector protocol target.
///
/// Targets vend domain clients such as ``dom``, ``network``, and ``runtime``.
/// Keep the target that DataKit or ProxyKit gives you instead of constructing
/// transport target identifiers yourself.
public struct WebInspectorTarget: Identifiable, Sendable {
    /// Stable identity for a protocol target within one proxy connection.
    public struct ID: Hashable, Sendable {
        package let rawValue: String

        package init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        package static let currentPage = ID("current-page")
    }

    /// The kind of backend target represented by a ``WebInspectorTarget``.
    public enum Kind: Sendable {
        case page
        case frame
        case worker
        case serviceWorker
    }

    /// The target identity used by typed domain clients.
    public let id: ID

    /// The backend target kind.
    public let kind: Kind

    /// The frame identifier for frame-backed targets.
    public let frameID: FrameID?

    /// A Boolean value indicating whether the target is provisional during
    /// navigation.
    public let isProvisional: Bool

    package let proxy: WebInspectorProxy
    package let route: RoutingTargetID
    package let pageBindingID: String?

    package init(
        id: ID,
        kind: Kind,
        frameID: FrameID?,
        isProvisional: Bool,
        proxy: WebInspectorProxy,
        route: RoutingTargetID,
        pageBindingID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.frameID = frameID
        self.isProvisional = isProvisional
        self.proxy = proxy
        self.route = route
        self.pageBindingID = pageBindingID
    }

    package func withPageBinding(from lifecycleTarget: WebInspectorLifecycleTarget) -> WebInspectorTarget {
        WebInspectorTarget(
            id: id,
            kind: lifecycleTarget.kind,
            frameID: lifecycleTarget.frameID,
            isProvisional: lifecycleTarget.isProvisional,
            proxy: proxy,
            route: route,
            pageBindingID: lifecycleTarget.pageBindingID
        )
    }

    /// A typed client for DOM protocol commands and events.
    public var dom: DOM.Client {
        DOM.Client(context: DomainClientContext(proxy: proxy, targetID: id, route: route))
    }

    /// A typed client for CSS protocol commands and events.
    public var css: CSS.Client {
        CSS.Client(context: DomainClientContext(proxy: proxy, targetID: id, route: route))
    }

    /// A typed client for Network protocol commands and events.
    public var network: Network.Client {
        Network.Client(context: DomainClientContext(proxy: proxy, targetID: id, route: route))
    }

    /// A typed client for Console protocol commands and events.
    public var console: Console.Client {
        Console.Client(context: DomainClientContext(proxy: proxy, targetID: id, route: route))
    }

    /// A typed client for Runtime protocol commands and events.
    public var runtime: Runtime.Client {
        Runtime.Client(context: DomainClientContext(proxy: proxy, targetID: id, route: route))
    }

    /// A typed client for Page protocol commands.
    public var page: Page.Client {
        Page.Client(context: DomainClientContext(proxy: proxy, targetID: id, route: route))
    }

    package var inspector: Inspector.Client {
        Inspector.Client(context: DomainClientContext(proxy: proxy, targetID: id, route: route))
    }

    package var lifecycleEvents: AsyncStream<WebInspectorTargetLifecycleEvent> {
        proxy.targetLifecycleEvents(targetID: id, route: route)
    }

    package var targetedConsoleEvents: AsyncStream<Console.TargetedEvent> {
        proxy.targetedConsoleEvents(targetID: id, route: route)
    }

    package func waitForModelEventSubscriptions() async {
        for domain in [WebInspectorProxyEventDomain.dom, .inspector, .css, .network, .console, .runtime] {
            await proxy.waitForEventSubscription(targetID: id, route: route, domain: domain)
        }
    }
}

package extension WebInspectorProxy {
    nonisolated func frameTarget(id: WebInspectorTarget.ID) -> WebInspectorTarget {
        WebInspectorTarget(
            id: id,
            kind: .frame,
            frameID: nil,
            isProvisional: false,
            proxy: self,
            route: RoutingTargetID(id.rawValue)
        )
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
