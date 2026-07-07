import Foundation

public enum WebInspectorProxyError: Error, Sendable, Equatable {
    case unsupported([String])
    case attachFailed(String)
    case closed
    case disconnected(String)
    case commandFailed(domain: String, method: String, message: String)
    case timeout(domain: String, method: String)
}

package func unimplementedCommand(domain: String, method: String) -> WebInspectorProxyError {
    .commandFailed(
        domain: domain,
        method: method,
        message: "WebInspectorProxyKit shell does not implement \(domain).\(method)."
    )
}
