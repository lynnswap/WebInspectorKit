import Observation
import WebInspectorDataKit
import WebInspectorProxyKit

/// Failures reported by deterministic DataKit test synchronization helpers.
public enum WebInspectorDataKitTestingError: Error, Equatable, Sendable {
    /// The inspector detached before startup reached a terminal result.
    case detachedBeforeStartupCompleted
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
        let wasApplied = try await attachAndWait(makeContainer: {
            WebInspectorContainer(proxy: proxy)
        })
        guard wasApplied else {
            throw CancellationError()
        }
        let attachedContext = context
        while true {
            try Task.checkCancellation()
            // A later call replaced the attachment while it was starting.
            guard context === attachedContext else {
                throw CancellationError()
            }
            switch attachedContext.state {
            case .attaching:
                await stateChange()
            case .attached:
                return
            case .detached:
                throw WebInspectorDataKitTestingError.detachedBeforeStartupCompleted
            case .failed(let error):
                throw error
            }
        }
    }

    /// Detaches and waits until the attachment has ended.
    func detachForTesting() async {
        await detachAndWait()
    }

    /// Suspends until ``state`` changes or the calling task is cancelled.
    private func stateChange() async {
        let waiter = StateChangeWaiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.continuation = continuation
                withObservationTracking {
                    _ = state
                } onChange: {
                    Task { @MainActor in
                        waiter.resume()
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                waiter.resume()
            }
        }
    }
}

@MainActor
private final class StateChangeWaiter {
    var continuation: CheckedContinuation<Void, Never>?

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
