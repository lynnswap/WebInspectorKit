import WebInspectorDataKit

/// Failures reported by deterministic DataKit test synchronization helpers.
public enum WebInspectorDataKitTestingError: Error, Equatable, Sendable {
    /// The context detached before startup reached a terminal result.
    case detachedBeforeStartupCompleted

    /// The context stopped publishing status before startup reached a terminal result.
    case statusUpdatesEndedBeforeStartupCompleted
}

public extension WebInspectorContext {
    /// Starts the context and waits for its startup state to become terminal.
    ///
    /// This observes lifecycle state instead of using a wall-clock deadline.
    /// Cancellation ends the wait and remains owned by the calling test.
    func startAndWaitForStartupForTesting(
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        let updates = statusUpdates
        start(isolation: isolation)
        for await status in updates {
            try Task.checkCancellation()
            switch status.state {
            case .attaching:
                continue
            case .attached:
                return
            case .detached:
                throw WebInspectorDataKitTestingError.detachedBeforeStartupCompleted
            case .failed(let error):
                throw error
            }
        }

        try Task.checkCancellation()
        throw WebInspectorDataKitTestingError.statusUpdatesEndedBeforeStartupCompleted
    }
}
