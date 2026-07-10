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
/// Targets vend domain handles such as ``dom``, ``network``, and ``runtime``.
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
    public enum Kind: Equatable, Sendable {
        /// A top-level page target.
        case page

        /// A frame target.
        case frame

        /// A worker target.
        case worker

        /// A service worker target.
        case serviceWorker
    }

    /// The target identity used by typed domain handles.
    public let id: ID

    /// The backend target kind.
    public let kind: Kind

    /// The frame identifier for frame-backed targets.
    public let frameID: FrameID?

    /// A Boolean value indicating whether the target is provisional during
    /// navigation.
    public let isProvisional: Bool

    package let proxyReference: WebInspectorProxyReference
    package let route: RoutingTargetID
    package let pageBindingID: String?
    package let authority: WebInspectorCommandAuthority

    package var proxy: WebInspectorProxy {
        guard let proxy = proxyReference.resolve() else {
            preconditionFailure("A package-only binding check outlived its WebInspectorProxy owner.")
        }
        return proxy
    }

    package init(
        id: ID,
        kind: Kind,
        frameID: FrameID?,
        isProvisional: Bool,
        proxy: WebInspectorProxy,
        route: RoutingTargetID,
        pageBindingID: String? = nil,
        authority: WebInspectorCommandAuthority = .direct
    ) {
        self.id = id
        self.kind = kind
        self.frameID = frameID
        self.isProvisional = isProvisional
        proxyReference = WebInspectorProxyReference(proxy)
        self.route = route
        self.pageBindingID = pageBindingID
        self.authority = authority
    }

    private init(
        id: ID,
        kind: Kind,
        frameID: FrameID?,
        isProvisional: Bool,
        proxyReference: WebInspectorProxyReference,
        route: RoutingTargetID,
        pageBindingID: String?,
        authority: WebInspectorCommandAuthority
    ) {
        self.id = id
        self.kind = kind
        self.frameID = frameID
        self.isProvisional = isProvisional
        self.proxyReference = proxyReference
        self.route = route
        self.pageBindingID = pageBindingID
        self.authority = authority
    }

    package func withPageBinding(from lifecycleTarget: WebInspectorLifecycleTarget) -> WebInspectorTarget {
        WebInspectorTarget(
            id: id,
            kind: lifecycleTarget.kind,
            frameID: lifecycleTarget.frameID,
            isProvisional: lifecycleTarget.isProvisional,
            proxyReference: proxyReference,
            route: route,
            pageBindingID: lifecycleTarget.pageBindingID,
            authority: authority
        )
    }

    /// A target-scoped handle for DOM protocol commands and events.
    public var dom: DOM {
        DOM(endpoint: endpoint)
    }

    /// A target-scoped handle for CSS protocol commands and events.
    public var css: CSS {
        CSS(endpoint: endpoint)
    }

    /// A target-scoped handle for Network protocol commands and events.
    public var network: Network {
        Network(endpoint: endpoint)
    }

    /// A target-scoped handle for Console protocol commands and events.
    public var console: Console {
        Console(endpoint: endpoint)
    }

    /// A target-scoped handle for Runtime protocol commands and events.
    public var runtime: Runtime {
        Runtime(endpoint: endpoint)
    }

    /// A target-scoped handle for Page protocol commands.
    public var page: Page {
        Page(endpoint: endpoint)
    }

    package var inspector: Inspector {
        Inspector(endpoint: endpoint)
    }

    package var lifecycleEvents: AsyncStream<WebInspectorTargetLifecycleEvent> {
        guard let proxy = proxyReference.resolve() else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        return proxy.targetLifecycleEvents(targetID: id, route: route)
    }

    package var targetedConsoleEvents: AsyncStream<Console.TargetedEvent> {
        guard let proxy = proxyReference.resolve() else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        return proxy.targetedConsoleEvents(targetID: id, route: route)
    }

    package func waitForModelEventSubscriptions() async {
        guard let proxy = proxyReference.resolve() else {
            return
        }
        for domain in [WebInspectorProxyEventDomain.dom, .inspector, .css, .network, .console, .runtime] {
            await proxy.waitForEventSubscription(targetID: id, route: route, domain: domain)
        }
    }

    private var endpoint: DomainEndpoint {
        DomainEndpoint(
            proxyReference: proxyReference,
            targetID: id,
            route: route,
            authority: authority
        )
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

    nonisolated func modelTarget(
        _ target: ModelTarget,
        authorization: ConnectionModelCommandAuthorization
    ) -> WebInspectorTarget {
        WebInspectorTarget(
            id: target.id,
            kind: target.kind,
            frameID: target.frameID,
            isProvisional: false,
            proxy: self,
            route: RoutingTargetID(target.id.rawValue),
            authority: .modelFeed(authorization)
        )
    }
}
