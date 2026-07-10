import Synchronization

package final class TransportReceiver: Sendable {
    // Swift cannot store a weak actor reference directly in this Sendable value
    // state. Every read and write of this box is protected by `state`'s Mutex;
    // the box never escapes the receiver. The unchecked conformance represents
    // only that synchronization fact, not ownership of connection state.
    private final class WeakCore: @unchecked Sendable {
        weak var value: ConnectionCore?
    }

    private struct QueuedMessage: Sendable {
        let ordinal: UInt64
        let payload: String
    }

    private struct DrainWaiter: Sendable {
        let through: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State: Sendable {
        var core = WeakCore()
        var messages: [QueuedMessage] = []
        var messageStartIndex = 0
        var isDraining = false
        var generation: UInt64 = 0
        var tailOrdinal: UInt64 = 0
        var completedOrdinal: UInt64 = 0
        var drainWaiters: [DrainWaiter] = []
        var isClosed = false
        var closeWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private enum DrainStep: Sendable {
        case deliver(core: ConnectionCore, message: QueuedMessage)
        case stop(closeWaiters: [CheckedContinuation<Void, Never>])
    }

    private let state = Mutex(State())

    package init() {}

    package func setCore(_ core: ConnectionCore) {
        let drainGeneration = state.withLock {
            guard !$0.isClosed else {
                return nil as UInt64?
            }
            $0.core.value = core
            guard $0.messages.isEmpty == false, !$0.isDraining else {
                return nil
            }
            $0.isDraining = true
            return $0.generation
        }

        guard let drainGeneration else {
            return
        }
        Task {
            await drain(generation: drainGeneration)
        }
    }

    package func receive(_ message: String) {
        let drainGeneration = state.withLock {
            guard !$0.isClosed else {
                return nil as UInt64?
            }
            precondition($0.tailOrdinal < UInt64.max, "TransportReceiver exhausted its message ordinal space.")
            $0.tailOrdinal += 1
            $0.messages.append(QueuedMessage(ordinal: $0.tailOrdinal, payload: message))
            guard $0.core.value != nil else {
                return nil
            }
            guard !$0.isDraining else {
                return nil
            }
            $0.isDraining = true
            return $0.generation
        }

        guard let drainGeneration else {
            return
        }
        Task {
            await drain(generation: drainGeneration)
        }
    }

    /// Returns the ordinal of the newest message accepted by this receiver.
    ///
    /// A caller can snapshot this value and then await exactly that prefix
    /// without waiting for messages that arrive later on the live connection.
    package func tailOrdinal() -> UInt64 {
        state.withLock { $0.tailOrdinal }
    }

    /// Suspends until `ConnectionCore` has completed every accepted message
    /// through `ordinal`, or until the receiver closes.
    package func waitUntilDrained(through ordinal: UInt64) async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                precondition(
                    ordinal <= state.tailOrdinal,
                    "Cannot wait for a TransportReceiver ordinal that has not been accepted."
                )
                guard !state.isClosed, state.completedOrdinal < ordinal else {
                    return true
                }
                state.drainWaiters.append(
                    DrainWaiter(through: ordinal, continuation: continuation)
                )
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    package func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let readyWaiters = state.withLock { state in
                let drainWaiters = Self.seal(&state)
                guard state.isDraining else {
                    return (
                        close: [continuation],
                        drain: drainWaiters
                    )
                }
                state.closeWaiters.append(continuation)
                return (
                    close: [] as [CheckedContinuation<Void, Never>],
                    drain: drainWaiters
                )
            }
            Self.resume(readyWaiters.close)
            Self.resumeDrainWaiters(readyWaiters.drain)
        }
    }

    /// Synchronous cancellation backstop for `NativeAttachment.isolated deinit`.
    ///
    /// Normal lifecycle code must use `close()` so it observes completion of an
    /// active drain before detaching the native frontend.
    package func closeSynchronously() {
        let readyWaiters = state.withLock { state in
            let drainWaiters = Self.seal(&state)
            return (
                close: Self.takeCloseWaitersIfQuiescent(from: &state),
                drain: drainWaiters
            )
        }
        Self.resume(readyWaiters.close)
        Self.resumeDrainWaiters(readyWaiters.drain)
    }

    package func closeWaiterCountForTesting() -> Int {
        state.withLock { $0.closeWaiters.count }
    }

    @discardableResult
    package func fail(_ message: String) -> Task<Void, Never>? {
        let result: (
            core: ConnectionCore?,
            readyCloseWaiters: [CheckedContinuation<Void, Never>],
            readyDrainWaiters: [DrainWaiter]
        ) = state.withLock { state in
            guard !state.isClosed else {
                return (nil, [], [])
            }
            let core = state.core.value
            let drainWaiters = Self.seal(&state)
            return (
                core,
                Self.takeCloseWaitersIfQuiescent(from: &state),
                drainWaiters
            )
        }
        Self.resume(result.readyCloseWaiters)
        Self.resumeDrainWaiters(result.readyDrainWaiters)
        guard let core = result.core else {
            return nil
        }
        return core.failFromNativeCallback(message)
    }

    private func drain(generation: UInt64) async {
        while true {
            switch nextDrainStep(generation: generation) {
            case let .deliver(core, message):
                await core.receiveRootMessage(message.payload)
                complete(message.ordinal)
            case let .stop(closeWaiters):
                Self.resume(closeWaiters)
                return
            }
        }
    }

    private func nextDrainStep(generation: UInt64) -> DrainStep {
        state.withLock {
            guard !$0.isClosed, $0.generation == generation else {
                $0.isDraining = false
                return .stop(closeWaiters: Self.takeCloseWaitersIfQuiescent(from: &$0))
            }
            guard $0.messageStartIndex < $0.messages.count else {
                $0.messages.removeAll(keepingCapacity: true)
                $0.messageStartIndex = 0
                $0.isDraining = false
                return .stop(closeWaiters: Self.takeCloseWaitersIfQuiescent(from: &$0))
            }
            guard let core = $0.core.value else {
                $0.isDraining = false
                return .stop(closeWaiters: Self.takeCloseWaitersIfQuiescent(from: &$0))
            }

            let message = $0.messages[$0.messageStartIndex]
            $0.messageStartIndex += 1
            compactMessagesIfNeeded(in: &$0)
            return .deliver(core: core, message: message)
        }
    }

    private func complete(_ ordinal: UInt64) {
        let readyWaiters = state.withLock { state in
            precondition(
                ordinal == state.completedOrdinal &+ 1,
                "TransportReceiver completed messages outside FIFO order."
            )
            state.completedOrdinal = ordinal
            return Self.takeReadyDrainWaiters(from: &state)
        }
        Self.resumeDrainWaiters(readyWaiters)
    }

    private static func seal(_ state: inout State) -> [DrainWaiter] {
        guard !state.isClosed else {
            return []
        }
        state.isClosed = true
        state.generation &+= 1
        state.core.value = nil
        state.messages.removeAll(keepingCapacity: false)
        state.messageStartIndex = 0
        let drainWaiters = state.drainWaiters
        state.drainWaiters.removeAll(keepingCapacity: false)
        return drainWaiters
    }

    private static func takeReadyDrainWaiters(
        from state: inout State
    ) -> [DrainWaiter] {
        var pending: [DrainWaiter] = []
        var ready: [DrainWaiter] = []
        for waiter in state.drainWaiters {
            if waiter.through <= state.completedOrdinal {
                ready.append(waiter)
            } else {
                pending.append(waiter)
            }
        }
        state.drainWaiters = pending
        return ready
    }

    private static func takeCloseWaitersIfQuiescent(
        from state: inout State
    ) -> [CheckedContinuation<Void, Never>] {
        guard state.isClosed, !state.isDraining else {
            return []
        }
        let waiters = state.closeWaiters
        state.closeWaiters.removeAll(keepingCapacity: false)
        return waiters
    }

    private static func resume(_ waiters: [CheckedContinuation<Void, Never>]) {
        for waiter in waiters {
            waiter.resume()
        }
    }

    private static func resumeDrainWaiters(_ waiters: [DrainWaiter]) {
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }

    private func compactMessagesIfNeeded(in state: inout State) {
        if state.messageStartIndex == state.messages.count {
            state.messages.removeAll(keepingCapacity: true)
            state.messageStartIndex = 0
        } else if state.messageStartIndex >= 64 && state.messageStartIndex * 2 >= state.messages.count {
            state.messages.removeFirst(state.messageStartIndex)
            state.messageStartIndex = 0
        }
    }
}
