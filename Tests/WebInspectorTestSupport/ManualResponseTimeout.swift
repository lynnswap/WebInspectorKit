import Foundation

package actor ManualResponseTimeout {
    private struct SuspensionContinuation {
        var minimumSleeps: Int
        var continuation: CheckedContinuation<Void, Never>
    }

    private var nextSleepID: UInt64 = 0
    private var continuations: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var nextSuspensionID: UInt64 = 0
    private var suspensionContinuations: [UInt64: SuspensionContinuation] = [:]
    private var handledTimeoutCount = 0
    private var handledTimeoutContinuation: CheckedContinuation<Void, Never>?

    package init() {}

    package func sleep(for _: Duration) async throws {
        nextSleepID &+= 1
        let sleepID = nextSleepID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[sleepID] = continuation
                let suspensionContinuations = popReadySuspensionContinuations()
                for suspensionContinuation in suspensionContinuations {
                    suspensionContinuation.resume()
                }
            }
        } onCancel: {
            Task {
                await self.cancel(sleepID)
            }
        }
    }

    package func fireNext() {
        guard let sleepID = continuations.keys.sorted().first,
              let continuation = continuations.removeValue(forKey: sleepID) else {
            return
        }
        continuation.resume()
    }

    package func waitUntilSuspended(by minimumSleeps: Int = 1) async {
        precondition(minimumSleeps > 0, "minimumSleeps must be positive")
        guard continuations.count < minimumSleeps else {
            return
        }

        nextSuspensionID &+= 1
        let suspensionID = nextSuspensionID
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if continuations.count >= minimumSleeps {
                    continuation.resume()
                } else {
                    suspensionContinuations[suspensionID] = SuspensionContinuation(
                        minimumSleeps: minimumSleeps,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelSuspension(suspensionID)
            }
        }
    }

    package func recordHandledTimeout() {
        handledTimeoutCount += 1
        handledTimeoutContinuation?.resume()
        handledTimeoutContinuation = nil
    }

    package func waitUntilHandledTimeout() async {
        guard handledTimeoutCount == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            if handledTimeoutCount > 0 {
                continuation.resume()
            } else {
                handledTimeoutContinuation = continuation
            }
        }
    }

    private func cancel(_ sleepID: UInt64) {
        guard let continuation = continuations.removeValue(forKey: sleepID) else {
            return
        }
        continuation.resume(throwing: CancellationError())
    }

    private func cancelSuspension(_ suspensionID: UInt64) {
        guard let continuation = suspensionContinuations.removeValue(forKey: suspensionID)?.continuation else {
            return
        }
        continuation.resume()
    }

    private func popReadySuspensionContinuations() -> [CheckedContinuation<Void, Never>] {
        let readyIDs = suspensionContinuations.keys.sorted().filter { id in
            guard let suspensionContinuation = suspensionContinuations[id] else {
                return false
            }
            return continuations.count >= suspensionContinuation.minimumSleeps
        }
        return readyIDs.compactMap { id in
            suspensionContinuations.removeValue(forKey: id)?.continuation
        }
    }
}
