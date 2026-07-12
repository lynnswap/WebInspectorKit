import Synchronization

package enum WebInspectorModelContextOwnerAdmissionResolution: Equatable, Sendable {
    case activated
    case abandoned
}

/// Synchronized admission shared by owner work that must finish before the
/// context core admits another source revision.
package final class WebInspectorModelContextOwnerAdmissionGate<
    OwnerID: Hashable & Sendable
>: Sendable {
    private typealias Waiter = CheckedContinuation<
        WebInspectorModelContextOwnerAdmissionResolution,
        Never
    >

    private struct State: Sendable {
        var resolution: WebInspectorModelContextOwnerAdmissionResolution?
        var waiters: [Waiter] = []
        var coreResolutionWasRecorded = false
        var claimantAcknowledgedCoreResolution = false
    }

    private let state = Mutex(State())
    package let ownerID: OwnerID

    package init(ownerID: OwnerID) {
        self.ownerID = ownerID
    }

    @discardableResult
    package func activate() -> Bool {
        resolve(.activated)
    }

    @discardableResult
    package func abandon() -> Bool {
        resolve(.abandoned)
    }

    package func value() async -> WebInspectorModelContextOwnerAdmissionResolution {
        await withCheckedContinuation { continuation in
            let resolution = state.withLock {
                state -> WebInspectorModelContextOwnerAdmissionResolution? in
                if let resolution = state.resolution {
                    return resolution
                }
                state.waiters.append(continuation)
                return nil
            }
            if let resolution {
                continuation.resume(returning: resolution)
            }
        }
    }

    package var waiterCountForTesting: Int {
        state.withLock { $0.waiters.count }
    }

    package var currentResolution: WebInspectorModelContextOwnerAdmissionResolution? {
        state.withLock(\.resolution)
    }

    package func recordCoreResolution() {
        state.withLock { state in
            precondition(
                state.resolution != nil,
                "Core cannot record an unresolved owner admission."
            )
            precondition(
                state.coreResolutionWasRecorded == false,
                "Core can record one owner admission resolution only once."
            )
            state.coreResolutionWasRecorded = true
        }
    }

    package func acknowledgeCoreResolution() {
        state.withLock { state in
            precondition(
                state.coreResolutionWasRecorded,
                "An owner admission claimant cannot acknowledge a foreign gate."
            )
            precondition(
                state.claimantAcknowledgedCoreResolution == false,
                "An owner admission claimant can acknowledge Core only once."
            )
            state.claimantAcknowledgedCoreResolution = true
        }
    }

    private func resolve(
        _ resolution: WebInspectorModelContextOwnerAdmissionResolution
    ) -> Bool {
        let waiters = state.withLock { state -> [Waiter]? in
            guard state.resolution == nil else {
                return nil
            }
            state.resolution = resolution
            let waiters = state.waiters
            state.waiters.removeAll(keepingCapacity: false)
            return waiters
        }
        guard let waiters else {
            return false
        }
        for waiter in waiters {
            waiter.resume(returning: resolution)
        }
        return true
    }
}
