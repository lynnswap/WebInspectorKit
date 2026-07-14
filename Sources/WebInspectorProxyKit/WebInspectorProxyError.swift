import Foundation

/// Errors thrown by `WebInspectorProxyKit` commands and attachment APIs.
public enum WebInspectorProxyError: Error, Sendable, Equatable {
    /// The current platform or WebKit runtime does not support required features.
    case unsupported([String])

    /// Attaching the inspector connection failed.
    case attachFailed(String)

    /// The proxy was closed before the requested operation completed.
    case closed

    /// No physical page target is currently available for the logical page.
    case pageUnavailable

    /// A target-scoped identifier belongs to an older page generation.
    case staleIdentifier

    /// The inspector connection disconnected.
    case disconnected(String)

    /// A protocol command failed in the backend.
    case commandFailed(domain: String, method: String, message: String)

    /// The inspected target rejected a protocol command.
    case commandRejected(method: String, message: String)

    /// A known protocol envelope or event payload was malformed.
    case protocolViolation(String)

    /// An ordered event scope could not retain another pending event.
    case eventBufferOverflow(capacity: Int)

    /// A bounded event scope requires a positive capacity.
    case invalidEventBufferCapacity(Int)

    /// A scope command was started while another reply boundary was outstanding.
    case replyBoundaryAlreadyOutstanding

    /// A requested reply boundary could not be reached before scope delivery ended.
    case replyBoundaryUnavailable

    /// More than one task attempted to consume the same ordered scope concurrently.
    case concurrentScopeConsumption

    /// Another exclusive consumer already owns this connection.
    case connectionInUse

    /// The underlying inspector transport failed.
    case transportFailure(String)

    /// A protocol command did not receive a reply before its timeout.
    case timeout(domain: String, method: String)
}

package enum ConnectionError: Error, Sendable, Equatable {
    case closed
    case failed(String)
    case unreadableEnvelope
    case malformedTargetControlPlane(String)
    case missingTarget(String)
    case replyTimeout(method: String)
    case remoteError(method: String, message: String)
}
