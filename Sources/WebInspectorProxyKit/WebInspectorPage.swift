import Foundation

/// A stable logical handle for the inspected page.
public struct WebInspectorPage: Sendable {
    public struct Generation: Hashable, Sendable {
        package let rawValue: UInt64
        package init(rawValue: UInt64) { self.rawValue = rawValue }
    }

    package let proxyReference: WebInspectorProxyReference

    package init(proxy: WebInspectorProxy) {
        proxyReference = WebInspectorProxyReference(proxy)
    }

    public var generation: Generation {
        get async throws {
            guard let proxy = proxyReference.resolve() else { throw WebInspectorProxyError.closed }
            return try await proxy.generation()
        }
    }

    public var dom: DOM { DOM(endpoint: endpoint) }
    public var css: CSS { CSS(endpoint: endpoint) }
    public var network: Network { Network(endpoint: endpoint) }
    public var console: Console { Console(endpoint: endpoint) }
    public var runtime: Runtime { Runtime(endpoint: endpoint) }
    public var page: Page { Page(endpoint: endpoint) }

    package func dom(agentTargetID: WebInspectorTarget.ID) -> DOM {
        DOM(
            endpoint: DomainEndpoint(
                proxyReference: proxyReference,
                route: .target(agentTargetID)
            )
        )
    }

    package func orderedScope<Element: Sendable>(
        descriptor: WebInspectorOrderedScopeDescriptor<Element>,
        buffering: WebInspectorEventBufferingPolicy
    ) async throws -> WebInspectorOrderedEventScope<Element> {
        guard let proxy = proxyReference.resolve() else { throw WebInspectorProxyError.closed }
        return try await proxy.openScope(descriptor: descriptor, buffering: buffering)
    }

    private var endpoint: DomainEndpoint {
        DomainEndpoint(proxyReference: proxyReference, route: .currentPage)
    }
}

public enum WebInspectorPageEvent<Element: Sendable>: Sendable {
    /// The current-page binding advanced after this event scope was registered.
    ///
    /// Scope registration does not emit an initial reset. The generation on a
    /// scoped reply or event establishes the scope's initial page identity.
    case reset(WebInspectorPage.Generation)

    /// A protocol event delivered under the accompanying page generation.
    case event(WebInspectorPage.Generation, Element)
}

public struct WebInspectorScopeError: Error {
    public let operationError: any Error
    public let cleanupError: any Error

    public init(operationError: any Error, cleanupError: any Error) {
        self.operationError = operationError
        self.cleanupError = cleanupError
    }
}
