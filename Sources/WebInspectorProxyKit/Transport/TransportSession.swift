import Foundation
import Synchronization

private struct ConnectionCapabilityCommandOperation: Sendable {
    let backend: any TransportBackend
    let message: String
    let promise: ReplyPromise<ProtocolCommand.Result>
    let pendingKey: TransportSession.PendingKey
    let timeoutAction: (@Sendable () async -> Void)?

    func value() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await backend.sendJSONString(message)
            try Task.checkCancellation()

            let timeoutTask = timeoutAction.map { action in
                Task {
                    await action()
                }
            }
            defer {
                timeoutTask?.cancel()
            }
            _ = try await promise.value()
        } onCancel: {
            Task {
                await promise.fulfill(.failure(CancellationError()))
            }
        }
    }
}

private struct ConnectionCapabilityTask: Sendable {
    let task: Task<Void, Never>
    let pendingKey: TransportSession.PendingKey?
}

private struct PhysicalTargetDisappearanceWaiters: Sendable {
    var activation: [ReplyPromise<Void>] = []
    var release: [ReplyPromise<Void>] = []
}

/// Owns one physical inspector connection.
///
/// Target membership, command/reply routing, inbound ordering, and terminal
/// state deliberately live on the same actor so no public handle has to mirror
/// transport state in order to stay current.
package actor ConnectionCore {
    package typealias TimeoutSleep = @Sendable (Duration) async throws -> Void
    package typealias ResponseTimeoutDidFire = @Sendable () async -> Void
    package typealias CloseAction = @Sendable () async -> Void
    package typealias MessageParser = @Sendable (String) async throws -> ParsedProtocolMessage

    package enum TerminalCause: Equatable, Sendable {
        case explicitClose
        case fatal(String)
        case protocolViolation(String)
    }

    private enum State {
        case open
        case closing
        case closed
    }

    private final class TerminalClaim: Sendable {
        struct Result: Sendable {
            let cause: TerminalCause
            let claimedProposedCause: Bool
        }

        private let cause = Mutex<TerminalCause?>(nil)

        func claim(_ proposedCause: TerminalCause) -> Result {
            cause.withLock { cause in
                if let cause {
                    return Result(cause: cause, claimedProposedCause: false)
                }
                cause = proposedCause
                return Result(cause: proposedCause, claimedProposedCause: true)
            }
        }

        var current: TerminalCause? {
            cause.withLock { $0 }
        }
    }

    private struct TerminalOperation: Sendable {
        let transportError: TransportSession.Error
        let scopeError: WebInspectorProxyError?
        let pendingReplies: [ReplyPromise<ProtocolCommand.Result>]
        let mainPageTargetWaiters: [ReplyPromise<TransportSession.MainPageTarget>]
        let activationWaiters: [ReplyPromise<Void>]
        let releaseWaiters: [ReplyPromise<Void>]
        let capabilityTasks: [Task<Void, Never>]
        let closeAction: CloseAction

        func run() async {
            for pending in pendingReplies {
                await pending.fulfill(.failure(transportError))
            }
            for waiter in mainPageTargetWaiters {
                await waiter.fulfill(.failure(transportError))
            }
            for waiter in activationWaiters {
                await waiter.fulfill(.failure(scopeError ?? WebInspectorProxyError.closed))
            }
            for waiter in releaseWaiters {
                if let scopeError {
                    await waiter.fulfill(.failure(scopeError))
                } else {
                    await waiter.fulfill(.success(()))
                }
            }
            for task in capabilityTasks {
                await task.value
            }
            await closeAction()
        }
    }

    private let backend: any TransportBackend
    private let responseTimeout: Duration?
    private let timeoutSleep: TimeoutSleep
    private let responseTimeoutDidFire: ResponseTimeoutDidFire
    private let messageParser: MessageParser
    private nonisolated let terminalClaim: TerminalClaim
    private var nextCommandID: UInt64
    private var eventSequences: TransportEventSequenceTracker
    private var replyStore: TransportReplyStore
    private var mainPageTargetWaiterStore: ConnectionCore.MainPageTargetWaiterStore
    private var targetRegistry: TransportTargetRegistry
    private var provisionalTargetMessageStore: TransportProvisionalTargetMessageStore
    private var styleSheetRouting: TransportStyleSheetRouting
    private var runtimeContextRegistry: RuntimeContextRegistry
    private var eventSubscribers: TransportEventSubscriberRegistry
    private var eventScopes: ConnectionEventScopeRegistry
    private var capabilities: ConnectionCapabilityRegistry
    private var capabilityTasks: [UInt64: ConnectionCapabilityTask]
    private var currentPageGeneration: WebInspectorPage.Generation
    private var currentPageBindingGapIsOpen: Bool
    private var eventScopeRegistrationWaiters: [(
        expectedCount: Int,
        continuation: CheckedContinuation<Void, Never>
    )]
    private var eventScopeActivationCancellationAction: (@Sendable () async -> Void)?
    private var inboundMessageQueue: TransportInboundMessageQueue
    private var closeAction: CloseAction
    private var terminalTask: Task<Void, Never>?
    private var state: State
    private var nextCloseWaiterID: UInt64
    private var closeWaiters: [UInt64: CheckedContinuation<Void, any Swift.Error>]
    private var closeWaiterRegistrationWaiters: [CheckedContinuation<Void, Never>]
    private var cancelledCloseWaiterIDs: Set<UInt64>
    private var nextTestTargetOrdinal: UInt64

    package init(
        backend: any TransportBackend,
        responseTimeout: Duration? = .seconds(5),
        timeoutSleep: TimeoutSleep? = nil,
        responseTimeoutDidFire: ResponseTimeoutDidFire? = nil,
        messageParser: @escaping MessageParser = {
            try await TransportMessageParser.parse($0)
        },
        closeAction: CloseAction? = nil
    ) {
        self.backend = backend
        self.responseTimeout = responseTimeout
        self.timeoutSleep = timeoutSleep ?? { try await Task.sleep(for: $0) }
        self.responseTimeoutDidFire = responseTimeoutDidFire ?? {}
        self.messageParser = messageParser
        terminalClaim = TerminalClaim()
        nextCommandID = 0
        eventSequences = TransportEventSequenceTracker()
        replyStore = TransportReplyStore()
        mainPageTargetWaiterStore = ConnectionCore.MainPageTargetWaiterStore()
        targetRegistry = TransportTargetRegistry()
        provisionalTargetMessageStore = TransportProvisionalTargetMessageStore()
        styleSheetRouting = TransportStyleSheetRouting()
        runtimeContextRegistry = RuntimeContextRegistry()
        eventSubscribers = TransportEventSubscriberRegistry()
        eventScopes = ConnectionEventScopeRegistry()
        capabilities = ConnectionCapabilityRegistry()
        capabilityTasks = [:]
        currentPageGeneration = WebInspectorPage.Generation(rawValue: 0)
        currentPageBindingGapIsOpen = false
        eventScopeRegistrationWaiters = []
        eventScopeActivationCancellationAction = nil
        inboundMessageQueue = TransportInboundMessageQueue()
        self.closeAction = closeAction ?? {
            await backend.detach()
        }
        terminalTask = nil
        state = .open
        nextCloseWaiterID = 0
        closeWaiters = [:]
        closeWaiterRegistrationWaiters = []
        cancelledCloseWaiterIDs = []
        nextTestTargetOrdinal = 0
    }

    isolated deinit {
        // Asynchronous detach belongs to explicit close. The isolated
        // deinitializer is only a synchronous backstop for actor-owned local
        // resources; native resources have their own isolated backstop.
        eventSubscribers.finishAndRemoveAll()
        eventScopes.finishAndRemoveAll(with: WebInspectorProxyError.closed)
        terminalTask?.cancel()
        terminalTask = nil
        let tasks = Array(capabilityTasks.values)
        capabilityTasks.removeAll()
        for task in tasks {
            task.task.cancel()
            if let pendingKey = task.pendingKey {
                replyStore.removePendingReply(pendingKey)
            }
        }
        precondition(replyStore.pendingReplies.isEmpty, "ConnectionCore deinitialized with pending replies; call close() explicitly.")
        precondition(mainPageTargetWaiterStore.isEmpty, "ConnectionCore deinitialized with pending target waiters; call close() explicitly.")
        precondition(closeWaiters.isEmpty, "ConnectionCore deinitialized with pending close waiters.")
        precondition(capabilities.states.values.allSatisfy { $0.activationWaiters.isEmpty && $0.releaseWaiters.isEmpty }, "ConnectionCore deinitialized with pending capability waiters.")
        precondition(eventScopeRegistrationWaiters.isEmpty, "ConnectionCore deinitialized with event-scope test waiters.")
    }

    private var isOpen: Bool {
        guard case .open = state else {
            return false
        }
        return terminalClaim.current == nil
    }

    private var claimedTerminalCause: TerminalCause {
        guard let cause = terminalClaim.current else {
            preconditionFailure("ConnectionCore entered terminal state without a claim.")
        }
        return cause
    }

    package func events(for domain: ProtocolDomain) -> AsyncStream<ProtocolEvent> {
        guard isOpen else {
            return finishedStream(of: ProtocolEvent.self)
        }
        let pair = AsyncStream<ProtocolEvent>.makeStream(bufferingPolicy: .unbounded)
        let subscriberID = eventSubscribers.insert(pair.continuation, domain: domain)
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeSubscriber(subscriberID, domain: domain)
            }
        }
        return pair.stream
    }

    package func orderedEvents() -> AsyncStream<ProtocolEvent> {
        guard isOpen else {
            return finishedStream(of: ProtocolEvent.self)
        }
        let pair = AsyncStream<ProtocolEvent>.makeStream(bufferingPolicy: .unbounded)
        let subscriberID = eventSubscribers.insertOrdered(pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeOrderedSubscriber(subscriberID)
            }
        }
        return pair.stream
    }

    package func pageGeneration() throws -> WebInspectorPage.Generation {
        guard isOpen else {
            throw terminalScopeError
        }
        guard targetRegistry.currentMainPageTargetID != nil else {
            throw WebInspectorProxyError.pageUnavailable
        }
        return currentPageGeneration
    }

    package func acquireEventScope<Element: Sendable>(
        route: RoutingTargetID,
        targetID: WebInspectorTarget.ID,
        domain: WebInspectorProxyEventDomain,
        buffering: WebInspectorEventBufferingPolicy,
        extract: @escaping @Sendable (WebInspectorProxyEvent) -> Element?
    ) async throws -> WebInspectorProxyEventScope<Element> {
        guard isOpen else {
            throw terminalScopeError
        }
        try requireAvailableTarget(for: route)

        let capacity = buffering.capacity
        let mailbox = WebInspectorEventMailbox<Element>(capacity: capacity)
        let stream = mailbox.makeStream()

        let scopeID = WebInspectorProxyEventScopeID()
        let key = ConnectionCapabilityKey(route: route, targetID: targetID, domain: domain)
        let generation = generation(for: route)
        let sink = WebInspectorEventSink(
            id: scopeID,
            route: route,
            targetID: targetID,
            domain: domain,
            mailbox: mailbox,
            extract: extract
        )

        // Registration and the initial generation marker happen before the
        // logical lease can send its first wire enable command.
        eventScopes.insert(
            sink,
            capability: key,
            capacity: capacity,
            generation: generation
        )
        resumeEventScopeRegistrationWaitersIfNeeded()

        var capability = capabilities.states[key]
            ?? ConnectionCapabilityRegistry.State(physical: .inactive(generation: generation))
        precondition(capability.leaseIDs.insert(scopeID).inserted, "Duplicate capability lease identifier.")

        let activation: ReplyPromise<Void>?
        if case let .enabled(activeGeneration) = capability.physical,
           activeGeneration == generation {
            activation = nil
            precondition(
                capability.activatedLeaseIDs.insert(scopeID).inserted,
                "A newly registered capability lease was already activated."
            )
        } else {
            let promise = ReplyPromise<Void>()
            capability.activationWaiters[scopeID] = promise
            activation = promise
        }
        capabilities.states[key] = capability
        await reconcileCapability(for: key)

        do {
            try await withTaskCancellationHandler {
                try await activation?.value()
            } onCancel: {
                Task { [weak self] in
                    await self?.cancelEventScopeActivation(scopeID, key: key)
                }
            }
        } catch is CancellationError {
            let cancellation = CancellationError()
            do {
                try await releaseEventScope(scopeID)
            } catch {
                throw WebInspectorScopeError(
                    operationError: cancellation,
                    cleanupError: error
                )
            }
            throw cancellation
        } catch {
            await abandonEventScopeAfterFailedAcquisition(scopeID, key: key)
            throw error
        }

        return WebInspectorProxyEventScope(id: scopeID, events: stream)
    }

    package func releaseEventScope(_ id: WebInspectorProxyEventScopeID) async throws {
        guard let entry = eventScopes.remove(id) else {
            return
        }
        resumeEventScopeRegistrationWaitersIfNeeded()
        entry.sink?.finish(nil)

        let key = entry.capability
        guard var capability = capabilities.states[key],
              capability.leaseIDs.remove(id) != nil else {
            return
        }
        capability.failedLeaseIDs.remove(id)
        capability.activatedLeaseIDs.remove(id)
        capability.activationWaiters.removeValue(forKey: id)

        guard case .open = state else {
            capabilities.states[key] = capability
            capabilities.removeEmptyState(for: key)
            return
        }

        guard capability.desiredCount == 0 else {
            capabilities.states[key] = capability
            return
        }

        let cleanup: ReplyPromise<Void>?
        switch capability.physical {
        case .inactive:
            cleanup = nil
        case .enabled:
            let promise = ReplyPromise<Void>()
            capability.releaseWaiters[id] = promise
            cleanup = promise
        case let .enabling(generation, operationID, _):
            let promise = ReplyPromise<Void>()
            capability.releaseWaiters[id] = promise
            capability.physical = .enabling(
                generation: generation,
                operationID: operationID,
                mustDisableAfterEnable: true
            )
            cleanup = promise
        case .disabling:
            let promise = ReplyPromise<Void>()
            capability.releaseWaiters[id] = promise
            cleanup = promise
        }
        capabilities.states[key] = capability
        await reconcileCapability(for: key)
        try await cleanup?.value()
        capabilities.removeEmptyState(for: key)
    }

    package func send(_ command: ProtocolCommand) async throws -> ProtocolCommand.Result {
        try Task.checkCancellation()
        guard isOpen else {
            throw terminalTransportError
        }

        switch command.routing {
        case .root:
            return try await sendRoot(command)
        case let .target(targetID):
            guard targetRegistry.containsTarget(targetID) else {
                throw TransportSession.Error.missingTarget(targetID)
            }
            if let result = transportLocalResult(for: command, targetID: targetID) {
                return result
            }
            return try await sendTarget(command, targetID: targetID)
        case let .octopus(pageTarget):
            let resolvedTarget = try pageTarget ?? currentMainPageTarget()
            guard targetRegistry.containsTarget(resolvedTarget) else {
                throw TransportSession.Error.missingTarget(resolvedTarget)
            }
            if let result = transportLocalResult(for: command, targetID: resolvedTarget) {
                return result
            }
            return try await sendTarget(command, targetID: resolvedTarget)
        }
    }

    @discardableResult
    package func receiveRootMessage(_ message: String) async -> UInt64 {
        guard isOpen else {
            return eventSequences.current.sequence
        }
        inboundMessageQueue.append(message)
        await drainInboundMessages()
        return eventSequences.current.sequence
    }

    package func detach() async {
        await close()
    }

    package func close() async {
        await terminate(.explicitClose)
    }

    @discardableResult
    package nonisolated func failFromNativeCallback(_ message: String) -> Task<Void, Never>? {
        let cause = TerminalCause.fatal(message)
        let claim = terminalClaim.claim(cause)
        guard claim.claimedProposedCause else {
            return nil
        }
        return Task { [weak self] in
            await self?.beginClaimedTerminationHandoff(cause)
        }
    }

    package func waitUntilClosed() async throws {
        switch state {
        case .open, .closing:
            break
        case .closed:
            return try terminalResult(for: claimedTerminalCause).get()
        }

        nextCloseWaiterID &+= 1
        let waiterID = nextCloseWaiterID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerCloseWaiter(id: waiterID, continuation: continuation)
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelCloseWaiter(waiterID)
            }
        }
    }

    package func waitForCloseWaiterForTesting() async {
        if case .closed = state {
            preconditionFailure("Cannot wait for a close waiter after ConnectionCore closed.")
        }
        guard closeWaiters.isEmpty else {
            return
        }
        await withCheckedContinuation { continuation in
            closeWaiterRegistrationWaiters.append(continuation)
        }
    }

    package func waitForEventScopeCountForTesting(_ expectedCount: Int) async {
        precondition(expectedCount >= 0)
        guard eventScopes.entries.count != expectedCount else {
            return
        }
        await withCheckedContinuation { continuation in
            eventScopeRegistrationWaiters.append((expectedCount, continuation))
        }
    }

    package func activeEventScopeSubscriberCountForTesting() -> Int {
        eventScopes.entries.values.count { $0.sink != nil }
    }

    package func replaceEventScopeActivationCancellationActionForTesting(
        _ action: @escaping @Sendable () async -> Void
    ) {
        eventScopeActivationCancellationAction = action
    }

    package func replaceCloseActionForTesting(_ action: @escaping CloseAction) {
        precondition(isOpen, "Close action must be installed before closing begins.")
        closeAction = action
    }

    package func requireOpen() throws {
        guard isOpen else {
            throw terminalTransportError
        }
    }

    package var terminalCause: TerminalCause? {
        terminalClaim.current
    }

    package func waitForCurrentMainPageTarget(timeout: Duration? = nil) async throws -> TransportSession.MainPageTarget {
        guard isOpen else {
            throw terminalTransportError
        }
        if let currentMainPageTargetID = targetRegistry.currentMainPageTargetID {
            return TransportSession.MainPageTarget(
                targetID: currentMainPageTargetID,
                receivedSequence: eventSequences.current.sequence
            )
        }

        let waiter = mainPageTargetWaiterStore.insert()

        let timeoutTask: Task<Void, Never>? = timeout.map { timeout in
            let timeoutSleep = self.timeoutSleep
            return Task {
                do {
                    try await timeoutSleep(timeout)
                } catch {
                    return
                }
                await self.failMainPageTargetWaiter(waiter.id, error: TransportSession.Error.missingMainPageTarget)
            }
        }
        defer {
            timeoutTask?.cancel()
        }

        do {
            return try await withTaskCancellationHandler {
                try await waiter.promise.value()
            } onCancel: {
                Task {
                    await self.failMainPageTargetWaiter(waiter.id, error: CancellationError())
                }
            }
        } catch {
            mainPageTargetWaiterStore.remove(id: waiter.id)
            throw error
        }
    }

    package func snapshot() -> TransportSession.Snapshot {
        TransportSession.Snapshot(
            currentMainPageTargetID: targetRegistry.currentMainPageTargetID,
            targetsByID: targetRegistry.targetsByID,
            frameTargetIDsByFrameID: targetRegistry.frameTargetIDsByFrameID,
            executionContextsByKey: runtimeContextRegistry.contextsByKey,
            pendingRootReplyIDs: replyStore.pendingRootReplyIDs,
            pendingTargetReplyKeys: replyStore.pendingTargetReplyKeys
        )
    }

    package func targetID(forExecutionContext key: RuntimeContext.Key) -> ProtocolTarget.ID? {
        runtimeContextRegistry.targetID(for: key)
    }

    package func targetID(forFrameID frameID: ProtocolFrame.ID) -> ProtocolTarget.ID? {
        targetRegistry.targetID(forFrameID: frameID)
    }

    package func currentMainPageRecord() -> ProtocolTarget.Record? {
        guard isOpen,
              let targetID = targetRegistry.currentMainPageTargetID else {
            return nil
        }
        return targetRegistry.target(for: targetID)
    }

    package func installTargetForTesting(
        kind: ProtocolTarget.Kind,
        frameID: ProtocolFrame.ID?,
        isProvisional: Bool
    ) -> ProtocolTarget.Record {
        precondition(isOpen, "Cannot install a target after ConnectionCore starts closing.")
        let ordinal = nextTestTargetOrdinal
        nextTestTargetOrdinal &+= 1
        let id = ProtocolTarget.ID("test-target-\(ordinal)")
        let record = ProtocolTarget.Record(
            id: id,
            kind: kind,
            frameID: frameID,
            parentFrameID: nil,
            capabilities: .resolved(for: kind, domainNames: nil),
            isProvisional: isProvisional,
            isPaused: false
        )
        _ = targetRegistry.recordTargetCreated(record)
        return record
    }

    private func requireAvailableTarget(for route: RoutingTargetID) throws {
        switch route.storage {
        case let .target(rawValue):
            guard targetRegistry.containsTarget(ProtocolTarget.ID(rawValue)) else {
                throw WebInspectorProxyError.pageUnavailable
            }
        case .currentPage:
            guard targetRegistry.currentMainPageTargetID != nil else {
                throw WebInspectorProxyError.pageUnavailable
            }
        }
    }

    private func resumeEventScopeRegistrationWaitersIfNeeded() {
        let count = eventScopes.entries.count
        var pending: [(
            expectedCount: Int,
            continuation: CheckedContinuation<Void, Never>
        )] = []
        for waiter in eventScopeRegistrationWaiters {
            if count == waiter.expectedCount {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        eventScopeRegistrationWaiters = pending
    }

    private func generation(for route: RoutingTargetID) -> WebInspectorPage.Generation {
        switch route.storage {
        case .currentPage:
            currentPageGeneration
        case .target:
            WebInspectorPage.Generation(rawValue: 0)
        }
    }

    private func cancelEventScopeActivation(
        _ id: WebInspectorProxyEventScopeID,
        key: ConnectionCapabilityKey
    ) async {
        guard var capability = capabilities.states[key],
              let waiter = capability.activationWaiters.removeValue(forKey: id) else {
            return
        }
        capability.failedLeaseIDs.insert(id)
        capabilities.states[key] = capability
        let cancellationAction = eventScopeActivationCancellationAction
        eventScopeActivationCancellationAction = nil
        await cancellationAction?()
        await waiter.fulfill(.failure(CancellationError()))
    }

    private func abandonEventScopeAfterFailedAcquisition(
        _ id: WebInspectorProxyEventScopeID,
        key: ConnectionCapabilityKey
    ) async {
        eventScopes.remove(id)?.sink?.finish(nil)
        resumeEventScopeRegistrationWaitersIfNeeded()
        guard var capability = capabilities.states[key] else {
            return
        }
        capability.leaseIDs.remove(id)
        capability.failedLeaseIDs.remove(id)
        capability.activatedLeaseIDs.remove(id)
        capability.activationWaiters.removeValue(forKey: id)
        capability.releaseWaiters.removeValue(forKey: id)
        capabilities.states[key] = capability
        await reconcileCapability(for: key)
        capabilities.removeEmptyState(for: key)
    }

    private func reconcileCapability(for key: ConnectionCapabilityKey) async {
        guard isOpen, var capability = capabilities.states[key] else {
            return
        }

        let expectedGeneration = generation(for: key.route)
        guard capability.physical.generation == expectedGeneration else {
            capability.physical = .inactive(generation: expectedGeneration)
            capabilities.states[key] = capability
            return await reconcileCapability(for: key)
        }

        if key.domain == .dom {
            if capability.desiredCount > 0 {
                capability.physical = .enabled(generation: expectedGeneration)
                capability.activatedLeaseIDs.formUnion(capability.activationWaiters.keys)
                let waiters = Array(capability.activationWaiters.values)
                capability.activationWaiters.removeAll()
                capabilities.states[key] = capability
                for waiter in waiters {
                    await waiter.fulfill(.success(()))
                }
            } else {
                capability.physical = .inactive(generation: expectedGeneration)
                let waiters = Array(capability.releaseWaiters.values)
                capability.releaseWaiters.removeAll()
                capabilities.states[key] = capability
                for waiter in waiters {
                    await waiter.fulfill(.success(()))
                }
            }
            capabilities.removeEmptyState(for: key)
            return
        }

        switch capability.physical {
        case .inactive where capability.desiredCount > 0:
            guard (try? requireAvailableTarget(for: key.route)) != nil else {
                capabilities.states[key] = capability
                return
            }
            startCapabilityEnable(for: key, generation: expectedGeneration)
        case .enabled where capability.desiredCount == 0:
            startCapabilityDisable(for: key, generation: expectedGeneration)
        case .inactive, .enabling, .enabled, .disabling:
            capabilities.states[key] = capability
        }
    }

    private func startCapabilityEnable(
        for key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation
    ) {
        guard var capability = capabilities.states[key] else {
            return
        }
        let operationID = capabilities.allocateOperationID()
        capability.physical = .enabling(
            generation: generation,
            operationID: operationID,
            mustDisableAfterEnable: false
        )
        capabilities.states[key] = capability
        startCapabilityTask(
            id: operationID,
            key: key,
            generation: generation,
            action: .enable
        )
    }

    private func startCapabilityDisable(
        for key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation
    ) {
        guard var capability = capabilities.states[key] else {
            return
        }
        let operationID = capabilities.allocateOperationID()
        capability.physical = .disabling(generation: generation, operationID: operationID)
        capabilities.states[key] = capability
        startCapabilityTask(
            id: operationID,
            key: key,
            generation: generation,
            action: .disable
        )
    }

    private enum CapabilityWireAction: Equatable, Sendable {
        case enable
        case disable
    }

    private func startCapabilityTask(
        id: UInt64,
        key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation,
        action: CapabilityWireAction
    ) {
        let operation: ConnectionCapabilityCommandOperation
        do {
            operation = try makeCapabilityCommandOperation(action, for: key)
        } catch {
            let result: Result<Void, any Swift.Error> = .failure(
                Self.mapCapabilityError(error, action: action, domain: key.domain)
            )
            let task = Task { [weak self] in
                _ = await self?.completeCapabilityOperation(
                    id: id,
                    key: key,
                    generation: generation,
                    action: action,
                    result: result
                )
            }
            capabilityTasks[id] = ConnectionCapabilityTask(task: task, pendingKey: nil)
            return
        }

        let task = Task { [weak self, operation] in
            let result: Result<Void, any Swift.Error>
            do {
                try await operation.value()
                result = .success(())
            } catch {
                result = .failure(Self.mapCapabilityError(error, action: action, domain: key.domain))
            }
            _ = await self?.completeCapabilityOperation(
                id: id,
                key: key,
                generation: generation,
                action: action,
                result: result
            )
        }
        capabilityTasks[id] = ConnectionCapabilityTask(
            task: task,
            pendingKey: operation.pendingKey
        )
    }

    private func makeCapabilityCommandOperation(
        _ action: CapabilityWireAction,
        for key: ConnectionCapabilityKey
    ) throws -> ConnectionCapabilityCommandOperation {
        let method: String
        switch action {
        case .enable:
            method = "\(key.domain.rawValue).enable"
        case .disable:
            method = "\(key.domain.rawValue).disable"
        }
        let targetID: ProtocolTarget.ID
        switch key.route.storage {
        case let .target(rawValue):
            targetID = ProtocolTarget.ID(rawValue)
            guard targetRegistry.containsTarget(targetID) else {
                throw TransportSession.Error.missingTarget(targetID)
            }
        case .currentPage:
            targetID = try currentMainPageTarget()
        }

        let domain = protocolDomain(for: key.domain)
        let innerCommandID = allocateCommandID()
        let outerCommandID = allocateCommandID()
        let replyKey = TransportSession.ReplyKey(
            targetID: targetID,
            commandID: innerCommandID
        )
        let pendingKey = TransportSession.PendingKey.target(replyKey)
        let message = try TransportMessageParser.makeCommandString(
            id: innerCommandID,
            method: method,
            parametersData: Data("{}".utf8)
        )
        let wrapperMessage = try TransportMessageParser.makeTargetWrapperCommandString(
            id: outerCommandID,
            targetIdentifier: targetID.rawValue,
            message: message
        )
        let promise = ReplyPromise<ProtocolCommand.Result>()
        replyStore.insertTargetReply(
            TransportSession.PendingReply(
                domain: domain,
                method: method,
                targetID: targetID,
                promise: promise,
                hasBufferedProvisionalResponse: false
            ),
            key: replyKey,
            rootWrapperID: outerCommandID
        )

        let timeoutAction: (@Sendable () async -> Void)?
        if let responseTimeout {
            let timeoutSleep = self.timeoutSleep
            let responseTimeoutDidFire = self.responseTimeoutDidFire
            timeoutAction = { [weak self] in
                do {
                    try await timeoutSleep(responseTimeout)
                } catch {
                    return
                }
                await self?.failPendingReplyFromTimeout(
                    pendingKey,
                    error: TransportSession.Error.replyTimeout(
                        method: method,
                        targetID: targetID
                    )
                )
                await responseTimeoutDidFire()
            }
        } else {
            timeoutAction = nil
        }

        return ConnectionCapabilityCommandOperation(
            backend: backend,
            message: wrapperMessage,
            promise: promise,
            pendingKey: pendingKey,
            timeoutAction: timeoutAction
        )
    }

    private func completeCapabilityOperation(
        id: UInt64,
        key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation,
        action: CapabilityWireAction,
        result: Result<Void, any Swift.Error>
    ) async {
        if let pendingKey = capabilityTasks.removeValue(forKey: id)?.pendingKey {
            replyStore.removePendingReply(pendingKey)
        }
        guard isOpen, var capability = capabilities.states[key] else {
            return
        }

        switch (action, capability.physical) {
        case let (.enable, .enabling(activeGeneration, operationID, mustDisableAfterEnable))
            where activeGeneration == generation && operationID == id:
            switch result {
            case .success:
                capability.physical = .enabled(generation: generation)
                capabilities.states[key] = capability
                if mustDisableAfterEnable, capability.desiredCount == 0 {
                    startCapabilityDisable(for: key, generation: generation)
                    return
                }
                capability.activatedLeaseIDs.formUnion(capability.activationWaiters.keys)
                let waiters = Array(capability.activationWaiters.values)
                capability.activationWaiters.removeAll()
                let releaseWaiters = Array(capability.releaseWaiters.values)
                capability.releaseWaiters.removeAll()
                capabilities.states[key] = capability
                for waiter in waiters {
                    await waiter.fulfill(.success(()))
                }
                for waiter in releaseWaiters {
                    await waiter.fulfill(.success(()))
                }
            case let .failure(error):
                let activeLeaseFailed = capability.hasActivatedDesiredLease
                let wireStateIsKnownInactive = Self.enableFailureProvesInactive(error)
                let failedIDs = Set(capability.activationWaiters.keys)
                capability.failedLeaseIDs.formUnion(failedIDs)
                let activationWaiters = Array(capability.activationWaiters.values)
                capability.activationWaiters.removeAll()
                capability.physical = .inactive(generation: generation)
                let releaseWaiters: [ReplyPromise<Void>]
                if capability.desiredCount == 0 {
                    releaseWaiters = Array(capability.releaseWaiters.values)
                    capability.releaseWaiters.removeAll()
                } else {
                    releaseWaiters = []
                }
                let proposedTerminalCause: TerminalCause? = if wireStateIsKnownInactive == false
                    || (activeLeaseFailed && Self.isCommandRejection(error)) {
                    Self.terminalCauseForUncertainEnableFailure(
                        error,
                        domain: key.domain,
                        wasReenable: activeLeaseFailed
                    )
                } else {
                    nil
                }
                let claimedTerminalCause: TerminalCause?
                if let proposedTerminalCause {
                    // Claim terminal ownership before resuming any waiter so
                    // actor reentrancy cannot admit a duplicate enable while
                    // the failed wire state is unknown.
                    let cause = terminalClaim.claim(proposedTerminalCause).cause
                    claimedTerminalCause = cause
                    state = .closing
                } else {
                    claimedTerminalCause = nil
                }
                capabilities.states[key] = capability
                for waiter in activationWaiters {
                    await waiter.fulfill(.failure(error))
                }
                for waiter in releaseWaiters {
                    await waiter.fulfill(.success(()))
                }
                if let claimedTerminalCause {
                    await finishClaimedTermination(claimedTerminalCause)
                }
            }

        case let (.disable, .disabling(activeGeneration, operationID))
            where activeGeneration == generation && operationID == id:
            switch result {
            case .success:
                capability.physical = .inactive(generation: generation)
                let releaseWaiters = Array(capability.releaseWaiters.values)
                capability.releaseWaiters.removeAll()
                capabilities.states[key] = capability
                await reconcileCapability(for: key)
                for waiter in releaseWaiters {
                    await waiter.fulfill(.success(()))
                }
            case let .failure(error):
                if Self.isCommandRejection(error) {
                    // A rejected disable proves that the command did not
                    // deactivate the physical domain. Retain the enabled state
                    // so a late lease can use it and a future final release can
                    // retry cleanup without sending a duplicate enable.
                    capability.physical = .enabled(generation: generation)
                    capability.activatedLeaseIDs.formUnion(capability.activationWaiters.keys)
                    let activationWaiters = Array(capability.activationWaiters.values)
                    capability.activationWaiters.removeAll()
                    let releaseWaiters = Array(capability.releaseWaiters.values)
                    capability.releaseWaiters.removeAll()
                    capabilities.states[key] = capability
                    for waiter in activationWaiters {
                        await waiter.fulfill(.success(()))
                    }
                    for waiter in releaseWaiters {
                        await waiter.fulfill(.failure(error))
                    }
                    return
                }

                if Self.isPageUnavailable(error) {
                    // Target disappearance normally supersedes the operation
                    // before its completion reaches this branch. If the local
                    // target lookup wins that race, the vanished target makes
                    // cleanup complete without establishing reusable wire state.
                    let failedIDs = Set(capability.activationWaiters.keys)
                    capability.failedLeaseIDs.formUnion(failedIDs)
                    capability.physical = .inactive(generation: generation)
                    let activationWaiters = Array(capability.activationWaiters.values)
                    capability.activationWaiters.removeAll()
                    let releaseWaiters = Array(capability.releaseWaiters.values)
                    capability.releaseWaiters.removeAll()
                    capabilities.states[key] = capability
                    for waiter in activationWaiters {
                        await waiter.fulfill(.failure(error))
                    }
                    for waiter in releaseWaiters {
                        await waiter.fulfill(.success(()))
                    }
                    return
                }

                let proposedTerminalCause = Self.terminalCauseForUncertainDisableFailure(
                    error,
                    domain: key.domain
                )
                // Claim terminal ownership before resuming any waiter so actor
                // reentrancy cannot admit a lease against uncertain wire state.
                let claimedTerminalCause = terminalClaim.claim(proposedTerminalCause).cause
                state = .closing
                let activationWaiters = Array(capability.activationWaiters.values)
                capability.activationWaiters.removeAll()
                let releaseWaiters = Array(capability.releaseWaiters.values)
                capability.releaseWaiters.removeAll()
                capabilities.states[key] = capability
                for waiter in activationWaiters {
                    await waiter.fulfill(.failure(error))
                }
                for waiter in releaseWaiters {
                    await waiter.fulfill(.failure(error))
                }
                await finishClaimedTermination(claimedTerminalCause)
            }

        default:
            // Completion from an older generation or superseded operation can
            // release its task, but it cannot mutate current physical state.
            return
        }
    }

    private nonisolated static func mapCapabilityError(
        _ error: any Swift.Error,
        action: CapabilityWireAction,
        domain: WebInspectorProxyEventDomain
    ) -> any Swift.Error {
        if let proxyError = error as? WebInspectorProxyError {
            return proxyError
        }
        let method = "\(domain.rawValue).\(action == .enable ? "enable" : "disable")"
        guard let transportError = error as? TransportSession.Error else {
            return WebInspectorProxyError.transportFailure(String(describing: error))
        }
        switch transportError {
        case .transportClosed:
            return WebInspectorProxyError.closed
        case let .transportFailure(message):
            return WebInspectorProxyError.transportFailure(message)
        case let .remoteError(_, _, message):
            return WebInspectorProxyError.commandRejected(method: method, message: message)
        case .missingMainPageTarget, .missingTarget:
            return WebInspectorProxyError.pageUnavailable
        case .malformedMessage:
            return WebInspectorProxyError.protocolViolation("Malformed reply for \(method).")
        case .replyTimeout:
            return WebInspectorProxyError.timeout(domain: domain.rawValue, method: action == .enable ? "enable" : "disable")
        }
    }

    private nonisolated static func enableFailureProvesInactive(
        _ error: any Swift.Error
    ) -> Bool {
        guard let error = error as? WebInspectorProxyError else {
            return false
        }
        switch error {
        case .commandRejected, .pageUnavailable:
            return true
        case .unsupported, .attachFailed, .closed, .staleIdentifier,
             .disconnected, .commandFailed, .protocolViolation,
             .eventBufferOverflow, .transportFailure, .timeout:
            return false
        }
    }

    private nonisolated static func isCommandRejection(
        _ error: any Swift.Error
    ) -> Bool {
        guard let error = error as? WebInspectorProxyError,
              case .commandRejected = error else {
            return false
        }
        return true
    }

    private nonisolated static func isPageUnavailable(
        _ error: any Swift.Error
    ) -> Bool {
        guard let error = error as? WebInspectorProxyError,
              case .pageUnavailable = error else {
            return false
        }
        return true
    }

    private nonisolated static func terminalCauseForUncertainEnableFailure(
        _ error: any Swift.Error,
        domain: WebInspectorProxyEventDomain,
        wasReenable: Bool
    ) -> TerminalCause {
        if let error = error as? WebInspectorProxyError,
           case let .protocolViolation(message) = error {
            return .protocolViolation(message)
        }
        let action = wasReenable ? "re-enable" : "enable"
        return .fatal(
            "Failed to \(action) \(domain.rawValue) with an uncertain wire state: \(error)"
        )
    }

    private nonisolated static func terminalCauseForUncertainDisableFailure(
        _ error: any Swift.Error,
        domain: WebInspectorProxyEventDomain
    ) -> TerminalCause {
        if let error = error as? WebInspectorProxyError,
           case let .protocolViolation(message) = error {
            return .protocolViolation(message)
        }
        return .fatal(
            "Failed to disable \(domain.rawValue) with an uncertain wire state: \(error)"
        )
    }

    private func protocolDomain(for domain: WebInspectorProxyEventDomain) -> ProtocolDomain {
        switch domain {
        case .target:
            .target
        case .dom:
            .dom
        case .inspector:
            .inspector
        case .css:
            .css
        case .network:
            .network
        case .console:
            .console
        case .runtime:
            .runtime
        case .page:
            .page
        }
    }

    private func sendRoot(_ command: ProtocolCommand) async throws -> ProtocolCommand.Result {
        let commandID = allocateCommandID()
        let promise = ReplyPromise<ProtocolCommand.Result>()
        replyStore.insertRootReply(TransportSession.PendingReply(
            domain: command.domain,
            method: command.method,
            targetID: nil,
            promise: promise,
            hasBufferedProvisionalResponse: false
        ), commandID: commandID)
        do {
            try Task.checkCancellation()
            let message = try TransportMessageParser.makeCommandString(
                id: commandID,
                method: command.method,
                parametersData: command.parametersData
            )
            try await backend.sendJSONString(message)
            try Task.checkCancellation()
        } catch {
            await failPendingReply(.root(commandID), error: error)
            throw error
        }
        return try await awaitReply(
            promise,
            timeout: .root(commandID),
            method: command.method,
            targetID: nil
        )
    }

    private func sendTarget(
        _ command: ProtocolCommand,
        targetID: ProtocolTarget.ID
    ) async throws -> ProtocolCommand.Result {
        let innerCommandID = allocateCommandID()
        let outerCommandID = allocateCommandID()
        let key = TransportSession.ReplyKey(targetID: targetID, commandID: innerCommandID)
        let promise = ReplyPromise<ProtocolCommand.Result>()
        replyStore.insertTargetReply(TransportSession.PendingReply(
            domain: command.domain,
            method: command.method,
            targetID: targetID,
            promise: promise,
            hasBufferedProvisionalResponse: false
        ), key: key, rootWrapperID: outerCommandID)
        do {
            try Task.checkCancellation()
            let message = try TransportMessageParser.makeCommandString(
                id: innerCommandID,
                method: command.method,
                parametersData: command.parametersData
            )
            let wrapperMessage = try TransportMessageParser.makeTargetWrapperCommandString(
                id: outerCommandID,
                targetIdentifier: targetID.rawValue,
                message: message
            )
            try await backend.sendJSONString(wrapperMessage)
            try Task.checkCancellation()
        } catch {
            await failPendingReply(.target(key), error: error)
            throw error
        }
        return try await awaitReply(
            promise,
            timeout: .target(key),
            method: command.method,
            targetID: targetID
        )
    }

    private func transportLocalResult(
        for command: ProtocolCommand,
        targetID: ProtocolTarget.ID
    ) -> ProtocolCommand.Result? {
        guard command.method == "DOM.enable" else {
            return nil
        }
        let eventSequence = eventSequences.current
        return ProtocolCommand.Result(
            domain: command.domain,
            method: command.method,
            targetID: targetID,
            receivedSequence: eventSequence.sequence,
            receivedDomainSequences: eventSequence.receivedDomainSequences,
            resultData: Data("{}".utf8)
        )
    }

    private func drainInboundMessages() async {
        guard inboundMessageQueue.startDraining() else {
            return
        }

        defer {
            inboundMessageQueue.finishDraining()
        }

        while isOpen, let rawMessage = inboundMessageQueue.popNext() {
            let parsed: ParsedProtocolMessage
            do {
                parsed = try await messageParser(rawMessage)
            } catch {
                guard isOpen else {
                    return
                }
                handoffTermination(.protocolViolation("Malformed root protocol message."))
                return
            }
            guard isOpen else {
                return
            }
            await handleRootMessage(parsed)
            guard isOpen else {
                return
            }
        }
    }

    private func awaitReply(
        _ promise: ReplyPromise<ProtocolCommand.Result>,
        timeout key: TransportSession.PendingKey,
        method: String,
        targetID: ProtocolTarget.ID?
    ) async throws -> ProtocolCommand.Result {
        if Task.isCancelled {
            await failPendingReply(key, error: CancellationError())
        }
        let timeoutTask: Task<Void, Never>? = responseTimeout.map { responseTimeout in
            let timeoutSleep = self.timeoutSleep
            let responseTimeoutDidFire = self.responseTimeoutDidFire
            return Task {
                do {
                    try await timeoutSleep(responseTimeout)
                } catch {
                    return
                }
                await self.failPendingReplyFromTimeout(
                    key,
                    error: TransportSession.Error.replyTimeout(method: method, targetID: targetID)
                )
                await responseTimeoutDidFire()
            }
        }
        defer {
            timeoutTask?.cancel()
        }
        do {
            return try await withTaskCancellationHandler {
                try await promise.value()
            } onCancel: {
                Task {
                    await self.failPendingReply(key, error: CancellationError())
                }
            }
        } catch {
            removePendingReply(key)
            throw error
        }
    }

    private func handleRootMessage(_ parsed: ParsedProtocolMessage) async {
        guard isOpen else {
            return
        }
        if let id = parsed.id,
           let key = replyStore.takeTargetReplyKey(forRootWrapperID: id) {
            if parsed.errorMessage != nil,
               let pending = replyStore.removeTargetReply(for: key) {
                await resolve(pending, parsed: parsed)
            }
            return
        }

        if let id = parsed.id,
           let pending = replyStore.removeRootReply(commandID: id) {
            await resolve(pending, parsed: parsed)
            return
        }

        guard let method = parsed.method else {
            return
        }

        if method == "Target.dispatchMessageFromTarget" {
            guard let dispatch = try? TransportMessageParser.decode(TargetDispatchParams.self, from: parsed.paramsData) else {
                handoffTermination(.protocolViolation("Malformed Target.dispatchMessageFromTarget payload."))
                return
            }
            let targetMessage: ParsedProtocolMessage
            do {
                targetMessage = try await messageParser(dispatch.message)
            } catch {
                guard isOpen else {
                    return
                }
                handoffTermination(.protocolViolation("Malformed target protocol message."))
                return
            }
            guard isOpen else {
                return
            }
            await handleTargetMessage(targetMessage, targetID: dispatch.targetId)
            return
        }

        let targetID = targetIDForRootEvent(method: method, paramsData: parsed.paramsData)
        let sourceTargetID = sourceTargetIDForRootEvent(method: method, targetID: targetID)
        let destroyedCurrentMainPageTarget = method == "Target.targetDestroyed"
            && targetID != nil
            && targetID == targetRegistry.currentMainPageTargetID
        let pendingStyleSheetAddedEvents: [ResolvedStyleSheetAddedEvent]
        do {
            pendingStyleSheetAddedEvents = try await updateRegistryFromRootEvent(
                method: method,
                targetID: targetID,
                sourceTargetID: sourceTargetID,
                paramsData: parsed.paramsData
            )
        } catch {
            guard isOpen else {
                return
            }
            handoffTermination(.protocolViolation("Failed to decode \(method): \(error)"))
            return
        }
        guard isOpen else {
            return
        }
        await emit(
            domain: ProtocolDomain(method: method),
            method: method,
            targetID: targetID,
            sourceTargetID: sourceTargetID,
            paramsData: parsed.paramsData,
            destroyedCurrentMainPageTarget: destroyedCurrentMainPageTarget
        )
        guard isOpen else {
            return
        }
        await emitResolvedStyleSheetAddedEvents(pendingStyleSheetAddedEvents)
        guard isOpen else {
            return
        }
        await dispatchCommittedProvisionalTargetMessagesIfNeeded(method: method, paramsData: parsed.paramsData)
    }

    private func handleTargetMessage(_ parsed: ParsedProtocolMessage, targetID: ProtocolTarget.ID) async {
        guard isOpen else {
            return
        }
        if targetRegistry.target(for: targetID)?.isProvisional == true {
            markTargetReplyAsBufferedIfNeeded(parsed, targetID: targetID)
            provisionalTargetMessageStore.append(parsed, for: targetID)
            return
        }

        if let id = parsed.id {
            let key = TransportSession.ReplyKey(targetID: targetID, commandID: id)
            if let pending = replyStore.removeTargetReply(for: key) {
                await resolve(pending, parsed: parsed)
                return
            }
        }

        guard let method = parsed.method else {
            return
        }

        if method == "Target.dispatchMessageFromTarget" {
            guard let dispatch = try? TransportMessageParser.decode(TargetDispatchParams.self, from: parsed.paramsData) else {
                handoffTermination(.protocolViolation("Malformed nested Target.dispatchMessageFromTarget payload."))
                return
            }
            let targetMessage: ParsedProtocolMessage
            do {
                targetMessage = try await messageParser(dispatch.message)
            } catch {
                guard isOpen else {
                    return
                }
                handoffTermination(.protocolViolation("Malformed nested Target.dispatchMessageFromTarget payload."))
                return
            }
            guard isOpen else {
                return
            }
            await handleTargetMessage(targetMessage, targetID: dispatch.targetId)
            return
        }

        let emittedTargetID = targetIDForTargetEvent(
            method: method,
            deliveredTargetID: targetID,
            paramsData: parsed.paramsData
        )
        updateRegistryFromTargetEvent(
            method: method,
            targetID: emittedTargetID,
            sourceTargetID: targetID,
            paramsData: parsed.paramsData
        )
        await emit(
            domain: ProtocolDomain(method: method),
            method: method,
            targetID: emittedTargetID,
            sourceTargetID: targetID,
            paramsData: parsed.paramsData
        )
    }

    private func resolve(_ pending: TransportSession.PendingReply, parsed: ParsedProtocolMessage) async {
        if let errorMessage = parsed.errorMessage {
            await pending.promise.fulfill(
                .failure(
                    TransportSession.Error.remoteError(
                        method: pending.method,
                        targetID: pending.targetID,
                        message: errorMessage
                    )
                )
            )
            return
        }
        let eventSequence = eventSequences.current
        await pending.promise.fulfill(
            .success(
                ProtocolCommand.Result(
                    domain: pending.domain,
                    method: pending.method,
                    targetID: pending.targetID,
                    receivedSequence: eventSequence.sequence,
                    receivedDomainSequences: eventSequence.receivedDomainSequences,
                    resultData: parsed.resultData
                )
            )
        )
    }

    private func updateRegistryFromRootEvent(
        method: String,
        targetID: ProtocolTarget.ID?,
        sourceTargetID: ProtocolTarget.ID?,
        paramsData: Data
    ) async throws -> [ResolvedStyleSheetAddedEvent] {
        switch method {
        case "Target.targetCreated":
            let params = try TransportMessageParser.decode(TargetCreatedParams.self, from: paramsData)
            return await applyTargetCreated(record(for: params.targetInfo))
        case "Target.targetDestroyed":
            let params = try TransportMessageParser.decode(TargetDestroyedParams.self, from: paramsData)
            await applyTargetDestroyed(params.targetId)
            return []
        case "Target.didCommitProvisionalTarget":
            let params = try TransportMessageParser.decode(TargetCommittedParams.self, from: paramsData)
            return await applyTargetCommitted(oldTargetID: params.oldTargetId, newTargetID: params.newTargetId)
        case "Runtime.executionContextCreated", "Runtime.executionContextDestroyed", "Runtime.executionContextsCleared":
            updateRegistryFromTargetEvent(
                method: method,
                targetID: targetID,
                sourceTargetID: sourceTargetID,
                paramsData: paramsData
            )
            return []
        case "CSS.styleSheetAdded", "CSS.styleSheetRemoved":
            updateCSSStyleSheetRegistry(method: method, targetID: targetID, paramsData: paramsData)
            return []
        default:
            return []
        }
    }

    private func updateRegistryFromTargetEvent(
        method: String,
        targetID: ProtocolTarget.ID?,
        sourceTargetID: ProtocolTarget.ID? = nil,
        paramsData: Data
    ) {
        guard let targetID else {
            return
        }
        if method == "CSS.styleSheetAdded" || method == "CSS.styleSheetRemoved" {
            updateCSSStyleSheetRegistry(method: method, targetID: targetID, paramsData: paramsData)
            return
        }
        switch method {
        case "Runtime.executionContextCreated":
            guard let params = try? TransportMessageParser.decode(RuntimeExecutionContextCreatedParams.self, from: paramsData) else {
                return
            }
            let frameID = params.context.frameId
            let resolvedTargetID = targetRegistry.recordRuntimeContext(
                deliveredTargetID: targetID,
                frameID: frameID
            )
            let context = RuntimeContext.Record(
                id: params.context.id,
                targetID: resolvedTargetID,
                runtimeAgentTargetID: sourceTargetID ?? targetID,
                type: params.context.type ?? .normal,
                name: params.context.name ?? "",
                frameID: frameID
            )
            runtimeContextRegistry.record(context)
        case "Runtime.executionContextDestroyed":
            guard let params = try? TransportMessageParser.decode(RuntimeExecutionContextDestroyedParams.self, from: paramsData) else {
                return
            }
            let runtimeAgentTargetID = sourceTargetID ?? targetID
            runtimeContextRegistry.remove(
                RuntimeContext.Key(
                    runtimeAgentTargetID: runtimeAgentTargetID,
                    contextID: params.executionContextId
                )
            )
        case "Runtime.executionContextsCleared":
            let runtimeAgentTargetID = sourceTargetID ?? targetID
            runtimeContextRegistry.clear(runtimeAgentTargetID: runtimeAgentTargetID)
        default:
            return
        }
    }

    private func applyTargetCreated(_ record: ProtocolTarget.Record) async -> [ResolvedStyleSheetAddedEvent] {
        let previousMainPageTargetID = targetRegistry.currentMainPageTargetID
        let resolution = targetRegistry.recordTargetCreated(record)
        await currentPageBindingDidChange(
            from: previousMainPageTargetID,
            to: targetRegistry.currentMainPageTargetID
        )
        guard isOpen else {
            return []
        }
        return resolvePendingStyleSheets(for: resolution)
    }

    private func record(for targetInfo: TargetInfoPayload) -> ProtocolTarget.Record {
        let kind = targetRegistry.targetKind(
            protocolType: targetInfo.type,
            frameID: targetInfo.frameId,
            parentFrameID: targetInfo.parentFrameId,
            isProvisional: targetInfo.isProvisional
        )
        return ProtocolTarget.Record(
            id: targetInfo.targetId,
            kind: kind,
            frameID: targetInfo.frameId,
            parentFrameID: targetInfo.parentFrameId,
            capabilities: capabilities(for: targetInfo, kind: kind),
            isProvisional: targetInfo.isProvisional ?? false,
            isPaused: targetInfo.isPaused ?? false
        )
    }

    private func capabilities(for targetInfo: TargetInfoPayload, kind: ProtocolTarget.Kind) -> ProtocolTarget.Capabilities {
        ProtocolTarget.Capabilities.resolved(for: kind, domainNames: targetInfo.domains)
    }

    private func applyTargetDestroyed(_ targetID: ProtocolTarget.ID) async {
        let previousMainPageTargetID = targetRegistry.currentMainPageTargetID
        targetRegistry.removeTarget(targetID)
        let capabilityWaiters = physicalTargetDidDisappear(targetID)
        let pendingReplies = replyStore.removeTargetReplies(for: targetID)
        provisionalTargetMessageStore.removeTarget(targetID)
        styleSheetRouting.removeTarget(targetID)
        runtimeContextRegistry.removeTarget(targetID)
        await currentPageBindingDidChange(
            from: previousMainPageTargetID,
            to: targetRegistry.currentMainPageTargetID
        )
        await resumePhysicalTargetDisappearanceWaiters(capabilityWaiters)
        for pending in pendingReplies {
            await pending.promise.fulfill(.failure(TransportSession.Error.missingTarget(targetID)))
        }
    }

    private func applyTargetCommitted(
        oldTargetID: ProtocolTarget.ID,
        newTargetID: ProtocolTarget.ID
    ) async -> [ResolvedStyleSheetAddedEvent] {
        let previousMainPageTargetID = targetRegistry.currentMainPageTargetID
        let mutation = targetRegistry.commitTarget(oldTargetID: oldTargetID, newTargetID: newTargetID)
        var capabilityWaiters = PhysicalTargetDisappearanceWaiters()
        var stalePendingReplies: [TransportSession.PendingReply] = []

        if mutation.shouldRetargetExternalState {
            let oldTargetID = mutation.committedOldTargetID
            capabilityWaiters = physicalTargetDidDisappear(oldTargetID)
            stalePendingReplies = replyStore.removeTargetReplies(for: oldTargetID)
            provisionalTargetMessageStore.removeTarget(oldTargetID)
            styleSheetRouting.retarget(from: oldTargetID, to: newTargetID)
            runtimeContextRegistry.retarget(oldTargetID: oldTargetID, newTargetID: newTargetID)
        }

        await currentPageBindingDidChange(
            from: previousMainPageTargetID,
            to: targetRegistry.currentMainPageTargetID
        )
        await resumePhysicalTargetDisappearanceWaiters(capabilityWaiters)
        for pending in stalePendingReplies {
            await pending.promise.fulfill(
                .failure(TransportSession.Error.missingTarget(mutation.committedOldTargetID))
            )
        }

        guard isOpen else {
            return []
        }
        return resolvePendingStyleSheets(for: mutation.resolvedFrameTarget)
    }

    private func currentPageBindingDidChange(
        from oldTargetID: ProtocolTarget.ID?,
        to newTargetID: ProtocolTarget.ID?
    ) async {
        guard oldTargetID != newTargetID else {
            return
        }

        if oldTargetID == nil,
           newTargetID != nil,
           currentPageBindingGapIsOpen {
            // The old -> nil transition already opened the replacement
            // generation and published its reset. Installing the replacement
            // only reactivates that generation; a second generation would
            // expose an empty intermediate binding as another logical page
            // transition.
            currentPageBindingGapIsOpen = false
            let keys = capabilities.states.keys.filter { $0.route == .currentPage }
            for key in keys {
                await reconcileCapability(for: key)
                guard isOpen else {
                    return
                }
            }
            return
        }

        currentPageBindingGapIsOpen = oldTargetID != nil && newTargetID == nil
        currentPageGeneration = WebInspectorPage.Generation(
            rawValue: currentPageGeneration.rawValue &+ 1
        )
        eventScopes.publishReset(currentPageGeneration) { sink in
            sink.route == .currentPage
        }

        let keys = capabilities.states.keys.filter { $0.route == .currentPage }
        var releaseWaiters: [ReplyPromise<Void>] = []
        for key in keys {
            guard var capability = capabilities.states[key] else {
                continue
            }
            releaseWaiters.append(contentsOf: capability.releaseWaiters.values)
            capability.releaseWaiters.removeAll()
            capability.physical = .inactive(generation: currentPageGeneration)
            capabilities.states[key] = capability
        }

        if newTargetID != nil {
            for key in keys {
                await reconcileCapability(for: key)
                if !isOpen {
                    break
                }
            }
        }
        for waiter in releaseWaiters {
            await waiter.fulfill(.success(()))
        }
    }

    private func physicalTargetDidDisappear(
        _ targetID: ProtocolTarget.ID
    ) -> PhysicalTargetDisappearanceWaiters {
        let route = RoutingTargetID(targetID.rawValue)
        eventScopes.finishSubscribers(where: { sink in
            sink.route == route
        }, with: WebInspectorProxyError.pageUnavailable)

        let keys = capabilities.states.keys.filter { $0.route == route }
        var waiters = PhysicalTargetDisappearanceWaiters()
        for key in keys {
            guard var capability = capabilities.states[key] else {
                continue
            }
            capability.failedLeaseIDs.formUnion(capability.activationWaiters.keys)
            waiters.activation.append(contentsOf: capability.activationWaiters.values)
            waiters.release.append(contentsOf: capability.releaseWaiters.values)
            capability.activationWaiters.removeAll()
            capability.releaseWaiters.removeAll()
            capability.physical = .inactive(generation: capability.physical.generation)
            capabilities.states[key] = capability
            capabilities.removeEmptyState(for: key)
        }

        return waiters
    }

    private func resumePhysicalTargetDisappearanceWaiters(
        _ waiters: PhysicalTargetDisappearanceWaiters
    ) async {
        for waiter in waiters.activation {
            await waiter.fulfill(.failure(WebInspectorProxyError.pageUnavailable))
        }
        for waiter in waiters.release {
            await waiter.fulfill(.success(()))
        }
    }

    private func resolvePendingStyleSheets(
        for frameTarget: TransportFrameTargetResolution?
    ) -> [ResolvedStyleSheetAddedEvent] {
        guard let frameTarget else {
            return []
        }
        return resolvePendingStyleSheets(frameID: frameTarget.frameID, targetID: frameTarget.targetID)
    }

    private func dispatchCommittedProvisionalTargetMessagesIfNeeded(method: String, paramsData: Data) async {
        guard method == "Target.didCommitProvisionalTarget",
              let params = try? TransportMessageParser.decode(TargetCommittedParams.self, from: paramsData) else {
            return
        }

        let messages = provisionalTargetMessageStore.takeMessages(for: params.newTargetId)
        for message in messages {
            await handleTargetMessage(message, targetID: params.newTargetId)
            guard isOpen else {
                return
            }
        }
    }

    private func targetIDForRootEvent(method: String, paramsData: Data) -> ProtocolTarget.ID? {
        switch method {
        case "Target.targetCreated":
            return (try? TransportMessageParser.decode(TargetCreatedParams.self, from: paramsData))?.targetInfo.targetId
        case "Target.targetDestroyed":
            return (try? TransportMessageParser.decode(TargetDestroyedParams.self, from: paramsData))?.targetId
        case "Target.didCommitProvisionalTarget":
            return (try? TransportMessageParser.decode(TargetCommittedParams.self, from: paramsData))?.newTargetId
        case "Runtime.executionContextCreated":
            if let frameID = (try? TransportMessageParser.decode(RuntimeExecutionContextCreatedParams.self, from: paramsData))?.context.frameId {
                return targetRegistry.targetID(forFrameID: frameID) ?? targetRegistry.currentMainPageTargetID
            }
            return targetRegistry.currentMainPageTargetID
        case "CSS.styleSheetAdded":
            return targetIDForCSSStyleSheetAdded(paramsData: paramsData)
        case "CSS.styleSheetChanged", "CSS.styleSheetRemoved":
            return targetIDForCSSStyleSheetID(paramsData: paramsData)
        case "DOM.documentUpdated":
            return nil
        default:
            switch ProtocolDomain(method: method) {
            case .dom, .runtime, .css, .console, .network, .page, .storage:
                return targetRegistry.currentMainPageTargetID
            default:
                return nil
            }
        }
    }

    private func sourceTargetIDForRootEvent(
        method: String,
        targetID: ProtocolTarget.ID?
    ) -> ProtocolTarget.ID? {
        switch ProtocolDomain(method: method) {
        case .runtime:
            return targetRegistry.currentMainPageTargetID ?? targetID
        default:
            return targetID
        }
    }

    private func targetIDForTargetEvent(
        method: String,
        deliveredTargetID: ProtocolTarget.ID,
        paramsData: Data
    ) -> ProtocolTarget.ID {
        guard method == "Runtime.executionContextCreated",
              let frameID = (try? TransportMessageParser.decode(RuntimeExecutionContextCreatedParams.self, from: paramsData))?.context.frameId else {
            return deliveredTargetID
        }
        return targetRegistry.resolvedTargetIDForRuntimeContext(deliveredTargetID: deliveredTargetID, frameID: frameID)
    }

    private func targetIDForCSSStyleSheetAdded(paramsData: Data) -> ProtocolTarget.ID? {
        guard let params = try? TransportMessageParser.decode(CSSStyleSheetAddedParams.self, from: paramsData) else {
            return nil
        }
        if let frameID = params.header.frameID {
            guard let targetID = targetRegistry.targetID(forFrameID: frameID),
                  targetRegistry.target(for: targetID)?.isProvisional != true else {
                return nil
            }
            return targetID
        }
        return styleSheetRouting.targetID(for: params.header.styleSheetID) ?? targetRegistry.currentMainPageTargetID
    }

    private func targetIDForCSSStyleSheetID(paramsData: Data) -> ProtocolTarget.ID? {
        guard let params = try? TransportMessageParser.decode(CSSStyleSheetIDParams.self, from: paramsData) else {
            return nil
        }
        if styleSheetRouting.hasUnresolvedStyleSheet(params.styleSheetID) {
            return nil
        }
        return styleSheetRouting.targetID(for: params.styleSheetID)
    }

    private func updateCSSStyleSheetRegistry(
        method: String,
        targetID: ProtocolTarget.ID?,
        paramsData: Data
    ) {
        switch method {
        case "CSS.styleSheetAdded":
            guard let params = try? TransportMessageParser.decode(CSSStyleSheetAddedParams.self, from: paramsData) else {
                return
            }
            if let frameID = params.header.frameID {
                if let resolvedTargetID = targetRegistry.targetID(forFrameID: frameID),
                   targetRegistry.target(for: resolvedTargetID)?.isProvisional != true {
                    styleSheetRouting.recordAdded(
                        styleSheetID: params.header.styleSheetID,
                        frameID: frameID,
                        paramsData: paramsData,
                        resolvedTargetID: resolvedTargetID
                    )
                } else {
                    styleSheetRouting.recordAdded(
                        styleSheetID: params.header.styleSheetID,
                        frameID: frameID,
                        paramsData: paramsData,
                        resolvedTargetID: nil
                    )
                }
                return
            }
            if let resolvedTargetID = targetID {
                styleSheetRouting.recordAdded(
                    styleSheetID: params.header.styleSheetID,
                    frameID: nil,
                    paramsData: paramsData,
                    resolvedTargetID: resolvedTargetID
                )
            }
        case "CSS.styleSheetRemoved":
            guard let params = try? TransportMessageParser.decode(CSSStyleSheetIDParams.self, from: paramsData) else {
                return
            }
            styleSheetRouting.remove(styleSheetID: params.styleSheetID)
        default:
            return
        }
    }

    private func resolvePendingStyleSheets(
        frameID: ProtocolFrame.ID,
        targetID: ProtocolTarget.ID
    ) -> [ResolvedStyleSheetAddedEvent] {
        styleSheetRouting.resolvePending(frameID: frameID, targetID: targetID)
    }

    private func emitResolvedStyleSheetAddedEvents(_ events: [ResolvedStyleSheetAddedEvent]) async {
        guard !events.isEmpty else {
            return
        }
        for event in events {
            guard isOpen else {
                return
            }
            await emit(
                domain: .css,
                method: "CSS.styleSheetAdded",
                targetID: event.targetID,
                paramsData: event.paramsData
            )
            guard isOpen else {
                return
            }
        }
    }

    private func currentMainPageTarget() throws -> ProtocolTarget.ID {
        guard let currentMainPageTargetID = targetRegistry.currentMainPageTargetID else {
            throw TransportSession.Error.missingMainPageTarget
        }
        return currentMainPageTargetID
    }

    private func allocateCommandID() -> UInt64 {
        nextCommandID &+= 1
        return nextCommandID
    }

    private func emit(
        domain: ProtocolDomain,
        method: String,
        targetID: ProtocolTarget.ID?,
        sourceTargetID: ProtocolTarget.ID? = nil,
        paramsData: Data,
        destroyedCurrentMainPageTarget: Bool = false
    ) async {
        guard isOpen else {
            return
        }
        let eventSequence = eventSequences.recordEvent(domain: domain)
        let envelope = ProtocolEvent(
            sequence: eventSequence.sequence,
            domain: domain,
            method: method,
            targetID: targetID,
            sourceTargetID: sourceTargetID,
            receivedDomainSequences: eventSequence.receivedDomainSequences,
            paramsData: paramsData,
            destroyedCurrentMainPageTarget: destroyedCurrentMainPageTarget
        )
        if let eventDomain = webInspectorEventDomain(for: domain) {
            var terminalViolation: String?
            let targetSnapshot = snapshot()
            let sinks = eventScopes.sinks(for: eventDomain).filter { sink in
                ConnectionEventProjection.shouldDeliver(
                    envelope,
                    to: sink.route,
                    in: targetSnapshot
                )
            }
            var projectedEvents: [ConnectionCapabilityKey: WebInspectorProxyEvent] = [:]
            do {
                if sinks.isEmpty {
                    let targetID = WebInspectorTarget.ID.currentPage
                    _ = try LiveProxyEventDecoder.proxyEvent(
                        from: envelope,
                        targetID: targetID,
                        lifecycleTarget: ConnectionEventProjection.lifecycleTarget(
                            for: envelope,
                            route: .currentPage,
                            targetID: targetID,
                            in: targetSnapshot
                        )
                    )
                }

                for sink in sinks {
                    let key = ConnectionCapabilityKey(
                        route: sink.route,
                        targetID: sink.targetID,
                        domain: sink.domain
                    )
                    let projectedEvent: WebInspectorProxyEvent
                    if let cachedEvent = projectedEvents[key] {
                        projectedEvent = cachedEvent
                    } else {
                        let decodedEvent = try LiveProxyEventDecoder.proxyEvent(
                            from: envelope,
                            targetID: sink.targetID,
                            lifecycleTarget: ConnectionEventProjection.lifecycleTarget(
                                for: envelope,
                                route: sink.route,
                                targetID: sink.targetID,
                                in: targetSnapshot
                            )
                        )
                        projectedEvent = ConnectionEventProjection.projectedEvent(
                            decodedEvent,
                            from: envelope,
                            route: sink.route,
                            in: targetSnapshot
                        )
                        projectedEvents[key] = projectedEvent
                    }

                    let result = sink.yieldEvent(generation(for: sink.route), projectedEvent)
                    switch result {
                    case .mismatchedEvent:
                        terminalViolation = "Decoded \(method) as an event outside \(eventDomain.rawValue)."
                    case .enqueued, .dropped, .terminated:
                        eventScopes.handleDelivery(
                            result,
                            id: sink.id,
                            capacity: eventScopes.entries[sink.id]?.capacity
                        )
                    }
                    if terminalViolation != nil {
                        break
                    }
                }
            } catch {
                terminalViolation = "Failed to decode \(method): \(error)"
            }
            if let terminalViolation {
                handoffTermination(.protocolViolation(terminalViolation))
                return
            }
        }
        for continuation in eventSubscribers.continuations(for: domain) {
            continuation.yield(envelope)
        }
        for continuation in eventSubscribers.orderedContinuations {
            continuation.yield(envelope)
        }
        await notifyMainPageTargetWaitersIfNeeded(receivedSequence: eventSequence.sequence)
    }

    private func webInspectorEventDomain(for domain: ProtocolDomain) -> WebInspectorProxyEventDomain? {
        switch domain {
        case .target:
            .target
        case .runtime:
            .runtime
        case .dom:
            .dom
        case .css:
            .css
        case .network:
            .network
        case .console:
            .console
        case .page:
            .page
        case .inspector:
            .inspector
        case .storage, .other:
            nil
        }
    }

    private func notifyMainPageTargetWaitersIfNeeded(receivedSequence: UInt64) async {
        guard let currentMainPageTargetID = targetRegistry.currentMainPageTargetID,
              !mainPageTargetWaiterStore.isEmpty else {
            return
        }
        let waiters = mainPageTargetWaiterStore.removeAll()
        let result = TransportSession.MainPageTarget(
            targetID: currentMainPageTargetID,
            receivedSequence: receivedSequence
        )
        for waiter in waiters {
            await waiter.fulfill(.success(result))
        }
    }

    private func failMainPageTargetWaiter(_ waiterID: UInt64, error: any Swift.Error) async {
        let waiter = mainPageTargetWaiterStore.remove(id: waiterID)
        await waiter?.fulfill(.failure(error))
    }

    private func removeSubscriber(_ subscriberID: UInt64, domain: ProtocolDomain) {
        eventSubscribers.remove(subscriberID, domain: domain)
    }

    private func removeOrderedSubscriber(_ subscriberID: UInt64) {
        eventSubscribers.removeOrdered(subscriberID)
    }

    private func removePendingReply(_ key: TransportSession.PendingKey) {
        replyStore.removePendingReply(key)
    }

    private func failPendingReply(_ key: TransportSession.PendingKey, error: any Swift.Error) async {
        let pending: TransportSession.PendingReply?
        switch key {
        case let .root(commandID):
            pending = replyStore.removeRootReply(commandID: commandID)
        case let .target(targetReplyKey):
            pending = replyStore.removeTargetReply(for: targetReplyKey)
                ?? replyStore.removeRetargetedReply(commandID: targetReplyKey.commandID)
        }
        await pending?.promise.fulfill(.failure(error))
    }

    private func failPendingReplyFromTimeout(_ key: TransportSession.PendingKey, error: any Swift.Error) async {
        let pending: TransportSession.PendingReply?
        switch key {
        case let .root(commandID):
            pending = replyStore.removeRootReply(commandID: commandID)
        case let .target(targetReplyKey):
            pending = replyStore.removeTargetReplyForTimeout(targetReplyKey)
        }
        await pending?.promise.fulfill(.failure(error))
    }

    private func markTargetReplyAsBufferedIfNeeded(
        _ parsed: ParsedProtocolMessage,
        targetID: ProtocolTarget.ID
    ) {
        guard let commandID = parsed.id else {
            return
        }
        replyStore.markTargetReplyAsBufferedIfNeeded(commandID: commandID, targetID: targetID)
    }

    private var terminalTransportError: TransportSession.Error {
        switch claimedTerminalCause {
        case .explicitClose:
            .transportClosed
        case let .fatal(message):
            .transportFailure(message)
        case let .protocolViolation(message):
            .transportFailure(message)
        }
    }

    private var terminalScopeError: WebInspectorProxyError {
        switch claimedTerminalCause {
        case .explicitClose:
            WebInspectorProxyError.closed
        case let .fatal(message):
            WebInspectorProxyError.transportFailure(message)
        case let .protocolViolation(message):
            WebInspectorProxyError.protocolViolation(message)
        }
    }

    private func terminate(_ proposedCause: TerminalCause) async {
        let cause = terminalClaim.claim(proposedCause).cause
        switch state {
        case .open:
            state = .closing
        case .closing:
            precondition(claimedTerminalCause == cause, "ConnectionCore terminal claims diverged.")
            try? await waitUntilClosed()
            return
        case .closed:
            precondition(claimedTerminalCause == cause, "ConnectionCore terminal claims diverged.")
            return
        }

        await finishClaimedTermination(cause)
    }

    private func handoffTermination(_ proposedCause: TerminalCause) {
        let cause = terminalClaim.claim(proposedCause).cause
        beginClaimedTerminationHandoff(cause)
    }

    private func beginClaimedTerminationHandoff(_ cause: TerminalCause) {
        precondition(terminalClaim.current == cause, "ConnectionCore terminal claims diverged.")
        switch state {
        case .open:
            break
        case .closing, .closed:
            precondition(claimedTerminalCause == cause, "ConnectionCore terminal claims diverged.")
            return
        }
        state = .closing
        let operation = prepareClaimedTermination(cause)
        precondition(terminalTask == nil, "ConnectionCore already owns a terminal task.")
        terminalTask = Task { [weak self, operation] in
            await operation.run()
            await self?.finishClaimedTerminalState(cause)
        }
    }

    private func finishClaimedTermination(_ cause: TerminalCause) async {
        let operation = prepareClaimedTermination(cause)
        await operation.run()
        finishClaimedTerminalState(cause)
    }

    private func prepareClaimedTermination(_ cause: TerminalCause) -> TerminalOperation {
        precondition(terminalClaim.current == cause, "ConnectionCore terminal claims diverged.")
        let transportError = terminalTransportError
        let scopeError: WebInspectorProxyError? = cause == .explicitClose ? nil : terminalScopeError
        if let scopeError {
            eventScopes.finishSubscribers(with: scopeError)
        }

        var activationWaiters: [ReplyPromise<Void>] = []
        var releaseWaiters: [ReplyPromise<Void>] = []
        for key in capabilities.states.keys {
            guard var capability = capabilities.states[key] else {
                continue
            }
            activationWaiters.append(contentsOf: capability.activationWaiters.values)
            releaseWaiters.append(contentsOf: capability.releaseWaiters.values)
            capability.activationWaiters.removeAll()
            capability.releaseWaiters.removeAll()
            capability.physical = .inactive(generation: capability.physical.generation)
            capabilities.states[key] = capability
        }

        let runningCapabilityTasks = capabilityTasks.values.map(\.task)
        capabilityTasks.removeAll()
        for task in runningCapabilityTasks {
            task.cancel()
        }
        let eventScopeWaiters = eventScopeRegistrationWaiters
        eventScopeRegistrationWaiters.removeAll()
        for waiter in eventScopeWaiters {
            waiter.continuation.resume()
        }
        let pendingReplies = replyStore.pendingReplies.map(\.promise)
        let mainPageTargetWaiters = mainPageTargetWaiterStore.removeAll()
        replyStore.removeAll()
        provisionalTargetMessageStore.removeAll()
        inboundMessageQueue = TransportInboundMessageQueue()
        if cause != .explicitClose {
            eventSubscribers.finishAndRemoveAll()
        }

        return TerminalOperation(
            transportError: transportError,
            scopeError: scopeError,
            pendingReplies: pendingReplies,
            mainPageTargetWaiters: mainPageTargetWaiters,
            activationWaiters: activationWaiters,
            releaseWaiters: releaseWaiters,
            capabilityTasks: runningCapabilityTasks,
            closeAction: closeAction
        )
    }

    private func finishClaimedTerminalState(_ cause: TerminalCause) {
        precondition(terminalClaim.current == cause, "ConnectionCore terminal claims diverged.")
        // A close action is allowed to suspend. The first terminal cause owns
        // the transition even if another close/fatal request arrives while it
        // is running.
        guard case .closing = state,
              claimedTerminalCause == cause else {
            preconditionFailure("ConnectionCore terminal state changed outside terminate(_:).")
        }
        state = .closed
        if cause == .explicitClose {
            eventScopes.finishSubscribers(with: nil)
            eventSubscribers.finishAndRemoveAll()
        }
        resumeCloseWaiters(with: terminalResult(for: cause))
        terminalTask = nil
    }

    private func terminalResult(for cause: TerminalCause) -> Result<Void, any Swift.Error> {
        switch cause {
        case .explicitClose:
            .success(())
        case let .fatal(message):
            .failure(WebInspectorProxyError.disconnected(message))
        case let .protocolViolation(message):
            .failure(WebInspectorProxyError.protocolViolation(message))
        }
    }

    private func registerCloseWaiter(
        id: UInt64,
        continuation: CheckedContinuation<Void, any Swift.Error>
    ) {
        if case .closed = state {
            continuation.resume(with: terminalResult(for: claimedTerminalCause))
            return
        }
        guard cancelledCloseWaiterIDs.remove(id) == nil else {
            continuation.resume(throwing: CancellationError())
            return
        }
        closeWaiters[id] = continuation
        resumeCloseWaiterRegistrationWaiters()
    }

    private func cancelCloseWaiter(_ id: UInt64) {
        guard let continuation = closeWaiters.removeValue(forKey: id) else {
            if case .closed = state {
                return
            }
            cancelledCloseWaiterIDs.insert(id)
            return
        }
        continuation.resume(throwing: CancellationError())
    }

    private func resumeCloseWaiters(with result: Result<Void, any Swift.Error>) {
        let waiters = closeWaiters.values
        closeWaiters.removeAll()
        cancelledCloseWaiterIDs.removeAll()
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    private func resumeCloseWaiterRegistrationWaiters() {
        let waiters = closeWaiterRegistrationWaiters
        closeWaiterRegistrationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// Temporary package-only spelling retained while downstream package targets
/// migrate in later phases. It is a typealias, not a second lifecycle owner.
package typealias TransportSession = ConnectionCore

private struct TargetDispatchParams: Decodable {
    var targetId: ProtocolTarget.ID
    var message: String
}

private struct TargetCreatedParams: Decodable {
    var targetInfo: TargetInfoPayload
}

private struct TargetInfoPayload: Decodable {
    var targetId: ProtocolTarget.ID
    var type: String
    var frameId: ProtocolFrame.ID?
    var parentFrameId: ProtocolFrame.ID?
    var domains: [String]?
    var isProvisional: Bool?
    var isPaused: Bool?

}

private struct TargetDestroyedParams: Decodable {
    var targetId: ProtocolTarget.ID
}

private struct TargetCommittedParams: Decodable {
    var oldTargetId: ProtocolTarget.ID
    var newTargetId: ProtocolTarget.ID
}

private struct RuntimeExecutionContextCreatedParams: Decodable {
    struct Context: Decodable {
        var id: RuntimeContext.ID
        var type: RuntimeContext.Kind?
        var name: String?
        var frameId: ProtocolFrame.ID?
    }

    var context: Context
}

private struct RuntimeExecutionContextDestroyedParams: Decodable {
    var executionContextId: RuntimeContext.ID
}

private struct CSSStyleSheetAddedParams: Decodable {
    var header: Header

    struct Header: Decodable {
        var styleSheetID: String
        var frameID: ProtocolFrame.ID?

        private enum CodingKeys: String, CodingKey {
            case styleSheetID = "styleSheetId"
            case frameID = "frameId"
        }
    }
}

private struct CSSStyleSheetIDParams: Decodable {
    var styleSheetID: String

    private enum CodingKeys: String, CodingKey {
        case styleSheetID = "styleSheetId"
    }
}
