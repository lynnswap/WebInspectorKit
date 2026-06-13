import Synchronization
import WebInspectorTransport

package final class TransportReceiver: @unchecked Sendable {
    private struct State: Sendable {
        var transport: TransportSession?
        var messages: [String] = []
        var messageStartIndex = 0
        var isDraining = false
    }

    private let state = Mutex(State())

    package init() {}

    package func setTransport(_ transport: TransportSession) {
        let shouldStartDraining = state.withLock {
            $0.transport = transport
            guard $0.messages.isEmpty == false, !$0.isDraining else {
                return false
            }
            $0.isDraining = true
            return true
        }

        guard shouldStartDraining else {
            return
        }
        Task {
            await drain()
        }
    }

    package func receive(_ message: String) {
        let shouldStartDraining = state.withLock {
            $0.messages.append(message)
            guard $0.transport != nil else {
                return false
            }
            guard !$0.isDraining else {
                return false
            }
            $0.isDraining = true
            return true
        }

        guard shouldStartDraining else {
            return
        }
        Task {
            await drain()
        }
    }

    private func drain() async {
        while let next = nextMessage() {
            await next.transport?.receiveRootMessage(next.message)
        }
    }

    private func nextMessage() -> (transport: TransportSession?, message: String)? {
        state.withLock {
            guard $0.messageStartIndex < $0.messages.count else {
                $0.messages.removeAll(keepingCapacity: true)
                $0.messageStartIndex = 0
                $0.isDraining = false
                return nil
            }

            let message = $0.messages[$0.messageStartIndex]
            $0.messageStartIndex += 1
            compactMessagesIfNeeded(in: &$0)
            return ($0.transport, message)
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
