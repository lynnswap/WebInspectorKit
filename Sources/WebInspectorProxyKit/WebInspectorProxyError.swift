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

    /// A structured event subscriber could not retain another pending event.
    case eventBufferOverflow(capacity: Int)

    /// The underlying inspector transport failed.
    case transportFailure(String)

    /// A protocol command did not receive a reply before its timeout.
    case timeout(domain: String, method: String)
}

package func unimplementedCommand(domain: String, method: String) -> WebInspectorProxyError {
    .commandFailed(
        domain: domain,
        method: method,
        message: "WebInspectorProxyKit shell does not implement \(domain).\(method)."
    )
}
