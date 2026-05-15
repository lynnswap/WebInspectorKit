import WebInspectorTransport

@MainActor
package final class DomainEventPump {
    private var task: Task<Void, Never>?

    package private(set) var appliedSequence: UInt64

    package init() {
        task = nil
        appliedSequence = 0
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
    }

    private func markApplied(_ sequence: UInt64) {
        appliedSequence = max(appliedSequence, sequence)
    }
}
