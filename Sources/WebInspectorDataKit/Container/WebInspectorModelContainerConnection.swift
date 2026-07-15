import Foundation
import Synchronization
import WebInspectorProxyKit
import WebKit

private final class WebInspectorProxyOwnership: Sendable {
    static let shared = WebInspectorProxyOwnership()

    private let owners = Mutex<[ObjectIdentifier: UUID]>([:])

    func claim(_ proxy: WebInspectorProxy, for owner: UUID) -> Bool {
        owners.withLock { owners in
            let id = ObjectIdentifier(proxy)
            guard owners[id] == nil else { return false }
            owners[id] = owner
            return true
        }
    }

    func release(_ proxy: WebInspectorProxy, for owner: UUID) {
        owners.withLock { owners in
            let id = ObjectIdentifier(proxy)
            guard owners[id] == owner else { return }
            owners[id] = nil
        }
    }
}

fileprivate struct WebInspectorWebViewAttachmentReservation: Sendable {
    fileprivate let viewID: ObjectIdentifier
    fileprivate let token: UUID

    fileprivate func release() {
        WebInspectorWebViewAttachmentRegistry.release(self)
    }
}

@MainActor
private enum WebInspectorWebViewAttachmentRegistry {
    fileprivate enum ClaimResult {
        case reserved(WebInspectorWebViewAttachmentReservation)
        case alreadyReservedByOwner
        case ownerReservedDifferentView
        case reservedByOther
    }

    private final class Entry: @unchecked Sendable {
        weak var webView: WKWebView?
        weak var owner: WebInspectorModelContainer?
        let token: UUID

        init(
            webView: WKWebView,
            owner: WebInspectorModelContainer,
            token: UUID
        ) {
            self.webView = webView
            self.owner = owner
            self.token = token
        }
    }

    private final class Storage: Sendable {
        let entries = Mutex<[ObjectIdentifier: Entry]>([:])
    }

    nonisolated private static let storage = Storage()

    static func claim(
        _ webView: WKWebView,
        for owner: WebInspectorModelContainer
    ) -> ClaimResult {
        storage.entries.withLock { entries in
            entries = entries.filter { _, entry in
                entry.webView != nil && entry.owner != nil
            }

            if let ownedEntry = entries.values.first(where: { $0.owner === owner }) {
                if ownedEntry.webView === webView {
                    return .alreadyReservedByOwner
                }
                return .ownerReservedDifferentView
            }

            let viewID = ObjectIdentifier(webView)
            if let entry = entries[viewID], entry.webView === webView {
                return .reservedByOther
            }

            let token = UUID()
            entries[viewID] = Entry(
                webView: webView,
                owner: owner,
                token: token
            )
            return .reserved(
                WebInspectorWebViewAttachmentReservation(
                    viewID: viewID,
                    token: token
                )
            )
        }
    }

    nonisolated static func release(
        _ reservation: WebInspectorWebViewAttachmentReservation
    ) {
        storage.entries.withLock { entries in
            guard entries[reservation.viewID]?.token == reservation.token else {
                return
            }
            entries[reservation.viewID] = nil
        }
    }
}

private func webInspectorProxyAlreadyOwnedFailure()
    -> WebInspectorConnectionFailure
{
    .targetControlPlane(
        WebInspectorFailureDescription(
            code: "attachment.proxy.in-use",
            phase: "attach",
            message: "The ProxyKit connection is already owned by another model container."
        )
    )
}

/// Sole owner of one physical ProxyKit connection and all feature runners.
package actor WebInspectorModelContainerConnectionOwner {
    private final class AttachmentControl: Sendable {
        private enum State {
            case pending
            case cancelled
            case claimed
        }

        private let state = Mutex(State.pending)

        func cancel() {
            state.withLock { state in
                guard case .pending = state else { return }
                state = .cancelled
            }
        }

        func claimCompletion() -> Bool {
            state.withLock { state in
                guard case .pending = state else { return false }
                state = .claimed
                return true
            }
        }
    }

    private enum AttachmentWorkerResult: Sendable {
        case candidate(WebInspectorProxy)
        case cancelled
        case failed(
            WebInspectorConnectionFailure,
            attachmentError: WebInspectorAttachmentError
        )
    }

    private enum AttachmentOutcome: Sendable {
        case attached
        case cancelled
        case failed(WebInspectorAttachmentError)
    }

    private struct AttachmentOperation: Sendable {
        let id: UUID
        let generation: WebInspectorAttachmentGeneration
        let control: AttachmentControl
        let worker: Task<AttachmentWorkerResult, Never>
        let completion: Task<AttachmentOutcome, Never>
        let webViewReservation: WebInspectorWebViewAttachmentReservation?
    }

    private struct TeardownOperation: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private enum Phase {
        case detached
        case attaching(AttachmentOperation)
        case attached(
            sessionID: UUID,
            generation: WebInspectorAttachmentGeneration,
            webViewReservation: WebInspectorWebViewAttachmentReservation?
        )
        case failing(
            generation: WebInspectorAttachmentGeneration,
            failure: WebInspectorConnectionFailure,
            teardown: TeardownOperation
        )
        case detaching(
            generation: WebInspectorAttachmentGeneration,
            teardown: TeardownOperation
        )
        case failed(
            generation: WebInspectorAttachmentGeneration,
            failure: WebInspectorConnectionFailure
        )
        case closing(TeardownOperation)
        case closed
    }

    private let ownerID = UUID()
    private let enabledFeatures: Set<WebInspectorFeatureID>
    private let storeID: WebInspectorContainerStoreID
    private let storeSink: WebInspectorModelStoreSink
    private let statePublisher: _WebInspectorStatePublisher<WebInspectorModelContainer.State>
    private let dom: WebInspectorDOMFeature
    private let network: WebInspectorNetworkFeature
    private let consoleRuntime: WebInspectorConsoleRuntimeFeature
    private var phase: Phase = .detached
    private var lastGeneration: UInt64 = 0
    private var proxy: WebInspectorProxy?
    private var featureTasks: [WebInspectorFeatureID: Task<Void, Never>] = [:]
    private var connectionMonitor: Task<Void, Never>?

    package init(
        enabledFeatures: Set<WebInspectorFeatureID>,
        storeID: WebInspectorContainerStoreID,
        storeSink: WebInspectorModelStoreSink,
        statePublisher: _WebInspectorStatePublisher<WebInspectorModelContainer.State>,
        dom: WebInspectorDOMFeature,
        network: WebInspectorNetworkFeature,
        consoleRuntime: WebInspectorConsoleRuntimeFeature
    ) {
        self.enabledFeatures = enabledFeatures
        self.storeID = storeID
        self.storeSink = storeSink
        self.statePublisher = statePublisher
        self.dom = dom
        self.network = network
        self.consoleRuntime = consoleRuntime
    }

    package func attach(
        using factory:
            @escaping @MainActor @Sendable () async throws -> WebInspectorProxy
    ) async throws {
        try await attach(using: factory, webViewReservation: nil)
    }

    fileprivate func attach(
        using factory:
            @escaping @MainActor @Sendable () async throws -> WebInspectorProxy,
        webViewReservation: WebInspectorWebViewAttachmentReservation
    ) async throws {
        try await attach(
            using: factory,
            webViewReservation: Optional(webViewReservation)
        )
    }

    private func attach(
        using factory:
            @escaping @MainActor @Sendable () async throws -> WebInspectorProxy,
        webViewReservation: WebInspectorWebViewAttachmentReservation?
    ) async throws {
        let generation: WebInspectorAttachmentGeneration
        do {
            generation = try reserveAttachmentGeneration()
        } catch {
            webViewReservation?.release()
            throw error
        }
        let control = AttachmentControl()
        let ownershipID = ownerID
        let worker = Task<AttachmentWorkerResult, Never> { @MainActor in
            do {
                let candidate = try await factory()
                guard WebInspectorProxyOwnership.shared.claim(
                    candidate,
                    for: ownershipID
                ) else {
                    let failure = webInspectorProxyAlreadyOwnedFailure()
                    return .failed(
                        failure,
                        attachmentError: .webViewAlreadyAttached
                    )
                }
                return .candidate(candidate)
            } catch is CancellationError {
                return .cancelled
            } catch {
                let failure = WebInspectorConnectionFailure.native(
                    WebInspectorFailureDescription(
                        code: "attachment.native.failed",
                        phase: "attach",
                        message: String(describing: error)
                    )
                )
                return .failed(
                    failure,
                    attachmentError: .native(failure)
                )
            }
        }
        try await installAndAwaitAttachment(
            generation: generation,
            control: control,
            worker: worker,
            webViewReservation: webViewReservation
        )
    }

    package func attach(owning candidate: WebInspectorProxy) async throws {
        let generation = try reserveAttachmentGeneration()
        guard WebInspectorProxyOwnership.shared.claim(candidate, for: ownerID) else {
            let failure = webInspectorProxyAlreadyOwnedFailure()
            phase = .failed(generation: generation, failure: failure)
            statePublisher.publish(
                .failed(generation: generation, failure: failure)
            )
            throw WebInspectorAttachmentError.webViewAlreadyAttached
        }

        let control = AttachmentControl()
        let worker = Task { @MainActor in
            AttachmentWorkerResult.candidate(candidate)
        }
        try await installAndAwaitAttachment(
            generation: generation,
            control: control,
            worker: worker,
            webViewReservation: nil
        )
    }

    private func reserveAttachmentGeneration() throws
        -> WebInspectorAttachmentGeneration
    {
        switch phase {
        case .detached, .failed:
            break
        case .attaching, .failing, .detaching:
            throw WebInspectorAttachmentError.attachmentInProgress
        case .attached:
            throw WebInspectorAttachmentError.alreadyAttached
        case .closing, .closed:
            throw WebInspectorAttachmentError.containerClosed
        }
        let (next, overflow) = lastGeneration.addingReportingOverflow(1)
        guard !overflow else {
            throw WebInspectorAttachmentError.native(
                .targetControlPlane(
                    WebInspectorFailureDescription(
                        code: "attachment.generation.exhausted",
                        phase: "attach",
                        message: "The attachment generation space was exhausted."
                    )
                )
            )
        }
        lastGeneration = next
        return WebInspectorAttachmentGeneration(rawValue: next)
    }

    private func installAndAwaitAttachment(
        generation: WebInspectorAttachmentGeneration,
        control: AttachmentControl,
        worker: Task<AttachmentWorkerResult, Never>,
        webViewReservation: WebInspectorWebViewAttachmentReservation?
    ) async throws {
        let id = UUID()
        let ownershipID = ownerID
        let completion = Task { [weak self] in
            let result = await worker.value
            guard let self else {
                if case let .candidate(candidate) = result {
                    await candidate.close()
                    WebInspectorProxyOwnership.shared.release(
                        candidate,
                        for: ownershipID
                    )
                }
                webViewReservation?.release()
                return AttachmentOutcome.failed(.containerClosed)
            }
            return await self.completeAttachment(
                id: id,
                generation: generation,
                control: control,
                result: result,
                webViewReservation: webViewReservation
            )
        }
        let operation = AttachmentOperation(
            id: id,
            generation: generation,
            control: control,
            worker: worker,
            completion: completion,
            webViewReservation: webViewReservation
        )
        phase = .attaching(operation)
        statePublisher.publish(.attaching(generation: generation))

        let outcome = await withTaskCancellationHandler {
            await completion.value
        } onCancel: {
            control.cancel()
            worker.cancel()
        }
        switch outcome {
        case .attached:
            return
        case .cancelled:
            throw CancellationError()
        case let .failed(error):
            throw error
        }
    }

    private func completeAttachment(
        id: UUID,
        generation: WebInspectorAttachmentGeneration,
        control: AttachmentControl,
        result: AttachmentWorkerResult,
        webViewReservation: WebInspectorWebViewAttachmentReservation?
    ) async -> AttachmentOutcome {
        let completionOwnsAttempt: Bool
        let interruptedOutcome: AttachmentOutcome
        switch phase {
        case let .attaching(operation) where operation.id == id:
            completionOwnsAttempt = control.claimCompletion()
            interruptedOutcome = .cancelled
        case let .detaching(currentGeneration, _)
            where currentGeneration == generation:
            completionOwnsAttempt = false
            interruptedOutcome = .cancelled
        case .closing, .closed:
            completionOwnsAttempt = false
            interruptedOutcome = .failed(.containerClosed)
        case .detached, .attaching, .attached, .failing, .detaching, .failed:
            completionOwnsAttempt = false
            interruptedOutcome = .failed(.containerClosed)
        }

        guard completionOwnsAttempt else {
            await retireAttachmentCandidateIfNeeded(result)
            if case let .attaching(operation) = phase, operation.id == id {
                webViewReservation?.release()
                phase = .detached
                statePublisher.publish(.detached)
            }
            return interruptedOutcome
        }

        switch result {
        case let .candidate(candidate):
            adoptClaimed(
                candidate,
                generation: generation,
                webViewReservation: webViewReservation
            )
            return .attached
        case .cancelled:
            webViewReservation?.release()
            phase = .detached
            statePublisher.publish(.detached)
            return .cancelled
        case let .failed(failure, attachmentError):
            webViewReservation?.release()
            phase = .failed(generation: generation, failure: failure)
            statePublisher.publish(
                .failed(generation: generation, failure: failure)
            )
            return .failed(attachmentError)
        }
    }

    private func retireAttachmentCandidateIfNeeded(
        _ result: AttachmentWorkerResult
    ) async {
        guard case let .candidate(candidate) = result else { return }
        await candidate.close()
        WebInspectorProxyOwnership.shared.release(candidate, for: ownerID)
    }

    private func adoptClaimed(
        _ candidate: WebInspectorProxy,
        generation: WebInspectorAttachmentGeneration,
        webViewReservation: WebInspectorWebViewAttachmentReservation?
    ) {
        let sessionID = UUID()
        proxy = candidate
        phase = .attached(
            sessionID: sessionID,
            generation: generation,
            webViewReservation: webViewReservation
        )
        let connection = WebInspectorFeatureConnection(
            page: candidate.page,
            attachmentGeneration: generation,
            storeID: storeID
        )
        startFeatures(connection: connection, sessionID: sessionID)
        connectionMonitor = Task { [weak self] in
            do {
                try await candidate.waitUntilClosed()
                await self?.connectionEnded(
                    sessionID: sessionID,
                    failure: .native(
                        WebInspectorFailureDescription(
                            code: "connection.closed",
                            phase: "events",
                            message: "The ProxyKit connection closed."
                        )
                    )
                )
            } catch {
                await self?.connectionEnded(
                    sessionID: sessionID,
                    failure: .native(
                        WebInspectorFailureDescription(
                            code: "connection.failed",
                            phase: "events",
                            message: String(describing: error)
                        )
                    )
                )
            }
        }
        statePublisher.publish(.attached(generation: generation))
    }

    package func detach() async {
        let generation: WebInspectorAttachmentGeneration
        let teardown: TeardownOperation
        switch phase {
        case let .attaching(operation):
            generation = operation.generation
            teardown = makeTeardownOperation(attachment: operation)
            phase = .detaching(generation: generation, teardown: teardown)
            statePublisher.publish(.detaching(generation: generation))
        case let .attached(_, attachedGeneration, webViewReservation):
            generation = attachedGeneration
            teardown = makeTeardownOperation(
                webViewReservation: webViewReservation
            )
            phase = .detaching(generation: generation, teardown: teardown)
            statePublisher.publish(.detaching(generation: generation))
        case let .failing(failingGeneration, _, currentTeardown):
            generation = failingGeneration
            teardown = currentTeardown
            phase = .detaching(generation: generation, teardown: teardown)
            statePublisher.publish(.detaching(generation: generation))
        case let .failed(failedGeneration, _):
            generation = failedGeneration
            teardown = makeTeardownOperation()
            phase = .detaching(generation: generation, teardown: teardown)
            statePublisher.publish(.detaching(generation: generation))
        case let .detaching(currentGeneration, currentTeardown):
            generation = currentGeneration
            teardown = currentTeardown
        case .detached:
            return
        case let .closing(currentTeardown):
            await currentTeardown.task.value
            return
        case .closed:
            return
        }

        await teardown.task.value
        guard case let .detaching(currentGeneration, currentTeardown) = phase,
              currentGeneration == generation,
              currentTeardown.id == teardown.id else { return }
        phase = .detached
        statePublisher.publish(.detached)
    }

    package func close() async {
        let teardown: TeardownOperation
        switch phase {
        case .closed:
            return
        case let .closing(currentTeardown):
            teardown = currentTeardown
        case let .failing(_, _, currentTeardown),
            let .detaching(_, currentTeardown):
            teardown = currentTeardown
            phase = .closing(teardown)
        case let .attaching(operation):
            teardown = makeTeardownOperation(attachment: operation)
            phase = .closing(teardown)
        case let .attached(_, _, webViewReservation):
            teardown = makeTeardownOperation(
                webViewReservation: webViewReservation
            )
            phase = .closing(teardown)
        case .detached, .failed:
            teardown = makeTeardownOperation()
            phase = .closing(teardown)
        }

        await teardown.task.value
        guard case let .closing(currentTeardown) = phase,
              currentTeardown.id == teardown.id else { return }
        phase = .closed
    }

    package func reload(ignoringCache: Bool) async throws {
        let proxy: WebInspectorProxy
        switch phase {
        case .attached:
            guard let currentProxy = self.proxy else {
                throw WebInspectorCommandError.containerClosed
            }
            proxy = currentProxy
        case let .failing(_, failure, _), let .failed(_, failure):
            throw WebInspectorCommandError.connection(failure)
        case .detached, .attaching, .detaching, .closing, .closed:
            throw WebInspectorCommandError.containerClosed
        }
        do { try await proxy.page.page.reload(ignoringCache: ignoringCache) }
        catch {
            throw webInspectorCommandError(
                error,
                featureID: .dom,
                phase: "Page.reload"
            )
        }
    }

    private func startFeatures(
        connection: WebInspectorFeatureConnection,
        sessionID: UUID
    ) {
        if enabledFeatures.contains(.dom) {
            featureTasks[.dom] = Task { [weak self, dom, storeSink] in
                let termination = await dom.run(connection: connection, store: storeSink)
                await self?.featureEnded(.dom, termination: termination, sessionID: sessionID)
            }
        }
        if enabledFeatures.contains(.network) {
            featureTasks[.network] = Task { [weak self, network, storeSink] in
                let termination = await network.run(connection: connection, store: storeSink)
                await self?.featureEnded(.network, termination: termination, sessionID: sessionID)
            }
        }
        if enabledFeatures.contains(.consoleRuntime) {
            featureTasks[.consoleRuntime] = Task { [weak self, consoleRuntime, storeSink] in
                let termination = await consoleRuntime.run(connection: connection, store: storeSink)
                await self?.featureEnded(
                    .consoleRuntime,
                    termination: termination,
                    sessionID: sessionID
                )
            }
        }
    }

    private func featureEnded(
        _ featureID: WebInspectorFeatureID,
        termination: WebInspectorFeatureTermination,
        sessionID: UUID
    ) async {
        guard case let .attached(
            currentSessionID,
            generation,
            webViewReservation
        ) = phase,
            currentSessionID == sessionID
        else { return }
        featureTasks[featureID] = nil
        switch termination {
        case .detached:
            return
        case let .connectionFailed(failure):
            await failConnection(
                generation: generation,
                failure: failure,
                webViewReservation: webViewReservation
            )
        case .containerClosed:
            let failure = WebInspectorConnectionFailure.native(
                WebInspectorFailureDescription(
                    code: "store.closed",
                    phase: featureID.name,
                    message: "The model store closed while a feature was active."
                )
            )
            await failConnection(
                generation: generation,
                failure: failure,
                webViewReservation: webViewReservation
            )
        }
    }

    private func connectionEnded(
        sessionID: UUID,
        failure: WebInspectorConnectionFailure
    ) async {
        guard case let .attached(
            currentSessionID,
            generation,
            webViewReservation
        ) = phase,
            currentSessionID == sessionID
        else { return }
        // This method is entered by the monitor task itself. Remove that handle
        // before creating the teardown operation so it cannot join its caller.
        connectionMonitor = nil
        await failConnection(
            generation: generation,
            failure: failure,
            webViewReservation: webViewReservation
        )
    }

    private func failConnection(
        generation: WebInspectorAttachmentGeneration,
        failure: WebInspectorConnectionFailure,
        webViewReservation: WebInspectorWebViewAttachmentReservation?
    ) async {
        let teardown = makeTeardownOperation(
            webViewReservation: webViewReservation
        )
        phase = .failing(
            generation: generation,
            failure: failure,
            teardown: teardown
        )
        await teardown.task.value
        guard case let .failing(currentGeneration, currentFailure, currentTeardown) = phase,
              currentGeneration == generation,
              currentFailure == failure,
              currentTeardown.id == teardown.id else { return }
        phase = .failed(generation: generation, failure: failure)
        statePublisher.publish(
            .failed(generation: generation, failure: failure)
        )
    }

    private func makeTeardownOperation(
        attachment: AttachmentOperation? = nil,
        webViewReservation: WebInspectorWebViewAttachmentReservation? = nil
    ) -> TeardownOperation {
        attachment?.control.cancel()
        attachment?.worker.cancel()
        let attachmentCompletion = attachment?.completion
        let reservation = attachment?.webViewReservation
            ?? webViewReservation
        let id = UUID()
        let task = Task { [weak self] in
            if let attachmentCompletion {
                _ = await attachmentCompletion.value
            }
            if let self {
                await self.tearDownConnectionResources()
            }
            reservation?.release()
        }
        return TeardownOperation(id: id, task: task)
    }

    private func tearDownConnectionResources() async {
        let connectionMonitor = connectionMonitor
        self.connectionMonitor = nil
        connectionMonitor?.cancel()
        let tasks = Array(featureTasks.values)
        featureTasks.removeAll(keepingCapacity: true)
        for task in tasks { task.cancel() }

        await dom.close()
        await network.close()
        await consoleRuntime.close()

        for task in tasks { await task.value }

        if let proxy {
            self.proxy = nil
            await proxy.close()
            WebInspectorProxyOwnership.shared.release(proxy, for: ownerID)
        }
        await connectionMonitor?.value
    }
}

public final class WebInspectorPageCommands: Sendable {
    private let owner: WebInspectorModelContainerConnectionOwner

    package init(owner: WebInspectorModelContainerConnectionOwner) {
        self.owner = owner
    }

    public func reload(ignoringCache: Bool = false) async throws {
        try await owner.reload(ignoringCache: ignoringCache)
    }
}

public extension WebInspectorModelContainer {
    @MainActor
    convenience init(
        attachingTo webView: WKWebView,
        configuration: Configuration = .init(),
        proxyConfiguration: WebInspectorProxy.Configuration = .init()
    ) async throws {
        self.init(configuration: configuration)
        try await attach(to: webView, proxyConfiguration: proxyConfiguration)
    }

    @MainActor
    func attach(
        to webView: WKWebView,
        proxyConfiguration: WebInspectorProxy.Configuration = .init()
    ) async throws {
        try await attach(to: webView) {
            try await WebInspectorProxy(
                attachingTo: webView,
                configuration: proxyConfiguration
            )
        }
    }

    @MainActor
    package func attach(
        to webView: WKWebView,
        proxyFactory:
            @escaping @MainActor @Sendable () async throws -> WebInspectorProxy
    ) async throws {
        switch state {
        case .attaching, .detaching:
            throw WebInspectorAttachmentError.attachmentInProgress
        case .closing, .closed:
            throw WebInspectorAttachmentError.containerClosed
        case .detached, .attached, .failed:
            break
        }

        let claim = WebInspectorWebViewAttachmentRegistry.claim(
            webView,
            for: self
        )
        switch claim {
        case let .reserved(reservation):
            if case .attached = state {
                reservation.release()
                throw WebInspectorAttachmentError.alreadyAttached
            }
            try await connectionOwner.attach(
                using: proxyFactory,
                webViewReservation: reservation
            )
        case .alreadyReservedByOwner:
            switch state {
            case .attached:
                return
            case .attaching, .detaching:
                throw WebInspectorAttachmentError.attachmentInProgress
            case .closing, .closed:
                throw WebInspectorAttachmentError.containerClosed
            case .detached, .failed:
                preconditionFailure(
                    "A detached container retained its WKWebView reservation."
                )
            }
        case .ownerReservedDifferentView:
            switch state {
            case .attached:
                throw WebInspectorAttachmentError.alreadyAttached
            case .attaching, .detaching:
                throw WebInspectorAttachmentError.attachmentInProgress
            case .closing, .closed:
                throw WebInspectorAttachmentError.containerClosed
            case .detached, .failed:
                preconditionFailure(
                    "A detached container retained a different WKWebView reservation."
                )
            }
        case .reservedByOther:
            if case .attached = state {
                throw WebInspectorAttachmentError.alreadyAttached
            }
            throw WebInspectorAttachmentError.webViewAlreadyAttached
        }
    }

    package func attach(owning proxy: WebInspectorProxy) async throws {
        try await connectionOwner.attach(owning: proxy)
    }

    func detach() async {
        if await joinCloseIfNeeded() { return }
        await connectionOwner.detach()
        _ = await joinCloseIfNeeded()
    }
}
