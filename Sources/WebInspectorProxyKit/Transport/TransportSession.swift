import Foundation
import Synchronization

private struct ConnectionPendingReplyOwnership: Equatable, Sendable {
    let key: TransportSession.PendingKey
    let purpose: TransportSession.PendingReply.Purpose
}

private struct ConnectionOwnedCommandOperation: Sendable {
    let backend: any TransportBackend
    let message: String
    let promise: ReplyPromise<ProtocolCommand.Result>
    let pendingReplyOwnership: ConnectionPendingReplyOwnership
    let timeoutAction: (@Sendable () async -> Void)?

    func result() async throws -> ProtocolCommand.Result {
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
            return try await promise.value()
        } onCancel: {
            promise.fulfill(.failure(CancellationError()))
        }
    }

    func value() async throws {
        _ = try await result()
    }
}

private struct ConnectionDirectCommandAdmission: Sendable {
    let bindingGeneration: WebInspectorPage.Generation?
    let documentEpoch: ModelDocumentEpoch?
}

private enum ConnectionTargetCommandOwner: Sendable {
    case direct(ConnectionDirectCommandAdmission)
    case elementPickerMode(
        key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation,
        documentEpoch: ModelDocumentEpoch,
        enabled: Bool
    )
}

private enum ConnectionModelCommandFailureOverride: Sendable {
    case staleIdentifier
    case notActive
    case cancelled
    case terminal(TransportSession.Error)

    var error: any Swift.Error {
        switch self {
        case .staleIdentifier:
            WebInspectorProxyError.staleIdentifier
        case .notActive:
            ConnectionModelCommandError.notActive
        case .cancelled:
            CancellationError()
        case let .terminal(error):
            error
        }
    }
}

private final class ConnectionModelCommandControl: Sendable {
    private struct State: Sendable {
        var task: Task<ProtocolCommand.Result, any Swift.Error>?
        var failure: ConnectionModelCommandFailureOverride?
    }

    private let state = Mutex(State())

    func install(_ task: Task<ProtocolCommand.Result, any Swift.Error>) {
        let shouldCancel = state.withLock { state in
            precondition(state.task == nil, "A model command installed more than one runner task.")
            state.task = task
            return state.failure != nil
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func cancelByCaller() {
        let task = state.withLock { state in
            if state.failure == nil {
                state.failure = .cancelled
            }
            return state.task
        }
        task?.cancel()
    }

    func failFromOwner(_ failure: ConnectionModelCommandFailureOverride) {
        let task = state.withLock { state in
            switch state.failure {
            case nil, .some(.cancelled):
                state.failure = failure
            case .some:
                break
            }
            return state.task
        }
        task?.cancel()
    }

    var task: Task<ProtocolCommand.Result, any Swift.Error>? {
        state.withLock { $0.task }
    }

    var failure: ConnectionModelCommandFailureOverride? {
        state.withLock { $0.failure }
    }

    func resolve(
        _ fallback: Result<ProtocolCommand.Result, any Swift.Error>
    ) -> Result<ProtocolCommand.Result, any Swift.Error> {
        if let failure {
            return .failure(failure.error)
        }
        return fallback
    }
}

private struct ConnectionModelCommandOperation: Sendable {
    let task: Task<ProtocolCommand.Result, any Swift.Error>
    let control: ConnectionModelCommandControl
}

private struct ConnectionModelCommandTask: Sendable {
    let control: ConnectionModelCommandControl
    let authorization: ConnectionModelCommandAuthorization
    let domain: ProtocolDomain
    let method: String
    let routing: ProtocolCommand.Routing
    var pendingReplyOwnership: ConnectionPendingReplyOwnership?
    var readinessSignal: ReplyPromise<Void>?
}

private enum ConnectionModelCommandReadiness: Sendable {
    case ready(targetID: ProtocolTarget.ID?)
    case waiting
}

private enum ConnectionModelCommandStep: Sendable {
    case waiting(ReplyPromise<Void>)
    case ready(ConnectionOwnedCommandOperation)
}

private enum ConnectionPendingReplyFailureReason: Sendable {
    case staleIdentifier
    case missingTarget(ProtocolTarget.ID)
    case modelFeedNotActive

    var error: any Swift.Error {
        switch self {
        case .staleIdentifier:
            WebInspectorProxyError.staleIdentifier
        case let .missingTarget(targetID):
            TransportSession.Error.missingTarget(targetID)
        case .modelFeedNotActive:
            ConnectionModelCommandError.notActive
        }
    }
}

private struct ConnectionPendingReplyFailure: Sendable {
    let pending: TransportSession.PendingReply
    let reason: ConnectionPendingReplyFailureReason
}

private struct ConnectionCommandInvalidationEffects: Sendable {
    var pendingFailures: [ConnectionPendingReplyFailure] = []
    var modelCommandTasksToAwait: [Task<ProtocolCommand.Result, any Swift.Error>] = []
}

private struct ConnectionCapabilityTask: Sendable {
    enum StartingWireState: Equatable, Sendable {
        case inactive
        case unknown
        case enabled
    }

    enum Policy: Equatable, Sendable {
        case standard
        case restoredPageEnable
        case cssSnapshot
        case cssEnableAndSnapshot
        case replayRefresh
    }

    let task: Task<Void, Never>
    var pendingReplyOwnership: ConnectionPendingReplyOwnership?
    var startingWireState: StartingWireState?
    var policy: Policy
}

private enum RememberedCurrentPageCapabilityState: Equatable, Sendable {
    case inactive
    case enabled
    case unknown
}

private struct ConnectionModelBootstrapTask: Sendable {
    let task: Task<Void, Never>
    let pendingReplyOwnership: ConnectionPendingReplyOwnership
    let feedID: ConnectionModelFeedID
    let generation: WebInspectorPage.Generation
}

private struct PhysicalTargetDisappearanceWaiters: Sendable {
    var activation: [ReplyPromise<Void>] = []
    var release: [ReplyPromise<Void>] = []
}

private struct ConnectionModelFeedCapabilityLease: Sendable {
    let owner: ConnectionCapabilityLeaseOwner
    let key: ConnectionCapabilityKey
}

private struct ConnectionModelFeedSynchronizationState: Sendable {
    let generation: WebInspectorPage.Generation
    var completedDomains: Set<ModelDomain> = []
    var didPublish = false
}

private struct ConnectionDOMBootstrapState: Sendable {
    enum ReplyDisposition: Equatable, Sendable {
        case published
        case stale
        case terminal
    }

    struct TargetState: Sendable {
        let target: ModelTarget
        var completedEpoch: ModelDocumentEpoch?
    }

    struct ActiveOperation: Sendable {
        let id: UInt64
        let targetID: ProtocolTarget.ID
        let documentEpoch: ModelDocumentEpoch
        var replyDisposition: ReplyDisposition?
    }

    let generation: WebInspectorPage.Generation
    var orderedTargetIDs: [ProtocolTarget.ID]
    var targetsByID: [ProtocolTarget.ID: TargetState]
    var activeOperation: ActiveOperation?
    var needsCompletionMarker: Bool
}

private enum ConnectionModelFeedLifecycle: Sendable {
    case acquiring
    case active
    case rollingBack
    case closing(ReplyPromise<Void>)
}

private struct ConnectionModelFeedRegistration: Sendable {
    let id: ConnectionModelFeedID
    let configuredDomains: Set<ModelDomain>
    let mailbox: ConnectionModelFeedMailbox
    var lifecycle: ConnectionModelFeedLifecycle
    var capabilityLeases: [ConnectionModelFeedCapabilityLease]
    var elementPickerLease: ConnectionModelFeedCapabilityLease?
    var targetSnapshotThrough: UInt64?
    var resetGeneration: WebInspectorPage.Generation
    var synchronization: ConnectionModelFeedSynchronizationState?
    var domBootstrap: ConnectionDOMBootstrapState?
}

private struct CurrentPageBindingChangeEffects: Sendable {
    var capabilityKeysToReconcile: [ConnectionCapabilityKey] = []
    var releaseWaiters: [ReplyPromise<Void>] = []
    var modelBootstrapTasksToAwait: [Task<Void, Never>] = []
    var commandInvalidation = ConnectionCommandInvalidationEffects()
}

private struct RootEventMutation: Sendable {
    var pendingStyleSheetEvents: [ResolvedStyleSheetAddedEvent] = []
    var bindingEffects = CurrentPageBindingChangeEffects()
    var physicalTargetWaiters = PhysicalTargetDisappearanceWaiters()
    var commandInvalidation = ConnectionCommandInvalidationEffects()
}

private struct MainPageTargetNotification: Sendable {
    let waiters: [ReplyPromise<TransportSession.MainPageTarget>]
    let result: TransportSession.MainPageTarget
}

private struct EventEmissionEffects: Sendable {
    var mainPageTargetNotification: MainPageTargetNotification?
    var commandInvalidation = ConnectionCommandInvalidationEffects()
}

private struct ConnectionElementPickerMode: Sendable {
    enum Physical: Sendable {
        case inactive(WebInspectorPage.Generation)
        case enabling(WebInspectorPage.Generation)
        case enabled(WebInspectorPage.Generation)
        case disabling(WebInspectorPage.Generation)

        var generation: WebInspectorPage.Generation {
            switch self {
            case let .inactive(generation),
                 let .enabling(generation),
                 let .enabled(generation),
                 let .disabling(generation):
                generation
            }
        }
    }

    var owners: Set<ConnectionCapabilityLeaseOwner>
    var activatedThrough: [ConnectionCapabilityLeaseOwner: UInt64]
    var activationWaiters: [
        ConnectionCapabilityLeaseOwner: ReplyPromise<Void>
    ]
    var releaseWaiters: [
        ConnectionCapabilityLeaseOwner: ReplyPromise<Void>
    ]
    var physical: Physical

    init(generation: WebInspectorPage.Generation) {
        owners = []
        activatedThrough = [:]
        activationWaiters = [:]
        releaseWaiters = [:]
        physical = .inactive(generation)
    }
}

/// Owns one physical inspector connection.
///
/// Target membership, command/reply routing, inbound ordering, and terminal
/// state deliberately live on the same actor so no public handle has to mirror
/// transport state in order to stay current.
package actor ConnectionCore {
    /// WebKit's current process-pool back/forward cache holds at most two
    /// suspended pages. `Target.targetDestroyed` does not identify which
    /// membership removals remain physically suspended, so retain a generous
    /// bounded window instead of treating that event as physical teardown.
    private static let parkedCurrentPageTargetRetentionLimit = 64

    package typealias TimeoutSleep = @Sendable (Duration) async throws -> Void
    package typealias ResponseTimeoutDidFire = @Sendable () async -> Void
    package typealias CloseAction = @Sendable () async -> Void
    package typealias MessageParser = @Sendable (String) async throws -> ParsedProtocolMessage

    package enum TerminalCause: Equatable, Sendable {
        case explicitClose
        case fatal(String)
        case protocolViolation(String)
        case modelFeedFailure(ConnectionModelFeedError)
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
        let pendingReplies: [TransportSession.PendingReply]
        let mainPageTargetWaiters: [ReplyPromise<TransportSession.MainPageTarget>]
        let activationWaiters: [ReplyPromise<Void>]
        let releaseWaiters: [ReplyPromise<Void>]
        let capabilityTasks: [Task<Void, Never>]
        let modelBootstrapTasks: [Task<Void, Never>]
        let modelCommandTasks: [Task<ProtocolCommand.Result, any Swift.Error>]
        let closeAction: CloseAction

        func run() async {
            for pending in pendingReplies {
                pending.promise.fulfill(.failure(transportError))
            }
            for waiter in mainPageTargetWaiters {
                waiter.fulfill(.failure(transportError))
            }
            for waiter in activationWaiters {
                waiter.fulfill(.failure(scopeError ?? WebInspectorProxyError.closed))
            }
            for waiter in releaseWaiters {
                if let scopeError {
                    waiter.fulfill(.failure(scopeError))
                } else {
                    waiter.fulfill(.success(()))
                }
            }
            for task in capabilityTasks {
                await task.value
            }
            for task in modelBootstrapTasks {
                await task.value
            }
            for task in modelCommandTasks {
                _ = await task.result
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
    private var eventScopes: ConnectionEventScopeRegistry
    private var modelFeed: ConnectionModelFeedRegistration?
    private var replayWasTaintedByDirectConsumer: Bool
    private var capabilities: ConnectionCapabilityRegistry
    private var elementPickerModes: [
        ConnectionCapabilityKey: ConnectionElementPickerMode
    ]
    private var inspectorInitializedGeneration: [
        ConnectionCapabilityKey: WebInspectorPage.Generation
    ]
    /// Wire state parked for page targets that remain connected but are no
    /// longer members of the active Target graph (for example, BFCache).
    /// The active target's state lives only in `capabilities`; transitions
    /// move ownership between that registry and this ledger. WebKit exposes
    /// `Target.targetDestroyed` for membership removal without disconnecting
    /// the inspector channel, so parked state lives until restoration or
    /// connection teardown rather than following that event.
    private var parkedCurrentPageCapabilityLedger: [
        ProtocolTarget.ID: [
            WebInspectorProxyEventDomain: RememberedCurrentPageCapabilityState
        ]
    ]
    private var parkedCurrentPageCapabilityLedgerOrder: [ProtocolTarget.ID]
    private var modelReplaySuppressedDomains: [
        ModelDomain: WebInspectorPage.Generation
    ]
    private var capabilityTasks: [UInt64: ConnectionCapabilityTask]
    private var nextModelBootstrapOperationID: UInt64
    private var modelBootstrapTasks: [UInt64: ConnectionModelBootstrapTask]
    private var nextModelCommandOperationID: UInt64
    private var modelCommandTasks: [UInt64: ConnectionModelCommandTask]
    private var modelCommandOwnerCountWaiters: [(
        expectedCount: Int,
        continuation: CheckedContinuation<Void, Never>
    )]
    private var modelCommandReadinessCountWaiters: [(
        expectedCount: Int,
        continuation: CheckedContinuation<Void, Never>
    )]
    private var modelDocumentEpochs: [ProtocolTarget.ID: ModelDocumentEpoch]
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
    private var modelTargetMutationActionForTesting: (@Sendable () -> Void)?

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
        eventScopes = ConnectionEventScopeRegistry()
        modelFeed = nil
        replayWasTaintedByDirectConsumer = false
        capabilities = ConnectionCapabilityRegistry()
        elementPickerModes = [:]
        inspectorInitializedGeneration = [:]
        parkedCurrentPageCapabilityLedger = [:]
        parkedCurrentPageCapabilityLedgerOrder = []
        modelReplaySuppressedDomains = [:]
        capabilityTasks = [:]
        nextModelBootstrapOperationID = 0
        modelBootstrapTasks = [:]
        nextModelCommandOperationID = 0
        modelCommandTasks = [:]
        modelCommandOwnerCountWaiters = []
        modelCommandReadinessCountWaiters = []
        modelDocumentEpochs = [:]
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
        modelTargetMutationActionForTesting = nil
    }

    isolated deinit {
        // Asynchronous detach belongs to explicit close. The isolated
        // deinitializer is only a synchronous backstop for actor-owned local
        // resources; native resources have their own isolated backstop.
        eventScopes.finishAndRemoveAll(with: WebInspectorProxyError.closed)
        modelFeed?.mailbox.finish(throwing: WebInspectorProxyError.closed)
        modelFeed = nil
        let modelTasks = Array(modelCommandTasks.values)
        modelCommandTasks.removeAll()
        for modelTask in modelTasks {
            modelTask.control.failFromOwner(.terminal(.transportClosed))
            if let ownership = modelTask.pendingReplyOwnership {
                _ = replyStore.removePendingReply(ownership.key)
            }
        }
        terminalTask?.cancel()
        terminalTask = nil
        let tasks = Array(capabilityTasks.values)
        capabilityTasks.removeAll()
        for task in tasks {
            task.task.cancel()
            if let ownership = task.pendingReplyOwnership,
               let pending = replyStore.removePendingReply(ownership.key) {
                precondition(
                    pending.purpose == ownership.purpose,
                    "A capability task attempted to remove a reply owned by another purpose."
                )
            }
        }
        let bootstrapTasks = Array(modelBootstrapTasks.values)
        modelBootstrapTasks.removeAll()
        for task in bootstrapTasks {
            task.task.cancel()
            if let pending = replyStore.removePendingReply(task.pendingReplyOwnership.key) {
                precondition(
                    pending.purpose == task.pendingReplyOwnership.purpose,
                    "A model bootstrap task attempted to remove a reply owned by another purpose."
                )
            }
        }
        precondition(replyStore.pendingReplies.isEmpty, "ConnectionCore deinitialized with pending replies; call close() explicitly.")
        precondition(mainPageTargetWaiterStore.isEmpty, "ConnectionCore deinitialized with pending target waiters; call close() explicitly.")
        precondition(closeWaiters.isEmpty, "ConnectionCore deinitialized with pending close waiters.")
        precondition(capabilities.states.values.allSatisfy { $0.activationWaiters.isEmpty && $0.releaseWaiters.isEmpty }, "ConnectionCore deinitialized with pending capability waiters.")
        precondition(eventScopeRegistrationWaiters.isEmpty, "ConnectionCore deinitialized with event-scope test waiters.")
        for waiter in modelCommandOwnerCountWaiters {
            waiter.continuation.resume()
        }
        modelCommandOwnerCountWaiters.removeAll()
        for waiter in modelCommandReadinessCountWaiters {
            waiter.continuation.resume()
        }
        modelCommandReadinessCountWaiters.removeAll()
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

    package func openModelFeed(
        configuredDomains: Set<ModelDomain>,
        onRegistered: (@Sendable (ConnectionModelFeed) async -> Bool)? = nil
    ) async throws -> ConnectionModelFeed {
        guard isOpen else {
            throw terminalScopeError
        }
        guard modelFeed == nil else {
            throw ConnectionModelFeedError.alreadyOpen
        }
        guard !replayWasTaintedByDirectConsumer else {
            throw ConnectionModelFeedError.connectionAlreadyUsedByDirectConsumer
        }

        let configuredDomains = ModelDomain.normalized(configuredDomains)
        let id = ConnectionModelFeedID()
        let mailbox = ConnectionModelFeedMailbox()
        let feed = ConnectionModelFeed(id: id, owner: self, mailbox: mailbox)
        let resetGeneration: WebInspectorPage.Generation
        if targetRegistry.currentMainPageTargetID != nil || currentPageBindingGapIsOpen {
            resetGeneration = currentPageGeneration
        } else {
            resetGeneration = WebInspectorPage.Generation(
                rawValue: currentPageGeneration.rawValue &+ 1
            )
        }
        modelFeed = ConnectionModelFeedRegistration(
            id: id,
            configuredDomains: configuredDomains,
            mailbox: mailbox,
            lifecycle: .acquiring,
            capabilityLeases: [],
            elementPickerLease: nil,
            targetSnapshotThrough: nil,
            resetGeneration: resetGeneration,
            synchronization: nil,
            domBootstrap: nil
        )

        guard enqueueModelFeedRecord(.reset(resetGeneration)) else {
            throw ConnectionModelFeedError.consumerTerminated
        }
        if targetRegistry.currentMainPageTargetID != nil,
           !publishModelTargetSnapshot() {
            throw ConnectionModelFeedError.consumerTerminated
        }

        do {
            if let onRegistered,
               !(await onRegistered(feed)) {
                throw ConnectionModelFeedError.consumerTerminated
            }
            for domain in ModelDomain.ordered(configuredDomains) {
                do {
                    let leaseOwner = ConnectionCapabilityLeaseOwner.modelFeed(id, domain)
                    let capabilityDomains = ConnectionCapabilityActivationPlan.domains(
                        for: domain.capabilityDependencies,
                        includePageDependencyForCSS: true
                    )
                    for capabilityDomain in capabilityDomains {
                        try Task.checkCancellation()
                        guard isOpen else {
                            throw terminalScopeError
                        }
                        let key = ConnectionCapabilityKey(
                            route: .currentPage,
                            targetID: .currentPage,
                            domain: capabilityDomain
                        )
                        let lease = ConnectionModelFeedCapabilityLease(
                            owner: leaseOwner,
                            key: key
                        )
                        let activation = beginCapabilityLease(
                            leaseOwner,
                            for: key,
                            generation: currentPageGeneration
                        )
                        appendModelFeedCapabilityLease(lease, feedID: id)
                        try await activateCapabilityLease(
                            leaseOwner,
                            for: key,
                            activation: activation
                        )
                    }
                } catch {
                    throw Self.modelFeedActivationError(error, domain: domain)
                }
            }
            try Task.checkCancellation()
            guard isOpen else {
                throw terminalScopeError
            }
            guard let registration = modelFeed,
                  registration.id == id else {
                preconditionFailure("A model feed lost its exclusive registration during acquisition.")
            }
            guard case .acquiring = registration.lifecycle else {
                preconditionFailure("A model feed changed lifecycle before acquisition completed.")
            }
            guard publishModelSynchronizationIfReady(
                allowWhileAcquiring: true
            ) else {
                throw ConnectionModelFeedError.consumerTerminated
            }
            guard var synchronizedRegistration = modelFeed,
                  synchronizedRegistration.id == id,
                  case .acquiring = synchronizedRegistration.lifecycle else {
                preconditionFailure("A model feed changed lifecycle while publishing readiness.")
            }
            synchronizedRegistration.lifecycle = .active
            modelFeed = synchronizedRegistration
            reevaluateModelCommandReadinessWaiters()
            return feed
        } catch {
            let cleanupError = await rollbackModelFeedAcquisition(id)
            let resultError: any Swift.Error
            if let cleanupError {
                resultError = WebInspectorScopeError(
                    operationError: error,
                    cleanupError: cleanupError
                )
            } else {
                resultError = error
            }
            mailbox.poison(throwing: resultError)
            throw resultError
        }
    }

    package func closeModelFeed(_ id: ConnectionModelFeedID) async throws {
        guard var registration = modelFeed,
              registration.id == id else {
            return
        }
        switch registration.lifecycle {
        case .acquiring:
            preconditionFailure("A model feed cannot close before openModelFeed returns.")
        case .rollingBack:
            preconditionFailure("A model feed cannot close while its failed open is rolling back.")
        case .closing(let completion):
            return try await completion.valueIgnoringCancellation()
        case .active:
            break
        }

        let completion = ReplyPromise<Void>()
        let elementPickerLease = registration.elementPickerLease
        registration.elementPickerLease = nil
        registration.lifecycle = .closing(completion)
        modelFeed = registration
        let commandInvalidation = invalidateModelCommands(
            where: { $0.authorization.feedID == id },
            failureOverride: .notActive,
            pendingFailureReason: .modelFeedNotActive
        )
        await completeCommandInvalidationEffects(commandInvalidation)
        await cancelAndAwaitModelBootstrapTasks(feedID: id)

        var cleanupError: (any Swift.Error)?
        if let elementPickerLease {
            if let error = await releaseElementPickerResources(
                elementPickerLease.owner,
                for: elementPickerLease.key
            ) {
                cleanupError = error
                registration.mailbox.poison(throwing: error)
            }
        }
        for lease in registration.capabilityLeases.reversed() {
            do {
                try await releaseCapabilityLease(lease.owner, for: lease.key)
            } catch {
                if cleanupError == nil {
                    cleanupError = error
                    registration.mailbox.poison(throwing: error)
                }
            }
        }

        if let cleanupError {
            await terminateForModelFeedCapabilityCleanupFailure(cleanupError)
            completion.fulfill(.failure(cleanupError))
            throw cleanupError
        }

        guard isOpen else {
            do {
                try await waitUntilClosed()
                completion.fulfill(.success(()))
                return
            } catch {
                completion.fulfill(.failure(error))
                throw error
            }
        }
        guard let currentRegistration = modelFeed,
              currentRegistration.id == id else {
            preconditionFailure("A closing model feed lost its exclusive registration.")
        }
        modelFeed = nil
        currentRegistration.mailbox.finish()
        completion.fulfill(.success(()))
    }

    private func appendModelFeedCapabilityLease(
        _ lease: ConnectionModelFeedCapabilityLease,
        feedID: ConnectionModelFeedID
    ) {
        guard var registration = modelFeed,
              registration.id == feedID else {
            preconditionFailure("A model feed lost its registration while acquiring a capability.")
        }
        guard case .acquiring = registration.lifecycle else {
            preconditionFailure("Only an acquiring model feed can add capability leases.")
        }
        precondition(
            !registration.capabilityLeases.contains {
                $0.owner == lease.owner && $0.key == lease.key
            },
            "A model feed attempted to acquire the same capability lease twice."
        )
        registration.capabilityLeases.append(lease)
        modelFeed = registration
    }

    package func acquireModelFeedElementPicker(
        _ feedID: ConnectionModelFeedID
    ) async throws {
        guard var registration = modelFeed,
              registration.id == feedID,
              case .active = registration.lifecycle else {
            throw ConnectionModelCommandError.notActive
        }
        guard registration.configuredDomains.contains(.dom) else {
            throw ConnectionModelCommandError.domainNotConfigured(.dom)
        }
        guard registration.elementPickerLease == nil else {
            return
        }

        let leaseOwner = ConnectionCapabilityLeaseOwner.modelElementPicker(feedID)
        let key = ConnectionCapabilityKey(
            route: .currentPage,
            targetID: .currentPage,
            domain: .inspector
        )
        let lease = ConnectionModelFeedCapabilityLease(
            owner: leaseOwner,
            key: key
        )
        let activation = beginCapabilityLease(
            leaseOwner,
            for: key,
            generation: currentPageGeneration
        )
        registration.elementPickerLease = lease
        modelFeed = registration

        do {
            try await activateCapabilityLease(
                leaseOwner,
                for: key,
                activation: activation
            )
            try await acquireElementPickerMode(leaseOwner, for: key)
        } catch {
            let operationError = error
            if var current = modelFeed,
               current.id == feedID,
               current.elementPickerLease?.owner == leaseOwner {
                current.elementPickerLease = nil
                modelFeed = current
            }
            if let cleanupError = await releaseElementPickerResources(
                leaseOwner,
                for: key
            ) {
                throw WebInspectorScopeError(
                    operationError: operationError,
                    cleanupError: cleanupError
                )
            }
            throw operationError
        }

        guard let current = modelFeed,
              current.id == feedID,
              case .active = current.lifecycle,
              current.elementPickerLease?.owner == leaseOwner else {
            if let cleanupError = await releaseElementPickerResources(
                leaseOwner,
                for: key
            ) {
                throw cleanupError
            }
            throw ConnectionModelCommandError.notActive
        }
    }

    package func releaseModelFeedElementPicker(
        _ feedID: ConnectionModelFeedID
    ) async throws {
        guard var registration = modelFeed,
              registration.id == feedID,
              let lease = registration.elementPickerLease else {
            return
        }
        registration.elementPickerLease = nil
        modelFeed = registration
        if let error = await releaseElementPickerResources(
            lease.owner,
            for: lease.key
        ) {
            registration.mailbox.poison(throwing: error)
            await terminateForModelFeedCapabilityCleanupFailure(error)
            throw error
        }
    }

    private func releaseElementPickerResources(
        _ owner: ConnectionCapabilityLeaseOwner,
        for key: ConnectionCapabilityKey
    ) async -> (any Swift.Error)? {
        let modeResult: Result<Void, any Swift.Error>
        do {
            try await releaseElementPickerMode(owner, for: key)
            modeResult = .success(())
        } catch {
            modeResult = .failure(error)
        }
        let capabilityResult: Result<Void, any Swift.Error>
        do {
            try await releaseCapabilityLease(owner, for: key)
            capabilityResult = .success(())
        } catch {
            capabilityResult = .failure(error)
        }
        if case .failure = modeResult,
           case .success = capabilityResult {
            markElementPickerModeInactive(for: key)
        }
        switch (modeResult, capabilityResult) {
        case (.success, .success):
            return nil
        case let (.failure(modeError), .success):
            return modeError
        case let (.success, .failure(capabilityError)):
            return capabilityError
        case let (.failure(modeError), .failure(capabilityError)):
            return WebInspectorScopeError(
                operationError: modeError,
                cleanupError: capabilityError
            )
        }
    }

    private func rollbackModelFeedAcquisition(
        _ id: ConnectionModelFeedID
    ) async -> (any Swift.Error)? {
        guard var registration = modelFeed,
              registration.id == id else {
            return await modelFeedTerminalErrorIfNeeded()
        }
        guard case .acquiring = registration.lifecycle else {
            preconditionFailure("Only an acquiring model feed can roll back its capabilities.")
        }
        registration.lifecycle = .rollingBack
        modelFeed = registration
        let commandInvalidation = invalidateModelCommands(
            where: { $0.authorization.feedID == id },
            failureOverride: .notActive,
            pendingFailureReason: .modelFeedNotActive
        )
        await completeCommandInvalidationEffects(commandInvalidation)
        await cancelAndAwaitModelBootstrapTasks(feedID: id)
        var cleanupError: (any Swift.Error)?
        for lease in registration.capabilityLeases.reversed() {
            do {
                try await releaseCapabilityLease(lease.owner, for: lease.key)
            } catch {
                if cleanupError == nil {
                    cleanupError = error
                    registration.mailbox.poison(throwing: error)
                }
            }
        }
        if let cleanupError {
            await terminateForModelFeedCapabilityCleanupFailure(cleanupError)
            return cleanupError
        }
        if let terminalError = await modelFeedTerminalErrorIfNeeded() {
            return terminalError
        }
        guard let currentRegistration = modelFeed,
              currentRegistration.id == id else {
            guard !isOpen else {
                preconditionFailure(
                    "A model feed lost its registration before rollback completed."
                )
            }
            // Explicit connection close owns terminal feed retirement and has
            // already finished the mailbox. A fatal terminal cause returned
            // its error above; normal close therefore completes rollback.
            return nil
        }
        modelFeed = nil
        return nil
    }

    private func modelFeedTerminalErrorIfNeeded() async -> (any Swift.Error)? {
        guard !isOpen else {
            return nil
        }
        do {
            try await waitUntilClosed()
            return nil
        } catch {
            return error
        }
    }

    private func terminateForModelFeedCapabilityCleanupFailure(
        _ error: any Swift.Error
    ) async {
        if isOpen {
            await terminate(.fatal(
                "Failed to release model feed capabilities: \(error)"
            ))
        } else {
            _ = await modelFeedTerminalErrorIfNeeded()
        }
    }

    private func cancelAndAwaitModelBootstrapTasks(
        feedID: ConnectionModelFeedID
    ) async {
        if var registration = modelFeed,
           registration.id == feedID {
            registration.domBootstrap = nil
            modelFeed = registration
        }
        let tasks = modelBootstrapTasks.values.filter { $0.feedID == feedID }
        for task in tasks {
            task.task.cancel()
        }
        for task in tasks {
            await task.task.value
        }
        precondition(
            modelBootstrapTasks.values.allSatisfy { $0.feedID != feedID },
            "A model feed stopped before its DOM bootstrap tasks completed."
        )
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
        try claimDirectConsumer()

        let capacity = buffering.capacity
        let mailbox = WebInspectorEventMailbox<Element>(capacity: capacity)
        let stream = mailbox.makeStream()

        let scopeID = WebInspectorProxyEventScopeID()
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
            capacity: capacity,
            generation: generation
        )
        resumeEventScopeRegistrationWaitersIfNeeded()

        let leaseOwner = ConnectionCapabilityLeaseOwner.eventScope(scopeID)

        do {
            let capabilityDomains = ConnectionCapabilityActivationPlan.domains(
                for: [domain],
                includePageDependencyForCSS: cssRequiresPageCapability(for: route)
            )
            for capabilityDomain in capabilityDomains {
                let key = ConnectionCapabilityKey(
                    route: route,
                    targetID: targetID,
                    domain: capabilityDomain
                )
                let activation = beginCapabilityLease(
                    leaseOwner,
                    for: key,
                    generation: generation
                )
                eventScopes.appendCapability(key, to: scopeID)
                try await activateCapabilityLease(
                    leaseOwner,
                    for: key,
                    activation: activation
                )
            }
            if domain == .inspector {
                let key = ConnectionCapabilityKey(
                    route: route,
                    targetID: targetID,
                    domain: domain
                )
                try await acquireElementPickerMode(leaseOwner, for: key)
            }
        } catch {
            let operationError = error
            do {
                try await releaseEventScope(scopeID)
            } catch {
                throw WebInspectorScopeError(
                    operationError: operationError,
                    cleanupError: error
                )
            }
            throw operationError
        }

        return WebInspectorProxyEventScope(id: scopeID, events: stream)
    }

    package func releaseEventScope(_ id: WebInspectorProxyEventScopeID) async throws {
        guard let entry = eventScopes.remove(id) else {
            return
        }
        resumeEventScopeRegistrationWaitersIfNeeded()
        entry.sink?.finish(nil)

        let owner = ConnectionCapabilityLeaseOwner.eventScope(id)
        if let inspectorKey = entry.capabilities.last,
           inspectorKey.domain == .inspector {
            if let error = await releaseElementPickerResources(owner, for: inspectorKey) {
                throw error
            }
            return
        }
        var cleanupError: (any Swift.Error)?
        for key in entry.capabilities.reversed() {
            do {
                try await releaseCapabilityLease(owner, for: key)
            } catch {
                if cleanupError == nil {
                    cleanupError = error
                }
            }
        }
        if let cleanupError {
            throw cleanupError
        }
    }

    private func cssRequiresPageCapability(
        for route: RoutingTargetID
    ) -> Bool {
        switch route.storage {
        case .currentPage:
            return true
        case let .target(rawValue):
            return targetRegistry.target(
                for: ProtocolTarget.ID(rawValue)
            )?.kind == .page
        }
    }

    package nonisolated func send(_ command: ProtocolCommand) async throws -> ProtocolCommand.Result {
        try Task.checkCancellation()

        switch command.authority {
        case .direct:
            return try await sendDirect(command)
        case let .modelFeed(authorization):
            let operation = try await beginModelCommand(command, authorization: authorization)
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await operation.task.value
            } onCancel: {
                operation.control.cancelByCaller()
            }
        }
    }

    private func sendDirect(_ command: ProtocolCommand) async throws -> ProtocolCommand.Result {
        guard isOpen else {
            throw terminalTransportError
        }
        // Admission owns both transport-local and wire-backed commands. A
        // model feed must never be bypassed by DOM.enable's local result.
        switch command.routing {
        case .root:
            try claimDirectConsumer()
            return try await sendRoot(
                command,
                admission: ConnectionDirectCommandAdmission(
                    bindingGeneration: nil,
                    documentEpoch: nil
                )
            )
        case let .target(targetID):
            return try await sendDirectTarget(command, targetID: targetID)
        case let .octopus(pageTarget):
            let resolvedTarget = try pageTarget ?? currentMainPageTarget()
            return try await sendDirectTarget(command, targetID: resolvedTarget)
        }
    }

    private func sendDirectTarget(
        _ command: ProtocolCommand,
        targetID: ProtocolTarget.ID
    ) async throws -> ProtocolCommand.Result {
        guard let target = targetRegistry.target(for: targetID) else {
            throw TransportSession.Error.missingTarget(targetID)
        }
        try claimDirectConsumer()
        let isCurrentPageTarget = targetRegistry.isCurrentPageModelTarget(target)
        let admission = ConnectionDirectCommandAdmission(
            bindingGeneration: isCurrentPageTarget ? currentPageGeneration : nil,
            documentEpoch: isCurrentPageTarget && isDocumentSensitive(
                command.domain,
                method: command.method
            )
                ? modelDocumentEpoch(for: targetID)
                : nil
        )
        if let result = transportLocalResult(for: command, targetID: targetID) {
            return result
        }
        return try await sendTarget(
            command,
            targetID: targetID,
            owner: .direct(admission)
        )
    }

    private func beginModelCommand(
        _ command: ProtocolCommand,
        authorization: ConnectionModelCommandAuthorization
    ) throws -> ConnectionModelCommandOperation {
        try Task.checkCancellation()
        try validateModelCommandAuthority(
            authorization,
            domain: command.domain,
            method: command.method
        )
        precondition(
            nextModelCommandOperationID < UInt64.max,
            "A model command operation identifier exhausted UInt64."
        )
        nextModelCommandOperationID += 1
        let operationID = nextModelCommandOperationID
        let control = ConnectionModelCommandControl()
        let task = Task { [weak self, command, authorization, control] () throws -> ProtocolCommand.Result in
            do {
                while true {
                    try Task.checkCancellation()
                    guard let step = try await self?.prepareModelCommandStep(
                        command,
                        authorization: authorization,
                        operationID: operationID
                    ) else {
                        throw WebInspectorProxyError.closed
                    }
                    switch step {
                    case let .waiting(signal):
                        try await signal.value()
                    case let .ready(operation):
                        let value = try await operation.result()
                        let fallback = control.resolve(.success(value))
                        let resolved = await self?.finishModelCommand(
                            operationID,
                            fallback: fallback
                        ) ?? fallback
                        return try resolved.get()
                    }
                }
            } catch {
                let fallback = control.resolve(.failure(error))
                let resolved = await self?.finishModelCommand(
                    operationID,
                    fallback: fallback
                ) ?? fallback
                return try resolved.get()
            }
        }
        precondition(
            modelCommandTasks[operationID] == nil,
            "A model command operation identifier already has an owner."
        )
        modelCommandTasks[operationID] = ConnectionModelCommandTask(
            control: control,
            authorization: authorization,
            domain: command.domain,
            method: command.method,
            routing: command.routing,
            pendingReplyOwnership: nil,
            readinessSignal: nil
        )
        control.install(task)
        resumeModelCommandOwnerCountWaitersIfNeeded()
        return ConnectionModelCommandOperation(task: task, control: control)
    }

    private func prepareModelCommandStep(
        _ command: ProtocolCommand,
        authorization: ConnectionModelCommandAuthorization,
        operationID: UInt64
    ) throws -> ConnectionModelCommandStep {
        guard var task = modelCommandTasks[operationID] else {
            throw ConnectionModelCommandError.notActive
        }
        if let failure = task.control.failure {
            throw failure.error
        }
        switch try modelCommandReadiness(
            authorization: authorization,
            domain: command.domain,
            method: command.method,
            routing: command.routing
        ) {
        case let .ready(targetID):
            task.readinessSignal = nil
            modelCommandTasks[operationID] = task
            // There is intentionally no suspension between this final
            // readiness check and pending-reply insertion.
            return .ready(try makeModelCommandOperation(
                command,
                targetID: targetID,
                authorization: authorization,
                operationID: operationID
            ))
        case .waiting:
            if let signal = task.readinessSignal {
                return .waiting(signal)
            }
            let signal = ReplyPromise<Void>()
            task.readinessSignal = signal
            modelCommandTasks[operationID] = task
            resumeModelCommandOwnerCountWaitersIfNeeded()
            return .waiting(signal)
        }
    }

    private func validateModelCommandAuthority(
        _ authorization: ConnectionModelCommandAuthorization,
        domain: ProtocolDomain,
        method: String
    ) throws {
        guard isOpen else {
            throw terminalTransportError
        }
        guard let registration = modelFeed,
              registration.id == authorization.feedID else {
            throw ConnectionModelCommandError.notActive
        }
        guard case .active = registration.lifecycle else {
            throw ConnectionModelCommandError.notActive
        }
        guard authorization.generation == registration.resetGeneration else {
            throw WebInspectorProxyError.staleIdentifier
        }
        guard let proxyDomain = proxyDomain(for: domain) else {
            throw ConnectionModelCommandError.notActive
        }
        if isConnectionOwnedCommand(method) {
            throw ConnectionModelCommandError.internalCommand(
                domain: proxyDomain,
                method: method
            )
        }
        if let requiredDomain = requiredModelDomain(for: domain),
           !registration.configuredDomains.contains(requiredDomain) {
            throw ConnectionModelCommandError.domainNotConfigured(proxyDomain)
        }
        if isDocumentSensitive(domain, method: method), authorization.document == nil {
            throw ConnectionModelCommandError.documentAuthorizationRequired(proxyDomain)
        }
    }

    private func modelCommandReadiness(
        authorization: ConnectionModelCommandAuthorization,
        domain: ProtocolDomain,
        method: String,
        routing: ProtocolCommand.Routing
    ) throws -> ConnectionModelCommandReadiness {
        try validateModelCommandAuthority(
            authorization,
            domain: domain,
            method: method
        )
        if currentPageGeneration.rawValue > authorization.generation.rawValue {
            throw WebInspectorProxyError.staleIdentifier
        }
        guard currentPageGeneration == authorization.generation else {
            return .waiting
        }

        let targetID: ProtocolTarget.ID?
        switch routing {
        case .root:
            targetID = nil
        case let .target(candidate):
            guard let record = targetRegistry.target(for: candidate),
                  targetRegistry.isCurrentPageModelTarget(record) else {
                throw WebInspectorProxyError.staleIdentifier
            }
            targetID = candidate
        case let .octopus(explicitTarget):
            guard let candidate = explicitTarget ?? targetRegistry.currentMainPageTargetID else {
                return .waiting
            }
            guard let record = targetRegistry.target(for: candidate),
                  targetRegistry.isCurrentPageModelTarget(record) else {
                throw WebInspectorProxyError.staleIdentifier
            }
            targetID = candidate
        }

        if isDocumentSensitive(domain, method: method) {
            guard let targetID,
                  let document = authorization.document,
                  ProtocolTarget.ID(document.targetID.rawValue) == targetID,
                  modelDocumentEpoch(for: targetID) == document.epoch else {
                throw WebInspectorProxyError.staleIdentifier
            }
        }

        guard let registration = modelFeed,
              let synchronization = registration.synchronization,
              synchronization.generation == authorization.generation,
              synchronization.didPublish else {
            return .waiting
        }

        if isDocumentSensitive(domain, method: method) {
            guard let targetID,
                  let document = authorization.document,
                  let bootstrap = registration.domBootstrap,
                  bootstrap.generation == authorization.generation,
                  bootstrap.targetsByID[targetID]?.completedEpoch == document.epoch else {
                return .waiting
            }
        }
        return .ready(targetID: targetID)
    }

    private func reevaluateModelCommandReadinessWaiters() {
        for operationID in modelCommandTasks.keys.sorted() {
            guard var task = modelCommandTasks[operationID],
                  let signal = task.readinessSignal else {
                continue
            }
            do {
                guard case .ready = try modelCommandReadiness(
                    authorization: task.authorization,
                    domain: task.domain,
                    method: task.method,
                    routing: task.routing
                ) else {
                    continue
                }
                task.readinessSignal = nil
                modelCommandTasks[operationID] = task
                signal.fulfill(.success(()))
            } catch {
                task.readinessSignal = nil
                modelCommandTasks[operationID] = task
                signal.fulfill(.failure(error))
            }
        }
        resumeModelCommandOwnerCountWaitersIfNeeded()
    }

    private func makeModelCommandOperation(
        _ command: ProtocolCommand,
        targetID: ProtocolTarget.ID?,
        authorization: ConnectionModelCommandAuthorization,
        operationID: UInt64
    ) throws -> ConnectionOwnedCommandOperation {
        let commandID = allocateCommandID()
        let promise = ReplyPromise<ProtocolCommand.Result>()
        let message = try TransportMessageParser.makeCommandString(
            id: commandID,
            method: command.method,
            parametersData: command.parametersData
        )
        let pending = TransportSession.PendingReply.modelCommand(
            domain: command.domain,
            method: command.method,
            targetID: targetID,
            promise: promise,
            authorization: authorization,
            operationID: operationID
        )

        let pendingKey: TransportSession.PendingKey
        let wireMessage: String
        if let targetID {
            guard targetRegistry.containsTarget(targetID) else {
                throw WebInspectorProxyError.staleIdentifier
            }
            let wrapperID = allocateCommandID()
            let replyKey = TransportSession.ReplyKey(
                targetID: targetID,
                commandID: commandID
            )
            pendingKey = .target(replyKey)
            wireMessage = try TransportMessageParser.makeTargetWrapperCommandString(
                id: wrapperID,
                targetIdentifier: targetID.rawValue,
                message: message
            )
            replyStore.insertTargetReply(
                pending,
                key: replyKey,
                rootWrapperID: wrapperID
            )
        } else {
            pendingKey = .root(commandID)
            wireMessage = message
            replyStore.insertRootReply(pending, commandID: commandID)
        }

        let ownership = ConnectionPendingReplyOwnership(
            key: pendingKey,
            purpose: pending.purpose
        )
        guard var task = modelCommandTasks[operationID] else {
            preconditionFailure("A model command pending reply has no task owner.")
        }
        task.pendingReplyOwnership = ownership
        modelCommandTasks[operationID] = task

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
                        method: command.method,
                        targetID: targetID
                    )
                )
                await responseTimeoutDidFire()
            }
        } else {
            timeoutAction = nil
        }
        return ConnectionOwnedCommandOperation(
            backend: backend,
            message: wireMessage,
            promise: promise,
            pendingReplyOwnership: ownership,
            timeoutAction: timeoutAction
        )
    }

    private func finishModelCommand(
        _ operationID: UInt64,
        fallback: Result<ProtocolCommand.Result, any Swift.Error>
    ) -> Result<ProtocolCommand.Result, any Swift.Error> {
        guard let task = modelCommandTasks.removeValue(forKey: operationID) else {
            return fallback
        }
        if let ownership = task.pendingReplyOwnership,
           let pending = replyStore.removePendingReply(ownership.key) {
            precondition(
                pending.purpose == ownership.purpose,
                "A model command task attempted to remove a reply owned by another purpose."
            )
        }
        task.readinessSignal?.fulfill(.failure(CancellationError()))
        resumeModelCommandOwnerCountWaitersIfNeeded()
        return task.control.resolve(fallback)
    }

    private func requiredModelDomain(for domain: ProtocolDomain) -> ModelDomain? {
        switch domain {
        case .dom, .inspector:
            .dom
        case .css:
            .css
        case .network:
            .network
        case .console:
            .console
        case .runtime:
            .runtime
        case .page:
            nil
        case .target, .storage, .other:
            nil
        }
    }

    private func proxyDomain(for domain: ProtocolDomain) -> WebInspectorProxyDomain? {
        switch domain {
        case .dom:
            .dom
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
        case .inspector:
            .inspector
        case .target, .storage, .other:
            nil
        }
    }

    private func isDocumentSensitive(
        _ domain: ProtocolDomain,
        method: String
    ) -> Bool {
        if domain == .dom, method == "DOM.hideHighlight" {
            return false
        }
        return domain == .dom || domain == .css || domain == .inspector
    }

    private func isConnectionOwnedCommand(_ method: String) -> Bool {
        method.hasSuffix(".enable")
            || method.hasSuffix(".disable")
            || method == "DOM.getDocument"
            || method == "Inspector.initialized"
    }

    private func invalidateModelCommands(
        where shouldInvalidate: (ConnectionModelCommandTask) -> Bool,
        failureOverride: ConnectionModelCommandFailureOverride,
        pendingFailureReason: ConnectionPendingReplyFailureReason
    ) -> ConnectionCommandInvalidationEffects {
        var effects = ConnectionCommandInvalidationEffects()
        for operationID in modelCommandTasks.keys.sorted() {
            guard var commandTask = modelCommandTasks[operationID],
                  shouldInvalidate(commandTask) else {
                continue
            }
            commandTask.control.failFromOwner(failureOverride)
            let readinessSignal = commandTask.readinessSignal
            commandTask.readinessSignal = nil
            modelCommandTasks[operationID] = commandTask
            readinessSignal?.fulfill(.failure(failureOverride.error))

            if let ownership = commandTask.pendingReplyOwnership,
               let pending = replyStore.removePendingReply(ownership.key) {
                precondition(
                    pending.purpose == ownership.purpose,
                    "A model command invalidation removed another operation's reply."
                )
                effects.pendingFailures.append(
                    ConnectionPendingReplyFailure(
                        pending: pending,
                        reason: pendingFailureReason
                    )
                )
            }
            if let task = commandTask.control.task {
                effects.modelCommandTasksToAwait.append(task)
            }
        }
        resumeModelCommandOwnerCountWaitersIfNeeded()
        return effects
    }

    private func completeCommandInvalidationEffects(
        _ effects: ConnectionCommandInvalidationEffects
    ) async {
        for failure in effects.pendingFailures {
            failure.pending.promise.fulfill(.failure(failure.reason.error))
        }
        for task in effects.modelCommandTasksToAwait {
            _ = await task.result
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

    package func waitForModelCommandOwnerCountForTesting(_ expectedCount: Int) async {
        precondition(expectedCount >= 0)
        guard modelCommandTasks.count != expectedCount else {
            return
        }
        await withCheckedContinuation { continuation in
            modelCommandOwnerCountWaiters.append((expectedCount, continuation))
        }
    }

    package func startModelCommandForTesting(
        _ command: ProtocolCommand,
        authorization: ConnectionModelCommandAuthorization
    ) throws -> Task<ProtocolCommand.Result, any Swift.Error> {
        try beginModelCommand(command, authorization: authorization).task
    }

    package func modelCommandOwnerCountForTesting() -> Int {
        modelCommandTasks.count
    }

    package func modelCommandReadinessWaiterCountForTesting() -> Int {
        modelCommandTasks.values.count { $0.readinessSignal != nil }
    }

    package func waitForModelCommandReadinessWaiterCountForTesting(
        _ expectedCount: Int
    ) async {
        precondition(expectedCount >= 0)
        guard modelCommandReadinessWaiterCountForTesting() != expectedCount else {
            return
        }
        await withCheckedContinuation { continuation in
            modelCommandReadinessCountWaiters.append((expectedCount, continuation))
        }
    }

    private func resumeModelCommandOwnerCountWaitersIfNeeded() {
        let count = modelCommandTasks.count
        var pending: [(
            expectedCount: Int,
            continuation: CheckedContinuation<Void, Never>
        )] = []
        for waiter in modelCommandOwnerCountWaiters {
            if count == waiter.expectedCount {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        modelCommandOwnerCountWaiters = pending

        let readinessCount = modelCommandReadinessWaiterCountForTesting()
        var pendingReadiness: [(
            expectedCount: Int,
            continuation: CheckedContinuation<Void, Never>
        )] = []
        for waiter in modelCommandReadinessCountWaiters {
            if readinessCount == waiter.expectedCount {
                waiter.continuation.resume()
            } else {
                pendingReadiness.append(waiter)
            }
        }
        modelCommandReadinessCountWaiters = pendingReadiness
    }

    package func replaceEventScopeActivationCancellationActionForTesting(
        _ action: @escaping @Sendable () async -> Void
    ) {
        eventScopeActivationCancellationAction = action
    }

    package func replaceModelTargetMutationActionForTesting(
        _ action: (@Sendable () -> Void)?
    ) {
        modelTargetMutationActionForTesting = action
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
                self.failMainPageTargetWaiter(waiter.id, error: TransportSession.Error.missingMainPageTarget)
            }
        }
        defer {
            timeoutTask?.cancel()
        }

        do {
            return try await waiter.promise.value()
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

    func pendingReplyPurposes() -> [
        TransportSession.PendingKey: TransportSession.PendingReply.Purpose
    ] {
        replyStore.pendingReplyPurposes
    }

    func capabilityLeaseOwnersForTesting() -> [
        ConnectionCapabilityKey: Set<ConnectionCapabilityLeaseOwner>
    ] {
        capabilities.states.mapValues(\.leaseOwners)
    }

    func desiredCapabilityLeaseOwnersForTesting() -> [
        ConnectionCapabilityKey: Set<ConnectionCapabilityLeaseOwner>
    ] {
        capabilities.states.mapValues(\.desiredLeaseOwners)
    }

    func parkedCurrentPageCapabilityCountForTesting() -> Int {
        precondition(
            parkedCurrentPageCapabilityLedger.count
                == parkedCurrentPageCapabilityLedgerOrder.count,
            "The parked capability ledger and its retention order diverged."
        )
        return parkedCurrentPageCapabilityLedger.count
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

    private func claimDirectConsumer() throws {
        guard modelFeed == nil else {
            throw WebInspectorProxyError.connectionInUse
        }
        replayWasTaintedByDirectConsumer = true
    }

    private func enqueueModelFeedRecord(
        _ record: ConnectionModelFeedRecord
    ) -> Bool {
        guard let registration = modelFeed else {
            return true
        }
        switch registration.mailbox.enqueue(record) {
        case .enqueued:
            return true
        case .terminated:
            handoffTermination(
                .modelFeedFailure(ConnectionModelFeedError.consumerTerminated)
            )
            return false
        }
    }

    @discardableResult
    private func publishModelTargetSnapshot() -> Bool {
        guard var registration = modelFeed else {
            return true
        }
        guard let snapshot = targetRegistry.modelTargetSnapshot() else {
            preconditionFailure("A current page binding has no model target snapshot.")
        }
        let through = eventSequences.current.sequence
        guard enqueueModelFeedRecord(
            .targetSnapshot(
                generation: currentPageGeneration,
                through: through,
                snapshot: snapshot
            )
        ) else {
            return false
        }
        registration.targetSnapshotThrough = through
        registration.synchronization = ConnectionModelFeedSynchronizationState(
            generation: currentPageGeneration
        )
        if registration.configuredDomains.contains(.dom) {
            registration.domBootstrap = makeDOMBootstrapState(
                snapshot: snapshot,
                generation: currentPageGeneration
            )
        } else {
            registration.domBootstrap = nil
        }
        modelFeed = registration

        guard publishModelSynchronizationIfReady() else {
            return false
        }
        startNextDOMBootstrapIfNeeded()
        return isOpen
    }

    @discardableResult
    private func completeModelDomain(
        _ domain: ModelDomain,
        generation: WebInspectorPage.Generation
    ) -> Bool {
        guard var registration = modelFeed,
              var synchronization = registration.synchronization,
              synchronization.generation == generation else {
            return true
        }
        guard registration.configuredDomains.contains(domain) else {
            preconditionFailure("A model feed completed a domain that it did not configure.")
        }
        precondition(
            synchronization.completedDomains.insert(domain).inserted,
            "A model feed domain completed more than once in one binding generation."
        )
        registration.synchronization = synchronization
        modelFeed = registration
        return publishModelSynchronizationIfReady()
    }

    @discardableResult
    private func publishModelSynchronizationIfReady(
        allowWhileAcquiring: Bool = false
    ) -> Bool {
        guard var registration = modelFeed,
              var synchronization = registration.synchronization else {
            return true
        }
        switch registration.lifecycle {
        case .active:
            break
        case .acquiring where allowWhileAcquiring:
            break
        case .acquiring, .rollingBack, .closing:
            return true
        }
        guard synchronization.completedDomains == registration.configuredDomains else {
            return true
        }
        precondition(
            !synchronization.didPublish,
            "A model feed published synchronization more than once in one binding generation."
        )
        guard enqueueModelFeedRecord(
            .synchronizationComplete(
                generation: synchronization.generation,
                through: eventSequences.current.sequence
            )
        ) else {
            return false
        }
        synchronization.didPublish = true
        registration.synchronization = synchronization
        modelFeed = registration
        reevaluateModelCommandReadinessWaiters()
        return true
    }

    private func makeDOMBootstrapState(
        snapshot: ModelTargetSnapshot,
        generation: WebInspectorPage.Generation
    ) -> ConnectionDOMBootstrapState {
        var targetsByID: [ProtocolTarget.ID: ConnectionDOMBootstrapState.TargetState] = [:]
        let orderedTargetIDs = snapshot.targets.map { target in
            let targetID = ProtocolTarget.ID(target.id.rawValue)
            precondition(
                !targetsByID.keys.contains(targetID),
                "A model target snapshot contains duplicate physical targets."
            )
            targetsByID[targetID] = ConnectionDOMBootstrapState.TargetState(
                target: target,
                completedEpoch: nil
            )
            _ = modelDocumentEpoch(for: targetID)
            return targetID
        }
        return ConnectionDOMBootstrapState(
            generation: generation,
            orderedTargetIDs: orderedTargetIDs,
            targetsByID: targetsByID,
            activeOperation: nil,
            needsCompletionMarker: true
        )
    }

    private func modelDocumentEpoch(
        for targetID: ProtocolTarget.ID
    ) -> ModelDocumentEpoch {
        if let epoch = modelDocumentEpochs[targetID] {
            return epoch
        }
        let epoch = ModelDocumentEpoch(rawValue: 0)
        modelDocumentEpochs[targetID] = epoch
        return epoch
    }

    private func advanceModelDocumentEpoch(
        for targetID: ProtocolTarget.ID
    ) -> ModelDocumentEpoch {
        let current = modelDocumentEpoch(for: targetID)
        precondition(
            current.rawValue < UInt64.max,
            "A DOM document epoch exhausted UInt64."
        )
        let next = ModelDocumentEpoch(rawValue: current.rawValue + 1)
        modelDocumentEpochs[targetID] = next
        return next
    }

    private func startNextDOMBootstrapIfNeeded() {
        guard isOpen,
              var registration = modelFeed,
              var bootstrap = registration.domBootstrap,
              bootstrap.generation == currentPageGeneration,
              bootstrap.activeOperation == nil else {
            return
        }
        switch registration.lifecycle {
        case .acquiring, .active:
            break
        case .rollingBack, .closing:
            return
        }

        let nextTargetID = bootstrap.orderedTargetIDs.first { targetID in
            guard let target = bootstrap.targetsByID[targetID] else {
                preconditionFailure("A DOM bootstrap order entry lost its target state.")
            }
            return target.completedEpoch != modelDocumentEpoch(for: targetID)
        }
        guard let targetID = nextTargetID else {
            _ = publishDOMBootstrapCompletionIfReady(
                through: eventSequences.current.sequence
            )
            return
        }

        precondition(
            nextModelBootstrapOperationID < UInt64.max,
            "A DOM bootstrap operation identifier exhausted UInt64."
        )
        nextModelBootstrapOperationID += 1
        let operationID = nextModelBootstrapOperationID
        let documentEpoch = modelDocumentEpoch(for: targetID)
        bootstrap.activeOperation = ConnectionDOMBootstrapState.ActiveOperation(
            id: operationID,
            targetID: targetID,
            documentEpoch: documentEpoch,
            replyDisposition: nil
        )
        registration.domBootstrap = bootstrap
        modelFeed = registration

        let feedID = registration.id
        let generation = bootstrap.generation
        let operation: ConnectionOwnedCommandOperation
        do {
            operation = try makeDOMBootstrapCommandOperation(
                feedID: feedID,
                generation: generation,
                targetID: targetID,
                documentEpoch: documentEpoch,
                operationID: operationID
            )
        } catch {
            handoffTermination(.fatal(
                "Failed to construct DOM.getDocument for target \(targetID.rawValue): \(error)"
            ))
            return
        }

        let task = Task { [weak self, operation] in
            let result: Result<Void, any Swift.Error>
            do {
                try await operation.value()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await self?.completeDOMBootstrapOperation(
                id: operationID,
                feedID: feedID,
                generation: generation,
                targetID: targetID,
                documentEpoch: documentEpoch,
                result: result
            )
        }
        let ownership = operation.pendingReplyOwnership
        precondition(
            modelBootstrapTasks[operationID] == nil,
            "A DOM bootstrap operation identifier already has an owner."
        )
        modelBootstrapTasks[operationID] = ConnectionModelBootstrapTask(
            task: task,
            pendingReplyOwnership: ownership,
            feedID: feedID,
            generation: generation
        )
    }

    /// Publishes the final DOM bootstrap watermark in the same inbound slot as
    /// the last document reply whenever possible. A later domain reply or
    /// event must not overtake this older watermark while the bootstrap task's
    /// continuation is waiting to resume.
    private func publishDOMBootstrapCompletionIfReady(
        through: UInt64
    ) -> Bool {
        guard var registration = modelFeed,
              var bootstrap = registration.domBootstrap,
              bootstrap.generation == currentPageGeneration,
              bootstrap.needsCompletionMarker else {
            return true
        }
        let allTargetsComplete = bootstrap.orderedTargetIDs.allSatisfy { targetID in
            guard let target = bootstrap.targetsByID[targetID] else {
                preconditionFailure("A DOM bootstrap order entry lost its target state.")
            }
            return target.completedEpoch == modelDocumentEpoch(for: targetID)
        }
        guard allTargetsComplete else {
            return true
        }
        guard enqueueModelFeedRecord(
            .bootstrapComplete(
                generation: bootstrap.generation,
                domain: .dom,
                through: through
            )
        ) else {
            markPublishedDOMBootstrapReplyTerminal()
            return false
        }
        bootstrap.needsCompletionMarker = false
        let generation = bootstrap.generation
        let domWasAlreadyComplete = registration.synchronization?
            .completedDomains.contains(.dom) == true
        registration.domBootstrap = bootstrap
        modelFeed = registration
        if !domWasAlreadyComplete,
           !completeModelDomain(.dom, generation: generation) {
            markPublishedDOMBootstrapReplyTerminal()
            return false
        }
        reevaluateModelCommandReadinessWaiters()
        return isOpen
    }

    private func markPublishedDOMBootstrapReplyTerminal() {
        guard var registration = modelFeed,
              var bootstrap = registration.domBootstrap,
              var active = bootstrap.activeOperation,
              active.replyDisposition == .published else {
            return
        }
        active.replyDisposition = .terminal
        bootstrap.activeOperation = active
        registration.domBootstrap = bootstrap
        modelFeed = registration
    }

    private func makeDOMBootstrapCommandOperation(
        feedID: ConnectionModelFeedID,
        generation: WebInspectorPage.Generation,
        targetID: ProtocolTarget.ID,
        documentEpoch: ModelDocumentEpoch,
        operationID: UInt64
    ) throws -> ConnectionOwnedCommandOperation {
        guard targetRegistry.containsTarget(targetID) else {
            throw TransportSession.Error.missingTarget(targetID)
        }
        let innerCommandID = allocateCommandID()
        let outerCommandID = allocateCommandID()
        let replyKey = TransportSession.ReplyKey(
            targetID: targetID,
            commandID: innerCommandID
        )
        let pendingKey = TransportSession.PendingKey.target(replyKey)
        let message = try TransportMessageParser.makeCommandString(
            id: innerCommandID,
            method: "DOM.getDocument",
            parametersData: Data("{}".utf8)
        )
        let wrapperMessage = try TransportMessageParser.makeTargetWrapperCommandString(
            id: outerCommandID,
            targetIdentifier: targetID.rawValue,
            message: message
        )
        let promise = ReplyPromise<ProtocolCommand.Result>()
        let pendingReply = TransportSession.PendingReply.modelBootstrap(
            targetID: targetID,
            promise: promise,
            feedID: feedID,
            generation: generation,
            documentEpoch: documentEpoch,
            operationID: operationID
        )
        replyStore.insertTargetReply(
            pendingReply,
            key: replyKey,
            rootWrapperID: outerCommandID
        )
        let ownership = ConnectionPendingReplyOwnership(
            key: pendingKey,
            purpose: pendingReply.purpose
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
                        method: "DOM.getDocument",
                        targetID: targetID
                    )
                )
                await responseTimeoutDidFire()
            }
        } else {
            timeoutAction = nil
        }

        return ConnectionOwnedCommandOperation(
            backend: backend,
            message: wrapperMessage,
            promise: promise,
            pendingReplyOwnership: ownership,
            timeoutAction: timeoutAction
        )
    }

    private func completeDOMBootstrapOperation(
        id: UInt64,
        feedID: ConnectionModelFeedID,
        generation: WebInspectorPage.Generation,
        targetID: ProtocolTarget.ID,
        documentEpoch: ModelDocumentEpoch,
        result: Result<Void, any Swift.Error>
    ) {
        if let ownership = modelBootstrapTasks.removeValue(forKey: id)?.pendingReplyOwnership,
           let pending = replyStore.removePendingReply(ownership.key) {
            precondition(
                pending.purpose == ownership.purpose,
                "A DOM bootstrap task attempted to remove a reply owned by another purpose."
            )
        }
        guard var registration = modelFeed,
              registration.id == feedID,
              var bootstrap = registration.domBootstrap,
              bootstrap.generation == generation,
              let active = bootstrap.activeOperation,
              active.id == id,
              active.targetID == targetID,
              active.documentEpoch == documentEpoch else {
            return
        }
        bootstrap.activeOperation = nil
        registration.domBootstrap = bootstrap
        modelFeed = registration

        if active.replyDisposition == .terminal {
            // Reply publication is the operation's terminal authority. The
            // connection teardown races its cancellation against promise
            // fulfillment, so consume this disposition before interpreting
            // the task's generic success or cancellation result.
            return
        }
        guard isOpen else {
            return
        }

        switch result {
        case .success:
            guard let replyDisposition = active.replyDisposition else {
                preconditionFailure(
                    "A successful DOM bootstrap operation has no reply-side disposition."
                )
            }
            switch replyDisposition {
            case .published, .stale:
                startNextDOMBootstrapIfNeeded()
            case .terminal:
                preconditionFailure(
                    "A terminal DOM bootstrap reply disposition escaped its operation boundary."
                )
            }
        case let .failure(error):
            let targetIsStillRequired = bootstrap.targetsByID[targetID] != nil
                && modelDocumentEpoch(for: targetID) == documentEpoch
                && targetRegistry.target(for: targetID).map(
                    targetRegistry.isCurrentPageModelTarget
                ) == true
            guard targetIsStillRequired else {
                startNextDOMBootstrapIfNeeded()
                return
            }
            if let transportError = error as? TransportSession.Error,
               case let .remoteError(_, _, message) = transportError {
                handoffTermination(
                    .modelFeedFailure(
                        .bootstrapFailed(domain: .dom, message: message)
                    )
                )
                return
            }
            handoffTermination(.fatal(
                "DOM.getDocument failed for required target \(targetID.rawValue): \(error)"
            ))
        }
    }

    private func reconcileDOMBootstrapTargets() {
        guard var registration = modelFeed,
              var bootstrap = registration.domBootstrap,
              bootstrap.generation == currentPageGeneration,
              let snapshot = targetRegistry.modelTargetSnapshot() else {
            return
        }

        var targetsByID: [ProtocolTarget.ID: ConnectionDOMBootstrapState.TargetState] = [:]
        var addedTarget = false
        let orderedTargetIDs = snapshot.targets.map { target in
            let targetID = ProtocolTarget.ID(target.id.rawValue)
            precondition(
                !targetsByID.keys.contains(targetID),
                "A reconciled model target snapshot contains duplicate physical targets."
            )
            let currentEpoch = modelDocumentEpoch(for: targetID)
            if var existing = bootstrap.targetsByID[targetID] {
                existing = ConnectionDOMBootstrapState.TargetState(
                    target: target,
                    completedEpoch: existing.completedEpoch
                )
                targetsByID[targetID] = existing
                if existing.completedEpoch != currentEpoch {
                    bootstrap.needsCompletionMarker = true
                }
            } else {
                targetsByID[targetID] = ConnectionDOMBootstrapState.TargetState(
                    target: target,
                    completedEpoch: nil
                )
                addedTarget = true
            }
            return targetID
        }
        if addedTarget {
            bootstrap.needsCompletionMarker = true
        }
        bootstrap.orderedTargetIDs = orderedTargetIDs
        bootstrap.targetsByID = targetsByID
        registration.domBootstrap = bootstrap
        modelFeed = registration
        startNextDOMBootstrapIfNeeded()
    }

    private func prepareDOMDocumentUpdateForModelFeed(
        _ event: ProtocolEvent
    ) -> ConnectionCommandInvalidationEffects {
        guard event.method == "DOM.documentUpdated" else {
            return ConnectionCommandInvalidationEffects()
        }
        let targetID = event.targetID
            ?? event.sourceTargetID
            ?? targetRegistry.currentMainPageTargetID
        guard let targetID,
              let targetRecord = targetRegistry.target(for: targetID),
              targetRegistry.isCurrentPageModelTarget(targetRecord) else {
            return ConnectionCommandInvalidationEffects()
        }
        let oldEpoch = modelDocumentEpoch(for: targetID)
        let documentEpoch = advanceModelDocumentEpoch(for: targetID)

        if var registration = modelFeed,
           var bootstrap = registration.domBootstrap,
           bootstrap.generation == currentPageGeneration,
           bootstrap.targetsByID[targetID] != nil {
            bootstrap.needsCompletionMarker = true
            registration.domBootstrap = bootstrap
            modelFeed = registration
        }

        var effects = invalidateModelCommands(
            where: { task in
                guard task.authorization.generation == currentPageGeneration,
                      isDocumentSensitive(task.domain, method: task.method),
                      let document = task.authorization.document else {
                    return false
                }
                return ProtocolTarget.ID(document.targetID.rawValue) == targetID
                    && document.epoch == oldEpoch
            },
            failureOverride: .staleIdentifier,
            pendingFailureReason: .staleIdentifier
        )
        let bindingReplies = replyStore.removePendingReplies { pending in
            guard pending.targetID == targetID,
                  isDocumentSensitive(pending.domain, method: pending.method) else {
                return false
            }
            let bindingGeneration: WebInspectorPage.Generation?
            let documentEpoch: ModelDocumentEpoch?
            switch pending.purpose {
            case let .direct(generation, epoch):
                bindingGeneration = generation
                documentEpoch = epoch
            case let .elementPickerMode(_, generation, epoch, _):
                bindingGeneration = generation
                documentEpoch = epoch
            case .modelCommand, .capability, .capabilityAuxiliary, .modelBootstrap:
                return false
            }
            return bindingGeneration == currentPageGeneration
                && documentEpoch == oldEpoch
        }
        effects.pendingFailures.append(contentsOf: bindingReplies.map {
            ConnectionPendingReplyFailure(pending: $0, reason: .staleIdentifier)
        })

        if let registration = modelFeed,
           registration.configuredDomains.contains(.dom),
           registration.targetSnapshotThrough != nil {
            guard let target = ModelTarget(record: targetRecord) else {
                preconditionFailure(
                    "A current-page DOM target cannot be represented in the model feed."
                )
            }
            _ = enqueueModelFeedRecord(
                .domDocumentInvalidated(
                    generation: currentPageGeneration,
                    sequence: event.sequence,
                    target: target,
                    documentEpoch: documentEpoch
                )
            )
        }
        return effects
    }

    private func publishModelTargetLifecycleEvent(
        _ event: ModelTargetLifecycleEvent,
        sequence: UInt64
    ) {
        guard let registration = modelFeed,
              targetRegistry.currentMainPageTargetID != nil,
              let targetSnapshotThrough = registration.targetSnapshotThrough,
              sequence > targetSnapshotThrough else {
            return
        }
        _ = enqueueModelFeedRecord(
            .event(
                generation: currentPageGeneration,
                sequence: sequence,
                payload: .target(event)
            )
        )
    }

    private func beginCapabilityLease(
        _ leaseOwner: ConnectionCapabilityLeaseOwner,
        for key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation
    ) -> ReplyPromise<Void>? {
        var capability = capabilities.states[key]
            ?? ConnectionCapabilityRegistry.State(physical: .inactive(generation: generation))
        precondition(
            capability.leaseOwners.insert(leaseOwner).inserted,
            "Duplicate capability lease owner."
        )

        let activation: ReplyPromise<Void>?
        if case let .enabled(activeGeneration) = capability.physical,
           activeGeneration == generation {
            activation = nil
            precondition(
                capability.activatedLeaseOwners.insert(leaseOwner).inserted,
                "A newly registered capability lease was already activated."
            )
        } else {
            let promise = ReplyPromise<Void>()
            capability.activationWaiters[leaseOwner] = promise
            activation = promise
        }
        capabilities.states[key] = capability
        return activation
    }

    private func activateCapabilityLease(
        _ leaseOwner: ConnectionCapabilityLeaseOwner,
        for key: ConnectionCapabilityKey,
        activation: ReplyPromise<Void>?
    ) async throws {
        do {
            await reconcileCapability(for: key)
            try Task.checkCancellation()
            try await activation?.value()
        } catch {
            if error is CancellationError {
                await cancelCapabilityActivation(leaseOwner, for: key)
            }
            throw error
        }
    }

    private func cancelCapabilityActivation(
        _ leaseOwner: ConnectionCapabilityLeaseOwner,
        for key: ConnectionCapabilityKey
    ) async {
        guard var capability = capabilities.states[key],
              let waiter = capability.activationWaiters.removeValue(forKey: leaseOwner) else {
            return
        }
        capability.failedLeaseOwners.insert(leaseOwner)
        capabilities.states[key] = capability
        if case .eventScope = leaseOwner {
            let cancellationAction = eventScopeActivationCancellationAction
            eventScopeActivationCancellationAction = nil
            await cancellationAction?()
        }
        waiter.fulfill(.failure(CancellationError()))
    }

    private func releaseCapabilityLease(
        _ leaseOwner: ConnectionCapabilityLeaseOwner,
        for key: ConnectionCapabilityKey
    ) async throws {
        guard var capability = capabilities.states[key] else {
            return
        }
        guard capability.leaseOwners.remove(leaseOwner) != nil else {
            return
        }
        capability.failedLeaseOwners.remove(leaseOwner)
        capability.activatedLeaseOwners.remove(leaseOwner)
        let activationWaiter = capability.activationWaiters.removeValue(
            forKey: leaseOwner
        )
        activationWaiter?.fulfill(.failure(CancellationError()))

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
        case .unknown, .replayRequired:
            let promise = ReplyPromise<Void>()
            capability.releaseWaiters[leaseOwner] = promise
            cleanup = promise
        case .enabled:
            let promise = ReplyPromise<Void>()
            capability.releaseWaiters[leaseOwner] = promise
            cleanup = promise
        case let .enabling(generation, operationID, _):
            let promise = ReplyPromise<Void>()
            capability.releaseWaiters[leaseOwner] = promise
            capability.physical = .enabling(
                generation: generation,
                operationID: operationID,
                mustDisableAfterEnable: true
            )
            cleanup = promise
        case .disabling:
            let promise = ReplyPromise<Void>()
            capability.releaseWaiters[leaseOwner] = promise
            cleanup = promise
        }
        capabilities.states[key] = capability
        await reconcileCapability(for: key)
        try await cleanup?.valueIgnoringCancellation()
        capabilities.removeEmptyState(for: key)
    }

    private func abandonCapabilityLease(
        _ leaseOwner: ConnectionCapabilityLeaseOwner,
        for key: ConnectionCapabilityKey
    ) async {
        guard var capability = capabilities.states[key] else {
            return
        }
        capability.leaseOwners.remove(leaseOwner)
        capability.failedLeaseOwners.remove(leaseOwner)
        capability.activatedLeaseOwners.remove(leaseOwner)
        capability.activationWaiters.removeValue(forKey: leaseOwner)
        capability.releaseWaiters.removeValue(forKey: leaseOwner)
        capabilities.states[key] = capability
        await reconcileCapability(for: key)
        capabilities.removeEmptyState(for: key)
    }

    private func acquireElementPickerMode(
        _ owner: ConnectionCapabilityLeaseOwner,
        for key: ConnectionCapabilityKey
    ) async throws {
        let generation = generation(for: key.route)
        var mode = elementPickerModes[key]
            ?? ConnectionElementPickerMode(generation: generation)
        if mode.physical.generation != generation {
            mode.physical = .inactive(generation)
            mode.activatedThrough.removeAll(keepingCapacity: true)
        }
        precondition(
            mode.owners.insert(owner).inserted,
            "Duplicate element-picker mode owner."
        )
        if case .enabled(generation) = mode.physical {
            mode.activatedThrough[owner] = eventSequences.current.sequence
            elementPickerModes[key] = mode
            return
        }
        let completion = ReplyPromise<Void>()
        mode.activationWaiters[owner] = completion
        elementPickerModes[key] = mode
        await reconcileElementPickerMode(for: key)
        do {
            try await completion.value()
        } catch {
            await abandonElementPickerMode(owner, for: key)
            throw error
        }
    }

    private func releaseElementPickerMode(
        _ owner: ConnectionCapabilityLeaseOwner,
        for key: ConnectionCapabilityKey
    ) async throws {
        guard var mode = elementPickerModes[key],
              mode.owners.remove(owner) != nil else {
            return
        }
        mode.activatedThrough[owner] = nil
        if let activation = mode.activationWaiters.removeValue(forKey: owner) {
            activation.fulfill(.failure(CancellationError()))
        }

        let completion: ReplyPromise<Void>?
        switch mode.physical {
        case .inactive:
            completion = nil
        case .enabled where !mode.owners.isEmpty:
            completion = nil
        case .enabling, .enabled, .disabling:
            let promise = ReplyPromise<Void>()
            mode.releaseWaiters[owner] = promise
            completion = promise
        }
        elementPickerModes[key] = mode
        await reconcileElementPickerMode(for: key)
        try await completion?.valueIgnoringCancellation()
        removeEmptyElementPickerMode(for: key)
    }

    private func abandonElementPickerMode(
        _ owner: ConnectionCapabilityLeaseOwner,
        for key: ConnectionCapabilityKey
    ) async {
        guard var mode = elementPickerModes[key] else {
            return
        }
        mode.owners.remove(owner)
        mode.activatedThrough[owner] = nil
        mode.activationWaiters.removeValue(forKey: owner)
        mode.releaseWaiters.removeValue(forKey: owner)
        elementPickerModes[key] = mode
        await reconcileElementPickerMode(for: key)
        removeEmptyElementPickerMode(for: key)
    }

    private func reconcileElementPickerMode(
        for key: ConnectionCapabilityKey
    ) async {
        guard isOpen, var mode = elementPickerModes[key] else {
            return
        }
        let generation = generation(for: key.route)
        if mode.physical.generation != generation {
            mode.physical = .inactive(generation)
            mode.activatedThrough.removeAll(keepingCapacity: true)
            elementPickerModes[key] = mode
        }

        switch mode.physical {
        case .inactive where !mode.owners.isEmpty:
            mode.physical = .enabling(generation)
            elementPickerModes[key] = mode
            let result: Result<ProtocolCommand.Result, any Swift.Error>
            do {
                result = .success(
                    try await sendElementPickerModeCommand(
                        enabled: true,
                        key: key,
                        generation: generation
                    )
                )
            } catch {
                result = .failure(
                    Self.mapElementPickerModeError(error, enabled: true)
                )
            }
            await completeElementPickerModeTransition(
                enabled: true,
                key: key,
                generation: generation,
                result: result
            )

        case .enabled where mode.owners.isEmpty:
            mode.physical = .disabling(generation)
            elementPickerModes[key] = mode
            let result: Result<ProtocolCommand.Result, any Swift.Error>
            do {
                result = .success(
                    try await sendElementPickerModeCommand(
                        enabled: false,
                        key: key,
                        generation: generation
                    )
                )
            } catch {
                result = .failure(
                    Self.mapElementPickerModeError(error, enabled: false)
                )
            }
            await completeElementPickerModeTransition(
                enabled: false,
                key: key,
                generation: generation,
                result: result
            )

        case .inactive, .enabling, .enabled, .disabling:
            break
        }
    }

    private func completeElementPickerModeTransition(
        enabled: Bool,
        key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation,
        result: Result<ProtocolCommand.Result, any Swift.Error>
    ) async {
        guard var mode = elementPickerModes[key],
              mode.physical.generation == generation else {
            return
        }
        if enabled {
            guard case .enabling = mode.physical else {
                return
            }
            switch result {
            case let .success(reply):
                mode.physical = .enabled(generation)
                for owner in mode.owners {
                    mode.activatedThrough[owner] = reply.receivedSequence
                }
                let waiters = Array(mode.activationWaiters.values)
                mode.activationWaiters.removeAll()
                elementPickerModes[key] = mode
                for waiter in waiters {
                    waiter.fulfill(.success(()))
                }
                await reconcileElementPickerMode(for: key)
            case let .failure(error):
                mode.physical = .inactive(generation)
                let activationWaiters = Array(mode.activationWaiters.values)
                mode.activationWaiters.removeAll()
                let releaseWaiters = Array(mode.releaseWaiters.values)
                mode.releaseWaiters.removeAll()
                elementPickerModes[key] = mode
                for waiter in activationWaiters {
                    waiter.fulfill(.failure(error))
                }
                for waiter in releaseWaiters {
                    waiter.fulfill(.success(()))
                }
            }
            return
        }

        guard case .disabling = mode.physical else {
            return
        }
        switch result {
        case .success:
            mode.physical = .inactive(generation)
            let waiters = Array(mode.releaseWaiters.values)
            mode.releaseWaiters.removeAll()
            elementPickerModes[key] = mode
            for waiter in waiters {
                waiter.fulfill(.success(()))
            }
            await reconcileElementPickerMode(for: key)
        case let .failure(error):
            mode.physical = .enabled(generation)
            let waiters = Array(mode.releaseWaiters.values)
            mode.releaseWaiters.removeAll()
            elementPickerModes[key] = mode
            for waiter in waiters {
                waiter.fulfill(.failure(error))
            }
        }
    }

    private func sendElementPickerModeCommand(
        enabled: Bool,
        key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation
    ) async throws -> ProtocolCommand.Result {
        guard generation == currentPageGeneration,
              case .currentPage = key.route.storage else {
            throw WebInspectorProxyError.staleIdentifier
        }
        let targetID = try currentMainPageTarget()
        let command = ProtocolCommand(
            domain: .dom,
            method: "DOM.setInspectModeEnabled",
            routing: .target(targetID),
            parametersData: try elementPickerModeParametersData(
                enabled: enabled
            )
        )
        return try await sendTarget(
            command,
            targetID: targetID,
            owner: .elementPickerMode(
                key: key,
                generation: generation,
                documentEpoch: modelDocumentEpoch(for: targetID),
                enabled: enabled
            )
        )
    }

    private func elementPickerShouldDeliver(
        _ eventSequence: UInt64,
        to owner: ConnectionCapabilityLeaseOwner,
        key: ConnectionCapabilityKey
    ) -> Bool {
        guard let through = elementPickerModes[key]?.activatedThrough[owner] else {
            return false
        }
        return eventSequence > through
    }

    private func removeEmptyElementPickerMode(
        for key: ConnectionCapabilityKey
    ) {
        guard let mode = elementPickerModes[key],
              mode.owners.isEmpty,
              mode.activationWaiters.isEmpty,
              mode.releaseWaiters.isEmpty,
              case .inactive = mode.physical else {
            return
        }
        elementPickerModes[key] = nil
    }

    private func markElementPickerModeInactive(
        for key: ConnectionCapabilityKey
    ) {
        guard var mode = elementPickerModes[key] else {
            return
        }
        mode.physical = .inactive(generation(for: key.route))
        mode.activatedThrough.removeAll(keepingCapacity: false)
        elementPickerModes[key] = mode
        removeEmptyElementPickerMode(for: key)
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
                capability.activatedLeaseOwners.formUnion(capability.activationWaiters.keys)
                let waiters = Array(capability.activationWaiters.values)
                capability.activationWaiters.removeAll()
                capabilities.states[key] = capability
                for waiter in waiters {
                    waiter.fulfill(.success(()))
                }
            } else {
                capability.physical = .inactive(generation: expectedGeneration)
                let waiters = Array(capability.releaseWaiters.values)
                capability.releaseWaiters.removeAll()
                capabilities.states[key] = capability
                for waiter in waiters {
                    waiter.fulfill(.success(()))
                }
            }
            capabilities.removeEmptyState(for: key)
            return
        }

        if capability.desiredCount > 0,
           !capabilityDependenciesAreEnabled(for: key, generation: expectedGeneration) {
            capabilities.states[key] = capability
            return
        }
        if capability.desiredCount == 0,
           !capabilityDependentsAreInactive(for: key, generation: expectedGeneration) {
            capabilities.states[key] = capability
            return
        }

        switch capability.physical {
        case .inactive where capability.desiredCount > 0:
            guard (try? requireAvailableTarget(for: key.route)) != nil else {
                capabilities.states[key] = capability
                return
            }
            startCapabilityEnable(for: key, generation: expectedGeneration)
        case .unknown where capability.desiredCount > 0:
            guard (try? requireAvailableTarget(for: key.route)) != nil else {
                capabilities.states[key] = capability
                return
            }
            switch key.domain {
            case .page:
                startCapabilityEnable(
                    for: key,
                    generation: expectedGeneration,
                    policy: .restoredPageEnable
                )
            case .css:
                if cssRequiresModelSnapshot(capability) {
                    startCSSCapabilitySnapshot(
                        for: key,
                        generation: expectedGeneration,
                        ensuringEnabled: true
                    )
                } else {
                    startCapabilityEnable(for: key, generation: expectedGeneration)
                }
            case .console, .runtime:
                startCapabilityDisable(
                    for: key,
                    generation: expectedGeneration,
                    policy: .replayRefresh
                )
            case .inspector, .network:
                startCapabilityEnable(for: key, generation: expectedGeneration)
            case .dom:
                preconditionFailure("DOM capability reconciliation is local-only.")
            case .target:
                preconditionFailure("Target is not an acquirable capability domain.")
            }
        case .replayRequired where capability.desiredCount > 0:
            switch key.domain {
            case .css:
                precondition(
                    cssRequiresModelSnapshot(capability),
                    "A CSS replay requirement has no model-feed owner."
                )
                startCSSCapabilitySnapshot(
                    for: key,
                    generation: expectedGeneration,
                    ensuringEnabled: false
                )
            case .network:
                startCapabilityEnable(for: key, generation: expectedGeneration)
            case .console, .runtime:
                startCapabilityDisable(
                    for: key,
                    generation: expectedGeneration,
                    policy: .replayRefresh
                )
            case .page, .inspector, .dom, .target:
                preconditionFailure(
                    "\(key.domain.rawValue) cannot require model replay while enabled."
                )
            }
        case .replayRequired where capability.desiredCount == 0:
            startCapabilityDisable(for: key, generation: expectedGeneration)
        case .unknown where capability.desiredCount == 0:
            startCapabilityDisable(for: key, generation: expectedGeneration)
        case .enabled where capability.desiredCount == 0:
            startCapabilityDisable(for: key, generation: expectedGeneration)
        case .enabled:
            capability.activatedLeaseOwners.formUnion(capability.activationWaiters.keys)
            let waiters = Array(capability.activationWaiters.values)
            capability.activationWaiters.removeAll()
            capabilities.states[key] = capability
            if key.domain == .inspector {
                await reconcileElementPickerMode(for: key)
            }
            await reconcileCapabilityDependents(of: key)
            for waiter in waiters {
                waiter.fulfill(.success(()))
            }
        case .inactive:
            capabilities.states[key] = capability
            capabilities.removeEmptyState(for: key)
        case .unknown, .replayRequired, .enabling, .disabling:
            capabilities.states[key] = capability
        }
    }

    private func cssRequiresModelSnapshot(
        _ capability: ConnectionCapabilityRegistry.State
    ) -> Bool {
        guard let registration = modelFeed,
              registration.configuredDomains.contains(.css) else {
            return false
        }
        return capability.desiredLeaseOwners.contains(
            .modelFeed(registration.id, .css)
        )
    }

    private func capabilityDependenciesAreEnabled(
        for key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation
    ) -> Bool {
        guard key.domain == .css else {
            return true
        }
        let pageKey = ConnectionCapabilityKey(
            route: key.route,
            targetID: key.targetID,
            domain: .page
        )
        guard let page = capabilities.states[pageKey] else {
            // Frame CSS agents do not expose or retain Page.
            return true
        }
        precondition(
            page.desiredCount > 0,
            "An active CSS capability lost its Page dependency lease."
        )
        guard case let .enabled(pageGeneration) = page.physical,
              pageGeneration == generation else {
            return false
        }
        return true
    }

    private func reconcileCapabilityDependents(of key: ConnectionCapabilityKey) async {
        guard key.domain == .page else {
            return
        }
        let cssKey = ConnectionCapabilityKey(
            route: key.route,
            targetID: key.targetID,
            domain: .css
        )
        await reconcileCapability(for: cssKey)
    }

    private func capabilityDependentsAreInactive(
        for key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation
    ) -> Bool {
        guard key.domain == .page else {
            return true
        }
        let cssKey = ConnectionCapabilityKey(
            route: key.route,
            targetID: key.targetID,
            domain: .css
        )
        guard let css = capabilities.states[cssKey] else {
            return true
        }
        precondition(
            css.desiredCount == 0,
            "A Page dependency was released while CSS still required it."
        )
        guard css.physical.generation == generation,
              case .inactive = css.physical else {
            return false
        }
        return true
    }

    private func reconcileCapabilityDependenciesAfterCleanup(
        of key: ConnectionCapabilityKey
    ) async {
        guard key.domain == .css else {
            return
        }
        let pageKey = ConnectionCapabilityKey(
            route: key.route,
            targetID: key.targetID,
            domain: .page
        )
        await reconcileCapability(for: pageKey)
    }

    private func startCapabilityEnable(
        for key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation,
        policy: ConnectionCapabilityTask.Policy = .standard
    ) {
        guard var capability = capabilities.states[key] else {
            return
        }
        let startingWireState = capabilityEnableStartingWireState(
            capability.physical
        )
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
            action: .enable,
            policy: policy,
            startingWireState: startingWireState
        )
    }

    private func startCapabilityDisable(
        for key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation,
        policy: ConnectionCapabilityTask.Policy = .standard
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
            action: .disable,
            policy: policy,
            startingWireState: nil
        )
    }

    private func startCSSCapabilitySnapshot(
        for key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation,
        ensuringEnabled: Bool
    ) {
        precondition(key.domain == .css, "A CSS snapshot requires the CSS capability.")
        guard var capability = capabilities.states[key] else {
            return
        }
        let startingWireState = capabilityEnableStartingWireState(
            capability.physical
        )
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
            action: .enable,
            policy: ensuringEnabled ? .cssEnableAndSnapshot : .cssSnapshot,
            startingWireState: startingWireState,
            method: ensuringEnabled ? "CSS.enable" : "CSS.getAllStyleSheets"
        )
    }

    private func capabilityEnableStartingWireState(
        _ physical: ConnectionCapabilityRegistry.PhysicalState
    ) -> ConnectionCapabilityTask.StartingWireState {
        switch physical {
        case .inactive:
            return .inactive
        case .unknown:
            return .unknown
        case .replayRequired:
            return .enabled
        case .enabling, .enabled, .disabling:
            preconditionFailure(
                "An enable operation must start from inactive, unknown, or replay-required wire state."
            )
        }
    }

    private enum CapabilityWireAction: Equatable, Sendable {
        case enable
        case disable
    }

    private func startCapabilityTask(
        id: UInt64,
        key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation,
        action: CapabilityWireAction,
        policy: ConnectionCapabilityTask.Policy,
        startingWireState: ConnectionCapabilityTask.StartingWireState?,
        method: String? = nil
    ) {
        precondition(
            (action == .enable) == (startingWireState != nil),
            "Only enable-class capability operations carry a starting wire state."
        )
        let operation: ConnectionOwnedCommandOperation
        do {
            operation = if let method {
                try makeCapabilityCommandOperation(
                    method: method,
                    for: key,
                    generation: generation,
                    operationID: id,
                    publishesReplay: false
                )
            } else {
                try makeCapabilityCommandOperation(
                    action,
                    for: key,
                    generation: generation,
                    operationID: id
                )
            }
        } catch {
            let result: Result<Void, any Swift.Error> = .failure(
                Self.mapCapabilityError(
                    error,
                    action: action,
                    domain: key.domain,
                    method: method
                )
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
            precondition(capabilityTasks[id] == nil, "A capability operation identifier already has an owner.")
            capabilityTasks[id] = ConnectionCapabilityTask(
                task: task,
                pendingReplyOwnership: nil,
                startingWireState: startingWireState,
                policy: policy
            )
            return
        }

        let task = Task { [weak self, operation] in
            let wireResult: Result<Void, any Swift.Error>
            do {
                _ = try await operation.result()
                if policy == .cssEnableAndSnapshot {
                    guard let self else {
                        return
                    }
                    try await self.requestAndPublishCSSSnapshotIfCurrent(
                        key: key,
                        generation: generation,
                        operationID: id
                    )
                }
                wireResult = .success(())
            } catch {
                wireResult = .failure(
                    Self.mapCapabilityError(
                        error,
                        action: action,
                        domain: key.domain,
                        method: method
                    )
                )
            }
            let result = await self?.initializeInspectorAfterEnableIfNeeded(
                id: id,
                key: key,
                generation: generation,
                action: action,
                wireResult: wireResult
            ) ?? .failure(WebInspectorProxyError.closed)
            _ = await self?.completeCapabilityOperation(
                id: id,
                key: key,
                generation: generation,
                action: action,
                result: result
            )
        }
        precondition(capabilityTasks[id] == nil, "A capability operation identifier already has an owner.")
        capabilityTasks[id] = ConnectionCapabilityTask(
            task: task,
            pendingReplyOwnership: operation.pendingReplyOwnership,
            startingWireState: startingWireState,
            policy: policy
        )
    }

    private func requestAndPublishCSSSnapshotIfCurrent(
        key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation,
        operationID: UInt64
    ) async throws {
        guard let capability = capabilities.states[key],
              case let .enabling(activeGeneration, activeOperationID, _) = capability.physical,
              activeGeneration == generation,
              activeOperationID == operationID,
              capability.desiredCount > 0 else {
            return
        }
        guard var task = capabilityTasks[operationID] else {
            throw WebInspectorProxyError.closed
        }
        // CSS.enable has completed successfully. Any failure from this point
        // belongs to the read-only snapshot while the physical CSS agent is
        // known to remain enabled.
        task.startingWireState = .enabled
        task.policy = .cssSnapshot
        capabilityTasks[operationID] = task
        let operation = try makeCapabilityCommandOperation(
            method: "CSS.getAllStyleSheets",
            for: key,
            generation: generation,
            operationID: operationID,
            publishesReplay: false
        )
        guard var activeTask = capabilityTasks[operationID] else {
            throw WebInspectorProxyError.closed
        }
        activeTask.pendingReplyOwnership = operation.pendingReplyOwnership
        capabilityTasks[operationID] = activeTask
        do {
            _ = try await operation.result()
        } catch {
            throw Self.mapCapabilityError(
                error,
                action: .enable,
                domain: .css,
                method: "CSS.getAllStyleSheets"
            )
        }
    }

    private func makeCapabilityCommandOperation(
        _ action: CapabilityWireAction,
        for key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation,
        operationID: UInt64
    ) throws -> ConnectionOwnedCommandOperation {
        let method: String
        switch action {
        case .enable:
            method = "\(key.domain.rawValue).enable"
        case .disable:
            method = "\(key.domain.rawValue).disable"
        }
        return try makeCapabilityCommandOperation(
            method: method,
            for: key,
            generation: generation,
            operationID: operationID
        )
    }

    private func makeCapabilityCommandOperation(
        method: String,
        for key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation,
        operationID: UInt64,
        publishesReplay: Bool = true
    ) throws -> ConnectionOwnedCommandOperation {
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
        let pendingReply = if publishesReplay {
            TransportSession.PendingReply.capability(
                domain: domain,
                method: method,
                targetID: targetID,
                promise: promise,
                key: key,
                generation: generation,
                operationID: operationID
            )
        } else {
            TransportSession.PendingReply.capabilityAuxiliary(
                domain: domain,
                method: method,
                targetID: targetID,
                promise: promise,
                key: key,
                generation: generation,
                operationID: operationID
            )
        }
        replyStore.insertTargetReply(
            pendingReply,
            key: replyKey,
            rootWrapperID: outerCommandID
        )
        let pendingReplyOwnership = ConnectionPendingReplyOwnership(
            key: pendingKey,
            purpose: pendingReply.purpose
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

        return ConnectionOwnedCommandOperation(
            backend: backend,
            message: wrapperMessage,
            promise: promise,
            pendingReplyOwnership: pendingReplyOwnership,
            timeoutAction: timeoutAction
        )
    }

    private func initializeInspectorAfterEnableIfNeeded(
        id: UInt64,
        key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation,
        action: CapabilityWireAction,
        wireResult: Result<Void, any Swift.Error>
    ) async -> Result<Void, any Swift.Error> {
        guard case .success = wireResult,
              action == .enable,
              key.domain == .inspector else {
            return wireResult
        }
        if inspectorInitializedGeneration[key] == generation {
            return wireResult
        }
        guard let capability = capabilities.states[key],
              case let .enabling(
                  activeGeneration,
                  operationID,
                  mustDisableAfterEnable
              ) = capability.physical,
              activeGeneration == generation,
              operationID == id,
              !mustDisableAfterEnable,
              capability.desiredCount > 0 else {
            return wireResult
        }

        let operation: ConnectionOwnedCommandOperation
        do {
            operation = try makeCapabilityCommandOperation(
                method: "Inspector.initialized",
                for: key,
                generation: generation,
                operationID: id,
                publishesReplay: false
            )
        } catch {
            return .failure(
                Self.mapCapabilityError(
                    error,
                    action: action,
                    domain: key.domain
                )
            )
        }
        guard var task = capabilityTasks[id] else {
            return .failure(WebInspectorProxyError.closed)
        }
        task.pendingReplyOwnership = operation.pendingReplyOwnership
        capabilityTasks[id] = task
        do {
            try await operation.value()
            inspectorInitializedGeneration[key] = generation
            return .success(())
        } catch {
            return .failure(
                Self.mapCapabilityError(
                    error,
                    action: action,
                    domain: key.domain
                )
            )
        }
    }

    private func completeCapabilityOperation(
        id: UInt64,
        key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation,
        action: CapabilityWireAction,
        result: Result<Void, any Swift.Error>
    ) async {
        let task = capabilityTasks.removeValue(forKey: id)
        if let ownership = task?.pendingReplyOwnership,
           let pending = replyStore.removePendingReply(ownership.key) {
            precondition(
                pending.purpose == ownership.purpose,
                "A capability task attempted to remove a reply owned by another purpose."
            )
        }
        guard isOpen, var capability = capabilities.states[key] else {
            return
        }
        let result = Self.normalizeCapabilityResult(
            result,
            action: action,
            domain: key.domain,
            policy: task?.policy ?? .standard
        )

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
                if key.domain == .inspector {
                    await reconcileElementPickerMode(for: key)
                }
                capability.activatedLeaseOwners.formUnion(capability.activationWaiters.keys)
                let waiters = Array(capability.activationWaiters.values)
                capability.activationWaiters.removeAll()
                let releaseWaiters = Array(capability.releaseWaiters.values)
                capability.releaseWaiters.removeAll()
                capabilities.states[key] = capability
                await reconcileCapabilityDependents(of: key)
                for waiter in waiters {
                    waiter.fulfill(.success(()))
                }
                for waiter in releaseWaiters {
                    waiter.fulfill(.success(()))
                }
            case let .failure(error):
                let activeLeaseFailed = capability.hasActivatedDesiredLease
                let startingWireState = task?.startingWireState ?? .unknown
                let failedIDs = Set(capability.activationWaiters.keys)
                capability.failedLeaseOwners.formUnion(failedIDs)
                let activationWaiters = Array(capability.activationWaiters.values)
                capability.activationWaiters.removeAll()

                if startingWireState == .enabled,
                   !Self.isPageUnavailable(error) {
                    // Replay enables and auxiliary snapshots begin with a
                    // physical agent that is already enabled. Their failure
                    // cannot make that agent inactive, regardless of whether
                    // the logical owner was released while awaiting the reply.
                    capability.physical = .enabled(generation: generation)
                    if capability.desiredCount == 0 {
                        capabilities.states[key] = capability
                        startCapabilityDisable(for: key, generation: generation)
                        for waiter in activationWaiters {
                            waiter.fulfill(.failure(error))
                        }
                        return
                    }

                    let releaseWaiters = Array(capability.releaseWaiters.values)
                    capability.releaseWaiters.removeAll()
                    let proposedTerminalCause = Self
                        .terminalCauseForEnabledCapabilityRefreshFailure(
                            error,
                            domain: key.domain
                        )
                    // Claim terminal ownership before resuming any waiter so
                    // actor reentrancy cannot continue against an enabled but
                    // unsynchronized physical agent.
                    let claimedTerminalCause = terminalClaim
                        .claim(proposedTerminalCause)
                        .cause
                    state = .closing
                    capabilities.states[key] = capability
                    for waiter in activationWaiters {
                        waiter.fulfill(.failure(error))
                    }
                    for waiter in releaseWaiters {
                        waiter.fulfill(.failure(error))
                    }
                    await finishClaimedTermination(claimedTerminalCause)
                    return
                }

                let wireStateIsKnownInactive = Self.isPageUnavailable(error)
                    || (
                        startingWireState == .inactive
                            && Self.enableFailureProvesInactive(error)
                    )
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
                    waiter.fulfill(.failure(error))
                }
                for waiter in releaseWaiters {
                    waiter.fulfill(.success(()))
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
                if task?.policy == .replayRefresh,
                   let domain = modelDomain(for: protocolDomain(for: key.domain)) {
                    modelReplaySuppressedDomains[domain] = nil
                }
                await reconcileCapability(for: key)
                await reconcileCapabilityDependenciesAfterCleanup(of: key)
                for waiter in releaseWaiters {
                    waiter.fulfill(.success(()))
                }
            case let .failure(error):
                if Self.isCommandRejection(error), task?.policy != .replayRefresh {
                    // A rejected disable proves that the command did not
                    // deactivate the physical domain. Retain the enabled state
                    // so a late lease can use it and a future final release can
                    // retry cleanup without sending a duplicate enable.
                    capability.physical = .enabled(generation: generation)
                    capability.activatedLeaseOwners.formUnion(capability.activationWaiters.keys)
                    let activationWaiters = Array(capability.activationWaiters.values)
                    capability.activationWaiters.removeAll()
                    let releaseWaiters = Array(capability.releaseWaiters.values)
                    capability.releaseWaiters.removeAll()
                    capabilities.states[key] = capability
                    for waiter in activationWaiters {
                        waiter.fulfill(.success(()))
                    }
                    for waiter in releaseWaiters {
                        waiter.fulfill(.failure(error))
                    }
                    return
                }

                if Self.isPageUnavailable(error) {
                    // Target disappearance normally supersedes the operation
                    // before its completion reaches this branch. If the local
                    // target lookup wins that race, the vanished target makes
                    // cleanup complete without establishing reusable wire state.
                    let failedIDs = Set(capability.activationWaiters.keys)
                    capability.failedLeaseOwners.formUnion(failedIDs)
                    capability.physical = .inactive(generation: generation)
                    let activationWaiters = Array(capability.activationWaiters.values)
                    capability.activationWaiters.removeAll()
                    let releaseWaiters = Array(capability.releaseWaiters.values)
                    capability.releaseWaiters.removeAll()
                    capabilities.states[key] = capability
                    for waiter in activationWaiters {
                        waiter.fulfill(.failure(error))
                    }
                    for waiter in releaseWaiters {
                        waiter.fulfill(.success(()))
                    }
                    return
                }

                let proposedTerminalCause = Self.terminalCauseForUncertainDisableFailure(
                    error,
                    domain: key.domain,
                    wasReplayRefresh: task?.policy == .replayRefresh
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
                    waiter.fulfill(.failure(error))
                }
                for waiter in releaseWaiters {
                    waiter.fulfill(.failure(error))
                }
                await finishClaimedTermination(claimedTerminalCause)
            }

        default:
            // Completion from an older generation or superseded operation can
            // release its task, but it cannot mutate current physical state.
            return
        }
    }

    private nonisolated static func normalizeCapabilityResult(
        _ result: Result<Void, any Swift.Error>,
        action: CapabilityWireAction,
        domain: WebInspectorProxyEventDomain,
        policy: ConnectionCapabilityTask.Policy
    ) -> Result<Void, any Swift.Error> {
        guard policy == .restoredPageEnable,
              action == .enable,
              domain == .page,
              case let .failure(error) = result,
              let error = error as? WebInspectorProxyError,
              case let .commandRejected(method, message) = error,
              method == "Page.enable",
              message == "Page domain already enabled" else {
            return result
        }
        return .success(())
    }

    private nonisolated static func mapCapabilityError(
        _ error: any Swift.Error,
        action: CapabilityWireAction,
        domain: WebInspectorProxyEventDomain,
        method: String? = nil
    ) -> any Swift.Error {
        if let proxyError = error as? WebInspectorProxyError {
            return proxyError
        }
        let method = method
            ?? "\(domain.rawValue).\(action == .enable ? "enable" : "disable")"
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
            return WebInspectorProxyError.timeout(
                domain: domain.rawValue,
                method: method.split(separator: ".").last.map(String.init)
                    ?? (action == .enable ? "enable" : "disable")
            )
        }
    }

    private nonisolated static func mapElementPickerModeError(
        _ error: any Swift.Error,
        enabled: Bool
    ) -> any Swift.Error {
        if let proxyError = error as? WebInspectorProxyError {
            return proxyError
        }
        let method = "DOM.setInspectModeEnabled"
        guard let transportError = error as? TransportSession.Error else {
            return WebInspectorProxyError.transportFailure(
                String(describing: error)
            )
        }
        switch transportError {
        case .transportClosed:
            return WebInspectorProxyError.closed
        case let .transportFailure(message):
            return WebInspectorProxyError.transportFailure(message)
        case let .remoteError(_, _, message):
            return WebInspectorProxyError.commandRejected(
                method: method,
                message: message
            )
        case .missingMainPageTarget, .missingTarget:
            return WebInspectorProxyError.pageUnavailable
        case .malformedMessage:
            return WebInspectorProxyError.protocolViolation(
                "Malformed reply for \(method)."
            )
        case .replyTimeout:
            return WebInspectorProxyError.timeout(
                domain: "DOM",
                method: enabled ? "setInspectModeEnabled(true)" : "setInspectModeEnabled(false)"
            )
        }
    }

    /// Maps a known model-domain activation rejection without deriving the
    /// domain from a wire method string. Transport, protocol, page-lifecycle,
    /// and cancellation failures retain their existing categories because
    /// their recovery is connection- rather than model-domain-specific.
    private nonisolated static func modelFeedActivationError(
        _ error: any Swift.Error,
        domain: ModelDomain
    ) -> any Swift.Error {
        guard let proxyError = error as? WebInspectorProxyError,
              case let .commandRejected(_, message) = proxyError else {
            return error
        }
        return ConnectionModelFeedError.bootstrapFailed(
            domain: domain,
            message: message
        )
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
             .eventBufferOverflow, .connectionInUse,
             .transportFailure, .timeout:
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

    private nonisolated static func terminalCauseForEnabledCapabilityRefreshFailure(
        _ error: any Swift.Error,
        domain: WebInspectorProxyEventDomain
    ) -> TerminalCause {
        if let error = error as? WebInspectorProxyError,
           case let .protocolViolation(message) = error {
            return .protocolViolation(message)
        }
        return .fatal(
            "Failed to refresh \(domain.rawValue) while its physical agent remained enabled: \(error)"
        )
    }

    private nonisolated static func terminalCauseForUncertainDisableFailure(
        _ error: any Swift.Error,
        domain: WebInspectorProxyEventDomain,
        wasReplayRefresh: Bool = false
    ) -> TerminalCause {
        if let error = error as? WebInspectorProxyError,
           case let .protocolViolation(message) = error {
            return .protocolViolation(message)
        }
        let action = wasReplayRefresh ? "refresh" : "disable"
        return .fatal(
            "Failed to \(action) \(domain.rawValue) with an uncertain wire state: \(error)"
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

    private func sendRoot(
        _ command: ProtocolCommand,
        admission: ConnectionDirectCommandAdmission
    ) async throws -> ProtocolCommand.Result {
        let commandID = allocateCommandID()
        let promise = ReplyPromise<ProtocolCommand.Result>()
        try Task.checkCancellation()
        let message = try TransportMessageParser.makeCommandString(
            id: commandID,
            method: command.method,
            parametersData: command.parametersData
        )
        let pending = makeDirectPendingReply(
            domain: command.domain,
            method: command.method,
            targetID: nil,
            promise: promise,
            admission: admission
        )
        replyStore.insertRootReply(pending, commandID: commandID)
        do {
            try await backend.sendJSONString(message)
            try Task.checkCancellation()
        } catch {
            failPendingReply(.root(commandID), error: error)
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
        targetID: ProtocolTarget.ID,
        owner: ConnectionTargetCommandOwner
    ) async throws -> ProtocolCommand.Result {
        let innerCommandID = allocateCommandID()
        let outerCommandID = allocateCommandID()
        let key = TransportSession.ReplyKey(targetID: targetID, commandID: innerCommandID)
        let promise = ReplyPromise<ProtocolCommand.Result>()
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
        let pending: TransportSession.PendingReply = switch owner {
        case let .direct(admission):
            makeDirectPendingReply(
                domain: command.domain,
                method: command.method,
                targetID: targetID,
                promise: promise,
                admission: admission
            )
        case let .elementPickerMode(key, generation, documentEpoch, enabled):
            TransportSession.PendingReply.elementPickerMode(
                targetID: targetID,
                promise: promise,
                key: key,
                generation: generation,
                documentEpoch: documentEpoch,
                enabled: enabled
            )
        }
        replyStore.insertTargetReply(pending, key: key, rootWrapperID: outerCommandID)
        do {
            try await backend.sendJSONString(wrapperMessage)
            try Task.checkCancellation()
        } catch {
            failPendingReply(.target(key), error: error)
            throw error
        }
        return try await awaitReply(
            promise,
            timeout: .target(key),
            method: command.method,
            targetID: targetID
        )
    }

    private func makeDirectPendingReply(
        domain: ProtocolDomain,
        method: String,
        targetID: ProtocolTarget.ID?,
        promise: ReplyPromise<ProtocolCommand.Result>,
        admission: ConnectionDirectCommandAdmission
    ) -> TransportSession.PendingReply {
        TransportSession.PendingReply.direct(
            domain: domain,
            method: method,
            targetID: targetID,
            promise: promise,
            bindingGeneration: admission.bindingGeneration,
            documentEpoch: admission.documentEpoch
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
            failPendingReply(key, error: CancellationError())
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
            return try await promise.value()
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
                resolve(pending, key: .target(key), parsed: parsed)
            }
            return
        }

        if let id = parsed.id,
           let pending = replyStore.removeRootReply(commandID: id) {
            resolve(pending, key: .root(id), parsed: parsed)
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

        let domain = ProtocolDomain(method: method)
        // Root event sequences are reserved before registry mutation. Target
        // snapshot watermarks can therefore subsume the exact lifecycle event
        // that installed their physical binding without an N/N+1 gap.
        let eventSequence = eventSequences.recordEvent(domain: domain)
        let targetID = targetIDForRootEvent(method: method, paramsData: parsed.paramsData)
        let sourceTargetID = sourceTargetIDForRootEvent(method: method, targetID: targetID)
        let destroyedCurrentMainPageTarget = method == "Target.targetDestroyed"
            && targetID != nil
            && targetID == targetRegistry.currentMainPageTargetID
        let mutation: RootEventMutation
        do {
            mutation = try updateRegistryFromRootEvent(
                method: method,
                targetID: targetID,
                sourceTargetID: sourceTargetID,
                paramsData: parsed.paramsData,
                eventSequence: eventSequence.sequence
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
        // Registry mutation and model-feed snapshot/delta publication above are
        // one synchronous prefix. Preserve the existing direct-consumer order
        // by reconciling capability ownership and disappearance effects before
        // publishing the corresponding root event.
        await completeRootEventMutation(mutation)
        guard isOpen else {
            return
        }
        let emission = emit(
            domain: domain,
            method: method,
            targetID: targetID,
            sourceTargetID: sourceTargetID,
            paramsData: parsed.paramsData,
            destroyedCurrentMainPageTarget: destroyedCurrentMainPageTarget,
            reservedEventSequence: eventSequence
        )
        await completeEventEmissionEffects(emission)
        guard isOpen else {
            return
        }
        await emitResolvedStyleSheetAddedEvents(mutation.pendingStyleSheetEvents)
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
                resolve(pending, key: .target(key), parsed: parsed)
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
        let emission = emit(
            domain: ProtocolDomain(method: method),
            method: method,
            targetID: emittedTargetID,
            sourceTargetID: targetID,
            paramsData: parsed.paramsData
        )
        await completeEventEmissionEffects(emission)
    }

    private func resolve(
        _ pending: TransportSession.PendingReply,
        key: TransportSession.PendingKey,
        parsed: ParsedProtocolMessage
    ) {
        validateReplyOwnership(pending, key: key)
        if let errorMessage = parsed.errorMessage {
            pending.promise.fulfill(
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
        let result = ProtocolCommand.Result(
            domain: pending.domain,
            method: pending.method,
            targetID: pending.targetID,
            receivedSequence: eventSequence.sequence,
            receivedDomainSequences: eventSequence.receivedDomainSequences,
            resultData: parsed.resultData
        )
        do {
            try processSuccessfulReply(result, for: pending)
        } catch {
            let message = "Failed to decode \(pending.method) reply: \(error)"
            handoffTermination(.protocolViolation(message))
            pending.promise.fulfill(
                .failure(WebInspectorProxyError.protocolViolation(message))
            )
            return
        }
        pending.promise.fulfill(
            .success(result)
        )
    }

    private func validateReplyOwnership(
        _ pending: TransportSession.PendingReply,
        key: TransportSession.PendingKey
    ) {
        switch pending.purpose {
        case .direct:
            break
        case let .elementPickerMode(key, generation, _, enabled):
            precondition(
                pending.method == "DOM.setInspectModeEnabled",
                "An element-picker reply has the wrong command owner."
            )
            guard let mode = elementPickerModes[key],
                  mode.physical.generation == generation else {
                preconditionFailure(
                    "An element-picker reply has no matching generation owner."
                )
            }
            switch (enabled, mode.physical) {
            case (true, .enabling), (false, .disabling):
                break
            case (true, _), (false, _):
                preconditionFailure(
                    "An element-picker reply does not match its active transition."
                )
            }
        case let .modelCommand(_, operationID):
            guard let ownership = modelCommandTasks[operationID]?.pendingReplyOwnership else {
                preconditionFailure("A model command reply has no model command task owner.")
            }
            precondition(
                ownership.key == key,
                "A model command reply key does not match its operation owner."
            )
            precondition(
                ownership.purpose == pending.purpose,
                "A model command reply purpose does not match its operation owner."
            )
        case let .capability(_, _, operationID),
             let .capabilityAuxiliary(_, _, operationID):
            guard let ownership = capabilityTasks[operationID]?.pendingReplyOwnership else {
                preconditionFailure("A capability reply has no capability operation owner.")
            }
            precondition(
                ownership.key == key,
                "A capability reply key does not match its operation owner."
            )
            precondition(
                ownership.purpose == pending.purpose,
                "A capability reply purpose does not match its operation owner."
            )
        case let .modelBootstrap(_, _, _, _, operationID):
            guard let ownership = modelBootstrapTasks[operationID]?.pendingReplyOwnership else {
                preconditionFailure("A model bootstrap reply has no task owner.")
            }
            precondition(
                ownership.key == key,
                "A model bootstrap reply key does not match its task owner."
            )
            precondition(
                ownership.purpose == pending.purpose,
                "A model bootstrap reply purpose does not match its task owner."
            )
        }
    }

    /// Synchronous phase boundary for successful reply-side effects.
    ///
    /// Model replay boundaries remain in this actor's inbound processing slot
    /// before `ReplyPromise.fulfill` resumes the waiting capability operation.
    private func processSuccessfulReply(
        _ result: ProtocolCommand.Result,
        for pending: TransportSession.PendingReply
    ) throws {
        switch pending.purpose {
        case .direct, .modelCommand:
            // Consumer replies have no internal publication side effect.
            break
        case let .capabilityAuxiliary(key, generation, operationID):
            guard pending.method == "CSS.getAllStyleSheets" else {
                break
            }
            guard capabilityTasks[operationID]?.policy == .cssSnapshot else {
                preconditionFailure(
                    "A CSS snapshot reply has no snapshot capability owner."
                )
            }
            try publishCSSSnapshotIfCurrent(
                result,
                key: key,
                generation: generation,
                operationID: operationID
            )
        case let .elementPickerMode(key, generation, _, enabled):
            publishElementPickerModeReplyIfCurrent(
                result,
                key: key,
                generation: generation,
                enabled: enabled
            )
        case let .capability(key, generation, operationID):
            publishModelReplayCompletionIfNeeded(
                result,
                pending: pending,
                key: key,
                generation: generation,
                operationID: operationID
            )
        case let .modelBootstrap(
            feedID,
            generation,
            targetID,
            documentEpoch,
            operationID
        ):
            try publishDOMBootstrapSnapshotIfCurrent(
                result,
                feedID: feedID,
                generation: generation,
                targetID: targetID,
                documentEpoch: documentEpoch,
                operationID: operationID
            )
        }
    }

    /// Publishes the picker activation watermark in the same inbound slot as
    /// its successful wire reply. WebKit may emit `Inspector.inspect`
    /// immediately after that reply; waiting for the command continuation to
    /// resume would incorrectly classify the event as pre-activation.
    private func publishElementPickerModeReplyIfCurrent(
        _ result: ProtocolCommand.Result,
        key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation,
        enabled: Bool
    ) {
        guard enabled,
              result.method == "DOM.setInspectModeEnabled",
              result.targetID == targetRegistry.currentMainPageTargetID,
              generation == currentPageGeneration,
              var mode = elementPickerModes[key],
              case .enabling(generation) = mode.physical else {
            return
        }
        for owner in mode.owners {
            mode.activatedThrough[owner] = result.receivedSequence
        }
        elementPickerModes[key] = mode
    }

    private func publishDOMBootstrapSnapshotIfCurrent(
        _ result: ProtocolCommand.Result,
        feedID: ConnectionModelFeedID,
        generation: WebInspectorPage.Generation,
        targetID: ProtocolTarget.ID,
        documentEpoch: ModelDocumentEpoch,
        operationID: UInt64
    ) throws {
        guard var registration = modelFeed,
              registration.id == feedID,
              var bootstrap = registration.domBootstrap,
              bootstrap.generation == generation,
              var active = bootstrap.activeOperation,
              active.id == operationID,
              active.targetID == targetID,
              active.documentEpoch == documentEpoch else {
            // A superseded binding no longer owns this operation. Its task
            // completion is ignored by the same generation/operation guards.
            return
        }

        guard generation == currentPageGeneration,
              modelDocumentEpoch(for: targetID) == documentEpoch,
              let targetState = bootstrap.targetsByID[targetID],
              let physicalRecord = targetRegistry.target(for: targetID),
              targetRegistry.isCurrentPageModelTarget(physicalRecord) else {
            // Superseded generation, membership, target, or document replies
            // are normal stale results and cannot publish into current state.
            active.replyDisposition = .stale
            bootstrap.activeOperation = active
            registration.domBootstrap = bootstrap
            modelFeed = registration
            return
        }
        precondition(
            result.targetID == targetID,
            "A DOM bootstrap reply does not belong to its physical target."
        )
        let document = try JSONDecoder()
            .decode(ProtocolDOMDocumentResult.self, from: result.resultData)
            .proxyRoot()
        let projectedDocument = ConnectionEventProjection.projectedDOMBootstrapNode(
            document,
            target: targetState.target
        )
        guard enqueueModelFeedRecord(
            .bootstrapSnapshot(
                generation: generation,
                domain: .dom,
                sequence: result.receivedSequence,
                payload: .domDocument(
                    target: targetState.target,
                    documentEpoch: documentEpoch,
                    root: projectedDocument
                )
            )
        ) else {
            active.replyDisposition = .terminal
            bootstrap.activeOperation = active
            registration.domBootstrap = bootstrap
            modelFeed = registration
            return
        }
        bootstrap.targetsByID[targetID]?.completedEpoch = documentEpoch
        active.replyDisposition = .published
        bootstrap.activeOperation = active
        registration.domBootstrap = bootstrap
        modelFeed = registration
        _ = publishDOMBootstrapCompletionIfReady(
            through: result.receivedSequence
        )
    }

    private func publishCSSSnapshotIfCurrent(
        _ result: ProtocolCommand.Result,
        key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation,
        operationID: UInt64
    ) throws {
        guard isOpen,
              generation == currentPageGeneration,
              result.targetID == targetRegistry.currentMainPageTargetID,
              let capability = capabilities.states[key],
              case let .enabling(activeGeneration, activeOperationID, _) = capability.physical,
              activeGeneration == generation,
              activeOperationID == operationID else {
            return
        }
        let resultPayload: CSSAllStyleSheetsResult
        do {
            resultPayload = try JSONDecoder().decode(
                CSSAllStyleSheetsResult.self,
                from: result.resultData
            )
        } catch {
            throw WebInspectorProxyError.protocolViolation(
                "Failed to decode CSS.getAllStyleSheets reply: \(error)"
            )
        }
        guard let targetSnapshot = targetRegistry.modelTargetSnapshot() else {
            preconditionFailure("A CSS snapshot has no current model target snapshot.")
        }
        let currentTarget = targetSnapshot.targets.first {
            $0.id == targetSnapshot.currentPageID
        }
        guard let currentTarget else {
            preconditionFailure("A CSS snapshot has no current page target.")
        }
        let targetsByFrameID = Dictionary(
            uniqueKeysWithValues: targetSnapshot.targets.compactMap { target in
                target.frameID.map { ($0, target) }
            }
        )
        let styleSheets = resultPayload.headers.map { payload in
            let header = payload.proxyHeader
            let target = header.frameID.flatMap { targetsByFrameID[$0] }
                ?? currentTarget
            return ModelCSSStyleSheet(
                target: target,
                header: ConnectionEventProjection.projectedCSSStyleSheetHeader(
                    header,
                    target: target
                )
            )
        }

        for target in targetSnapshot.targets {
            styleSheetRouting.removeTarget(ProtocolTarget.ID(target.id.rawValue))
        }
        for (payload, styleSheet) in zip(resultPayload.headers, styleSheets) {
            styleSheetRouting.recordAdded(
                styleSheetID: payload.styleSheetId,
                frameID: payload.frameId.map { ProtocolFrame.ID($0) },
                paramsData: Data(),
                resolvedTargetID: ProtocolTarget.ID(styleSheet.target.id.rawValue)
            )
        }

        guard let registration = modelFeed,
              registration.configuredDomains.contains(.css),
              registration.synchronization?.generation == generation,
              capability.desiredLeaseOwners.contains(
                  .modelFeed(registration.id, .css)
              ) else {
            return
        }
        guard enqueueModelFeedRecord(
            .bootstrapSnapshot(
                generation: generation,
                domain: .css,
                sequence: result.receivedSequence,
                payload: .cssStyleSheets(styleSheets)
            )
        ) else {
            return
        }
        guard enqueueModelFeedRecord(
            .bootstrapComplete(
                generation: generation,
                domain: .css,
                through: result.receivedSequence
            )
        ) else {
            return
        }
        _ = completeModelDomain(.css, generation: generation)
    }

    private func publishModelReplayCompletionIfNeeded(
        _ result: ProtocolCommand.Result,
        pending: TransportSession.PendingReply,
        key: ConnectionCapabilityKey,
        generation: WebInspectorPage.Generation,
        operationID: UInt64
    ) {
        let enableMethod = "\(key.domain.rawValue).enable"
        let disableMethod = "\(key.domain.rawValue).disable"
        guard pending.method != disableMethod else {
            return
        }
        precondition(
            pending.method == enableMethod,
            "A capability reply does not match its enable or disable operation."
        )
        guard let capability = capabilities.states[key],
              case let .enabling(activeGeneration, activeOperationID, _) = capability.physical,
              activeGeneration == generation,
              activeOperationID == operationID else {
            // A reply from a superseded physical binding cannot publish a
            // boundary into the current model generation.
            return
        }
        guard let registration = modelFeed else {
            return
        }
        guard let synchronization = registration.synchronization,
              synchronization.generation == generation else {
            return
        }
        let replayDomains = ModelDomain.ordered(registration.configuredDomains).filter { domain in
            domain.replayCapability == key.domain
                && capability.desiredLeaseOwners.contains(.modelFeed(registration.id, domain))
        }
        guard !replayDomains.isEmpty else {
            return
        }
        precondition(
            key.route == .currentPage && key.targetID == .currentPage,
            "A model feed capability must use the semantic current-page route."
        )
        precondition(
            generation == currentPageGeneration,
            "A current model-feed capability reply must match the current page generation."
        )
        precondition(
            pending.targetID == targetRegistry.currentMainPageTargetID,
            "A current model-feed capability reply must belong to the current physical target."
        )

        for domain in replayDomains {
            precondition(
                !synchronization.completedDomains.contains(domain),
                "A model feed received duplicate replay completion in one binding generation."
            )
            guard enqueueModelFeedRecord(
                .replayComplete(
                    generation: generation,
                    domain: domain,
                    through: result.receivedSequence
                )
            ) else {
                // enqueueModelFeedRecord synchronously claims terminal
                // ownership for overflow or a terminated consumer.
                return
            }
            guard completeModelDomain(domain, generation: generation) else {
                return
            }
        }
    }

    private func updateRegistryFromRootEvent(
        method: String,
        targetID: ProtocolTarget.ID?,
        sourceTargetID: ProtocolTarget.ID?,
        paramsData: Data,
        eventSequence: UInt64
    ) throws -> RootEventMutation {
        switch method {
        case "Target.targetCreated":
            let params = try TransportMessageParser.decode(TargetCreatedParams.self, from: paramsData)
            return applyTargetCreated(
                record(for: params.targetInfo),
                eventSequence: eventSequence
            )
        case "Target.targetDestroyed":
            let params = try TransportMessageParser.decode(TargetDestroyedParams.self, from: paramsData)
            return applyTargetDestroyed(
                params.targetId,
                eventSequence: eventSequence
            )
        case "Target.didCommitProvisionalTarget":
            let params = try TransportMessageParser.decode(TargetCommittedParams.self, from: paramsData)
            return applyTargetCommitted(
                oldTargetID: params.oldTargetId,
                newTargetID: params.newTargetId,
                eventSequence: eventSequence
            )
        case "Runtime.executionContextCreated", "Runtime.executionContextDestroyed", "Runtime.executionContextsCleared":
            updateRegistryFromTargetEvent(
                method: method,
                targetID: targetID,
                sourceTargetID: sourceTargetID,
                paramsData: paramsData
            )
            return RootEventMutation()
        case "CSS.styleSheetAdded", "CSS.styleSheetRemoved":
            updateCSSStyleSheetRegistry(method: method, targetID: targetID, paramsData: paramsData)
            return RootEventMutation()
        default:
            return RootEventMutation()
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

    private func applyTargetCreated(
        _ record: ProtocolTarget.Record,
        eventSequence: UInt64
    ) -> RootEventMutation {
        let previousMainPageTargetID = targetRegistry.currentMainPageTargetID
        let resolution = targetRegistry.recordTargetCreated(record)
        modelTargetMutationActionForTesting?()
        let bindingEffects = prepareCurrentPageBindingChange(
            from: previousMainPageTargetID,
            to: targetRegistry.currentMainPageTargetID
        )
        if targetRegistry.isCurrentPageModelTarget(record),
           let target = ModelTarget(record: record) {
            publishModelTargetLifecycleEvent(
                .targetCreated(target),
                sequence: eventSequence
            )
        }
        reconcileDOMBootstrapTargets()
        return RootEventMutation(
            pendingStyleSheetEvents: isOpen ? resolvePendingStyleSheets(for: resolution) : [],
            bindingEffects: bindingEffects
        )
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

    private func applyTargetDestroyed(
        _ targetID: ProtocolTarget.ID,
        eventSequence: UInt64
    ) -> RootEventMutation {
        let previousMainPageTargetID = targetRegistry.currentMainPageTargetID
        let destroyedRecord = targetRegistry.target(for: targetID)
        let destroyedTargetWasCurrent = destroyedRecord.map(
            targetRegistry.isCurrentPageModelTarget
        ) ?? false
        targetRegistry.removeTarget(targetID)
        modelDocumentEpochs.removeValue(forKey: targetID)
        modelTargetMutationActionForTesting?()
        let capabilityWaiters = physicalTargetDidDisappear(targetID)
        provisionalTargetMessageStore.removeTarget(targetID)
        styleSheetRouting.removeTarget(targetID)
        runtimeContextRegistry.removeTarget(targetID)
        let bindingEffects = prepareCurrentPageBindingChange(
            from: previousMainPageTargetID,
            to: targetRegistry.currentMainPageTargetID
        )
        let pendingReplies = replyStore.removeTargetReplies(for: targetID)
        if destroyedTargetWasCurrent,
           let destroyedRecord,
           let target = ModelTarget(record: destroyedRecord) {
            publishModelTargetLifecycleEvent(
                .targetDestroyed(target),
                sequence: eventSequence
            )
        }
        reconcileDOMBootstrapTargets()
        return RootEventMutation(
            bindingEffects: bindingEffects,
            physicalTargetWaiters: capabilityWaiters,
            commandInvalidation: ConnectionCommandInvalidationEffects(
                pendingFailures: pendingReplies.map {
                    ConnectionPendingReplyFailure(
                        pending: $0,
                        reason: .missingTarget(targetID)
                    )
                }
            )
        )
    }

    private func applyTargetCommitted(
        oldTargetID: ProtocolTarget.ID,
        newTargetID: ProtocolTarget.ID,
        eventSequence: UInt64
    ) -> RootEventMutation {
        let previousMainPageTargetID = targetRegistry.currentMainPageTargetID
        let mutation = targetRegistry.commitTarget(oldTargetID: oldTargetID, newTargetID: newTargetID)
        modelTargetMutationActionForTesting?()
        var capabilityWaiters = PhysicalTargetDisappearanceWaiters()
        var disappearedTargetID: ProtocolTarget.ID?

        if mutation.shouldRetargetExternalState {
            let oldTargetID = mutation.committedOldTargetID
            capabilityWaiters = physicalTargetDidDisappear(oldTargetID)
            disappearedTargetID = oldTargetID
            provisionalTargetMessageStore.removeTarget(oldTargetID)
            styleSheetRouting.retarget(from: oldTargetID, to: newTargetID)
            runtimeContextRegistry.retarget(oldTargetID: oldTargetID, newTargetID: newTargetID)
        }

        let bindingEffects = prepareCurrentPageBindingChange(
            from: previousMainPageTargetID,
            to: targetRegistry.currentMainPageTargetID
        )
        let remainingPendingReplies = disappearedTargetID.map {
            replyStore.removeTargetReplies(for: $0)
        } ?? []
        if let newRecord = targetRegistry.target(for: newTargetID),
           targetRegistry.isCurrentPageModelTarget(newRecord),
           let newTarget = ModelTarget(record: newRecord) {
            publishModelTargetLifecycleEvent(
                .didCommitProvisionalTarget(
                    oldTargetID: WebInspectorTarget.ID(oldTargetID.rawValue),
                    newTarget: newTarget
                ),
                sequence: eventSequence
            )
        }
        modelDocumentEpochs.removeValue(forKey: oldTargetID)
        reconcileDOMBootstrapTargets()
        return RootEventMutation(
            pendingStyleSheetEvents: isOpen
                ? resolvePendingStyleSheets(for: mutation.resolvedFrameTarget)
                : [],
            bindingEffects: bindingEffects,
            physicalTargetWaiters: capabilityWaiters,
            commandInvalidation: ConnectionCommandInvalidationEffects(
                pendingFailures: remainingPendingReplies.map {
                    ConnectionPendingReplyFailure(
                        pending: $0,
                        reason: .missingTarget(mutation.committedOldTargetID)
                    )
                }
            )
        )
    }

    private func prepareCurrentPageBindingChange(
        from oldTargetID: ProtocolTarget.ID?,
        to newTargetID: ProtocolTarget.ID?
    ) -> CurrentPageBindingChangeEffects {
        guard oldTargetID != newTargetID else {
            return CurrentPageBindingChangeEffects()
        }

        if let oldTargetID {
            rememberCurrentPageCapabilities(for: oldTargetID)
        }

        let obsoleteBootstrapTasks = cancelModelBootstrapTasks(
            generation: currentPageGeneration
        )

        if oldTargetID == nil,
           newTargetID != nil,
           currentPageBindingGapIsOpen {
            // The old -> nil transition already opened the replacement
            // generation and published its reset. Installing the replacement
            // only reactivates that generation; a second generation would
            // expose an empty intermediate binding as another logical page
            // transition.
            currentPageBindingGapIsOpen = false
            let prepared = prepareCurrentPageCapabilities(for: newTargetID)
            publishModelBindingChange(hasCurrentBinding: true)
            guard isOpen else {
                return CurrentPageBindingChangeEffects()
            }
            return CurrentPageBindingChangeEffects(
                capabilityKeysToReconcile: prepared.keys,
                releaseWaiters: prepared.releaseWaiters,
                modelBootstrapTasksToAwait: obsoleteBootstrapTasks
            )
        }

        let oldGeneration = currentPageGeneration
        var commandInvalidation = invalidateModelCommands(
            where: { $0.authorization.generation == oldGeneration },
            failureOverride: .staleIdentifier,
            pendingFailureReason: .staleIdentifier
        )
        let bindingReplies = replyStore.removePendingReplies { pending in
            switch pending.purpose {
            case let .direct(bindingGeneration, _):
                return bindingGeneration == oldGeneration
            case let .elementPickerMode(_, generation, _, _):
                return generation == oldGeneration
            case .modelCommand, .capability, .capabilityAuxiliary, .modelBootstrap:
                return false
            }
        }
        commandInvalidation.pendingFailures.append(contentsOf: bindingReplies.map {
            ConnectionPendingReplyFailure(pending: $0, reason: .staleIdentifier)
        })

        currentPageBindingGapIsOpen = oldTargetID != nil && newTargetID == nil
        currentPageGeneration = WebInspectorPage.Generation(
            rawValue: currentPageGeneration.rawValue &+ 1
        )
        for key in elementPickerModes.keys where key.route == .currentPage {
            guard var mode = elementPickerModes[key] else {
                continue
            }
            mode.physical = .inactive(currentPageGeneration)
            mode.activatedThrough.removeAll(keepingCapacity: true)
            elementPickerModes[key] = mode
        }
        eventScopes.publishReset(currentPageGeneration) { sink in
            sink.route == .currentPage
        }
        publishModelBindingChange(hasCurrentBinding: newTargetID != nil)
        guard isOpen else {
            return CurrentPageBindingChangeEffects(
                modelBootstrapTasksToAwait: obsoleteBootstrapTasks,
                commandInvalidation: commandInvalidation
            )
        }

        let prepared = prepareCurrentPageCapabilities(for: newTargetID)

        return CurrentPageBindingChangeEffects(
            capabilityKeysToReconcile: newTargetID == nil ? [] : prepared.keys,
            releaseWaiters: prepared.releaseWaiters,
            modelBootstrapTasksToAwait: obsoleteBootstrapTasks,
            commandInvalidation: commandInvalidation
        )
    }

    private func rememberCurrentPageCapabilities(for targetID: ProtocolTarget.ID) {
        var remembered: [
            WebInspectorProxyEventDomain: RememberedCurrentPageCapabilityState
        ] = [:]
        for (key, capability) in capabilities.states where key.route == .currentPage {
            guard key.domain != .dom, key.domain != .target else {
                continue
            }
            remembered[key.domain] = switch capability.physical {
            case .inactive:
                .inactive
            case .enabled, .replayRequired:
                .enabled
            case .unknown, .enabling, .disabling:
                .unknown
            }
        }
        parkCurrentPageCapabilities(remembered, for: targetID)
    }

    private func parkCurrentPageCapabilities(
        _ capabilities: [
            WebInspectorProxyEventDomain: RememberedCurrentPageCapabilityState
        ],
        for targetID: ProtocolTarget.ID
    ) {
        parkedCurrentPageCapabilityLedger[targetID] = capabilities
        parkedCurrentPageCapabilityLedgerOrder.removeAll { $0 == targetID }
        parkedCurrentPageCapabilityLedgerOrder.append(targetID)

        while parkedCurrentPageCapabilityLedgerOrder.count
                > Self.parkedCurrentPageTargetRetentionLimit {
            let evictedTargetID = parkedCurrentPageCapabilityLedgerOrder.removeFirst()
            parkedCurrentPageCapabilityLedger[evictedTargetID] = nil
        }
    }

    private func takeParkedCurrentPageCapabilities(
        for targetID: ProtocolTarget.ID
    ) -> [
        WebInspectorProxyEventDomain: RememberedCurrentPageCapabilityState
    ]? {
        let capabilities = parkedCurrentPageCapabilityLedger.removeValue(
            forKey: targetID
        )
        if capabilities != nil {
            parkedCurrentPageCapabilityLedgerOrder.removeAll { $0 == targetID }
        }
        return capabilities
    }

    private func prepareCurrentPageCapabilities(
        for targetID: ProtocolTarget.ID?
    ) -> (keys: [ConnectionCapabilityKey], releaseWaiters: [ReplyPromise<Void>]) {
        let remembered: [
            WebInspectorProxyEventDomain: RememberedCurrentPageCapabilityState
        ]?
        if let targetID {
            remembered = takeParkedCurrentPageCapabilities(for: targetID)
        } else {
            remembered = nil
        }
        modelReplaySuppressedDomains.removeAll(keepingCapacity: true)
        var keys = Set(capabilities.states.keys.filter { $0.route == .currentPage })

        if targetID != nil, let remembered {
            for (domain, state) in remembered where state != .inactive {
                guard domain != .dom, domain != .target else {
                    continue
                }
                keys.insert(ConnectionCapabilityKey(
                    route: .currentPage,
                    targetID: .currentPage,
                    domain: domain
                ))
            }
        }

        var releaseWaiters: [ReplyPromise<Void>] = []
        for key in keys {
            var capability = capabilities.states[key]
                ?? ConnectionCapabilityRegistry.State(
                    physical: .inactive(generation: currentPageGeneration)
                )
            releaseWaiters.append(contentsOf: capability.releaseWaiters.values)
            capability.releaseWaiters.removeAll()
            let modelFeedOwnsDomain = currentModelFeedOwns(
                key.domain,
                capability: capability
            )
            capability.physical = restoredCurrentPagePhysicalState(
                domain: key.domain,
                remembered: remembered?[key.domain],
                hasBinding: targetID != nil,
                modelFeedOwnsDomain: modelFeedOwnsDomain
            )
            capabilities.states[key] = capability

            if modelFeedOwnsDomain,
               (key.domain == .console || key.domain == .runtime) {
                switch capability.physical {
                case .unknown, .replayRequired:
                    let domain = key.domain == .console
                        ? ModelDomain.console
                        : ModelDomain.runtime
                    modelReplaySuppressedDomains[domain] = currentPageGeneration
                case .inactive, .enabling, .enabled, .disabling:
                    break
                }
            }

            if key.domain == .inspector {
                if case .enabled = capability.physical {
                    inspectorInitializedGeneration[key] = currentPageGeneration
                } else {
                    inspectorInitializedGeneration[key] = nil
                }
            }
        }

        return (
            keys: keys.sorted(by: currentPageCapabilityReconciliationPrecedes),
            releaseWaiters: releaseWaiters
        )
    }

    private func restoredCurrentPagePhysicalState(
        domain: WebInspectorProxyEventDomain,
        remembered: RememberedCurrentPageCapabilityState?,
        hasBinding: Bool,
        modelFeedOwnsDomain: Bool
    ) -> ConnectionCapabilityRegistry.PhysicalState {
        guard hasBinding, domain != .dom else {
            return .inactive(generation: currentPageGeneration)
        }
        switch remembered {
        case .inactive, nil:
            return .inactive(generation: currentPageGeneration)
        case .enabled:
            switch domain {
            case .page, .inspector:
                return .enabled(generation: currentPageGeneration)
            case .css, .console, .runtime:
                guard modelFeedOwnsDomain else {
                    return .enabled(generation: currentPageGeneration)
                }
                return .replayRequired(generation: currentPageGeneration)
            case .network:
                // WebKit's Network.enable is idempotent and republishes every
                // active WebSocket. Both model feeds and direct event scopes
                // need that replay after their logical generation resets.
                return .replayRequired(generation: currentPageGeneration)
            case .dom:
                return .inactive(generation: currentPageGeneration)
            case .target:
                preconditionFailure("Target is not an acquirable capability domain.")
            }
        case .unknown:
            return .unknown(generation: currentPageGeneration)
        }
    }

    private func currentModelFeedOwns(
        _ domain: WebInspectorProxyEventDomain,
        capability: ConnectionCapabilityRegistry.State
    ) -> Bool {
        guard let registration = modelFeed,
              let modelDomain = modelDomain(for: protocolDomain(for: domain)),
              registration.configuredDomains.contains(modelDomain) else {
            return false
        }
        return capability.desiredLeaseOwners.contains(
            .modelFeed(registration.id, modelDomain)
        )
    }

    private func currentPageCapabilityReconciliationPrecedes(
        _ lhs: ConnectionCapabilityKey,
        _ rhs: ConnectionCapabilityKey
    ) -> Bool {
        let lhsRank = currentPageCapabilityRank(lhs.domain)
        let rhsRank = currentPageCapabilityRank(rhs.domain)
        let lhsIsDesired = capabilities.states[lhs]?.desiredCount ?? 0 > 0
        let rhsIsDesired = capabilities.states[rhs]?.desiredCount ?? 0 > 0
        if lhsIsDesired != rhsIsDesired {
            return lhsIsDesired
        }
        if lhsRank != rhsRank {
            return lhsIsDesired ? lhsRank < rhsRank : lhsRank > rhsRank
        }
        return lhs.domain.rawValue < rhs.domain.rawValue
    }

    private func currentPageCapabilityRank(
        _ domain: WebInspectorProxyEventDomain
    ) -> Int {
        switch domain {
        case .page:
            0
        case .dom:
            1
        case .inspector:
            2
        case .css:
            3
        case .network:
            4
        case .console:
            5
        case .runtime:
            6
        case .target:
            preconditionFailure("Target is not an acquirable capability domain.")
        }
    }

    private func completeCurrentPageBindingChange(
        _ effects: CurrentPageBindingChangeEffects
    ) async {
        await completeCommandInvalidationEffects(effects.commandInvalidation)
        for task in effects.modelBootstrapTasksToAwait {
            await task.value
        }
        for key in effects.capabilityKeysToReconcile {
            await reconcileCapability(for: key)
            if !isOpen {
                break
            }
        }
        for waiter in effects.releaseWaiters {
            waiter.fulfill(.success(()))
        }
    }

    private func cancelModelBootstrapTasks(
        generation: WebInspectorPage.Generation
    ) -> [Task<Void, Never>] {
        guard let feedID = modelFeed?.id else {
            return []
        }
        let tasks = modelBootstrapTasks.values.filter {
            $0.feedID == feedID && $0.generation == generation
        }.map(\.task)
        for task in tasks {
            task.cancel()
        }
        return tasks
    }

    private func completeRootEventMutation(
        _ mutation: RootEventMutation
    ) async {
        await completeCurrentPageBindingChange(mutation.bindingEffects)
        resumePhysicalTargetDisappearanceWaiters(
            mutation.physicalTargetWaiters
        )
        await completeCommandInvalidationEffects(mutation.commandInvalidation)
    }

    private func publishModelBindingChange(hasCurrentBinding: Bool) {
        guard var registration = modelFeed else {
            return
        }
        if registration.targetSnapshotThrough != nil {
            registration.targetSnapshotThrough = nil
            registration.resetGeneration = currentPageGeneration
            registration.synchronization = nil
            registration.domBootstrap = nil
            modelFeed = registration
            guard enqueueModelFeedRecord(.reset(currentPageGeneration)) else {
                return
            }
        }
        if hasCurrentBinding {
            precondition(
                registration.resetGeneration == currentPageGeneration,
                "A model target snapshot must use the generation established by its preceding reset."
            )
            _ = publishModelTargetSnapshot()
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
            capability.failedLeaseOwners.formUnion(capability.activationWaiters.keys)
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
    ) {
        for waiter in waiters.activation {
            waiter.fulfill(.failure(WebInspectorProxyError.pageUnavailable))
        }
        for waiter in waiters.release {
            waiter.fulfill(.success(()))
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
            let emission = emit(
                domain: .css,
                method: "CSS.styleSheetAdded",
                targetID: event.targetID,
                paramsData: event.paramsData
            )
            await completeEventEmissionEffects(emission)
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
        destroyedCurrentMainPageTarget: Bool = false,
        reservedEventSequence: TransportEventSequenceSnapshot? = nil
    ) -> EventEmissionEffects {
        guard isOpen else {
            return EventEmissionEffects()
        }
        let eventSequence: TransportEventSequenceSnapshot
        if let reservedEventSequence {
            precondition(
                reservedEventSequence.sequence == eventSequences.current.sequence,
                "A reserved root event sequence was not published before another event advanced the feed watermark."
            )
            precondition(
                reservedEventSequence.receivedDomainSequences[domain]
                    == reservedEventSequence.sequence,
                "A reserved root event sequence does not own its protocol domain watermark."
            )
            eventSequence = reservedEventSequence
        } else {
            eventSequence = eventSequences.recordEvent(domain: domain)
        }
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
        // WebKit invalidates every bound node identifier before emitting
        // documentUpdated. Advance the target epoch and publish its dedicated
        // model boundary before this event can reach any later model delta.
        let commandInvalidation = prepareDOMDocumentUpdateForModelFeed(envelope)
        guard isOpen else {
            return EventEmissionEffects(commandInvalidation: commandInvalidation)
        }
        if let eventDomain = webInspectorEventDomain(for: domain) {
            var terminalViolation: String?
            let targetSnapshot = snapshot()
            let sinks = eventScopes.sinks(for: eventDomain).filter { sink in
                guard ConnectionEventProjection.shouldDeliver(
                    envelope,
                    to: sink.route,
                    in: targetSnapshot
                ) else {
                    return false
                }
                guard eventDomain == .inspector else {
                    return true
                }
                let key = ConnectionCapabilityKey(
                    route: sink.route,
                    targetID: sink.targetID,
                    domain: .inspector
                )
                return elementPickerShouldDeliver(
                    eventSequence.sequence,
                    to: .eventScope(sink.id),
                    key: key
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
                return EventEmissionEffects(commandInvalidation: commandInvalidation)
            }
        }
        do {
            try publishConfiguredModelEvent(
                envelope,
                in: snapshot()
            )
        } catch {
            handoffTermination(
                .protocolViolation("Failed to decode \(method): \(error)")
            )
            return EventEmissionEffects(commandInvalidation: commandInvalidation)
        }
        startNextDOMBootstrapIfNeeded()
        guard isOpen else {
            return EventEmissionEffects(commandInvalidation: commandInvalidation)
        }
        return EventEmissionEffects(
            mainPageTargetNotification: prepareMainPageTargetNotificationIfNeeded(
                receivedSequence: eventSequence.sequence
            ),
            commandInvalidation: commandInvalidation
        )
    }

    private func completeEventEmissionEffects(
        _ effects: EventEmissionEffects
    ) async {
        await completeCommandInvalidationEffects(effects.commandInvalidation)
        completeMainPageTargetNotification(effects.mainPageTargetNotification)
    }

    private func publishConfiguredModelEvent(
        _ event: ProtocolEvent,
        in targetSnapshot: TransportSession.Snapshot
    ) throws {
        guard let registration = modelFeed,
              let targetSnapshotThrough = registration.targetSnapshotThrough,
              event.sequence > targetSnapshotThrough,
              targetRegistry.currentMainPageTargetID != nil else {
            return
        }
        guard event.domain != .target else {
            // Target lifecycle records are projected synchronously with their
            // registry mutation, before that path can suspend.
            return
        }
        guard event.domain != .dom || event.method != "DOM.documentUpdated" else {
            // The target + epoch record is the model feed's sole document
            // invalidation boundary. Public structured scopes still receive
            // their independently projected DOM event where applicable.
            return
        }

        let configuredDomain = modelDomain(for: event.domain)
        if let configuredDomain,
           modelReplaySuppressedDomains[configuredDomain] == currentPageGeneration {
            return
        }
        let elementPickerOwner = ConnectionCapabilityLeaseOwner.modelElementPicker(
            registration.id
        )
        let elementPickerKey = ConnectionCapabilityKey(
            route: .currentPage,
            targetID: .currentPage,
            domain: .inspector
        )
        let isElementPickerEvent = event.domain == .inspector
            && registration.configuredDomains.contains(.dom)
            && registration.elementPickerLease != nil
            && elementPickerShouldDeliver(
                event.sequence,
                to: elementPickerOwner,
                key: elementPickerKey
            )
        guard event.domain == .page
                || configuredDomain.map(registration.configuredDomains.contains) == true
                || isElementPickerEvent else {
            return
        }
        guard ConnectionEventProjection.shouldDeliver(
            event,
            to: .currentPage,
            in: targetSnapshot
        ) else {
            return
        }

        let physicalTargetID = event.targetID ?? targetRegistry.currentMainPageTargetID
        guard let physicalTargetID,
              let physicalRecord = targetRegistry.target(for: physicalTargetID),
              targetRegistry.isCurrentPageModelTarget(physicalRecord),
              let target = ModelTarget(record: physicalRecord) else {
            return
        }

        let semanticTargetID = WebInspectorTarget.ID.currentPage
        let decodedEvent = try LiveProxyEventDecoder.proxyEvent(
            from: event,
            targetID: semanticTargetID,
            lifecycleTarget: ConnectionEventProjection.lifecycleTarget(
                for: event,
                route: .currentPage,
                targetID: semanticTargetID,
                in: targetSnapshot
            )
        )
        let projectedEvent = ConnectionEventProjection.projectedEvent(
            decodedEvent,
            from: event,
            route: .currentPage,
            in: targetSnapshot
        )

        let payload: ModelProtocolEvent?
        switch projectedEvent {
        case let .targetLifecycle(lifecycle):
            switch lifecycle {
            case let .frameNavigated(frame):
                payload = .target(.frameNavigated(frame))
            case let .frameDetached(frameID):
                payload = .target(.frameDetached(frameID: frameID))
            case .didCommitProvisionalTarget, .targetDestroyed, .unknown:
                payload = nil
            }
        case let .dom(value):
            guard configuredDomain == .dom else {
                throw TransportSession.Error.malformedMessage
            }
            payload = .dom(target: target, event: value)
        case let .css(value):
            guard configuredDomain == .css else {
                throw TransportSession.Error.malformedMessage
            }
            payload = .css(target: target, event: value)
        case let .network(value):
            guard configuredDomain == .network else {
                throw TransportSession.Error.malformedMessage
            }
            payload = .network(target: target, event: value)
        case let .console(value):
            guard configuredDomain == .console else {
                throw TransportSession.Error.malformedMessage
            }
            payload = .console(target: target, event: value.event)
        case let .runtime(value):
            guard configuredDomain == .runtime else {
                throw TransportSession.Error.malformedMessage
            }
            payload = .runtime(target: target, event: value)
        case let .inspector(value):
            guard isElementPickerEvent else {
                return
            }
            payload = .inspector(target: target, event: value)
        }

        guard let payload else {
            return
        }
        _ = enqueueModelFeedRecord(
            .event(
                generation: currentPageGeneration,
                sequence: event.sequence,
                payload: payload
            )
        )
    }

    private func modelDomain(for domain: ProtocolDomain) -> ModelDomain? {
        switch domain {
        case .dom:
            .dom
        case .css:
            .css
        case .network:
            .network
        case .console:
            .console
        case .runtime:
            .runtime
        case .target, .page, .inspector, .storage, .other:
            nil
        }
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

    private func prepareMainPageTargetNotificationIfNeeded(
        receivedSequence: UInt64
    ) -> MainPageTargetNotification? {
        guard let currentMainPageTargetID = targetRegistry.currentMainPageTargetID,
              !mainPageTargetWaiterStore.isEmpty else {
            return nil
        }
        let waiters = mainPageTargetWaiterStore.removeAll()
        let result = TransportSession.MainPageTarget(
            targetID: currentMainPageTargetID,
            receivedSequence: receivedSequence
        )
        return MainPageTargetNotification(waiters: waiters, result: result)
    }

    private func completeMainPageTargetNotification(
        _ notification: MainPageTargetNotification?
    ) {
        guard let notification else {
            return
        }
        for waiter in notification.waiters {
            waiter.fulfill(.success(notification.result))
        }
    }

    private func failMainPageTargetWaiter(_ waiterID: UInt64, error: any Swift.Error) {
        let waiter = mainPageTargetWaiterStore.remove(id: waiterID)
        waiter?.fulfill(.failure(error))
    }

    private func removePendingReply(_ key: TransportSession.PendingKey) {
        replyStore.removePendingReply(key)
    }

    private func failPendingReply(_ key: TransportSession.PendingKey, error: any Swift.Error) {
        let pending: TransportSession.PendingReply?
        switch key {
        case let .root(commandID):
            pending = replyStore.removeRootReply(commandID: commandID)
        case let .target(targetReplyKey):
            pending = replyStore.removeTargetReply(for: targetReplyKey)
                ?? replyStore.removeRetargetedReply(commandID: targetReplyKey.commandID)
        }
        pending?.promise.fulfill(.failure(error))
    }

    private func failPendingReplyFromTimeout(_ key: TransportSession.PendingKey, error: any Swift.Error) {
        let pending: TransportSession.PendingReply?
        switch key {
        case let .root(commandID):
            pending = replyStore.removeRootReply(commandID: commandID)
        case let .target(targetReplyKey):
            pending = replyStore.removeTargetReplyForTimeout(targetReplyKey)
        }
        pending?.promise.fulfill(.failure(error))
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
        case let .modelFeedFailure(error):
            .transportFailure(String(describing: error))
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
        case let .modelFeedFailure(error):
            WebInspectorProxyError.transportFailure(String(describing: error))
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
            switch cause {
            case let .modelFeedFailure(error):
                // The package model consumer needs the exact terminal feed
                // category. Direct/public consumers still observe the mapped
                // connection-level scope error above.
                modelFeed?.mailbox.poison(throwing: error)
            case .explicitClose, .fatal, .protocolViolation:
                modelFeed?.mailbox.poison(throwing: scopeError)
            }
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

        let pendingReplyRecords = replyStore.pendingReplyRecords
        for (key, pending) in pendingReplyRecords {
            validateReplyOwnership(pending, key: key)
        }
        let pendingReplies = Array(pendingReplyRecords.values)
        var runningModelCommandTasks: [Task<ProtocolCommand.Result, any Swift.Error>] = []
        for operationID in modelCommandTasks.keys.sorted() {
            guard var commandTask = modelCommandTasks[operationID] else {
                continue
            }
            commandTask.control.failFromOwner(.terminal(transportError))
            let readinessSignal = commandTask.readinessSignal
            commandTask.readinessSignal = nil
            modelCommandTasks[operationID] = commandTask
            readinessSignal?.fulfill(.failure(transportError))
            if let task = commandTask.control.task {
                runningModelCommandTasks.append(task)
            }
        }
        resumeModelCommandOwnerCountWaitersIfNeeded()
        let runningCapabilityTasks = capabilityTasks.values.map(\.task)
        capabilityTasks.removeAll()
        for task in runningCapabilityTasks {
            task.cancel()
        }
        let runningModelBootstrapTasks = modelBootstrapTasks.values.map(\.task)
        modelBootstrapTasks.removeAll()
        for task in runningModelBootstrapTasks {
            task.cancel()
        }
        let eventScopeWaiters = eventScopeRegistrationWaiters
        eventScopeRegistrationWaiters.removeAll()
        for waiter in eventScopeWaiters {
            waiter.continuation.resume()
        }
        let mainPageTargetWaiters = mainPageTargetWaiterStore.removeAll()
        replyStore.removeAll()
        provisionalTargetMessageStore.removeAll()
        inboundMessageQueue = TransportInboundMessageQueue()
        if cause != .explicitClose {
        }

        return TerminalOperation(
            transportError: transportError,
            scopeError: scopeError,
            pendingReplies: pendingReplies,
            mainPageTargetWaiters: mainPageTargetWaiters,
            activationWaiters: activationWaiters,
            releaseWaiters: releaseWaiters,
            capabilityTasks: runningCapabilityTasks,
            modelBootstrapTasks: runningModelBootstrapTasks,
            modelCommandTasks: runningModelCommandTasks,
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
            modelFeed?.mailbox.finish()
        }
        modelFeed = nil
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
        case let .modelFeedFailure(error):
            .failure(WebInspectorProxyError.transportFailure(String(describing: error)))
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

private struct CSSAllStyleSheetsResult: Decodable {
    var headers: [StyleSheetHeaderPayload]
}
