import WebInspectorTransport

@MainActor
package final class DomainEventPump {
    private var task: Task<Void, Never>?
    private var appliedSequenceWaiters: [UInt64: [CheckedContinuation<Bool, Never>]]

    package private(set) var appliedSequence: UInt64

    package init() {
        task = nil
        appliedSequenceWaiters = [:]
        appliedSequence = 0
    }

    deinit {
        task?.cancel()
    }

    package func start(
        stream: AsyncStream<ProtocolEventEnvelope>,
        apply: @escaping @MainActor @Sendable (ProtocolEventEnvelope) async -> Void
    ) {
        stop()
        task = Task { @MainActor [weak self] in
            for await event in stream {
                if Task.isCancelled {
                    break
                }
                await apply(event)
                self?.markApplied(event.sequence)
            }
        }
    }

    package func stop() {
        task?.cancel()
        task = nil
        resumeAppliedSequenceWaiters(returning: false)
    }

    package func waitUntilApplied(_ sequence: UInt64) async -> Bool {
        guard appliedSequence < sequence else {
            return true
        }

        return await withCheckedContinuation { continuation in
            if appliedSequence >= sequence {
                continuation.resume(returning: true)
            } else {
                appliedSequenceWaiters[sequence, default: []].append(continuation)
            }
        }
    }

    private func markApplied(_ sequence: UInt64) {
        appliedSequence = max(appliedSequence, sequence)
        let readySequences = appliedSequenceWaiters.keys.filter { $0 <= appliedSequence }
        let readyWaiters = readySequences.flatMap { sequence in
            appliedSequenceWaiters.removeValue(forKey: sequence) ?? []
        }
        for waiter in readyWaiters {
            waiter.resume(returning: true)
        }
    }

    private func resumeAppliedSequenceWaiters(returning value: Bool) {
        let waiters = appliedSequenceWaiters.values.flatMap { $0 }
        appliedSequenceWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: value)
        }
    }
}
