import Synchronization

package final class TransportReceiver: Sendable {
    // Swift cannot store a weak actor reference directly in this Sendable value
    // state. Every read and write of this box is protected by `state`'s Mutex;
    // the box never escapes the receiver. The unchecked conformance represents
    // only that synchronization fact, not ownership of connection state.
    private final class WeakCore: @unchecked Sendable {
        weak var value: ConnectionCore?
    }

    private struct State: Sendable {
        var core = WeakCore()
        var messages: [String] = []
        var messageStartIndex = 0
        var isDraining = false
        var generation: UInt64 = 0
        var isClosed = false
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
            $0.messages.append(message)
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

    package func close() {
        state.withLock {
            $0.isClosed = true
            $0.generation &+= 1
            $0.core.value = nil
            $0.messages.removeAll(keepingCapacity: false)
            $0.messageStartIndex = 0
            $0.isDraining = false
        }
    }

    package func fail(_ message: String) {
        let core = state.withLock { state in
            guard !state.isClosed else {
                return nil as ConnectionCore?
            }
            return state.core.value
        }
        Task { [weak core] in
            await core?.failFromNativeCallback(message)
        }
    }

    private func drain(generation: UInt64) async {
        while let next = nextMessage(generation: generation) {
            await next.core.receiveRootMessage(next.message)
        }
    }

    private func nextMessage(generation: UInt64) -> (core: ConnectionCore, message: String)? {
        state.withLock {
            guard !$0.isClosed, $0.generation == generation else {
                return nil
            }
            guard $0.messageStartIndex < $0.messages.count else {
                $0.messages.removeAll(keepingCapacity: true)
                $0.messageStartIndex = 0
                $0.isDraining = false
                return nil
            }
            guard let core = $0.core.value else {
                $0.isDraining = false
                return nil
            }

            let message = $0.messages[$0.messageStartIndex]
            $0.messageStartIndex += 1
            compactMessagesIfNeeded(in: &$0)
            return (core, message)
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
