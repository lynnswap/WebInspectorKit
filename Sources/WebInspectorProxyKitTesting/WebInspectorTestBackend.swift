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

private struct OrderedEventSubscriptionKey: Hashable, Sendable {
    var route: RoutingTargetID
    var targetID: WebInspectorTarget.ID
}

private struct SubscriberWaiter: Sendable {
    var id: UInt64
    var route: RoutingTargetID?
    var targetID: WebInspectorTarget.ID
    var domain: WebInspectorProxyEventDomain
    var count: Int
    var promise: ReplyPromise<Void>
}

private struct SubscriberWaiterRegistrationWaiter: Sendable {
    var id: UInt64
    var promise: ReplyPromise<Void>
}

private struct RecordedCommandWaiter: Sendable {
    var domain: String
    var method: String
    var count: Int
    var continuation: CheckedContinuation<[RecordedCommand], Never>
}

private struct CompletedCommandWaiter: Sendable {
    var domain: String
    var method: String
    var count: Int
    var continuation: CheckedContinuation<[RecordedCommand], Never>
}

private struct EventTermination: Sendable {
    var error: WebInspectorProxyError?

    var operationError: WebInspectorProxyError {
        error ?? .closed
    }
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
    private var completedCommands: [RecordedCommand]
    private var heldCommands: [HeldCommand]
    private var eventContinuations: [EventSubscriptionKey: [UUID: AsyncStream<WebInspectorProxyEvent>.Continuation]]
    private var orderedEventContinuations: [
        OrderedEventSubscriptionKey: [
            UUID: AsyncThrowingStream<WebInspectorProxyOrderedEvent, any Error>.Continuation
        ]
    ]
    private var cancelledEventSubscriptionIDs: Set<UUID>
    private var eventTermination: EventTermination?
    private var orderedEventSequence: UInt64
    private var subscriberWaiters: [SubscriberWaiter]
    private var subscriberWaiterRegistrationWaiters: [SubscriberWaiterRegistrationWaiter]
    private var recordedCommandWaiters: [RecordedCommandWaiter]
    private var completedCommandWaiters: [CompletedCommandWaiter]
    private var nextSubscriberWaiterID: UInt64
    private var nextSubscriberWaiterRegistrationWaiterID: UInt64

    /// Creates an empty test backend.
    public init() {
        enqueuedReplies = [:]
        commands = []
        completedCommands = []
        heldCommands = []
        eventContinuations = [:]
        orderedEventContinuations = [:]
        cancelledEventSubscriptionIDs = []
        eventTermination = nil
        orderedEventSequence = 0
        subscriberWaiters = []
        subscriberWaiterRegistrationWaiters = []
        recordedCommandWaiters = []
        completedCommandWaiters = []
        nextSubscriberWaiterID = 0
        nextSubscriberWaiterRegistrationWaiterID = 0
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

    /// Returns commands whose backend dispatch has completed.
    public func completedCommands() async -> [RecordedCommand] {
        completedCommands
    }

    /// Waits until at least the requested number of matching commands has been recorded.
    public func waitForRecordedCommands(
        domain: String,
        method: String,
        count: Int
    ) async -> [RecordedCommand] {
        let matches = recordedCommands(domain: domain, method: method)
        guard matches.count < count else {
            return matches
        }
        return await withCheckedContinuation { continuation in
            let matches = recordedCommands(domain: domain, method: method)
            if matches.count >= count {
                continuation.resume(returning: matches)
            } else {
                recordedCommandWaiters.append(RecordedCommandWaiter(
                    domain: domain,
                    method: method,
                    count: count,
                    continuation: continuation
                ))
            }
        }
    }

    /// Waits until at least the requested number of matching commands has completed backend dispatch.
    public func waitForCompletedCommands(
        domain: String,
        method: String,
        count: Int
    ) async -> [RecordedCommand] {
        let matches = completedCommands(domain: domain, method: method)
        guard matches.count < count else {
            return matches
        }
        return await withCheckedContinuation { continuation in
            let matches = completedCommands(domain: domain, method: method)
            if matches.count >= count {
                continuation.resume(returning: matches)
            } else {
                completedCommandWaiters.append(CompletedCommandWaiter(
                    domain: domain,
                    method: method,
                    count: count,
                    continuation: continuation
                ))
            }
        }
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
        try await waitForSubscriber(route: nil, targetID: target, domain: eventDomain, count: count)
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
        try await waitForSubscriber(route: target.route, targetID: target.id, domain: eventDomain, count: count)
    }

    /// Returns the number of active ordered event subscribers for a target.
    public func activeOrderedEventSubscriberCount(for target: WebInspectorTarget) -> Int {
        orderedEventContinuations[OrderedEventSubscriptionKey(
            route: target.route,
            targetID: target.id
        )]?.count ?? 0
    }

    package func eventSubscriptionBookkeepingCountForTesting() -> Int {
        eventContinuations.values.reduce(0) { $0 + $1.count }
            + orderedEventContinuations.values.reduce(0) { $0 + $1.count }
            + cancelledEventSubscriptionIDs.count
    }

    package func eventSubscriptionWaiterCountForTesting() -> Int {
        subscriberWaiters.count
    }

    package func waitForEventSubscriptionWaiterForTesting() async {
        guard subscriberWaiters.isEmpty, eventTermination == nil else {
            return
        }
        let id = nextSubscriberWaiterRegistrationWaiterID
        nextSubscriberWaiterRegistrationWaiterID += 1
        let waiter = SubscriberWaiterRegistrationWaiter(
            id: id,
            promise: ReplyPromise<Void>()
        )
        subscriberWaiterRegistrationWaiters.append(waiter)
        defer {
            subscriberWaiterRegistrationWaiters.removeAll { $0.id == id }
        }
        _ = try? await waiter.promise.value()
    }

    package func exerciseCancelledSubscriptionRegistrationForTesting(
        ordered: Bool,
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID
    ) -> Bool {
        let id = UUID()
        if ordered {
            let key = OrderedEventSubscriptionKey(route: route, targetID: targetID)
            let pair = AsyncThrowingStream<WebInspectorProxyOrderedEvent, any Error>.makeStream()
            cancelOrderedEventContinuation(id: id, key: key)
            addOrderedEventContinuation(pair.continuation, id: id, key: key)
            return eventSubscriptionBookkeepingCountForTesting() == 0
        }
        let key = EventSubscriptionKey(
            route: route,
            targetID: targetID,
            domain: .network
        )
        let pair = AsyncStream<WebInspectorProxyEvent>.makeStream()
        cancelEventContinuation(id: id, key: key)
        addEventContinuation(pair.continuation, id: id, key: key)
        return eventSubscriptionBookkeepingCountForTesting() == 0
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
        guard eventTermination == nil else {
            return
        }
        let (nextSequence, overflow) = orderedEventSequence.addingReportingOverflow(1)
        precondition(!overflow, "Test event sequence exhausted.")
        orderedEventSequence = nextSequence
        let resolvedRoute = route ?? unambiguousRoute(for: targetID, domain: domain)
        let key = EventSubscriptionKey(
            route: resolvedRoute,
            targetID: targetID,
            domain: domain
        )
        for continuation in eventContinuations[key, default: [:]].values {
            continuation.yield(event)
        }
        for (orderedKey, continuations) in orderedEventContinuations {
            let deliveredEvent = orderedKey.route == resolvedRoute && orderedKey.targetID == targetID
                ? event
                : nil
            for continuation in continuations.values {
                continuation.yield(WebInspectorProxyOrderedEvent(
                    sequence: nextSequence,
                    event: deliveredEvent
                ))
            }
        }
    }

    private func addEventContinuation(
        _ continuation: AsyncStream<WebInspectorProxyEvent>.Continuation,
        id: UUID,
        key: EventSubscriptionKey
    ) {
        guard eventTermination == nil else {
            continuation.finish()
            return
        }
        guard cancelledEventSubscriptionIDs.remove(id) == nil else {
            continuation.finish()
            return
        }
        eventContinuations[key, default: [:]][id] = continuation
        resolveSubscriberWaiters()
    }

    private func cancelEventContinuation(id: UUID, key: EventSubscriptionKey) {
        guard eventTermination == nil else {
            return
        }
        guard eventContinuations[key]?.removeValue(forKey: id) != nil else {
            cancelledEventSubscriptionIDs.insert(id)
            return
        }
        if eventContinuations[key]?.isEmpty == true {
            eventContinuations.removeValue(forKey: key)
        }
    }

    private func addOrderedEventContinuation(
        _ continuation: AsyncThrowingStream<WebInspectorProxyOrderedEvent, any Error>.Continuation,
        id: UUID,
        key: OrderedEventSubscriptionKey
    ) {
        guard let termination = eventTermination else {
            guard cancelledEventSubscriptionIDs.remove(id) == nil else {
                continuation.finish()
                return
            }
            orderedEventContinuations[key, default: [:]][id] = continuation
            resolveSubscriberWaiters()
            return
        }
        continuation.finish(throwing: termination.error)
    }

    private func cancelOrderedEventContinuation(id: UUID, key: OrderedEventSubscriptionKey) {
        guard eventTermination == nil else {
            return
        }
        guard orderedEventContinuations[key]?.removeValue(forKey: id) != nil else {
            cancelledEventSubscriptionIDs.insert(id)
            return
        }
        if orderedEventContinuations[key]?.isEmpty == true {
            orderedEventContinuations.removeValue(forKey: key)
        }
    }

    private func subscriberCount(for key: EventSubscriptionKey) -> Int {
        (eventContinuations[key]?.count ?? 0)
            + (orderedEventContinuations[OrderedEventSubscriptionKey(
                route: key.route,
                targetID: key.targetID
            )]?.count ?? 0)
    }

    private func subscriberCount(for targetID: WebInspectorTarget.ID, domain: WebInspectorProxyEventDomain) -> Int {
        let domainCount = eventContinuations.reduce(into: 0) { count, entry in
            if entry.key.targetID == targetID && entry.key.domain == domain {
                count += entry.value.count
            }
        }
        return domainCount + orderedEventContinuations.reduce(into: 0) { count, entry in
            if entry.key.targetID == targetID {
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
        let routes = Set(matchingKeys.map(\.route)).union(
            orderedEventContinuations.keys.compactMap {
                $0.targetID == targetID ? $0.route : nil
            }
        )
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
            if subscriberCount(for: waiter) >= waiter.count {
                waiter.promise.fulfill(.success(()))
            } else {
                unresolved.append(waiter)
            }
        }
        subscriberWaiters = unresolved
    }

    private func waitForSubscriber(
        route: RoutingTargetID?,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain,
        count: Int
    ) async throws {
        if let termination = eventTermination {
            throw termination.operationError
        }
        let waiterID = nextSubscriberWaiterID
        nextSubscriberWaiterID += 1
        let waiter = SubscriberWaiter(
            id: waiterID,
            route: route,
            targetID: targetID,
            domain: domain,
            count: count,
            promise: ReplyPromise<Void>()
        )
        addSubscriberWaiter(waiter)
        defer {
            removeSubscriberWaiter(waiterID)
        }
        try await waiter.promise.value()
    }

    private func addSubscriberWaiter(_ waiter: SubscriberWaiter) {
        if let termination = eventTermination {
            waiter.promise.fulfill(.failure(termination.operationError))
            return
        }
        guard subscriberCount(for: waiter) < waiter.count else {
            waiter.promise.fulfill(.success(()))
            return
        }
        subscriberWaiters.append(waiter)
        let registrationWaiters = subscriberWaiterRegistrationWaiters
        subscriberWaiterRegistrationWaiters.removeAll()
        for waiter in registrationWaiters {
            waiter.promise.fulfill(.success(()))
        }
    }

    private func removeSubscriberWaiter(_ id: UInt64) {
        guard let index = subscriberWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        subscriberWaiters.remove(at: index)
    }

    private func subscriberCount(for waiter: SubscriberWaiter) -> Int {
        if let route = waiter.route {
            subscriberCount(for: EventSubscriptionKey(
                route: route,
                targetID: waiter.targetID,
                domain: waiter.domain
            ))
        } else {
            subscriberCount(for: waiter.targetID, domain: waiter.domain)
        }
    }

    private func recordedCommands(domain: String, method: String) -> [RecordedCommand] {
        commands.filter { $0.domain == domain && $0.method == method }
    }

    private func completedCommands(domain: String, method: String) -> [RecordedCommand] {
        completedCommands.filter { $0.domain == domain && $0.method == method }
    }

    private func resolveRecordedCommandWaiters() {
        var unresolved: [RecordedCommandWaiter] = []
        for waiter in recordedCommandWaiters {
            let matches = recordedCommands(domain: waiter.domain, method: waiter.method)
            if matches.count >= waiter.count {
                waiter.continuation.resume(returning: matches)
            } else {
                unresolved.append(waiter)
            }
        }
        recordedCommandWaiters = unresolved
    }

    private func recordCompletedCommand(_ command: RecordedCommand) {
        completedCommands.append(command)
        resolveCompletedCommandWaiters()
    }

    private func resolveCompletedCommandWaiters() {
        var unresolved: [CompletedCommandWaiter] = []
        for waiter in completedCommandWaiters {
            let matches = completedCommands(domain: waiter.domain, method: waiter.method)
            if matches.count >= waiter.count {
                waiter.continuation.resume(returning: matches)
            } else {
                unresolved.append(waiter)
            }
        }
        completedCommandWaiters = unresolved
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
        let recordedCommand = RecordedCommand(command: command)
        commands.append(recordedCommand)
        resolveRecordedCommandWaiters()
        defer {
            recordCompletedCommand(recordedCommand)
        }

        if let gate = heldCommands.first(where: {
            $0.domain == command.domain.rawValue && $0.method == command.method
        })?.gate {
            await gate.wait()
        }

        if let termination = eventTermination {
            throw termination.error ?? WebInspectorProxyError.closed
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

    package func dispatchCommandWithReplyBoundary<Payload: Sendable, Result: Sendable>(
        _ command: WebInspectorProxyCommand<Payload, Result>
    ) async throws -> WebInspectorProxyCommandReply<Result> {
        let value = try await dispatchCommand(command)
        return WebInspectorProxyCommandReply(
            value: value,
            receivedSequence: orderedEventSequence
        )
    }

    package func finishEventSubscriptions(throwing error: WebInspectorProxyError?) async {
        guard eventTermination == nil else {
            return
        }
        let termination = EventTermination(error: error)
        eventTermination = termination
        let domainContinuations = eventContinuations.values.flatMap { Array($0.values) }
        eventContinuations.removeAll()
        let orderedContinuations = orderedEventContinuations.values.flatMap { Array($0.values) }
        orderedEventContinuations.removeAll()
        cancelledEventSubscriptionIDs.removeAll()
        let waiters = subscriberWaiters
        subscriberWaiters.removeAll()
        let registrationWaiters = subscriberWaiterRegistrationWaiters
        subscriberWaiterRegistrationWaiters.removeAll()
        let gates = Set(heldCommands.map { ObjectIdentifier($0.gate) })
            .compactMap { identifier in
                heldCommands.first { ObjectIdentifier($0.gate) == identifier }?.gate
            }
        heldCommands.removeAll()

        for waiter in waiters {
            waiter.promise.fulfill(.failure(termination.operationError))
        }
        for waiter in registrationWaiters {
            waiter.promise.fulfill(.success(()))
        }
        for continuation in domainContinuations {
            continuation.finish()
        }
        for continuation in orderedContinuations {
            continuation.finish(throwing: error)
        }
        for gate in gates {
            await gate.open()
        }
    }

    package func orderedEvents(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        terminalFailureHandler: @escaping WebInspectorProxyTerminalFailureHandler
    ) async -> WebInspectorProxyOrderedEventFeed {
        _ = terminalFailureHandler
        let key = OrderedEventSubscriptionKey(route: route, targetID: targetID)
        let pair = AsyncThrowingStream<WebInspectorProxyOrderedEvent, any Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        let id = UUID()
        pair.continuation.onTermination = { _ in
            Task {
                await self.cancelOrderedEventContinuation(id: id, key: key)
            }
        }
        addOrderedEventContinuation(pair.continuation, id: id, key: key)
        return WebInspectorProxyOrderedEventFeed(
            initialSequence: orderedEventSequence,
            events: pair.stream
        )
    }

    package func waitForEventSubscription(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain
    ) async {
        try? await waitForSubscriber(route: route, targetID: targetID, domain: domain, count: 1)
    }

    package nonisolated func events(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain,
        terminalFailureHandler: @escaping WebInspectorProxyTerminalFailureHandler
    ) -> AsyncStream<WebInspectorProxyEvent> {
        _ = terminalFailureHandler
        _ = route
        let key = EventSubscriptionKey(route: route, targetID: targetID, domain: domain)
        return AsyncStream<WebInspectorProxyEvent> { continuation in
            let id = UUID()
            continuation.onTermination = { _ in
                Task {
                    await self.cancelEventContinuation(id: id, key: key)
                }
            }
            Task {
                await self.addEventContinuation(continuation, id: id, key: key)
            }
        }
    }
}
