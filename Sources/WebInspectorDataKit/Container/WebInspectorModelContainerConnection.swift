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
    private enum Phase {
        case detached
        case attaching(WebInspectorAttachmentReservation)
        case attached(sessionID: UUID, generation: WebInspectorAttachmentGeneration)
        case detaching
        case failed(WebInspectorAttachmentGeneration)
        case closing
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
        case .attaching:
            throw WebInspectorAttachmentError.attachmentInProgress
        case .attached, .detaching:
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
            phase = .failed(reservation.generation)
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
            phase = .failed(reservation.generation)
            let failure = WebInspectorConnectionFailure.targetControlPlane(
                WebInspectorFailureDescription(
                    code: "attachment.proxy.in-use",
                    phase: "attach",
                    message: "The ProxyKit connection is already owned by another model container."
                )
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
        switch phase {
        case let .attaching(reservation):
            phase = .detached
            statePublisher.publish(.detached)
            _ = reservation
        case let .attached(_, generation), .failed(let generation):
            phase = .detaching
            statePublisher.publish(.detaching(generation: generation))
            await tearDownConnection()
            phase = .detached
            statePublisher.publish(.detached)
        case .detached, .detaching:
            return
        case .closing, .closed:
            return
        }
    }

    package func close() async {
        switch phase {
        case .closed:
            return
        case .closing:
            return
        default:
            phase = .closing
        }
        await tearDownConnection()
        phase = .closed
    }

    package func reload(ignoringCache: Bool) async throws {
        guard let proxy else { throw WebInspectorCommandError.containerClosed }
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
            phase = .failed(generation)
            await tearDownConnection()
            statePublisher.publish(.failed(generation: generation, failure: failure))
        case .containerClosed:
            let failure = WebInspectorConnectionFailure.native(
                WebInspectorFailureDescription(
                    code: "store.closed",
                    phase: featureID.name,
                    message: "The model store closed while a feature was active."
                )
            )
            phase = .failed(generation)
            await tearDownConnection()
            statePublisher.publish(.failed(generation: generation, failure: failure))
        }
    }

    private func connectionEnded(
        sessionID: UUID,
        failure: WebInspectorConnectionFailure
    ) async {
        guard case let .attached(currentSessionID, generation) = phase,
            currentSessionID == sessionID
        else { return }
        phase = .failed(generation)
        // This method is entered by the monitor task itself. Remove that handle
        // before teardown so the owner never awaits its current task.
        connectionMonitor = nil
        await tearDownConnection()
        statePublisher.publish(.failed(generation: generation, failure: failure))
    }

    private func tearDownConnection() async {
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

    func detach() async { await connectionOwner.detach() }
}
