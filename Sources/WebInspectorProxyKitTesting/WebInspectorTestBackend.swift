import Foundation
import WebInspectorProxyKit

package struct AnyRecordedValue: @unchecked Sendable {
    package let value: Any

    package init(_ value: some Sendable) {
        self.value = value
    }

    package func cast<T>(as type: T.Type = T.self) -> T? {
        value as? T
    }
}

/// A command recorded by ``WebInspectorTestBackend``.
public struct RecordedCommand: Equatable, Sendable {
    /// The target that received the command.
    public let targetID: WebInspectorTarget.ID

    /// The protocol domain for the command.
    public let domain: String

    /// The protocol method for the command.
    public let method: String
    package let route: RoutingTargetID
    package let payload: AnyRecordedValue

    /// Creates an unscoped recorded command used for equality assertions.
    public init(domain: String, method: String) {
        targetID = WebInspectorTarget.ID("unscoped-recorded-command")
        route = RoutingTargetID("unscoped-recorded-command")
        self.domain = domain
        self.method = method
        payload = AnyRecordedValue(())
    }

    package init<Payload: Sendable, Result: Sendable>(
        command: WebInspectorProxyCommand<Payload, Result>
    ) {
        targetID = command.targetID
        route = command.route
        domain = command.domain.rawValue
        method = command.method
        payload = AnyRecordedValue(command.payload)
    }

    /// Compares recorded commands by domain and method.
    public static func == (lhs: RecordedCommand, rhs: RecordedCommand) -> Bool {
        lhs.domain == rhs.domain && lhs.method == rhs.method
    }
}

private struct HeldCommand: Sendable {
    var domain: String
    var method: String
    var gate: WebInspectorTestGate
}

private struct CommandKey: Hashable, Sendable {
    var domain: String
    var method: String
}

private struct QueuedReply: @unchecked Sendable {
    enum Storage {
        case result(Any)
        case failure(any Error)
    }

    var storage: Storage

    init(_ value: some Sendable) {
        storage = .result(value)
    }

    init(failure error: any Error & Sendable) {
        storage = .failure(error)
    }
}

private struct EventSubscriptionKey: Hashable, Sendable {
    var route: RoutingTargetID
    var targetID: WebInspectorTarget.ID
    var domain: WebInspectorProxyEventDomain
}

private struct SubscriberWaiter: Sendable {
    var route: RoutingTargetID?
    var targetID: WebInspectorTarget.ID
    var domain: WebInspectorProxyEventDomain
    var count: Int
    var continuation: CheckedContinuation<Void, Never>
}

/// Errors thrown by ``WebInspectorTestBackend`` helpers.
public enum WebInspectorTestBackendError: Error, Equatable, Sendable {
    /// The requested event domain is not supported by the test backend.
    case unsupportedEventDomain(String)
}

/// Controllable in-memory backend for `WebInspectorProxyKit` tests.
public actor WebInspectorTestBackend {
    private var enqueuedReplies: [CommandKey: [QueuedReply]]
    private var commands: [RecordedCommand]
    private var heldCommands: [HeldCommand]
    private var eventContinuations: [EventSubscriptionKey: [UUID: AsyncStream<WebInspectorProxyEvent>.Continuation]]
    private var subscriberWaiters: [SubscriberWaiter]

    /// Creates an empty test backend.
    public init() {
        enqueuedReplies = [:]
        commands = []
        heldCommands = []
        eventContinuations = [:]
        subscriberWaiters = []
    }

    /// Enqueues a successful reply for the next matching command.
    public func enqueue<Result: Sendable>(
        _ result: Result,
        for domain: String,
        method: String
    ) async {
        let key = CommandKey(domain: domain, method: method)
        enqueuedReplies[key, default: []].append(QueuedReply(result))
    }

    /// Enqueues a failing reply for the next matching command.
    public func enqueueFailure(
        _ error: any Error & Sendable,
        for domain: String,
        method: String
    ) async {
        let key = CommandKey(domain: domain, method: method)
        enqueuedReplies[key, default: []].append(QueuedReply(failure: error))
    }

    /// Emits a Network event to subscribers for a target identity.
    public func emit(_ event: Network.Event, target: WebInspectorTarget.ID) async {
        emit(.network(event), target: target, route: nil, domain: .network)
    }

    /// Emits a Network event to subscribers for a target.
    public func emit(_ event: Network.Event, target: WebInspectorTarget) async {
        emit(.network(event), target: target.id, route: target.route, domain: .network)
    }

    /// Emits a DOM event to subscribers for a target identity.
    public func emit(_ event: DOM.Event, target: WebInspectorTarget.ID) async {
        emit(.dom(event), target: target, route: nil, domain: .dom)
    }

    /// Emits a DOM event to subscribers for a target.
    public func emit(_ event: DOM.Event, target: WebInspectorTarget) async {
        emit(.dom(event), target: target.id, route: target.route, domain: .dom)
    }

    package func emit(_ event: Inspector.Event, target: WebInspectorTarget.ID) async {
        emit(.inspector(event), target: target, route: nil, domain: .inspector)
    }

    package func emit(_ event: Inspector.Event, target: WebInspectorTarget) async {
        emit(.inspector(event), target: target.id, route: target.route, domain: .inspector)
    }

    /// Emits a CSS event to subscribers for a target identity.
    public func emit(_ event: CSS.Event, target: WebInspectorTarget.ID) async {
        emit(.css(event), target: target, route: nil, domain: .css)
    }

    /// Emits a CSS event to subscribers for a target.
    public func emit(_ event: CSS.Event, target: WebInspectorTarget) async {
        emit(.css(event), target: target.id, route: target.route, domain: .css)
    }

    /// Emits a Console event to subscribers for a target identity.
    public func emit(_ event: Console.Event, target: WebInspectorTarget.ID) async {
        emit(.console(Console.TargetedEvent(event: event, targetID: target)), target: target, route: nil, domain: .console)
    }

    /// Emits a Console event to subscribers for a target.
    public func emit(_ event: Console.Event, target: WebInspectorTarget) async {
        emit(
            .console(Console.TargetedEvent(event: event, targetID: target.id)),
            target: target.id,
            route: target.route,
            domain: .console
        )
    }

    /// Emits a Runtime event to subscribers for a target identity.
    public func emit(_ event: Runtime.Event, target: WebInspectorTarget.ID) async {
        emit(.runtime(event), target: target, route: nil, domain: .runtime)
    }

    /// Emits a Runtime event to subscribers for a target.
    public func emit(_ event: Runtime.Event, target: WebInspectorTarget) async {
        emit(.runtime(event), target: target.id, route: target.route, domain: .runtime)
    }

    package func emit(_ event: WebInspectorTargetLifecycleEvent, target: WebInspectorTarget) async {
        emit(.targetLifecycle(event), target: target.id, route: target.route, domain: lifecycleDomain(for: event))
    }

    /// Returns commands recorded by the backend.
    public func recordedCommands() async -> [RecordedCommand] {
        commands
    }

    /// Waits until a target identity has at least the requested subscriber count.
    public func waitForSubscribers(
        domain: String,
        target: WebInspectorTarget.ID,
        count: Int
    ) async throws {
        guard let eventDomain = WebInspectorProxyEventDomain(rawValue: domain) else {
            throw WebInspectorTestBackendError.unsupportedEventDomain(domain)
        }
        guard subscriberCount(for: target, domain: eventDomain) < count else {
            return
        }
        await withCheckedContinuation { continuation in
            if subscriberCount(for: target, domain: eventDomain) >= count {
                continuation.resume()
            } else {
                subscriberWaiters.append(SubscriberWaiter(
                    route: nil,
                    targetID: target,
                    domain: eventDomain,
                    count: count,
                    continuation: continuation
                ))
            }
        }
    }

    /// Waits until a target has at least the requested subscriber count.
    public func waitForSubscribers(
        domain: String,
        target: WebInspectorTarget,
        count: Int
    ) async throws {
        guard let eventDomain = WebInspectorProxyEventDomain(rawValue: domain) else {
            throw WebInspectorTestBackendError.unsupportedEventDomain(domain)
        }
        let key = EventSubscriptionKey(route: target.route, targetID: target.id, domain: eventDomain)
        guard subscriberCount(for: key) < count else {
            return
        }
        await withCheckedContinuation { continuation in
            if subscriberCount(for: key) >= count {
                continuation.resume()
            } else {
                subscriberWaiters.append(SubscriberWaiter(
                    route: target.route,
                    targetID: target.id,
                    domain: eventDomain,
                    count: count,
                    continuation: continuation
                ))
            }
        }
    }

    /// Holds matching commands until the supplied gate opens.
    public func hold(domain: String, method: String, gate: WebInspectorTestGate) async {
        heldCommands.append(HeldCommand(domain: domain, method: method, gate: gate))
    }

    private func emit(
        _ event: WebInspectorProxyEvent,
        target targetID: WebInspectorTarget.ID,
        route: RoutingTargetID?,
        domain: WebInspectorProxyEventDomain
    ) {
        let key = EventSubscriptionKey(
            route: route ?? unambiguousRoute(for: targetID, domain: domain),
            targetID: targetID,
            domain: domain
        )
        for continuation in eventContinuations[key, default: [:]].values {
            continuation.yield(event)
        }
    }

    private func addEventContinuation(
        _ continuation: AsyncStream<WebInspectorProxyEvent>.Continuation,
        id: UUID,
        key: EventSubscriptionKey
    ) {
        eventContinuations[key, default: [:]][id] = continuation
        resolveSubscriberWaiters()
    }

    private func removeEventContinuation(id: UUID, key: EventSubscriptionKey) {
        eventContinuations[key]?[id] = nil
        if eventContinuations[key]?.isEmpty == true {
            eventContinuations[key] = nil
        }
    }

    private func subscriberCount(for key: EventSubscriptionKey) -> Int {
        eventContinuations[key]?.count ?? 0
    }

    private func subscriberCount(for targetID: WebInspectorTarget.ID, domain: WebInspectorProxyEventDomain) -> Int {
        eventContinuations.reduce(into: 0) { count, entry in
            if entry.key.targetID == targetID && entry.key.domain == domain {
                count += entry.value.count
            }
        }
    }

    private func unambiguousRoute(
        for targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain,
        matching keys: [EventSubscriptionKey]? = nil
    ) -> RoutingTargetID {
        let matchingKeys = keys ?? eventContinuations.keys.filter {
            $0.targetID == targetID && $0.domain == domain
        }
        let routes = Set(matchingKeys.map(\.route))
        guard routes.count <= 1 else {
            preconditionFailure(
                "Multiple routes are subscribed for \(domain.rawValue) target \(targetID); emit with WebInspectorTarget."
            )
        }
        guard let route = routes.first else {
            preconditionFailure("No route is subscribed for \(domain.rawValue) target \(targetID).")
        }
        return route
    }

    private func resolveSubscriberWaiters() {
        var unresolved: [SubscriberWaiter] = []
        for waiter in subscriberWaiters {
            let currentCount = if let route = waiter.route {
                subscriberCount(for: EventSubscriptionKey(
                    route: route,
                    targetID: waiter.targetID,
                    domain: waiter.domain
                ))
            } else {
                subscriberCount(for: waiter.targetID, domain: waiter.domain)
            }
            if currentCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                unresolved.append(waiter)
            }
        }
        subscriberWaiters = unresolved
    }
}

private func lifecycleDomain(for event: WebInspectorTargetLifecycleEvent) -> WebInspectorProxyEventDomain {
    switch event {
    case .didCommitProvisionalTarget, .targetDestroyed:
        .target
    case .frameNavigated, .frameDetached:
        .page
    case .unknown:
        .target
    }
}

extension WebInspectorTestBackend: WebInspectorProxyBackend {
    package func dispatchCommand<Payload: Sendable, Result: Sendable>(
        _ command: WebInspectorProxyCommand<Payload, Result>
    ) async throws -> Result {
        commands.append(RecordedCommand(command: command))

        if let gate = heldCommands.first(where: {
            $0.domain == command.domain.rawValue && $0.method == command.method
        })?.gate {
            await gate.wait()
        }

        let key = CommandKey(domain: command.domain.rawValue, method: command.method)
        guard var results = enqueuedReplies[key], results.isEmpty == false else {
            throw WebInspectorProxyError.commandFailed(
                domain: command.domain.rawValue,
                method: command.method,
                message: "No enqueued result for \(command.domain.rawValue).\(command.method)."
            )
        }

        let queued = results.removeFirst()
        enqueuedReplies[key] = results.isEmpty ? nil : results

        let value: Any
        switch queued.storage {
        case let .result(result):
            value = result
        case let .failure(error):
            throw error
        }

        guard let result = value as? Result else {
            throw WebInspectorProxyError.commandFailed(
                domain: command.domain.rawValue,
                method: command.method,
                message: "Enqueued result for \(command.domain.rawValue).\(command.method) has type "
                    + "\(type(of: value)); expected \(Result.self)."
            )
        }
        return result
    }

    package func waitForEventSubscription(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain
    ) async {
        let key = EventSubscriptionKey(route: route, targetID: targetID, domain: domain)
        while subscriberCount(for: key) < 1 {
            guard Task.isCancelled == false else {
                return
            }
            await Task.yield()
        }
    }

    package nonisolated func events(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain
    ) -> AsyncStream<WebInspectorProxyEvent> {
        _ = route
        let key = EventSubscriptionKey(route: route, targetID: targetID, domain: domain)
        return AsyncStream<WebInspectorProxyEvent> { continuation in
            let id = UUID()
            Task {
                await self.addEventContinuation(continuation, id: id, key: key)
            }
            continuation.onTermination = { _ in
                Task {
                    await self.removeEventContinuation(id: id, key: key)
                }
            }
        }
    }
}
