import Dispatch
import Foundation
import Synchronization

package enum WebInspectorModelContextCloseReason: Sendable {
    case contextClosed
    case containerClosed

    package var fetchError: WebInspectorFetchError {
        switch self {
        case .contextClosed: .contextClosed
        case .containerClosed: .containerClosed
        }
    }
}

package class _WebInspectorModelContextOperation: @unchecked Sendable {
    package func process(
        on lifecycle: WebInspectorModelContextLifecycle
    ) async {
        fatalError("abstract context operation")
    }

    package var isSourceOperation: Bool { false }
    package var isRebaseOperation: Bool { false }
}

private final class _WebInspectorContextInitialOperation:
    _WebInspectorModelContextOperation,
    @unchecked Sendable
{
    let rebase: WebInspectorModelStoreRebase

    init(_ rebase: WebInspectorModelStoreRebase) {
        self.rebase = rebase
    }

    override var isSourceOperation: Bool { true }
    override var isRebaseOperation: Bool { true }

    override func process(
        on lifecycle: WebInspectorModelContextLifecycle
    ) async {
        await lifecycle.process(rebase: rebase, isInitial: true)
    }
}

private final class _WebInspectorContextCommitOperation:
    _WebInspectorModelContextOperation,
    @unchecked Sendable
{
    let commit: WebInspectorModelStoreCommit

    init(_ commit: WebInspectorModelStoreCommit) {
        self.commit = commit
    }

    override var isSourceOperation: Bool { true }

    override func process(
        on lifecycle: WebInspectorModelContextLifecycle
    ) async {
        await lifecycle.process(commit: commit)
    }
}

private final class _WebInspectorContextRebaseOperation:
    _WebInspectorModelContextOperation,
    @unchecked Sendable
{
    let rebase: WebInspectorModelStoreRebase

    init(_ rebase: WebInspectorModelStoreRebase) {
        self.rebase = rebase
    }

    override var isSourceOperation: Bool { true }
    override var isRebaseOperation: Bool { true }

    override func process(
        on lifecycle: WebInspectorModelContextLifecycle
    ) async {
        await lifecycle.process(rebase: rebase, isInitial: false)
    }
}

package final class _WebInspectorContextControlOperation:
    _WebInspectorModelContextOperation,
    @unchecked Sendable
{
    private let body: @Sendable (WebInspectorModelContextLifecycle) async -> Void

    package init(
        _ body:
            @escaping @Sendable (
                WebInspectorModelContextLifecycle
            ) async -> Void
    ) {
        self.body = body
    }

    package override func process(
        on lifecycle: WebInspectorModelContextLifecycle
    ) async {
        await body(lifecycle)
    }
}

private final class _WebInspectorContextCloseOperation:
    _WebInspectorModelContextOperation,
    @unchecked Sendable
{
    let reason: WebInspectorModelContextCloseReason

    init(reason: WebInspectorModelContextCloseReason) {
        self.reason = reason
    }

    override func process(
        on lifecycle: WebInspectorModelContextLifecycle
    ) async {
        await lifecycle.processClose(reason: reason)
    }
}

/// The narrow Sendable store-to-context endpoint.
///
/// It owns a lock-protected source mailbox and one drain-scheduled bit. Store
/// overflow replaces only the trailing source segment with a latest rebase;
/// control operations remain ordered at their original linearization points.
package final class WebInspectorModelContextIngress: @unchecked Sendable {
    private enum Phase {
        case open
        case closing
        case closed
    }

    private struct State {
        var phase = Phase.open
        var operations: [_WebInspectorModelContextOperation] = []
        var isActivated = false
        var isDrainScheduled = false
    }

    package let registrationID: UUID
    private let state = Mutex(State())
    private weak var lifecycle: WebInspectorModelContextLifecycle?
    private let trailingSourceCapacity: Int

    package init(
        registrationID: UUID = UUID(),
        trailingSourceCapacity: Int = 32
    ) {
        self.registrationID = registrationID
        self.trailingSourceCapacity = max(1, trailingSourceCapacity)
    }

    package func bind(
        to lifecycle: WebInspectorModelContextLifecycle
    ) {
        self.lifecycle = lifecycle
    }

    package func activate() {
        let shouldSchedule = state.withLock { state -> Bool in
            guard case .open = state.phase else { return false }
            state.isActivated = true
            guard
                !state.operations.isEmpty,
                !state.isDrainScheduled
            else {
                return false
            }
            state.isDrainScheduled = true
            return true
        }
        if shouldSchedule {
            lifecycle?.scheduleDrain()
        }
    }

    package var acceptsSource: Bool {
        state.withLock { state in
            if case .open = state.phase { true } else { false }
        }
    }

    package func enqueueInitial(_ rebase: WebInspectorModelStoreRebase) {
        enqueueSourceOperation(_WebInspectorContextInitialOperation(rebase))
    }

    package func enqueueSource(
        commit: WebInspectorModelStoreCommit,
        latestRebase: WebInspectorModelStoreRebase
    ) {
        let shouldSchedule = state.withLock { state -> Bool in
            guard case .open = state.phase else { return false }

            let trailingStart =
                state.operations.lastIndex {
                    !$0.isSourceOperation
                }.map { state.operations.index(after: $0) }
                ?? state.operations.startIndex
            let trailingCount = state.operations.distance(
                from: trailingStart,
                to: state.operations.endIndex
            )

            if let last = state.operations.last, last.isRebaseOperation {
                state.operations[state.operations.index(before: state.operations.endIndex)] =
                    _WebInspectorContextRebaseOperation(latestRebase)
            } else if trailingCount >= trailingSourceCapacity {
                state.operations.removeSubrange(trailingStart...)
                state.operations.append(
                    _WebInspectorContextRebaseOperation(latestRebase)
                )
            } else {
                state.operations.append(
                    _WebInspectorContextCommitOperation(commit)
                )
            }
            return markDrainScheduledIfNeeded(&state)
        }
        if shouldSchedule {
            lifecycle?.scheduleDrain()
        }
    }

    @discardableResult
    package func enqueueControl(
        _ operation: _WebInspectorModelContextOperation
    ) -> Bool {
        let result = state.withLock { state -> (accepted: Bool, schedule: Bool) in
            guard case .open = state.phase else { return (false, false) }
            state.operations.append(operation)
            state.isActivated = true
            return (true, markDrainScheduledIfNeeded(&state))
        }
        if result.schedule {
            lifecycle?.scheduleDrain()
        }
        return result.accepted
    }

    @discardableResult
    package func beginClose(
        reason: WebInspectorModelContextCloseReason
    ) -> WebInspectorContextReply<Void>? {
        lifecycle?.beginClose(reason: reason)
    }

    package func enqueueClose(reason: WebInspectorModelContextCloseReason) {
        let shouldSchedule = state.withLock { state -> Bool in
            guard case .open = state.phase else { return false }
            state.phase = .closing
            state.isActivated = true
            state.operations.append(
                _WebInspectorContextCloseOperation(reason: reason)
            )
            return markDrainScheduledIfNeeded(&state)
        }
        if shouldSchedule {
            lifecycle?.scheduleDrain()
        }
    }

    package func dequeue()
        -> _WebInspectorModelContextOperation?
    {
        state.withLock { state in
            guard !state.operations.isEmpty else {
                state.isDrainScheduled = false
                return nil
            }
            return state.operations.removeFirst()
        }
    }

    package func finishClose() {
        state.withLock { state in
            state.phase = .closed
            state.operations.removeAll(keepingCapacity: false)
            state.isDrainScheduled = false
        }
    }

    package func synchronouslyInvalidateDormantIssuance() -> Bool {
        state.withLock { state in
            guard
                case .open = state.phase,
                !state.isActivated
            else {
                return false
            }
            state.phase = .closed
            state.operations.removeAll(keepingCapacity: false)
            return true
        }
    }

    private func enqueueSourceOperation(
        _ operation: _WebInspectorModelContextOperation
    ) {
        let shouldSchedule = state.withLock { state -> Bool in
            guard case .open = state.phase else { return false }
            if let last = state.operations.last, last.isRebaseOperation {
                state.operations[state.operations.index(before: state.operations.endIndex)] =
                    operation
            } else {
                state.operations.append(operation)
            }
            return markDrainScheduledIfNeeded(&state)
        }
        if shouldSchedule {
            lifecycle?.scheduleDrain()
        }
    }

    private func markDrainScheduledIfNeeded(
        _ state: inout State
    ) -> Bool {
        guard
            state.isActivated,
            !state.isDrainScheduled,
            !state.operations.isEmpty
        else {
            return false
        }
        state.isDrainScheduled = true
        return true
    }
}
