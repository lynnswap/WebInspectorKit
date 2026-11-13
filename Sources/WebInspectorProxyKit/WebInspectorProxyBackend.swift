import Foundation

package enum WebInspectorProxyDomain: String, Hashable, Sendable {
    case dom = "DOM"
    case css = "CSS"
    case network = "Network"
    case console = "Console"
    case runtime = "Runtime"
    case page = "Page"
    case inspector = "Inspector"
}

package enum WebInspectorProxyEventDomain: String, Hashable, Sendable {
    case ordered = "Ordered"
    case target = "Target"
    case dom = "DOM"
    case inspector = "Inspector"
    case css = "CSS"
    case network = "Network"
    case console = "Console"
    case runtime = "Runtime"
    case page = "Page"
}

package struct WebInspectorProxyTerminalFailure: Sendable {
    package let publicError: WebInspectorProxyError
    package let transportError: TransportSession.Error

    package static func transportFailed(_ error: TransportSession.Error) -> Self {
        let description: String
        switch error {
        case let .messageDecodingFailed(boundary, message):
            description = "Failed to decode \(boundary): \(message)"
        case let .eventDecodingFailed(method, message):
            description = "Failed to decode \(method): \(message)"
        case let .nativeAttachmentInvalidated(message):
            description = "Native inspector attachment invalidated: \(message)"
        default:
            description = "Inspector transport failed: \(error)"
        }
        return Self(publicError: .disconnected(description), transportError: error)
    }

    package static func eventDecodingFailed(
        method: String,
        error: any Error
    ) -> WebInspectorProxyTerminalFailure {
        let message = String(describing: error)
        return WebInspectorProxyTerminalFailure(
            publicError: .disconnected("Failed to decode \(method): \(message)"),
            transportError: .eventDecodingFailed(method: method, message: message)
        )
    }
}

package typealias WebInspectorProxyTerminalFailureHandler = @Sendable (
    WebInspectorProxyTerminalFailure
) async -> Void

package struct WebInspectorProxyCommandReply<Result: Sendable>: Sendable {
    package let value: Result
    package let receivedSequence: UInt64

    package init(value: Result, receivedSequence: UInt64) {
        self.value = value
        self.receivedSequence = receivedSequence
    }
}

/// A command of the inspector protocol, described by the type of its
/// payload.
///
/// The payload type states everything a backend needs to send the command
/// and read its reply, so a command cannot be sent with the parameters or the
/// reply decoding of another.
package protocol WebInspectorProxyCommandPayload: Sendable {
    /// The value the reply decodes to.
    associatedtype Result: Sendable

    static var domain: WebInspectorProxyDomain { get }

    /// The method name without its domain, such as `getDocument`.
    static var method: String { get }

    /// The scope of the identifier the command acts on, when a frame target
    /// owns that identifier. The command is sent to that target instead of
    /// the one it was issued on.
    var owningTargetScope: String? { get }

    /// The `params` object sent to WebKit.
    func parameters() throws -> [String: Any]

    /// Decodes the `result` object of the reply.
    /// - Parameter targetScope: The scope to give the identifiers in the
    ///   reply, when the command ran on a frame target.
    static func decodeResult(from data: Data, targetScope: String?) throws -> Result
}

package extension WebInspectorProxyCommandPayload {
    var owningTargetScope: String? {
        nil
    }

    func parameters() throws -> [String: Any] {
        [:]
    }
}

package extension WebInspectorProxyCommandPayload where Result == Void {
    static func decodeResult(from data: Data, targetScope: String?) throws {}
}

package struct WebInspectorProxyCommand<Payload: WebInspectorProxyCommandPayload>: Sendable {
    package let targetID: WebInspectorTarget.ID
    package let route: RoutingTargetID
    package let payload: Payload

    package var domain: WebInspectorProxyDomain {
        Payload.domain
    }

    package var method: String {
        Payload.method
    }

    package init(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID,
        payload: Payload
    ) {
        self.targetID = targetID
        self.route = route
        self.payload = payload
    }
}

package enum WebInspectorProxyEvent: Sendable {
    case targetLifecycle(WebInspectorTargetLifecycleEvent)
    case dom(DOM.Event)
    case inspector(Inspector.Event)
    case css(CSS.Event)
    case network(Network.Event)
    case console(Console.TargetedEvent)
    case runtime(Runtime.Event)
}

package struct WebInspectorProxyOrderedEvent: Sendable {
    package let sequence: UInt64
    package let event: WebInspectorProxyEvent?

    package init(sequence: UInt64, event: WebInspectorProxyEvent?) {
        self.sequence = sequence
        self.event = event
    }
}

package struct WebInspectorProxyOrderedEventFeed: Sendable {
    package let initialSequence: UInt64
    package let events: AsyncThrowingStream<WebInspectorProxyOrderedEvent, any Error>

    package init(
        initialSequence: UInt64,
        events: AsyncThrowingStream<WebInspectorProxyOrderedEvent, any Error>
    ) {
        self.initialSequence = initialSequence
        self.events = events
    }
}

package protocol WebInspectorProxyBackend: Sendable {
    func dispatchCommand<Payload: WebInspectorProxyCommandPayload>(
        _ command: WebInspectorProxyCommand<Payload>
    ) async throws -> Payload.Result

    func dispatchCommandWithReplyBoundary<Payload: WebInspectorProxyCommandPayload>(
        _ command: WebInspectorProxyCommand<Payload>
    ) async throws -> WebInspectorProxyCommandReply<Payload.Result>

    func finishEventSubscriptions(throwing error: WebInspectorProxyError?) async

    func orderedEvents(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        terminalFailureHandler: @escaping WebInspectorProxyTerminalFailureHandler
    ) async -> WebInspectorProxyOrderedEventFeed

    nonisolated func events(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain,
        terminalFailureHandler: @escaping WebInspectorProxyTerminalFailureHandler
    ) -> AsyncStream<WebInspectorProxyEvent>

    func waitForEventSubscription(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain
    ) async
}

/// The backend of a proxy that is not connected to a web view, which
/// previews and tests create. Every command fails, and every event stream
/// ends without an event.
package struct UnavailableProxyBackend: WebInspectorProxyBackend {
    package init() {}

    package func dispatchCommand<Payload: WebInspectorProxyCommandPayload>(
        _ command: WebInspectorProxyCommand<Payload>
    ) async throws -> Payload.Result {
        throw unimplementedCommand(domain: Payload.domain.rawValue, method: Payload.method)
    }

    package func dispatchCommandWithReplyBoundary<Payload: WebInspectorProxyCommandPayload>(
        _ command: WebInspectorProxyCommand<Payload>
    ) async throws -> WebInspectorProxyCommandReply<Payload.Result> {
        throw unimplementedCommand(domain: Payload.domain.rawValue, method: Payload.method)
    }

    package func finishEventSubscriptions(throwing error: WebInspectorProxyError?) async {}

    package func orderedEvents(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        terminalFailureHandler: @escaping WebInspectorProxyTerminalFailureHandler
    ) async -> WebInspectorProxyOrderedEventFeed {
        WebInspectorProxyOrderedEventFeed(
            initialSequence: 0,
            events: AsyncThrowingStream { $0.finish() }
        )
    }

    package nonisolated func events(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain,
        terminalFailureHandler: @escaping WebInspectorProxyTerminalFailureHandler
    ) -> AsyncStream<WebInspectorProxyEvent> {
        finishedStream()
    }

    package func waitForEventSubscription(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain
    ) async {}
}
