import Foundation
import WebViewProxyKit

package struct AnyRecordedValue: @unchecked Sendable {
    package let value: Any

    package init(_ value: some Sendable) {
        self.value = value
    }

    package func cast<T>(as type: T.Type = T.self) -> T? {
        value as? T
    }
}

public struct RecordedCommand: Equatable, Sendable {
    public let targetID: WebViewTarget.ID
    public let domain: String
    public let method: String
    package let route: RoutingTargetID
    package let payload: AnyRecordedValue

    public init(domain: String, method: String) {
        targetID = WebViewTarget.ID("unscoped-recorded-command")
        route = RoutingTargetID("unscoped-recorded-command")
        self.domain = domain
        self.method = method
        payload = AnyRecordedValue(())
    }

    package init<Payload: Sendable, Result: Sendable>(
        command: WebViewProxyCommand<Payload, Result>
    ) {
        targetID = command.targetID
        route = command.route
        domain = command.domain.rawValue
        method = command.method
        payload = AnyRecordedValue(command.payload)
    }

    public static func == (lhs: RecordedCommand, rhs: RecordedCommand) -> Bool {
        lhs.domain == rhs.domain && lhs.method == rhs.method
    }
}

private struct HeldCommand: Sendable {
    var domain: String
    var method: String
    var gate: WebViewTestGate
}

private struct CommandKey: Hashable, Sendable {
    var domain: String
    var method: String
}

private struct QueuedResult: @unchecked Sendable {
    var value: Any

    init(_ value: some Sendable) {
        self.value = value
    }
}

private struct EventSubscriptionKey: Hashable, Sendable {
    var route: RoutingTargetID
    var targetID: WebViewTarget.ID
    var domain: WebViewProxyEventDomain
}

private struct SubscriberWaiter: Sendable {
    var route: RoutingTargetID?
    var targetID: WebViewTarget.ID
    var domain: WebViewProxyEventDomain
    var count: Int
    var continuation: CheckedContinuation<Void, Never>
}

public enum WebViewTestBackendError: Error, Equatable, Sendable {
    case unsupportedEventDomain(String)
}

public actor WebViewTestBackend {
    private var enqueuedReplies: [CommandKey: [QueuedResult]]
    private var commands: [RecordedCommand]
    private var heldCommands: [HeldCommand]
    private var eventContinuations: [EventSubscriptionKey: [UUID: AsyncStream<WebViewProxyEvent>.Continuation]]
    private var subscriberWaiters: [SubscriberWaiter]

    public init() {
        enqueuedReplies = [:]
        commands = []
        heldCommands = []
        eventContinuations = [:]
        subscriberWaiters = []
    }

    public func enqueue<Result: Sendable>(
        _ result: Result,
        for domain: String,
        method: String
    ) async {
        let key = CommandKey(domain: domain, method: method)
        enqueuedReplies[key, default: []].append(QueuedResult(result))
    }

    public func emit(_ event: Network.Event, target: WebViewTarget.ID) async {
        emit(.network(event), target: target, route: nil, domain: .network)
    }

    public func emit(_ event: Network.Event, target: WebViewTarget) async {
        emit(.network(event), target: target.id, route: target.route, domain: .network)
    }

    public func emit(_ event: DOM.Event, target: WebViewTarget.ID) async {
        emit(.dom(event), target: target, route: nil, domain: .dom)
    }

    public func emit(_ event: DOM.Event, target: WebViewTarget) async {
        emit(.dom(event), target: target.id, route: target.route, domain: .dom)
    }

    public func emit(_ event: CSS.Event, target: WebViewTarget.ID) async {
        emit(.css(event), target: target, route: nil, domain: .css)
    }

    public func emit(_ event: CSS.Event, target: WebViewTarget) async {
        emit(.css(event), target: target.id, route: target.route, domain: .css)
    }

    public func emit(_ event: Console.Event, target: WebViewTarget.ID) async {
        emit(.console(event), target: target, route: nil, domain: .console)
    }

    public func emit(_ event: Console.Event, target: WebViewTarget) async {
        emit(.console(event), target: target.id, route: target.route, domain: .console)
    }

    public func emit(_ event: Runtime.Event, target: WebViewTarget.ID) async {
        emit(.runtime(event), target: target, route: nil, domain: .runtime)
    }

    public func emit(_ event: Runtime.Event, target: WebViewTarget) async {
        emit(.runtime(event), target: target.id, route: target.route, domain: .runtime)
    }

    public func recordedCommands() async -> [RecordedCommand] {
        commands
    }

    public func waitForSubscribers(
        domain: String,
        target: WebViewTarget.ID,
        count: Int
    ) async throws {
        guard let eventDomain = WebViewProxyEventDomain(rawValue: domain) else {
            throw WebViewTestBackendError.unsupportedEventDomain(domain)
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

    public func waitForSubscribers(
        domain: String,
        target: WebViewTarget,
        count: Int
    ) async throws {
        guard let eventDomain = WebViewProxyEventDomain(rawValue: domain) else {
            throw WebViewTestBackendError.unsupportedEventDomain(domain)
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

    public func hold(domain: String, method: String, gate: WebViewTestGate) async {
        heldCommands.append(HeldCommand(domain: domain, method: method, gate: gate))
    }

    private func emit(
        _ event: WebViewProxyEvent,
        target targetID: WebViewTarget.ID,
        route: RoutingTargetID?,
        domain: WebViewProxyEventDomain
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
        _ continuation: AsyncStream<WebViewProxyEvent>.Continuation,
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

    private func subscriberCount(for targetID: WebViewTarget.ID, domain: WebViewProxyEventDomain) -> Int {
        eventContinuations.reduce(into: 0) { count, entry in
            if entry.key.targetID == targetID && entry.key.domain == domain {
                count += entry.value.count
            }
        }
    }

    private func unambiguousRoute(
        for targetID: WebViewTarget.ID,
        domain: WebViewProxyEventDomain,
        matching keys: [EventSubscriptionKey]? = nil
    ) -> RoutingTargetID {
        let matchingKeys = keys ?? eventContinuations.keys.filter {
            $0.targetID == targetID && $0.domain == domain
        }
        let routes = Set(matchingKeys.map(\.route))
        guard routes.count <= 1 else {
            preconditionFailure(
                "Multiple routes are subscribed for \(domain.rawValue) target \(targetID); emit with WebViewTarget."
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

extension WebViewTestBackend: WebViewProxyBackend {
    package func dispatchCommand<Payload: Sendable, Result: Sendable>(
        _ command: WebViewProxyCommand<Payload, Result>
    ) async throws -> Result {
        commands.append(RecordedCommand(command: command))

        if let gate = heldCommands.first(where: {
            $0.domain == command.domain.rawValue && $0.method == command.method
        })?.gate {
            await gate.wait()
        }

        let key = CommandKey(domain: command.domain.rawValue, method: command.method)
        guard var results = enqueuedReplies[key], results.isEmpty == false else {
            throw WebViewProxyError.commandFailed(
                domain: command.domain.rawValue,
                method: command.method,
                message: "No enqueued result for \(command.domain.rawValue).\(command.method)."
            )
        }

        let queued = results.removeFirst()
        enqueuedReplies[key] = results.isEmpty ? nil : results

        guard let result = queued.value as? Result else {
            throw WebViewProxyError.commandFailed(
                domain: command.domain.rawValue,
                method: command.method,
                message: "Enqueued result for \(command.domain.rawValue).\(command.method) has type "
                    + "\(type(of: queued.value)); expected \(Result.self)."
            )
        }
        return result
    }

    package func waitForEventSubscription(
        route: RoutingTargetID,
        targetID: WebViewTarget.ID,
        domain: WebViewProxyEventDomain
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
        targetID: WebViewTarget.ID,
        domain: WebViewProxyEventDomain
    ) -> AsyncStream<WebViewProxyEvent> {
        _ = route
        let key = EventSubscriptionKey(route: route, targetID: targetID, domain: domain)
        return AsyncStream<WebViewProxyEvent> { continuation in
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
