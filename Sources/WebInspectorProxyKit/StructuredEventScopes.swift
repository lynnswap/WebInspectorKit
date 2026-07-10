import Foundation
import Synchronization

/// Controls how many protocol events a structured event scope may retain while
/// its consumer is suspended.
public enum WebInspectorEventBufferingPolicy: Equatable, Sendable {
    /// Retains the oldest pending events up to `capacity`.
    ///
    /// `capacity` must be greater than zero.
    ///
    /// The first event that cannot be retained terminates only that subscriber
    /// with ``WebInspectorProxyError/eventBufferOverflow(capacity:)``.
    case bounded(Int)

    /// Retains every pending event. This is an explicit opt-in because protocol
    /// domains do not provide a general resynchronization mechanism.
    case unbounded

    package var capacity: Int? {
        switch self {
        case let .bounded(capacity):
            precondition(capacity > 0, "A bounded Web Inspector event buffer must have a positive capacity.")
            return capacity
        case .unbounded:
            return nil
        }
    }

}

package final class WebInspectorEventMailbox<Element: Sendable>: Sendable {
    package typealias Event = WebInspectorPageEvent<Element>

    private enum PendingElement {
        case reset(WebInspectorPage.Generation)
        case event(WebInspectorPage.Generation, Element)
    }

    private enum Terminal {
        case finished
        case failed(any Error)
    }

    private struct State {
        var pendingElements: [PendingElement] = []
        var pendingElementStartIndex = 0
        var pendingEventCount = 0
        var waiter: CheckedContinuation<Event?, any Error>?
        var terminal: Terminal?

        mutating func removeFirstElement() -> PendingElement? {
            guard pendingElementStartIndex < pendingElements.count else {
                return nil
            }
            let element = pendingElements[pendingElementStartIndex]
            pendingElementStartIndex += 1
            if case .event = element {
                pendingEventCount -= 1
            }
            if pendingElementStartIndex == pendingElements.count {
                pendingElements.removeAll(keepingCapacity: true)
                pendingElementStartIndex = 0
            } else if pendingElementStartIndex >= 64,
                      pendingElementStartIndex * 2 >= pendingElements.count {
                pendingElements.removeFirst(pendingElementStartIndex)
                pendingElementStartIndex = 0
            }
            return element
        }

        mutating func appendReset(_ generation: WebInspectorPage.Generation) {
            if pendingElementStartIndex < pendingElements.count,
               case .reset = pendingElements[pendingElements.count - 1] {
                pendingElements[pendingElements.count - 1] = .reset(generation)
            } else {
                pendingElements.append(.reset(generation))
            }
        }

        mutating func appendEvent(
            _ generation: WebInspectorPage.Generation,
            _ event: Element
        ) {
            pendingElements.append(.event(generation, event))
            pendingEventCount += 1
        }
    }

    private let capacity: Int?
    private let state = Mutex(State())

    package init(capacity: Int?) {
        self.capacity = capacity
    }

    package func makeStream() -> AsyncThrowingStream<Event, any Error> {
        AsyncThrowingStream { [self] in
            try await next()
        }
    }

    package func yieldReset(
        _ generation: WebInspectorPage.Generation
    ) -> WebInspectorEventDeliveryResult {
        let (result, waiter) = state.withLock { state in
            guard state.terminal == nil else {
                return (
                    WebInspectorEventDeliveryResult.terminated,
                    nil as CheckedContinuation<Event?, any Error>?
                )
            }
            if let waiter = state.waiter {
                state.waiter = nil
                return (WebInspectorEventDeliveryResult.enqueued, waiter)
            }
            // A reset never consumes protocol-event capacity. Preserve all
            // events that precede the binding boundary, while folding a run
            // of adjacent resets to the latest physical generation.
            state.appendReset(generation)
            return (
                WebInspectorEventDeliveryResult.enqueued,
                nil as CheckedContinuation<Event?, any Error>?
            )
        }
        waiter?.resume(returning: .reset(generation))
        return result
    }

    package func yieldEvent(
        _ generation: WebInspectorPage.Generation,
        _ event: Element
    ) -> WebInspectorEventDeliveryResult {
        let (result, waiter) = state.withLock { state in
            guard state.terminal == nil else {
                return (
                    WebInspectorEventDeliveryResult.terminated,
                    nil as CheckedContinuation<Event?, any Error>?
                )
            }
            if let waiter = state.waiter {
                state.waiter = nil
                return (WebInspectorEventDeliveryResult.enqueued, waiter)
            }
            if let capacity, state.pendingEventCount >= capacity {
                return (
                    WebInspectorEventDeliveryResult.dropped,
                    nil as CheckedContinuation<Event?, any Error>?
                )
            }
            state.appendEvent(generation, event)
            return (
                WebInspectorEventDeliveryResult.enqueued,
                nil as CheckedContinuation<Event?, any Error>?
            )
        }
        waiter?.resume(returning: .event(generation, event))
        return result
    }

    package func finish(throwing error: (any Error)? = nil) {
        let waiter = state.withLock { state in
            guard state.terminal == nil else {
                return nil as CheckedContinuation<Event?, any Error>?
            }
            if let error {
                state.terminal = .failed(error)
            } else {
                state.terminal = .finished
            }
            guard state.pendingElements.isEmpty else {
                return nil
            }
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        guard let waiter else {
            return
        }
        if let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume(returning: nil)
        }
    }

    private func next() async throws -> Event? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { state -> Result<Event?, any Error>? in
                    if let element = state.removeFirstElement() {
                        switch element {
                        case let .reset(generation):
                            return .success(.reset(generation))
                        case let .event(generation, event):
                            return .success(.event(generation, event))
                        }
                    }
                    if let terminal = state.terminal {
                        switch terminal {
                        case .finished:
                            return .success(nil)
                        case let .failed(error):
                            return .failure(error)
                        }
                    }
                    precondition(state.waiter == nil, "A Web Inspector event stream cannot have concurrent next() calls.")
                    state.waiter = continuation
                    return nil
                }
                if let result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: { [self] in
            cancel()
        }
    }

    private func cancel() {
        let error = CancellationError()
        let waiter = state.withLock { state in
            state.pendingElements.removeAll(keepingCapacity: true)
            state.pendingElementStartIndex = 0
            state.pendingEventCount = 0
            state.terminal = .failed(error)
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume(throwing: error)
    }
}

/// A stable logical handle for the inspected page.
///
/// The handle survives physical WebKit target replacement. Domain operations
/// resolve the current physical target through the connection core.
public struct WebInspectorPage: Sendable {
    /// Identifies one physical binding of the logical inspected page.
    public struct Generation: Hashable, Sendable {
        package let rawValue: UInt64

        package init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
    }

    package let proxy: WebInspectorProxy

    package init(proxy: WebInspectorProxy) {
        self.proxy = proxy
    }

    /// The current physical page generation.
    public var generation: Generation {
        get async throws {
            try await proxy.pageGeneration()
        }
    }

    /// A typed client for DOM protocol commands and events.
    public var dom: DOM.Client {
        DOM.Client(context: context)
    }

    /// A typed client for CSS protocol commands and events.
    public var css: CSS.Client {
        CSS.Client(context: context)
    }

    /// A typed client for Network protocol commands and events.
    public var network: Network.Client {
        Network.Client(context: context)
    }

    /// A typed client for Console protocol commands and events.
    public var console: Console.Client {
        Console.Client(context: context)
    }

    /// A typed client for Runtime protocol commands and events.
    public var runtime: Runtime.Client {
        Runtime.Client(context: context)
    }

    /// A typed client for Page protocol commands.
    public var page: Page.Client {
        Page.Client(context: context)
    }

    private var context: DomainClientContext {
        DomainClientContext(proxy: proxy, targetID: .currentPage, route: .currentPage)
    }
}

/// An event from one physical binding of a logical inspected page.
public enum WebInspectorPageEvent<Element: Sendable>: Sendable {
    /// Invalidates state from the preceding physical page binding.
    ///
    /// A slow consumer still receives protocol events in binding order:
    /// old-generation events, then the reset, then new-generation events.
    /// Adjacent unconsumed resets with no event between them are coalesced to
    /// the latest generation, and resets do not consume event-buffer capacity.
    case reset(WebInspectorPage.Generation)

    /// Delivers a domain event from the supplied physical page binding.
    case event(WebInspectorPage.Generation, Element)
}

/// Preserves both failures when a structured operation and its cleanup fail.
public struct WebInspectorScopeError: Error {
    /// The error thrown by the operation body.
    public let operationError: any Error

    /// The error thrown while balancing the scope's capability lease.
    public let cleanupError: any Error

    /// Creates an error containing both the operation and cleanup failures.
    public init(operationError: any Error, cleanupError: any Error) {
        self.operationError = operationError
        self.cleanupError = cleanupError
    }
}

package struct WebInspectorProxyEventScopeID: Hashable, Sendable {
    package let rawValue: UUID

    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

package struct WebInspectorProxyEventScope<Element: Sendable>: Sendable {
    package let id: WebInspectorProxyEventScopeID
    package let events: AsyncThrowingStream<WebInspectorPageEvent<Element>, any Error>

    package init(
        id: WebInspectorProxyEventScopeID,
        events: AsyncThrowingStream<WebInspectorPageEvent<Element>, any Error>
    ) {
        self.id = id
        self.events = events
    }
}

package enum WebInspectorEventDeliveryResult: Sendable {
    case enqueued
    case dropped
    case terminated
    case mismatchedEvent
}

package struct WebInspectorEventSink: Sendable {
    package let id: WebInspectorProxyEventScopeID
    package let route: RoutingTargetID
    package let targetID: WebInspectorTarget.ID
    package let domain: WebInspectorProxyEventDomain
    package let yieldReset: @Sendable (WebInspectorPage.Generation) -> WebInspectorEventDeliveryResult
    package let yieldEvent: @Sendable (
        WebInspectorPage.Generation,
        WebInspectorProxyEvent
    ) -> WebInspectorEventDeliveryResult
    package let finish: @Sendable ((any Error)?) -> Void

    package init<Element: Sendable>(
        id: WebInspectorProxyEventScopeID,
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain,
        mailbox: WebInspectorEventMailbox<Element>,
        extract: @escaping @Sendable (WebInspectorProxyEvent) -> Element?
    ) {
        self.id = id
        self.route = route
        self.targetID = targetID
        self.domain = domain
        yieldReset = { generation in
            mailbox.yieldReset(generation)
        }
        yieldEvent = { generation, proxyEvent in
            guard let event = extract(proxyEvent) else {
                return .mismatchedEvent
            }
            return mailbox.yieldEvent(generation, event)
        }
        finish = { error in
            mailbox.finish(throwing: error)
        }
    }
}

package func withWebInspectorEventScope<Element: Sendable, Output>(
    backend: any WebInspectorProxyBackend,
    targetID: WebInspectorTarget.ID,
    route: RoutingTargetID,
    domain: WebInspectorProxyEventDomain,
    buffering: WebInspectorEventBufferingPolicy,
    isolation: isolated (any Actor)? = #isolation,
    extract: @escaping @Sendable (WebInspectorProxyEvent) -> Element?,
    _ operation: (
        AsyncThrowingStream<WebInspectorPageEvent<Element>, any Error>
    ) async throws -> Output
) async throws -> Output {
    _ = isolation
    _ = buffering.capacity
    let scope = try await backend.acquireEventScope(
        route: route,
        targetID: targetID,
        domain: domain,
        buffering: buffering,
        extract: extract
    )

    let operationResult: Result<Output, any Error>
    do {
        try Task.checkCancellation()
        operationResult = .success(try await operation(scope.events))
    } catch {
        operationResult = .failure(error)
    }

    let cleanupResult: Result<Void, any Error>
    do {
        try await backend.releaseEventScope(scope.id)
        cleanupResult = .success(())
    } catch {
        cleanupResult = .failure(error)
    }

    switch (operationResult, cleanupResult) {
    case let (.success(value), .success):
        return value
    case let (.success, .failure(cleanupError)):
        throw cleanupError
    case let (.failure(operationError), .success):
        throw operationError
    case let (.failure(operationError), .failure(cleanupError)):
        throw WebInspectorScopeError(
            operationError: operationError,
            cleanupError: cleanupError
        )
    }
}
