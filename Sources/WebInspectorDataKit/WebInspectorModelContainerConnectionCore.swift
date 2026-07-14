import Synchronization
import WebInspectorProxyKit

package nonisolated func webInspectorRunIgnoringCancellation<
    Value: Sendable
>(
    _ operation: @escaping @Sendable () async -> Value
) async -> Value {
    let task = Task.detached(operation: operation)
    return await task.value
}

package nonisolated func webInspectorRunIgnoringCancellation<
    Value: Sendable
>(
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let task = Task.detached(operation: operation)
    return try await task.value
}

package typealias WebInspectorNativeProxyCreationTask =
    Task<WebInspectorProxy, any Error>

/// Owns the one allowed `close()` invocation for an attempt-produced Proxy.
package final class WebInspectorModelContainerProxyLease: Sendable {
    package let proxy: WebInspectorProxy

    private let closeTask = Mutex<Task<Void, Never>?>(nil)

    package init(_ proxy: WebInspectorProxy) {
        self.proxy = proxy
    }

    package func requestClose() {
        _ = taskClosingProxy()
    }

    package var isCloseRequested: Bool {
        closeTask.withLock { $0 != nil }
    }

    package func close() async {
        await taskClosingProxy().value
    }

    private func taskClosingProxy() -> Task<Void, Never> {
        closeTask.withLock { closeTask in
            if let closeTask {
                return closeTask
            }
            let proxy = proxy
            let task = Task.detached {
                await proxy.close()
            }
            closeTask = task
            return task
        }
    }
}

package enum WebInspectorModelContainerAttachmentInvalidation:
    Int,
    Equatable,
    Sendable
{
    case callerCancelled = 0
    case superseded = 1
    case detached = 2
    case closed = 3
}

package struct WebInspectorModelContainerLifecycleTurn: Sendable {
    package let predecessor: ReplyPromise<Void>
    package let completion: ReplyPromise<Void>

    package func wait() async throws {
        try await predecessor.value()
    }

    package func waitIgnoringCancellation() async {
        do {
            try await predecessor.valueIgnoringCancellation()
        } catch {
            preconditionFailure(
                "A Model Container lifecycle predecessor failed: \(error)"
            )
        }
    }

    package func finish() {
        precondition(
            completion.fulfill(.success(())),
            "A Model Container lifecycle turn completed twice."
        )
    }
}

package final class WebInspectorModelContainerAttachmentAttemptControl:
    Sendable
{
    private enum Phase: Equatable {
        case pending
        case promoted
        case completed
    }

    private struct Storage {
        var phase = Phase.pending
        var invalidation: WebInspectorModelContainerAttachmentInvalidation?
        var proxyLease: WebInspectorModelContainerProxyLease?
        var nativeTask: WebInspectorNativeProxyCreationTask?
        var operationTask: Task<Void, Never>?
    }

    private let storage = Mutex(Storage())
    private let nativeStartGate = ReplyPromise<Void>()
    package let completion = ReplyPromise<Void>()

    package var invalidation: WebInspectorModelContainerAttachmentInvalidation? {
        storage.withLock { $0.invalidation }
    }

    package var isPromoted: Bool {
        storage.withLock { storage in
            if case .promoted = storage.phase {
                true
            } else {
                false
            }
        }
    }

    package func installNativeTask(
        _ task: WebInspectorNativeProxyCreationTask
    ) {
        let shouldCancel = storage.withLock { storage in
            precondition(
                storage.nativeTask == nil,
                "An attachment attempt supports one native creation Task."
            )
            storage.nativeTask = task
            return storage.invalidation != nil
        }
        if shouldCancel {
            task.cancel()
        }
        precondition(
            nativeStartGate.fulfill(.success(())),
            "An attachment attempt opened its native start gate twice."
        )
    }

    package func waitForNativeTaskInstallation() async throws {
        try await nativeStartGate.value()
    }

    package func nativeTask() -> WebInspectorNativeProxyCreationTask? {
        storage.withLock { $0.nativeTask }
    }

    package func installProxyLease(
        _ lease: WebInspectorModelContainerProxyLease
    ) {
        let shouldClose = storage.withLock { storage in
            precondition(
                storage.proxyLease == nil,
                "An attachment attempt supports one Proxy lease."
            )
            storage.proxyLease = lease
            return storage.invalidation != nil
        }
        if shouldClose {
            lease.requestClose()
        }
    }

    package func installOperationTask(_ task: Task<Void, Never>) {
        let shouldCancel = storage.withLock { storage in
            precondition(
                storage.operationTask == nil,
                "An attachment attempt supports one lifecycle operation Task."
            )
            storage.operationTask = task
            return storage.invalidation != nil && storage.phase == .pending
        }
        if shouldCancel {
            task.cancel()
        }
    }

    @discardableResult
    package func invalidate(
        _ proposed: WebInspectorModelContainerAttachmentInvalidation
    ) -> Bool {
        let tasks = storage.withLock {
            storage -> (
                changed: Bool,
                proxyLease: WebInspectorModelContainerProxyLease?,
                native: WebInspectorNativeProxyCreationTask?,
                operation: Task<Void, Never>?
            ) in
            guard storage.phase == .pending else {
                return (false, nil, nil, nil)
            }
            if let current = storage.invalidation,
                current.rawValue >= proposed.rawValue
            {
                return (false, nil, nil, nil)
            }
            storage.invalidation = proposed
            return (
                true,
                storage.proxyLease,
                storage.nativeTask,
                storage.operationTask
            )
        }
        tasks.proxyLease?.requestClose()
        tasks.native?.cancel()
        tasks.operation?.cancel()
        return tasks.changed
    }

    package func markPromoted() -> Bool {
        storage.withLock { storage in
            guard storage.phase == .pending,
                storage.invalidation == nil
            else {
                return false
            }
            storage.phase = .promoted
            return true
        }
    }

    package func complete(_ result: Result<Void, any Error>) {
        storage.withLock { storage in
            precondition(
                storage.phase != .completed,
                "An attachment attempt completed twice."
            )
            storage.phase = .completed
            storage.proxyLease = nil
            storage.nativeTask = nil
            storage.operationTask = nil
        }
        precondition(
            completion.fulfill(result),
            "An attachment attempt published completion twice."
        )
    }
}

package struct WebInspectorModelContainerAttachmentAttempt: Sendable {
    package let generation: WebInspectorContainerAttachmentGeneration
    package let turn: WebInspectorModelContainerLifecycleTurn
    package let control: WebInspectorModelContainerAttachmentAttemptControl

    package func waitForNativeCreationStart() async throws {
        try await control.waitForNativeTaskInstallation()
        try await turn.wait()
    }

    package func cancelFromCaller() {
        control.invalidate(.callerCancelled)
    }
}

package enum WebInspectorModelContainerFeedDriverTerminal: Sendable {
    case finished
    case cancelled
    case failed(WebInspectorModelContainer.Failure)
}

package final class WebInspectorModelContainerAttachmentResource: Sendable {
    package let id: UInt64
    package let generation: WebInspectorContainerAttachmentGeneration
    package let proxyLease: WebInspectorModelContainerProxyLease
    package let feed: ConnectionModelFeed
    package let driverTask:
        Task<
            WebInspectorModelContainerFeedDriverTerminal,
            Never
        >
    package let synchronization: ReplyPromise<UInt64>

    private let startGate: ReplyPromise<Void>
    private let supervisor = Mutex<Task<Void, Never>?>(nil)
    private let terminalOperation = Mutex<Task<Void, Never>?>(nil)

    package init(
        id: UInt64,
        generation: WebInspectorContainerAttachmentGeneration,
        proxyLease: WebInspectorModelContainerProxyLease,
        feed: ConnectionModelFeed,
        startGate: ReplyPromise<Void>,
        synchronization: ReplyPromise<UInt64>,
        driverTask: Task<
            WebInspectorModelContainerFeedDriverTerminal,
            Never
        >
    ) {
        self.id = id
        self.generation = generation
        self.proxyLease = proxyLease
        self.feed = feed
        self.startGate = startGate
        self.synchronization = synchronization
        self.driverTask = driverTask
    }

    package func installSupervisor(_ task: Task<Void, Never>) {
        supervisor.withLock { supervisor in
            precondition(
                supervisor == nil,
                "A model-feed driver supports one supervisor."
            )
            supervisor = task
        }
    }

    package var supervisorTask: Task<Void, Never>? {
        supervisor.withLock { $0 }
    }

    package func installTerminalOperation(_ task: Task<Void, Never>) {
        terminalOperation.withLock { terminalOperation in
            precondition(
                terminalOperation == nil,
                "A model-feed resource supports one terminal operation."
            )
            terminalOperation = task
        }
    }

    package func startDriver() {
        precondition(
            startGate.fulfill(.success(())),
            "A model-feed driver started twice."
        )
    }
}

package struct WebInspectorModelContainerAttachmentAttemptState: Sendable {
    package let attempt: WebInspectorModelContainerAttachmentAttempt
    package var candidateProxy: WebInspectorModelContainerProxyLease?
    package var provisionalResource: WebInspectorModelContainerAttachmentResource?
}

package struct WebInspectorModelContainerFeedApplication: Sendable {
    package let synchronizationBarrier: WebInspectorModelContextAcknowledgementBarrier?
    package let domRecoveryScopes: [ModelEventScope]
}

package extension WebInspectorModelContainerCore {
    func reserveAttachmentAttempt()
        throws -> WebInspectorModelContainerAttachmentAttempt
    {
        guard !isConnectionCloseRequested else {
            throw WebInspectorModelContainer.Failure.closed
        }
        precondition(
            nextAttachmentGeneration < UInt64.max,
            "Model Container exhausted attachment generations."
        )
        nextAttachmentGeneration += 1
        let generation = WebInspectorContainerAttachmentGeneration(
            rawValue: nextAttachmentGeneration
        )

        for state in attachmentAttempts.values {
            state.attempt.control.invalidate(.superseded)
        }

        let attempt = WebInspectorModelContainerAttachmentAttempt(
            generation: generation,
            turn: reserveLifecycleTurn(),
            control: WebInspectorModelContainerAttachmentAttemptControl()
        )
        attachmentAttempts[generation] =
            WebInspectorModelContainerAttachmentAttemptState(
                attempt: attempt,
                candidateProxy: nil,
                provisionalResource: nil
            )
        return attempt
    }

    func installNativeProxyCreationTask(
        _ task: WebInspectorNativeProxyCreationTask,
        for attempt: WebInspectorModelContainerAttachmentAttempt
    ) {
        guard let state = attachmentAttempts[attempt.generation],
            state.attempt.control === attempt.control
        else {
            task.cancel()
            preconditionFailure(
                "A native Proxy creation Task lost its reserved attempt."
            )
        }
        attempt.control.installNativeTask(task)
    }

    func beginNativeProxyCreation(
        for attempt: WebInspectorModelContainerAttachmentAttempt
    ) throws {
        try requirePendingAttempt(attempt)
        connectionStatePublication.publish(.attaching)
    }

    func completeAttachmentAttempt(
        _ attempt: WebInspectorModelContainerAttachmentAttempt
    ) async throws {
        startAttachmentOperationIfNeeded(attempt)
        try await attempt.control.completion.valueIgnoringCancellation()
    }

    func attach(owning proxy: WebInspectorProxy) async throws {
        let attempt: WebInspectorModelContainerAttachmentAttempt
        do {
            attempt = try reserveAttachmentAttempt()
        } catch {
            await webInspectorRunIgnoringCancellation {
                await proxy.close()
            }
            throw error
        }
        guard var state = attachmentAttempts[attempt.generation] else {
            preconditionFailure(
                "A package-owned Proxy lost its reserved attachment attempt."
            )
        }
        let lease = WebInspectorModelContainerProxyLease(proxy)
        attempt.control.installProxyLease(lease)
        state.candidateProxy = lease
        attachmentAttempts[attempt.generation] = state
        startAttachmentOperationIfNeeded(attempt)

        try await withTaskCancellationHandler {
            try await attempt.control.completion.valueIgnoringCancellation()
        } onCancel: {
            attempt.cancelFromCaller()
        }
    }

    func detachConnection() async {
        if let connectionCloseCompletion {
            _ =
                try? await connectionCloseCompletion
                .valueIgnoringCancellation()
            return
        }

        for state in attachmentAttempts.values {
            state.attempt.control.invalidate(.detached)
        }
        connectionStatePublication.publish(.detaching)
        let turn = reserveLifecycleTurn()
        await turn.waitIgnoringCancellation()

        let cleanupFailure = await webInspectorRunIgnoringCancellation {
            await self.detachCurrentAttachment(skipSupervisorWait: false)
        }
        if !isConnectionCloseRequested {
            if let cleanupFailure {
                connectionStatePublication.publish(.failed(cleanupFailure))
            } else {
                connectionStatePublication.publish(.detached)
            }
        }
        turn.finish()
    }

    func closeConnection() async {
        if let connectionCloseCompletion {
            _ =
                try? await connectionCloseCompletion
                .valueIgnoringCancellation()
            return
        }

        isConnectionCloseRequested = true
        retireAllSynchronizationGenerations(with: .closed)
        retireElementPickerOperation(
            with: WebInspectorElementPickerError.closed
        )
        connectionStatePublication.publish(.closing)
        for state in attachmentAttempts.values {
            state.attempt.control.invalidate(.closed)
        }
        let completion = ReplyPromise<Void>()
        connectionCloseCompletion = completion
        let close = beginClose()
        let turn = reserveLifecycleTurn()
        await turn.waitIgnoringCancellation()

        let resource = activeAttachment
        activeAttachment = nil
        if let resource {
            let cleanupFailure = await webInspectorRunIgnoringCancellation {
                await self.closeResource(
                    resource,
                    skipSupervisorWait: false
                )
            }
            if let cleanupFailure {
                WebInspectorDataKitLog.error(
                    "Model Container close cleanup failed: \(cleanupFailure)"
                )
            }
        }
        await webInspectorRunIgnoringCancellation {
            do {
                try await self.finishClose(close)
            } catch {
                preconditionFailure(
                    "A Container-owned close transaction failed: \(error)"
                )
            }
        }
        turn.finish()
        let terminalTail = lifecycleOperationTail
        do {
            try await terminalTail.valueIgnoringCancellation()
        } catch {
            preconditionFailure(
                "A terminal Model Container lifecycle operation failed: \(error)"
            )
        }
        connectionStatePublication.finish()
        precondition(
            completion.fulfill(.success(())),
            "A Model Container connection close completed twice."
        )
    }

    func consumeFeedRecord(
        _ record: ConnectionModelFeedRecord,
        resourceID: UInt64,
        generation: WebInspectorContainerAttachmentGeneration
    ) throws -> WebInspectorModelContainerFeedApplication {
        let ownership = feedResourceOwnership(
            id: resourceID,
            generation: generation
        )
        guard ownership != nil else {
            throw CancellationError()
        }
        if case let .provisional(attempt) = ownership {
            try requirePendingAttempt(attempt)
        }

        let commit = try reduce(
            record,
            attachmentGeneration: generation
        )
        var domRecoveryScopes: [ModelEventScope] = []
        if let commit {
            applyCanonicalElementPickerActions(
                commit.transaction.actions,
                resourceID: resourceID,
                generation: generation
            )
            for action in commit.transaction.actions {
                guard case let .recoverDOM(
                    scope,
                    rejectedSequence,
                    operation,
                    error
                ) = action else {
                    continue
                }
                WebInspectorDataKitLog.error(
                    "Canonical DOM delta rejected; resynchronizing target=\(scope.target.id.rawValue) sequence=\(rejectedSequence) operation=\(operation.rawValue) error=\(error)"
                )
                performanceCounters.domRecoveryCount += 1
                domRecoveryScopes.append(scope)
            }
        }
        guard let commit,
            commit.transaction.feedChanges.contains(where: {
                if case .synchronizationComplete = $0 {
                    true
                } else {
                    false
                }
            })
        else {
            return WebInspectorModelContainerFeedApplication(
                synchronizationBarrier: nil,
                domRecoveryScopes: domRecoveryScopes
            )
        }

        return WebInspectorModelContainerFeedApplication(
            synchronizationBarrier: try makeAcknowledgementBarrier(
                through: commit.toRevision
            ),
            domRecoveryScopes: domRecoveryScopes
        )
    }

    func feedDriverDidTerminate(
        resourceID: UInt64,
        terminal: WebInspectorModelContainerFeedDriverTerminal
    ) {
        let failure: WebInspectorModelContainer.Failure
        switch terminal {
        case .finished, .cancelled:
            failure = .connection(.closed)
        case let .failed(driverFailure):
            failure = driverFailure
        }

        for state in attachmentAttempts.values {
            guard state.provisionalResource?.id == resourceID else {
                continue
            }
            guard let generation = state.provisionalResource?.generation else {
                preconditionFailure(
                    "A matched provisional feed resource lost its attachment generation."
                )
            }
            retireSynchronizationGeneration(
                generation,
                with: .synchronizationFailed(failure)
            )
            state.provisionalResource?.synchronization.fulfill(
                .failure(failure)
            )
            return
        }
        guard let resource = activeAttachment,
            resource.id == resourceID
        else {
            return
        }

        let turn = reserveLifecycleTurn()
        let operation = Task.detached(priority: .userInitiated) { [weak self] in
            await turn.waitIgnoringCancellation()
            guard let self else {
                turn.finish()
                return
            }
            await self.applyFeedDriverTerminal(
                resourceID: resourceID,
                failure: failure,
                turn: turn
            )
        }
        resource.installTerminalOperation(operation)
    }
}

private extension WebInspectorModelContainerCore {
    enum FeedResourceOwnership {
        case provisional(WebInspectorModelContainerAttachmentAttempt)
        case active
    }

    func reserveLifecycleTurn()
        -> WebInspectorModelContainerLifecycleTurn
    {
        let completion = ReplyPromise<Void>()
        let turn = WebInspectorModelContainerLifecycleTurn(
            predecessor: lifecycleOperationTail,
            completion: completion
        )
        lifecycleOperationTail = completion
        return turn
    }

    func startAttachmentOperationIfNeeded(
        _ attempt: WebInspectorModelContainerAttachmentAttempt
    ) {
        guard let state = attachmentAttempts[attempt.generation],
            state.attempt.control === attempt.control
        else {
            preconditionFailure(
                "A reserved attachment attempt disappeared before operation start."
            )
        }
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else {
                return
            }
            await self.runAttachmentOperation(attempt)
        }
        attempt.control.installOperationTask(task)
    }

    func runAttachmentOperation(
        _ attempt: WebInspectorModelContainerAttachmentAttempt
    ) async {
        await attempt.turn.waitIgnoringCancellation()
        let result: Result<Void, any Error>
        do {
            let proxy: WebInspectorProxy
            if let nativeTask = attempt.control.nativeTask() {
                proxy = try await nativeTask.value
                guard var state = attachmentAttempts[attempt.generation]
                else {
                    preconditionFailure(
                        "A completed native Proxy lost its attachment attempt."
                    )
                }
                let lease = WebInspectorModelContainerProxyLease(proxy)
                attempt.control.installProxyLease(lease)
                state.candidateProxy = lease
                attachmentAttempts[attempt.generation] = state
                try requirePendingAttempt(attempt)
            } else {
                try requirePendingAttempt(attempt)
                connectionStatePublication.publish(.attaching)
                guard
                    attachmentAttempts[attempt.generation]?.candidateProxy
                        != nil
                else {
                    preconditionFailure(
                        "A package attachment operation has no owned Proxy."
                    )
                }
            }

            try await adoptCandidate(for: attempt)
            result = .success(())
        } catch {
            let reportedError = await webInspectorRunIgnoringCancellation {
                await self.rollbackAttachmentAttempt(
                    attempt,
                    operationError: error
                )
            }
            if attempt.control.invalidation == nil {
                WebInspectorDataKitLog.error(
                    "Model Container attachment failed generation=\(attempt.generation.rawValue): \(reportedError)"
                )
            }
            result = .failure(reportedError)
        }

        finishAttachmentAttempt(attempt, result: result)
    }

    func applyFeedDriverTerminal(
        resourceID: UInt64,
        failure: WebInspectorModelContainer.Failure,
        turn: WebInspectorModelContainerLifecycleTurn
    ) async {
        guard activeAttachment?.id == resourceID else {
            turn.finish()
            return
        }
        WebInspectorDataKitLog.error(
            "Model Container feed terminated resource=\(resourceID): \(failure)"
        )
        if let generation = activeAttachment?.generation {
            retireSynchronizationGeneration(
                generation,
                with: .synchronizationFailed(failure)
            )
        }
        retireElementPickerOperation(
            with: WebInspectorElementPickerError.feedFailure(failure)
        )
        let cleanupFailure = await webInspectorRunIgnoringCancellation {
            await self.detachCurrentAttachment(skipSupervisorWait: true)
        }
        if let cleanupFailure {
            WebInspectorDataKitLog.error(
                "Model Container feed termination cleanup failed: \(cleanupFailure)"
            )
        }
        if !isConnectionCloseRequested {
            connectionStatePublication.publish(.failed(failure))
        }
        turn.finish()
    }

    func adoptCandidate(
        for attempt: WebInspectorModelContainerAttachmentAttempt
    ) async throws {
        try requirePendingAttempt(attempt)
        guard
            let candidateLease = attachmentAttempts[attempt.generation]?
                .candidateProxy
        else {
            preconditionFailure(
                "An attachment operation reached adoption without a Proxy."
            )
        }
        let candidate = candidateLease.proxy

        if activeAttachment != nil || hasCanonicalBinding {
            let cleanupFailure = await webInspectorRunIgnoringCancellation {
                await self.detachCurrentAttachment(
                    skipSupervisorWait: false
                )
            }
            if let cleanupFailure {
                throw cleanupFailure
            }
        } else {
            let barrier = try makeAcknowledgementBarrier(
                through: currentRevision
            )
            try await webInspectorRunIgnoringCancellation {
                try await self.waitForAcknowledgements(barrier)
            }
        }
        try requirePendingAttempt(attempt)

        do {
            _ = try await candidate.openModelFeed(
                configuredDomains: configuredDomains,
                onRegistered: { [weak self] feed in
                    guard let self else {
                        return false
                    }
                    return await self.installProvisionalFeed(
                        feed,
                        proxyLease: candidateLease,
                        for: attempt
                    )
                }
            )
        } catch {
            throw Self.mapConnectionFailure(error)
        }

        guard
            let synchronization = attachmentAttempts[attempt.generation]?
                .provisionalResource?.synchronization
        else {
            preconditionFailure(
                "An opened model feed has no Core-owned driver synchronization."
            )
        }
        _ = try await synchronization.value()
        try requirePendingAttempt(attempt)
        try promoteProvisionalResource(
            attempt: attempt
        )
        connectionStatePublication.publish(.attached)
    }

    func installProvisionalFeed(
        _ feed: ConnectionModelFeed,
        proxyLease: WebInspectorModelContainerProxyLease,
        for attempt: WebInspectorModelContainerAttachmentAttempt
    ) -> Bool {
        do {
            try requirePendingAttempt(attempt)
        } catch {
            return false
        }
        guard var state = attachmentAttempts[attempt.generation],
            state.candidateProxy === proxyLease,
            state.provisionalResource == nil
        else {
            return false
        }
        precondition(
            nextFeedResourceID < UInt64.max,
            "Model Container exhausted feed-resource identifiers."
        )
        nextFeedResourceID += 1
        let resourceID = nextFeedResourceID
        let startGate = ReplyPromise<Void>()
        let synchronization = ReplyPromise<UInt64>()
        let resolveCore: @Sendable () -> WebInspectorModelContainerCore? = {
            [weak self] in self
        }
        let driverTask = Task.detached(priority: .userInitiated) {
            await Self.driveModelFeed(
                feed,
                resourceID: resourceID,
                generation: attempt.generation,
                startGate: startGate,
                synchronization: synchronization,
                resolveCore: resolveCore
            )
        }
        let resource = WebInspectorModelContainerAttachmentResource(
            id: resourceID,
            generation: attempt.generation,
            proxyLease: proxyLease,
            feed: feed,
            startGate: startGate,
            synchronization: synchronization,
            driverTask: driverTask
        )
        let supervisorTask = Task.detached(priority: .userInitiated) {
            let terminal = await driverTask.value
            guard let core = resolveCore() else {
                return
            }
            await core.feedDriverDidTerminate(
                resourceID: resourceID,
                terminal: terminal
            )
        }
        resource.installSupervisor(supervisorTask)
        state.provisionalResource = resource
        attachmentAttempts[attempt.generation] = state
        resource.startDriver()
        return true
    }

    nonisolated static func driveModelFeed(
        _ feed: ConnectionModelFeed,
        resourceID: UInt64,
        generation: WebInspectorContainerAttachmentGeneration,
        startGate: ReplyPromise<Void>,
        synchronization: ReplyPromise<UInt64>,
        resolveCore:
            @escaping @Sendable ()
            -> WebInspectorModelContainerCore?
    ) async -> WebInspectorModelContainerFeedDriverTerminal {
        do {
            try await startGate.valueIgnoringCancellation()
            for try await record in feed.records {
                try Task.checkCancellation()
                guard let core = resolveCore() else {
                    return .cancelled
                }
                let application = try await core.consumeFeedRecord(
                    record,
                    resourceID: resourceID,
                    generation: generation
                )
                for scope in application.domRecoveryScopes {
                    try Task.checkCancellation()
                    try await feed.requestDOMRecovery(
                        afterRejecting: scope
                    )
                }
                if let barrier = application.synchronizationBarrier {
                    try await core.waitForAcknowledgements(barrier)
                    try await core.recordSynchronizationCompletion(
                        resourceID: resourceID,
                        generation: generation,
                        through: barrier.revision
                    )
                    synchronization.fulfill(
                        .success(barrier.revision)
                    )
                }
            }
            return .finished
        } catch is CancellationError {
            synchronization.fulfill(.failure(CancellationError()))
            return .cancelled
        } catch {
            let failure = mapConnectionFailure(error)
            synchronization.fulfill(.failure(failure))
            return .failed(failure)
        }
    }

    func promoteProvisionalResource(
        attempt: WebInspectorModelContainerAttachmentAttempt
    ) throws {
        try requirePendingAttempt(attempt)
        guard var state = attachmentAttempts[attempt.generation],
            let resource = state.provisionalResource
        else {
            throw CancellationError()
        }
        precondition(
            activeAttachment == nil,
            "A model container cannot promote two active feed resources."
        )
        guard attempt.control.markPromoted() else {
            throw failure(for: attempt)
        }
        state.provisionalResource = nil
        state.candidateProxy = nil
        attachmentAttempts[attempt.generation] = state
        activeAttachment = resource
    }

    func rollbackAttachmentAttempt(
        _ attempt: WebInspectorModelContainerAttachmentAttempt,
        operationError: any Error
    ) async -> any Error {
        var resource: WebInspectorModelContainerAttachmentResource?
        var candidate: WebInspectorModelContainerProxyLease?
        if var state = attachmentAttempts[attempt.generation] {
            resource = state.provisionalResource
            candidate =
                state.provisionalResource == nil
                ? state.candidateProxy
                : nil
            state.provisionalResource = nil
            state.candidateProxy = nil
            attachmentAttempts[attempt.generation] = state
        }
        if activeAttachment?.generation == attempt.generation {
            resource = activeAttachment
            activeAttachment = nil
        }

        retireSynchronizationGeneration(
            attempt.generation,
            with: .synchronizationFailed(
                Self.mapConnectionFailure(operationError)
            )
        )

        var cleanupFailure: WebInspectorModelContainer.Failure?
        if let resource {
            cleanupFailure = await closeResource(
                resource,
                skipSupervisorWait: false
            )
        } else if let candidate {
            await candidate.close()
        }
        if !isConnectionCloseRequested,
            activeAttachment == nil,
            hasCanonicalBinding
        {
            let resetFailure = await resetCanonicalStateForDetach()
            if cleanupFailure == nil {
                cleanupFailure = resetFailure
            }
        }

        let reportedError: any Error
        if let invalidation = attempt.control.invalidation {
            if let cleanupFailure {
                WebInspectorDataKitLog.error(
                    "Invalidated Model Container attachment cleanup failed: \(cleanupFailure)"
                )
            }
            switch invalidation {
            case .callerCancelled:
                reportedError = CancellationError()
            case .superseded, .detached:
                reportedError =
                    WebInspectorModelContainer.Failure
                    .attachmentSuperseded
            case .closed:
                reportedError = WebInspectorModelContainer.Failure.closed
            }
        } else if let cleanupFailure {
            reportedError = cleanupFailure
        } else {
            reportedError = Self.mapConnectionFailure(operationError)
        }

        if !isConnectionCloseRequested,
            attempt.control.invalidation == nil
        {
            if activeAttachment != nil {
                connectionStatePublication.publish(.attached)
            } else {
                connectionStatePublication.publish(
                    .failed(
                        Self.mapConnectionFailure(reportedError)
                    ))
            }
        } else if !isConnectionCloseRequested,
            attempt.control.invalidation == .callerCancelled
        {
            connectionStatePublication.publish(
                activeAttachment == nil ? .detached : .attached
            )
        }
        return reportedError
    }

    func finishAttachmentAttempt(
        _ attempt: WebInspectorModelContainerAttachmentAttempt,
        result: Result<Void, any Error>
    ) {
        guard
            attachmentAttempts.removeValue(
                forKey: attempt.generation
            ) != nil
        else {
            preconditionFailure(
                "An attachment operation completed after its attempt was removed."
            )
        }
        attempt.turn.finish()
        attempt.control.complete(result)
    }

    func detachCurrentAttachment(
        skipSupervisorWait: Bool
    ) async -> WebInspectorModelContainer.Failure? {
        let resource = activeAttachment
        retireElementPickerOperation(
            with: WebInspectorElementPickerError.detached
        )
        if let generation = resource?.generation {
            retireSynchronizationGeneration(
                generation,
                with: .detached
            )
        }
        activeAttachment = nil
        let resetFailure = await resetCanonicalStateForDetach()
        let resourceFailure: WebInspectorModelContainer.Failure?
        if let resource {
            resourceFailure = await closeResource(
                resource,
                skipSupervisorWait: skipSupervisorWait
            )
        } else {
            resourceFailure = nil
        }
        return resetFailure ?? resourceFailure
    }

    func resetCanonicalStateForDetach()
        async -> WebInspectorModelContainer.Failure?
    {
        do {
            if let reset = try resetForDetach() {
                try await webInspectorRunIgnoringCancellation {
                    try await self.finishDetach(reset)
                }
            } else {
                let barrier = try makeAcknowledgementBarrier(
                    through: currentRevision
                )
                try await webInspectorRunIgnoringCancellation {
                    try await self.waitForAcknowledgements(barrier)
                }
            }
            return nil
        } catch {
            return Self.mapConnectionFailure(error)
        }
    }

    func closeResource(
        _ resource: WebInspectorModelContainerAttachmentResource,
        skipSupervisorWait: Bool
    ) async -> WebInspectorModelContainer.Failure? {
        resource.driverTask.cancel()
        _ = await resource.driverTask.value

        var firstFailure: WebInspectorModelContainer.Failure?
        if !resource.proxyLease.isCloseRequested {
            do {
                try await resource.feed.close()
            } catch {
                firstFailure = Self.mapConnectionFailure(error)
            }
        }
        await resource.proxyLease.close()
        if !skipSupervisorWait,
            let supervisor = resource.supervisorTask
        {
            await supervisor.value
        }
        return firstFailure
    }

    func feedResourceOwnership(
        id: UInt64,
        generation: WebInspectorContainerAttachmentGeneration
    ) -> FeedResourceOwnership? {
        if let activeAttachment,
            activeAttachment.id == id,
            activeAttachment.generation == generation
        {
            return .active
        }
        guard let state = attachmentAttempts[generation],
            state.provisionalResource?.id == id
        else {
            return nil
        }
        return .provisional(state.attempt)
    }

    func requirePendingAttempt(
        _ attempt: WebInspectorModelContainerAttachmentAttempt
    ) throws {
        guard let state = attachmentAttempts[attempt.generation],
            state.attempt.control === attempt.control
        else {
            throw WebInspectorModelContainer.Failure.attachmentSuperseded
        }
        if attempt.control.invalidation != nil {
            throw failure(for: attempt)
        }
        guard !isConnectionCloseRequested else {
            throw WebInspectorModelContainer.Failure.closed
        }
    }

    func failure(
        for attempt: WebInspectorModelContainerAttachmentAttempt
    ) -> any Error {
        switch attempt.control.invalidation {
        case .callerCancelled:
            CancellationError()
        case .closed:
            WebInspectorModelContainer.Failure.closed
        case .superseded, .detached, .none:
            WebInspectorModelContainer.Failure.attachmentSuperseded
        }
    }

    static func mapConnectionFailure(
        _ error: any Error
    ) -> WebInspectorModelContainer.Failure {
        if let failure = error as? WebInspectorModelContainer.Failure {
            return failure
        }
        if let scopeError = error as? WebInspectorScopeError {
            return .connection(
                .transport(
                    "Operation failed: \(String(describing: scopeError.operationError)); cleanup failed: \(String(describing: scopeError.cleanupError))"
                ))
        }
        if let feedError = error as? ConnectionModelFeedError {
            switch feedError {
            case let .bootstrapFailed(domain, message):
                return .bootstrap(
                    domain: domain.containerDomain,
                    message: message
                )
            case .connectionAlreadyUsedByDirectConsumer:
                return .connection(
                    .protocolViolation(
                        "The Proxy connection was already used outside its model feed."
                    ))
            case .alreadyOpen:
                return .connection(
                    .protocolViolation(
                        "The Proxy connection already owns a model feed."
                    ))
            case .consumerTerminated:
                return .connection(
                    .transport(
                        "The model feed consumer terminated."
                    ))
            }
        }
        if let proxyError = error as? WebInspectorProxyError {
            switch proxyError {
            case .closed:
                return .connection(.closed)
            case .pageUnavailable:
                return .connection(.pageUnavailable)
            case let .protocolViolation(message):
                return .connection(.protocolViolation(message))
            case let .transportFailure(message),
                let .disconnected(message),
                let .attachFailed(message):
                return .connection(.transport(message))
            case let .unsupported(features):
                return .connection(
                    .transport(
                        features.joined(separator: ", ")
                    ))
            case let .commandRejected(method, message):
                return .connection(.transport("\(method): \(message)"))
            case let .commandFailed(domain, method, message):
                return .connection(
                    .transport(
                        "\(domain).\(method): \(message)"
                    ))
            case .staleIdentifier:
                return .connection(
                    .protocolViolation(
                        "Attachment became stale during startup."
                    ))
            case let .eventBufferOverflow(capacity):
                return .connection(
                    .transport(
                        "An event subscriber exceeded its buffer capacity of \(capacity)."
                    ))
            case .connectionInUse:
                return .connection(
                    .protocolViolation(
                        "The Proxy connection is already in use."
                    ))
            case let .timeout(domain, method):
                return .connection(
                    .transport(
                        "Timed out waiting for \(domain).\(method)."
                    ))
            }
        }
        if let coreError = error as? WebInspectorModelContainerCoreError {
            switch coreError {
            case .closed:
                return .connection(.closed)
            case let .canonicalStore(storeError):
                return .connection(
                    .protocolViolation(
                        String(describing: storeError)
                    ))
            default:
                return .connection(
                    .protocolViolation(
                        String(describing: coreError)
                    ))
            }
        }
        return .connection(.transport(String(describing: error)))
    }
}

package extension ModelDomain {
    var containerDomain: WebInspectorModelContainer.Domain {
        switch self {
        case .dom:
            .dom
        case .network:
            .network
        case .console:
            .console
        case .runtime:
            .runtime
        case .css:
            .css
        }
    }
}
