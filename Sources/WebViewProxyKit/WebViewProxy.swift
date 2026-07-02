import Foundation
import WebKit

public actor WebViewProxy {
    public struct Configuration: Equatable, Sendable {
        public var responseTimeout: Duration
        public var bootstrapTimeout: Duration

        public init(
            responseTimeout: Duration = .seconds(5),
            bootstrapTimeout: Duration = .seconds(5)
        ) {
            self.responseTimeout = responseTimeout
            self.bootstrapTimeout = bootstrapTimeout
        }
    }

    private let configuration: Configuration
    private let backend: (any WebViewProxyBackend)?
    private var pageTarget: WebViewTarget?
    private var targetsByID: [WebViewTarget.ID: WebViewTarget]
    private var nextTargetOrdinal: UInt64
    private var closed: Bool

    @MainActor
    public init(
        attachingTo webView: WKWebView,
        configuration: Configuration = .init()
    ) async throws {
        _ = webView
        self.configuration = configuration
        backend = nil
        pageTarget = nil
        targetsByID = [:]
        nextTargetOrdinal = 0
        closed = false
        throw WebViewProxyError.unsupported([
            "Native WKWebView attachment is not implemented in the WebViewProxyKit shell."
        ])
    }

    package init(
        configuration: Configuration = .init(),
        backend: (any WebViewProxyBackend)? = nil
    ) {
        self.configuration = configuration
        self.backend = backend
        pageTarget = nil
        targetsByID = [:]
        nextTargetOrdinal = 0
        closed = false
    }

    public var currentPage: WebViewTarget? {
        pageTarget
    }

    public nonisolated var targets: WebViewTargetChanges {
        WebViewTargetChanges { [self] in
            AsyncStream<WebViewTargetChange> { continuation in
                Task {
                    let targets = await currentTargetsSnapshot()
                    for target in targets {
                        continuation.yield(.created(target))
                    }
                    continuation.finish()
                }
            }
        }
    }

    public var canReload: Bool {
        pageTarget != nil && closed == false
    }

    public func waitForCurrentPage() async throws -> WebViewTarget {
        if let pageTarget {
            return pageTarget
        }
        throw WebViewProxyError.disconnected("WebViewProxyKit shell has no current page target.")
    }

    public func reload() async throws {
        guard let pageTarget else {
            throw WebViewProxyError.disconnected("WebViewProxyKit shell has no current page target.")
        }
        let _: Void = try await dispatchCommand(
            targetID: pageTarget.id,
            route: pageTarget.route,
            domain: .page,
            method: "reload",
            payload: Page.ReloadPayload(ignoringCache: false)
        )
    }

    public func close() async {
        closed = true
        pageTarget = nil
        targetsByID.removeAll()
    }

    public func waitUntilClosed() async throws {
        guard closed else {
            throw WebViewProxyError.disconnected("WebViewProxyKit shell is not connected.")
        }
    }

    package func installTargetForTesting(
        kind: WebViewTarget.Kind = .page,
        frameID: FrameID? = nil,
        isProvisional: Bool = false
    ) -> WebViewTarget {
        let ordinal = nextTargetOrdinal
        nextTargetOrdinal += 1
        let target = WebViewTarget(
            id: WebViewTarget.ID("test-target-\(ordinal)"),
            kind: kind,
            frameID: frameID,
            isProvisional: isProvisional,
            proxy: self,
            route: RoutingTargetID("test-route-\(ordinal)")
        )
        targetsByID[target.id] = target
        if kind == .page && isProvisional == false {
            pageTarget = target
        }
        return target
    }

    private func currentTargetsSnapshot() -> [WebViewTarget] {
        Array(targetsByID.values)
    }

    package func dispatchCommand<Payload: Sendable, Result: Sendable>(
        targetID: WebViewTarget.ID,
        route: RoutingTargetID,
        domain: WebViewProxyDomain,
        method: String,
        payload: Payload
    ) async throws -> Result {
        guard closed == false else {
            throw WebViewProxyError.closed
        }
        guard let backend else {
            throw unimplementedCommand(domain: domain.rawValue, method: method)
        }
        let command = WebViewProxyCommand<Payload, Result>(
            targetID: targetID,
            route: route,
            domain: domain,
            method: method,
            payload: payload
        )
        return try await backend.dispatchCommand(command)
    }

    package nonisolated func domEvents(
        targetID: WebViewTarget.ID,
        route: RoutingTargetID
    ) -> AsyncStream<DOM.Event> {
        eventStream(targetID: targetID, route: route, domain: .dom) { event in
            guard case let .dom(value) = event else {
                return nil
            }
            return value
        }
    }

    package nonisolated func cssEvents(
        targetID: WebViewTarget.ID,
        route: RoutingTargetID
    ) -> AsyncStream<CSS.Event> {
        eventStream(targetID: targetID, route: route, domain: .css) { event in
            guard case let .css(value) = event else {
                return nil
            }
            return value
        }
    }

    package nonisolated func networkEvents(
        targetID: WebViewTarget.ID,
        route: RoutingTargetID
    ) -> AsyncStream<Network.Event> {
        eventStream(targetID: targetID, route: route, domain: .network) { event in
            guard case let .network(value) = event else {
                return nil
            }
            return value
        }
    }

    package nonisolated func consoleEvents(
        targetID: WebViewTarget.ID,
        route: RoutingTargetID
    ) -> AsyncStream<Console.Event> {
        eventStream(targetID: targetID, route: route, domain: .console) { event in
            guard case let .console(value) = event else {
                return nil
            }
            return value
        }
    }

    package nonisolated func runtimeEvents(
        targetID: WebViewTarget.ID,
        route: RoutingTargetID
    ) -> AsyncStream<Runtime.Event> {
        eventStream(targetID: targetID, route: route, domain: .runtime) { event in
            guard case let .runtime(value) = event else {
                return nil
            }
            return value
        }
    }

    package nonisolated func waitForEventSubscription(
        targetID: WebViewTarget.ID,
        route: RoutingTargetID,
        domain: WebViewProxyEventDomain
    ) async {
        guard let backend else {
            preconditionFailure("WebViewProxy has no backend for \(domain.rawValue) events.")
        }
        await backend.waitForEventSubscription(route: route, targetID: targetID, domain: domain)
    }

    private nonisolated func eventStream<Element: Sendable>(
        targetID: WebViewTarget.ID,
        route: RoutingTargetID,
        domain: WebViewProxyEventDomain,
        extract: @escaping @Sendable (WebViewProxyEvent) -> Element?
    ) -> AsyncStream<Element> {
        guard let backend else {
            preconditionFailure("WebViewProxy has no backend for \(domain.rawValue) events.")
        }
        return AsyncStream<Element> { continuation in
            let task = Task {
                for await event in backend.events(route: route, targetID: targetID, domain: domain) {
                    guard let value = extract(event) else {
                        preconditionFailure("Backend emitted a mismatched event for \(domain.rawValue).")
                    }
                    continuation.yield(value)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
