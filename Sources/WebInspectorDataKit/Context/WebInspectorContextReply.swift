import Synchronization

package final class WebInspectorContextReply<Value: Sendable>:
    @unchecked Sendable
{
    private enum State {
        case pending([CheckedContinuation<Value, any Error>])
        case resolved(Result<Value, any Error>)
    }

    private let state = Mutex(State.pending([]))

    package init() {}

    package var isPending: Bool {
        state.withLock { state in
            if case .pending = state { true } else { false }
        }
    }

    /// Joins a shared operation without allowing one waiter's cancellation to
    /// resolve the operation for every other waiter.
    package func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let result = state.withLock {
                state -> Result<Value, any Error>? in
                switch state {
                case let .pending(waiters):
                    state = .pending(waiters + [continuation])
                    return nil
                case let .resolved(result):
                    return result
                }
            }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    /// Waits for a caller-owned operation and cancels that operation when the
    /// calling task is cancelled.
    package func cancellableValue() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock {
                    state -> Result<Value, any Error>? in
                    switch state {
                    case let .pending(waiters):
                        state = .pending(waiters + [continuation])
                        return nil
                    case let .resolved(result):
                        return result
                    }
                }
                if let result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }

    package func succeed(_ value: Value) {
        resolve(.success(value))
    }

    package func fail(_ error: any Error) {
        resolve(.failure(error))
    }

    package func resolve(_ result: Result<Value, any Error>) {
        let waiters = state.withLock {
            state -> [CheckedContinuation<Value, any Error>] in
            guard case let .pending(waiters) = state else { return [] }
            state = .resolved(result)
            return waiters
        }
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }
}
