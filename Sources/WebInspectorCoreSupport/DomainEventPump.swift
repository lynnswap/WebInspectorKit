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
        stream: AsyncStream<ProtocolEvent>,
        apply: @escaping @MainActor @Sendable (ProtocolEvent) async -> Void
    ) {
        stop()
        let target = DomainEventPumpTarget(pump: self, apply: apply)
        task = Task.detached(priority: .userInitiated) {
            for await event in stream {
                if Task.isCancelled {
                    break
                }
                await target.apply(event)
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

    fileprivate func markApplied(_ sequence: UInt64) {
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

private final class DomainEventPumpTarget: @unchecked Sendable {
    private weak var pump: DomainEventPump?
    private let applyEvent: @MainActor @Sendable (ProtocolEvent) async -> Void

    @MainActor
    init(
        pump: DomainEventPump,
        apply: @escaping @MainActor @Sendable (ProtocolEvent) async -> Void
    ) {
        self.pump = pump
        applyEvent = apply
    }

    func apply(_ event: ProtocolEvent) async {
        await applyEvent(event)
        await pump?.markApplied(event.sequence)
    }
}
