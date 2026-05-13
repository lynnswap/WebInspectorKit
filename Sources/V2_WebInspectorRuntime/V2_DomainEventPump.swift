import V2_WebInspectorTransport

@MainActor
package final class V2_DomainEventPump {
    private var task: Task<Void, Never>?
    private var nextWaiterID: UInt64
    private var waiters: [UInt64: (sequence: UInt64, promise: ReplyPromise<Void>)]

    package private(set) var appliedSequence: UInt64
    package var pendingWaiterCount: Int {
        waiters.count
    }

    package init() {
        task = nil
        nextWaiterID = 0
        waiters = [:]
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
        let pendingWaiters = waiters.values.map(\.promise)
        waiters.removeAll()
        for promise in pendingWaiters {
            Task {
                await promise.fulfill(.success(()))
            }
        }
    }

    package func waitUntilApplied(_ sequence: UInt64, timeout: Duration? = nil) async {
        guard sequence > appliedSequence else {
            return
        }

        nextWaiterID &+= 1
        let waiterID = nextWaiterID
        let promise = ReplyPromise<Void>()
        waiters[waiterID] = (sequence, promise)
        let timeoutTask: Task<Void, Never>? = timeout.map { timeout in
            Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                await promise.fulfill(.success(()))
            }
        }
        defer {
            timeoutTask?.cancel()
            waiters.removeValue(forKey: waiterID)
        }
        do {
            try await promise.value()
        } catch {
            return
        }
    }

    private func markApplied(_ sequence: UInt64) {
        appliedSequence = max(appliedSequence, sequence)
        let readyWaiters = waiters.filter { $0.value.sequence <= appliedSequence }
        for waiterID in readyWaiters.keys {
            waiters.removeValue(forKey: waiterID)
        }
        for waiter in readyWaiters.values {
            Task {
                await waiter.promise.fulfill(.success(()))
            }
        }
    }
}
