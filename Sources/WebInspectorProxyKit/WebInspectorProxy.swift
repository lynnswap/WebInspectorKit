import Foundation
import WebKit

public actor WebInspectorProxy {
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
    private let backend: (any WebInspectorProxyBackend)?
    private var pageTarget: WebInspectorTarget?
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
        nextTargetOrdinal = 0
        closed = false
        throw WebInspectorProxyError.unsupported([
            "Native WKWebView attachment is not implemented in the WebInspectorProxyKit shell."
        ])
    }

    package init(
        configuration: Configuration = .init(),
        backend: (any WebInspectorProxyBackend)? = nil
    ) {
        self.configuration = configuration
        self.backend = backend
        pageTarget = nil
        nextTargetOrdinal = 0
        closed = false
    }

    public var currentPage: WebInspectorTarget? {
        pageTarget
    }

    public var canReload: Bool {
        pageTarget != nil && closed == false
    }

    public func waitForCurrentPage() async throws -> WebInspectorTarget {
        if let pageTarget {
            return pageTarget
        }
        throw WebInspectorProxyError.disconnected("WebInspectorProxyKit shell has no current page target.")
    }

    public func reload() async throws {
        guard let pageTarget else {
            throw WebInspectorProxyError.disconnected("WebInspectorProxyKit shell has no current page target.")
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
    }

    public func waitUntilClosed() async throws {
        guard closed else {
            throw WebInspectorProxyError.disconnected("WebInspectorProxyKit shell is not connected.")
        }
    }

    package func installTargetForTesting(
        kind: WebInspectorTarget.Kind = .page,
        frameID: FrameID? = nil,
        isProvisional: Bool = false
    ) -> WebInspectorTarget {
        let ordinal = nextTargetOrdinal
        nextTargetOrdinal += 1
        let target = WebInspectorTarget(
            id: WebInspectorTarget.ID("test-target-\(ordinal)"),
            kind: kind,
            frameID: frameID,
            isProvisional: isProvisional,
            proxy: self,
            route: RoutingTargetID("test-route-\(ordinal)")
        )
        if kind == .page && isProvisional == false {
            pageTarget = target
        }
        return target
    }

    package func dispatchCommand<Payload: Sendable, Result: Sendable>(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID,
        domain: WebInspectorProxyDomain,
        method: String,
        payload: Payload
    ) async throws -> Result {
        guard closed == false else {
            throw WebInspectorProxyError.closed
        }
        guard let backend else {
            throw unimplementedCommand(domain: domain.rawValue, method: method)
        }
        let command = WebInspectorProxyCommand<Payload, Result>(
            targetID: targetID,
            route: route,
            domain: domain,
            method: method,
            payload: payload
        )
        return try await backend.dispatchCommand(command)
    }

    package nonisolated func domEvents(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID
    ) -> AsyncStream<DOM.Event> {
        guard let backend else {
            preconditionFailure("WebInspectorProxy has no backend for DOM events.")
        }
        return AsyncStream<DOM.Event> { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await event in backend.events(route: route, targetID: targetID, domain: .dom) {
                            guard case let .dom(value) = event else {
                                preconditionFailure("Backend emitted a mismatched event for DOM.")
                            }
                            continuation.yield(value)
                        }
                    }
                    group.addTask {
                        for await event in backend.events(route: route, targetID: targetID, domain: .inspector) {
                            guard case let .inspector(value) = event else {
                                preconditionFailure("Backend emitted a mismatched event for Inspector.")
                            }
                            await self.emitDOMInspectEvent(
                                for: value,
                                targetID: targetID,
                                route: route,
                                continuation: continuation
                            )
                        }
                    }
                    await group.waitForAll()
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    package nonisolated func cssEvents(
        targetID: WebInspectorTarget.ID,
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
        targetID: WebInspectorTarget.ID,
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
        targetID: WebInspectorTarget.ID,
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
        targetID: WebInspectorTarget.ID,
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
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID,
        domain: WebInspectorProxyEventDomain
    ) async {
        guard let backend else {
            preconditionFailure("WebInspectorProxy has no backend for \(domain.rawValue) events.")
        }
        await backend.waitForEventSubscription(route: route, targetID: targetID, domain: domain)
    }

    private nonisolated func eventStream<Element: Sendable>(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID,
        domain: WebInspectorProxyEventDomain,
        extract: @escaping @Sendable (WebInspectorProxyEvent) -> Element?
    ) -> AsyncStream<Element> {
        guard let backend else {
            preconditionFailure("WebInspectorProxy has no backend for \(domain.rawValue) events.")
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

    private nonisolated func emitDOMInspectEvent(
        for event: Inspector.Event,
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID,
        continuation: AsyncStream<DOM.Event>.Continuation
    ) async {
        guard case let .inspect(object, _) = event else {
            return
        }
        guard object.subtype?.rawValue == "node", let objectID = object.id else {
            return
        }
        do {
            let nodeID: DOM.Node.ID = try await dispatchCommand(
                targetID: targetID,
                route: route,
                domain: .dom,
                method: "requestNode",
                payload: DOM.RequestNodePayload(objectID: objectID)
            )
            continuation.yield(.inspect(nodeID))
        } catch {
            continuation.yield(.unknown(RawEvent(domain: "Inspector", method: "inspect")))
        }
    }
}
