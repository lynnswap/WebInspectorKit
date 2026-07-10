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
    public enum Kind: Sendable {
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

    private var endpoint: DomainEndpoint {
        DomainEndpoint(proxy: proxy, targetID: id, route: route)
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
