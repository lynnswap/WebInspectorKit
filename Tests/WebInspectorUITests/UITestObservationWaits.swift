#if canImport(UIKit)
import ObservationBridge
import WebInspectorDataKit

@MainActor
func waitForObservedCondition(
    timeout: Duration = .seconds(1),
    deliveries: @MainActor () -> [PortableObservationTracking.Token],
    sample: @MainActor @escaping @Sendable () -> Bool
) async -> Bool {
    if sample() {
        return true
    }

    let tokens = deliveries()
    guard tokens.isEmpty == false else {
        return sample()
    }

    var values: [ObservedValues<Bool>] = []
    for token in tokens {
        values.append(await token.values { sample() })
    }
    defer {
        for value in values {
            value.cancel()
        }
    }

    if values.contains(where: { $0.latestValue == true }) {
        return true
    }

    let didObserveMatch = await withTaskGroup(of: Bool.self) { group in
        for value in values {
            group.addTask {
                await value.waitUntil(timeout: timeout) { $0 } != nil
            }
        }

        for await didMatch in group {
            if didMatch {
                for value in values {
                    value.cancel()
                }
                group.cancelAll()
                return true
            }
        }
        return false
    }

    return didObserveMatch || sample()
}

@MainActor
func waitForNetworkBodyPhase(
    in body: NetworkBody,
    _ predicate: @escaping @Sendable (NetworkBody.Phase) -> Bool
) async -> NetworkBody.Phase? {
    let observation = withPortableContinuousObservation { _ in
        _ = body.phase
    }
    defer {
        observation.cancel()
    }
    let observedValues = await observation.values {
        body.phase
    }
    defer {
        observedValues.cancel()
    }
    return await observedValues.waitUntil(predicate)
}

@MainActor
final class UITestDeinitProbe {
    private struct Waiter {
        var continuation: CheckedContinuation<Bool, Never>
        var timeoutTask: Task<Void, Never>
    }

    private var didDeinit = false
    private var waiter: Waiter?

    func signalDeinit() {
        didDeinit = true
        resolveWaiter(true)
    }

    func wait(timeout: Duration = .seconds(1)) async -> Bool {
        if didDeinit {
            return true
        }

        return await withCheckedContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolveWaiter(false)
            }
            waiter = Waiter(continuation: continuation, timeoutTask: timeoutTask)
        }
    }

    private func resolveWaiter(_ result: Bool) {
        guard let waiter else {
            return
        }
        self.waiter = nil
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: result)
    }
}
#endif
