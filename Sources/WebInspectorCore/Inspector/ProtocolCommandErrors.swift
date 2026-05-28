import WebInspectorTransport

package func isUnsupportedProtocolCommandError(
    _ method: String,
    error: any Error
) -> Bool {
    guard case let TransportError.remoteError(errorMethod, _, message) = error,
          errorMethod == method else {
        return false
    }
    let normalizedMessage = message.lowercased()
    if normalizedMessage.contains("unknown command")
        || normalizedMessage.contains("unknown method")
        || normalizedMessage.contains("unrecognized command")
        || normalizedMessage.contains("unrecognized method")
        || normalizedMessage.contains("unsupported command")
        || normalizedMessage.contains("unsupported method")
        || normalizedMessage.contains("command not found")
        || normalizedMessage.contains("method not found") {
        return true
    }

    guard normalizedMessage.contains("not implemented") else {
        return false
    }
    return normalizedMessage.contains(method.lowercased())
        || normalizedMessage.contains("command")
        || normalizedMessage.contains("method")
}
