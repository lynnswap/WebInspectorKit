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

public struct WebViewTarget: Identifiable, Sendable {
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

    package let proxy: WebViewProxy
    package let route: RoutingTargetID

    package init(
        id: ID,
        kind: Kind,
        frameID: FrameID?,
        isProvisional: Bool,
        proxy: WebViewProxy,
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
        DOM.Client(context: DomainClientContext(proxy: proxy, targetID: id))
    }

    public var css: CSS.Client {
        CSS.Client(context: DomainClientContext(proxy: proxy, targetID: id))
    }

    public var network: Network.Client {
        Network.Client(context: DomainClientContext(proxy: proxy, targetID: id))
    }

    public var console: Console.Client {
        Console.Client(context: DomainClientContext(proxy: proxy, targetID: id))
    }

    public var runtime: Runtime.Client {
        Runtime.Client(context: DomainClientContext(proxy: proxy, targetID: id))
    }

    public var page: Page.Client {
        Page.Client(context: DomainClientContext(proxy: proxy, targetID: id))
    }
}

package struct DomainClientContext: Sendable {
    package let proxy: WebViewProxy
    package let targetID: WebViewTarget.ID

    package init(proxy: WebViewProxy, targetID: WebViewTarget.ID) {
        self.proxy = proxy
        self.targetID = targetID
    }
}
