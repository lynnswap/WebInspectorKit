import Synchronization

/// A deterministic, cancellation-aware suspension point for asynchronous tests.
public final class WebInspectorCancellationAwareTestGate: Sendable {
    private final class Storage: Sendable {
        struct State: Sendable {
            var isOpen = false
            var isCancelled = false
            var waiters: [UInt64: CheckedContinuation<Void, any Error>] = [:]
            var cancelledWaiterIDs: Set<UInt64> = []
            var nextWaiterID: UInt64 = 0
        }

        let state = Mutex(State())
    }

    private enum RegistrationAction {
        case wait
        case open
        case cancelled
    }

    private let storage = Storage()

    public init() {}

    deinit {
        Self.cancel(storage)
    }

    /// Opens the gate and resumes every current and future waiter successfully.
    public func open() async {
        let storage = storage
        let waiters = storage.state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            guard !state.isOpen, !state.isCancelled else {
                return []
            }
            state.isOpen = true
            state.cancelledWaiterIDs.removeAll(keepingCapacity: false)
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Cancels the gate and resumes every current and future waiter with cancellation.
    public func cancel() async {
        Self.cancel(storage)
    }

    /// Suspends until the gate opens or is cancelled.
    ///
    /// Cancellation is intentionally terminal for a test gate. Callers that
    /// need to observe cancellation should use the module-internal throwing
    /// operation used by the raw-wire driver.
    public func wait() async {
        _ = try? await Self.waitUntilOpen(storage)
    }

    func waitUntilOpen() async throws {
        try await Self.waitUntilOpen(storage)
    }

    private static func waitUntilOpen(_ storage: Storage) async throws {
        try Task.checkCancellation()
        let waiterID = storage.state.withLock { state -> UInt64 in
            precondition(
                state.nextWaiterID < UInt64.max,
                "WebInspectorCancellationAwareTestGate exhausted its waiter identifier space."
            )
            state.nextWaiterID += 1
            return state.nextWaiterID
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let action = storage.state.withLock { state -> RegistrationAction in
                    if state.cancelledWaiterIDs.remove(waiterID) != nil || state.isCancelled {
                        return .cancelled
                    }
                    if state.isOpen {
                        return .open
                    }
                    state.waiters[waiterID] = continuation
                    return .wait
                }
                switch action {
                case .wait:
                    break
                case .open:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let waiter = storage.state.withLock { state -> CheckedContinuation<Void, any Error>? in
                guard let waiter = state.waiters.removeValue(forKey: waiterID) else {
                    if !state.isOpen, !state.isCancelled {
                        state.cancelledWaiterIDs.insert(waiterID)
                    }
                    return nil
                }
                return waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    private static func cancel(_ storage: Storage) {
        let waiters = storage.state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            guard !state.isOpen, !state.isCancelled else {
                return []
            }
            state.isCancelled = true
            state.cancelledWaiterIDs.removeAll(keepingCapacity: false)
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waiters {
            waiter.resume(throwing: CancellationError())
        }
    }
}
