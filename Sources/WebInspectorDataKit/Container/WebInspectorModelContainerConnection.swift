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

package struct WebInspectorAttachmentReservation: Hashable, Sendable {
    package let token: UUID
    package let generation: WebInspectorAttachmentGeneration
}

/// Sole owner of one physical ProxyKit connection and all feature runners.
package actor WebInspectorModelContainerConnectionOwner {
    private struct TeardownOperation: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private enum Phase {
        case detached
        case attaching(WebInspectorAttachmentReservation)
        case attached(sessionID: UUID, generation: WebInspectorAttachmentGeneration)
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

    package func reserveAttachment() throws -> WebInspectorAttachmentReservation {
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
        let reservation = WebInspectorAttachmentReservation(
            token: UUID(),
            generation: WebInspectorAttachmentGeneration(rawValue: next)
        )
        phase = .attaching(reservation)
        statePublisher.publish(.attaching(generation: reservation.generation))
        return reservation
    }

    package func abandon(
        _ reservation: WebInspectorAttachmentReservation,
        failure: WebInspectorConnectionFailure?
    ) {
        guard case let .attaching(current) = phase, current == reservation else { return }
        if let failure {
            phase = .failed(
                generation: reservation.generation,
                failure: failure
            )
            statePublisher.publish(
                .failed(generation: reservation.generation, failure: failure)
            )
        } else {
            phase = .detached
            statePublisher.publish(.detached)
        }
    }

    package func adopt(
        _ candidate: WebInspectorProxy,
        reservation: WebInspectorAttachmentReservation
    ) async throws {
        guard case let .attaching(current) = phase, current == reservation else {
            throw WebInspectorAttachmentError.containerClosed
        }
        guard WebInspectorProxyOwnership.shared.claim(candidate, for: ownerID) else {
            let failure = WebInspectorConnectionFailure.targetControlPlane(
                WebInspectorFailureDescription(
                    code: "attachment.proxy.in-use",
                    phase: "attach",
                    message: "The ProxyKit connection is already owned by another model container."
                )
            )
            phase = .failed(
                generation: reservation.generation,
                failure: failure
            )
            statePublisher.publish(.failed(generation: reservation.generation, failure: failure))
            throw WebInspectorAttachmentError.webViewAlreadyAttached
        }

        let sessionID = UUID()
        proxy = candidate
        phase = .attached(sessionID: sessionID, generation: reservation.generation)
        let connection = WebInspectorFeatureConnection(
            page: candidate.page,
            attachmentGeneration: reservation.generation,
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
        statePublisher.publish(.attached(generation: reservation.generation))
    }

    package func detach() async {
        let generation: WebInspectorAttachmentGeneration
        let teardown: TeardownOperation
        switch phase {
        case let .attaching(reservation):
            phase = .detached
            statePublisher.publish(.detached)
            _ = reservation
            return
        case let .attached(_, attachedGeneration):
            generation = attachedGeneration
            teardown = makeTeardownOperation()
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
        case .detached, .attaching, .attached, .failed:
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
        guard case let .attached(currentSessionID, generation) = phase,
            currentSessionID == sessionID
        else { return }
        featureTasks[featureID] = nil
        switch termination {
        case .detached:
            return
        case let .connectionFailed(failure):
            await failConnection(
                generation: generation,
                failure: failure
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
                failure: failure
            )
        }
    }

    private func connectionEnded(
        sessionID: UUID,
        failure: WebInspectorConnectionFailure
    ) async {
        guard case let .attached(currentSessionID, generation) = phase,
            currentSessionID == sessionID
        else { return }
        // This method is entered by the monitor task itself. Remove that handle
        // before creating the teardown operation so it cannot join its caller.
        connectionMonitor = nil
        await failConnection(generation: generation, failure: failure)
    }

    private func failConnection(
        generation: WebInspectorAttachmentGeneration,
        failure: WebInspectorConnectionFailure
    ) async {
        let teardown = makeTeardownOperation()
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

    private func makeTeardownOperation() -> TeardownOperation {
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.tearDownConnectionResources()
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
            WebInspectorProxyOwnership.shared.release(proxy, for: ownerID)
            await proxy.close()
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
        let reservation = try await connectionOwner.reserveAttachment()
        let proxy: WebInspectorProxy
        do {
            proxy = try await WebInspectorProxy(
                attachingTo: webView,
                configuration: proxyConfiguration
            )
        } catch is CancellationError {
            await connectionOwner.abandon(reservation, failure: nil)
            throw CancellationError()
        } catch {
            let failure = WebInspectorConnectionFailure.native(
                WebInspectorFailureDescription(
                    code: "attachment.native.failed",
                    phase: "attach",
                    message: String(describing: error)
                )
            )
            await connectionOwner.abandon(reservation, failure: failure)
            throw WebInspectorAttachmentError.native(failure)
        }
        do {
            try await connectionOwner.adopt(proxy, reservation: reservation)
        } catch {
            await proxy.close()
            throw error
        }
    }

    package func attach(owning proxy: WebInspectorProxy) async throws {
        let reservation = try await connectionOwner.reserveAttachment()
        do {
            try await connectionOwner.adopt(proxy, reservation: reservation)
        } catch {
            await connectionOwner.abandon(reservation, failure: nil)
            throw error
        }
    }

    func detach() async {
        if await joinCloseIfNeeded() { return }
        await connectionOwner.detach()
        _ = await joinCloseIfNeeded()
    }
}
