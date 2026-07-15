import WebInspectorProxyKit

/// A typed, container-owned semantic feature.
public protocol WebInspectorFeatureHandle: Sendable {
    var state: WebInspectorFeatureState { get }
    var stateUpdates: WebInspectorStateUpdates<WebInspectorFeatureState> { get }
}

/// The backend-visible state of WebKit's element picker.
public enum WebInspectorElementPickerState: Equatable, Sendable {
    case idle
    case enabling
    case active
    case resolvingSelection
    case disabling
}

/// Failures from commands whose model identity or feature authority changed.
public enum WebInspectorCommandError: Error, Equatable, Sendable {
    case staleIdentifier
    case targetChanged
    case connection(WebInspectorConnectionFailure)
    case featureUnsupported(
        WebInspectorFeatureID,
        requirements: [String]
    )
    case rejected(WebInspectorFailureDescription)
    case timedOut
    case containerClosed
}

/// Picker-specific failures. A picker failure never fails the DOM feature.
public enum WebInspectorElementPickerError: Error, Equatable, Sendable {
    case busy
    case targetChanged
    case enableFailed(WebInspectorFailureDescription)
    case disableFailed(WebInspectorFailureDescription)
    case selectionResolutionFailed(WebInspectorFailureDescription)
}

package func webInspectorCommandError(
    _ error: any Error,
    featureID: WebInspectorFeatureID,
    phase: String
) -> WebInspectorCommandError {
    if let command = error as? WebInspectorCommandError { return command }
    guard let proxy = error as? WebInspectorProxyError else {
        return .rejected(
            WebInspectorFailureDescription(
                code: "command.failed",
                phase: phase,
                message: String(describing: error)
            )
        )
    }
    switch proxy {
    case .closed:
        return .containerClosed
    case .staleIdentifier:
        return .staleIdentifier
    case .pageUnavailable:
        return .targetChanged
    case .timeout:
        return .timedOut
    case let .disconnected(message), let .transportFailure(message):
        return .connection(
            .native(
                WebInspectorFailureDescription(
                    code: "connection.disconnected",
                    phase: phase,
                    message: message
                )
            )
        )
    case let .unsupported(requirements):
        return .featureUnsupported(
            featureID,
            requirements: requirements.sorted()
        )
    case let .commandFailed(domain, method, message):
        return .rejected(
            WebInspectorFailureDescription(
                code: "\(domain).\(method)",
                phase: phase,
                message: message
            )
        )
    case let .commandRejected(method, message):
        return .rejected(
            WebInspectorFailureDescription(
                code: method,
                phase: phase,
                message: message
            )
        )
    case .attachFailed,
        .protocolViolation,
        .eventBufferOverflow,
        .invalidEventBufferCapacity,
        .replyBoundaryAlreadyOutstanding,
        .replyBoundaryUnavailable,
        .concurrentScopeConsumption,
        .connectionInUse:
        return .rejected(
            WebInspectorFailureDescription(
                code: "\(featureID.name).command",
                phase: phase,
                message: String(describing: proxy)
            )
        )
    }
}
