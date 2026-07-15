import Synchronization

package final class ReplyPromise<Value: Sendable>: Sendable {
    private final class Storage: Sendable {
        let state = Mutex(State())
    }

    private enum RegistrationAction {
        case wait
        case resume(Result<Value, any Error>)
    }

    private struct State: Sendable {
        var result: Result<Value, any Error>?
        var waiters: [UInt64: CheckedContinuation<Value, any Error>] = [:]
        var registeringWaiterIDs: Set<UInt64> = []
        var nextWaiterID: UInt64 = 0
    }

    private let storage = Storage()

    package init() {}

    package func value() async throws -> Value {
        let storage = storage
        let waiterID = Self.registerWaiter(in: storage)

        return try await withTaskCancellationHandler {
            try await Self.wait(storage, waiterID: waiterID)
        } onCancel: {
            Self.cancelWaiter(waiterID, in: storage)
        }
    }

    package func valueIgnoringCancellation() async throws -> Value {
        let storage = storage
        let waiterID = Self.registerWaiter(in: storage)
        return try await Self.wait(storage, waiterID: waiterID)
    }

    @discardableResult
    package func fulfill(_ result: Result<Value, any Error>) -> Bool {
        let waiters = storage.state.withLock { state -> [CheckedContinuation<Value, any Error>]? in
            guard state.result == nil else {
                return nil
            }
            state.result = result
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll(keepingCapacity: false)
            return waiters
        }
        guard let waiters else {
            return false
        }
        for waiter in waiters {
            waiter.resume(with: result)
        }
        return true
    }

    package func waiterCountForTesting() -> Int {
        storage.state.withLock { $0.waiters.count }
    }

    package func bookkeepingCountForTesting() -> Int {
        storage.state.withLock { $0.waiters.count + $0.registeringWaiterIDs.count }
    }

    private static func registerWaiter(in storage: Storage) -> UInt64 {
        storage.state.withLock { state in
            precondition(
                state.nextWaiterID < UInt64.max,
                "ReplyPromise exhausted its waiter identifier space."
            )
            state.nextWaiterID += 1
            let waiterID = state.nextWaiterID
            state.registeringWaiterIDs.insert(waiterID)
            return waiterID
        }
    }

    private static func wait(
        _ storage: Storage,
        waiterID: UInt64
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let action = storage.state.withLock { state -> RegistrationAction in
                guard state.registeringWaiterIDs.remove(waiterID) != nil else {
                    return .resume(.failure(CancellationError()))
                }
                if let result = state.result {
                    return .resume(result)
                }
                precondition(
                    state.waiters[waiterID] == nil,
                    "ReplyPromise registered the same waiter twice."
                )
                state.waiters[waiterID] = continuation
                return .wait
            }

            switch action {
            case .wait:
                break
            case let .resume(result):
                continuation.resume(with: result)
            }
        }
    }

    private static func cancelWaiter(_ waiterID: UInt64, in storage: Storage) {
        let waiter = storage.state.withLock { state -> CheckedContinuation<Value, any Error>? in
            if let waiter = state.waiters.removeValue(forKey: waiterID) {
                return waiter
            }
            guard state.result == nil else {
                return nil
            }
            state.registeringWaiterIDs.remove(waiterID)
            return nil
        }
        waiter?.resume(throwing: CancellationError())
    }
}
