import WebInspectorDataKit
import WebInspectorProxyKit

/// Failures reported by deterministic DataKit test synchronization helpers.
public enum WebInspectorDataKitTestingError: Error, Equatable, Sendable {
    /// The inspector detached before startup reached a terminal result.
    case detachedBeforeStartupCompleted

    /// The inspector stopped publishing status before startup reached a terminal result.
    case statusUpdatesEndedBeforeStartupCompleted
}

public extension WebInspector {
    /// Attaches through an existing proxy connection, such as the one of a
    /// `WebInspectorProxyTestRuntime`, and waits for startup to finish.
    ///
    /// The inspector closes the proxy when the attachment ends. The wait
    /// observes lifecycle state instead of using a wall-clock deadline.
    /// - Throws: The startup failure, or `CancellationError` when a later
    ///   call replaced this one.
    func attachForTesting(to proxy: WebInspectorProxy) async throws {
        let wasApplied = try await attach(makeContainer: {
            WebInspectorContainer(proxy: proxy)
        })
        guard wasApplied else {
            throw CancellationError()
        }
        for await status in context.statusUpdates {
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

    /// Detaches and waits until the attachment has ended.
    func detachForTesting() async {
        await detachAndWait()
    }
}
