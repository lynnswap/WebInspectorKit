import Synchronization

/// A deterministic, cancellation-aware suspension point for asynchronous tests.
public final class WebInspectorTestGate: Sendable {
    /// A wait handle that owns only gate state, not the gate owner itself.
    public struct Waiter: Sendable {
        fileprivate let storage: Storage

        fileprivate init(storage: Storage) {
            self.storage = storage
        }

        /// Suspends until the gate opens or is cancelled.
        public func wait() async {
            _ = try? await WebInspectorTestGate.waitUntilOpen(storage)
        }

        func waitUntilOpen() async throws {
            try await WebInspectorTestGate.waitUntilOpen(storage)
        }

        func waitUntilOpenForTesting(
            afterWaiterAllocation action: @escaping @Sendable () async -> Void
        ) async throws {
            try await WebInspectorTestGate.waitUntilOpen(
                storage,
                afterWaiterAllocation: action
            )
        }

        var pendingWaiterCountForTesting: Int {
            storage.state.withLock { $0.waiters.count }
        }
    }

    fileprivate final class Storage: Sendable {
        struct State: Sendable {
            var isOpen = false
            var isCancelled = false
            var waiters: [UInt64: CheckedContinuation<Void, any Error>] = [:]
            var registeringWaiterIDs: Set<UInt64> = []
            var nextWaiterID: UInt64 = 0
        }

        let state = Mutex(State())
    }

    private enum RegistrationAction {
        case wait
        case open
        case cancelled
    }

    private let storage: Storage
    public let waiter: Waiter

    public init() {
        let storage = Storage()
        self.storage = storage
        waiter = Waiter(storage: storage)
    }

    deinit {
        Self.cancel(storage)
    }

    /// Opens the gate and resumes every current and future waiter successfully.
    public func open() {
        let storage = storage
        let waiters = storage.state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            guard !state.isOpen, !state.isCancelled else {
                return []
            }
            state.isOpen = true
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Cancels the gate and resumes every current and future waiter with cancellation.
    public func cancel() {
        Self.cancel(storage)
    }

    private static func waitUntilOpen(
        _ storage: Storage,
        afterWaiterAllocation: (@Sendable () async -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        let waiterID = storage.state.withLock { state -> UInt64 in
            precondition(
                state.nextWaiterID < UInt64.max,
                "WebInspectorTestGate exhausted its waiter identifier space."
            )
            state.nextWaiterID += 1
            let waiterID = state.nextWaiterID
            state.registeringWaiterIDs.insert(waiterID)
            return waiterID
        }

        try await withTaskCancellationHandler {
            await afterWaiterAllocation?()
            try await withCheckedThrowingContinuation { continuation in
                let action = storage.state.withLock { state -> RegistrationAction in
                    if state.registeringWaiterIDs.remove(waiterID) == nil || state.isCancelled {
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
                guard !state.isOpen, !state.isCancelled else {
                    return nil
                }
                guard let waiter = state.waiters.removeValue(forKey: waiterID) else {
                    state.registeringWaiterIDs.remove(waiterID)
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
            state.registeringWaiterIDs.removeAll(keepingCapacity: false)
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waiters {
            waiter.resume(throwing: CancellationError())
        }
    }
}
