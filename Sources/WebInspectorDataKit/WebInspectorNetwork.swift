import Foundation
import WebInspectorProxyKit

package enum WebInspectorNetworkWireEvent: Sendable {
    case network(WebInspectorRoutedEvent<Network.Event>)
    case page(WebInspectorRoutedEvent<Page.Event>)
}

private struct WebInspectorNetworkRecoveryRequest: Error, Sendable {
    let reason: WebInspectorRecoveryReason
    let fingerprint: WebInspectorRecoveryFingerprint
}

private enum WebInspectorNetworkBodyLocator: Sendable {
    case network(
        rawID: Network.Request.ID,
        backendResourceIdentifier: Network.BackendResourceID?
    )
    case page(frameID: FrameID, url: String)
}

/// Sole semantic owner of Network bootstrap, grouping, and body commands.
package actor WebInspectorNetworkFeature: WebInspectorModelFeature {
    package static let id = WebInspectorFeatureID.network

    private let registry: WebInspectorFeatureRegistry
    private var connection: WebInspectorFeatureConnection?
    private var storeSink: WebInspectorModelStoreSink?
    private var orderedScope: WebInspectorOrderedEventScope<WebInspectorNetworkWireEvent>?
    private var canonicalStore: CanonicalNetworkStore?
    private var bodyLocators: [CanonicalNetworkRequestIDStorage: WebInspectorNetworkBodyLocator] = [:]
    private var state: WebInspectorFeatureState = .disabled
    private var recoveryBudget = WebInspectorFeatureRecoveryBudget()
    private var closeRequested = false
    private var isConsumingOrderedScopeEvents = false

    package init(registry: WebInspectorFeatureRegistry) {
        self.registry = registry
    }

    package func run(
        connection: WebInspectorFeatureConnection,
        store: WebInspectorModelStoreSink
    ) async -> WebInspectorFeatureTermination {
        self.connection = connection
        storeSink = store
        closeRequested = false
        recoveryBudget = WebInspectorFeatureRecoveryBudget()
        if let canonicalStore {
            precondition(
                canonicalStore.storeID == connection.storeID,
                "A Network feature cannot move between container stores."
            )
        } else {
            canonicalStore = CanonicalNetworkStore(storeID: connection.storeID)
        }
        await publish(.synchronizing(generation: await currentGeneration()))

        while !closeRequested {
            do {
                try await runOrderedScope()
                return closeRequested ? .detached : .connectionFailed(
                    connectionFailure(
                        code: "network.scope.ended",
                        phase: "events",
                        message: "The Network event scope ended unexpectedly."
                    )
                )
            } catch is CancellationError {
                return .detached
            } catch let request as WebInspectorNetworkRecoveryRequest {
                let generation = await currentGeneration()
                switch recoveryBudget.consume(request.fingerprint, generation: generation) {
                case .retry:
                    await publish(.recovering(generation: generation, reason: request.reason))
                case .repeatedFingerprint, .generationBudgetExhausted:
                    let summary = WebInspectorFailureDescription(
                        code: "network.recovery.exhausted",
                        phase: request.fingerprint.phase,
                        message: String(describing: request.reason)
                    )
                    return await becomeUnavailable(
                        .recoveryBudgetExhausted(summary),
                        generation: generation
                    )
                }
            } catch {
                if isConnectionTerminal(error) {
                    await orderedScope?.close()
                    orderedScope = nil
                    return termination(for: error)
                }
                let featureError = (error as? WebInspectorFeatureError)
                    ?? .bootstrap(
                        webInspectorFailureDescription(
                            error,
                            code: "network.bootstrap.failed",
                            phase: "bootstrap"
                        )
                    )
                return await becomeUnavailable(featureError)
            }
        }
        return .detached
    }

    package func close() async {
        guard !closeRequested else { return }
        closeRequested = true
        await orderedScope?.close()
        orderedScope = nil
        if let storeSink {
            // Keep the last successful models across detach. The next attach
            // stages a full snapshot and replaces them atomically; clearing
            // here would publish an empty intermediate baseline.
            var modelTransaction = WebInspectorModelTransaction()
            modelTransaction.setFeatureState(.disabled, for: .network)
            _ = try? await storeSink.commit(modelTransaction)
        }
        connection = nil
        self.storeSink = nil
        transition(to: .disabled)
    }

    package func clear() async throws {
        guard var staged = canonicalStore, let storeSink else {
            throw WebInspectorCommandError.containerClosed
        }
        let canonical = staged.clear()
        var transaction = WebInspectorModelTransaction()
        append(canonical, staged: staged, to: &transaction)
        let revision = try await storeSink.commit(transaction)
        canonicalStore = staged
        bodyLocators.removeAll(keepingCapacity: true)
        refreshReadyRevision(revision)
    }

    package func responseBody(for id: NetworkRequest.ID) async throws -> Network.Body {
        guard let connection, let canonicalStore else {
            throw WebInspectorCommandError.containerClosed
        }
        let canonicalID = id.canonicalStorage
        guard let lease = canonicalStore.responseBodyLease(for: canonicalID),
            let locator = bodyLocators[canonicalID]
        else {
            throw WebInspectorCommandError.staleIdentifier
        }
        let body: Network.Body
        do {
            switch locator {
            case let .network(rawID, backendResourceIdentifier):
                body = try await connection.page.network.responseBody(
                    for: rawID,
                    backendResourceIdentifier: backendResourceIdentifier
                )
            case let .page(frameID, url):
                let content = try await connection.page.page.resourceContent(
                    frameID: frameID,
                    url: url
                )
                body = Network.Body(
                    data: content.content,
                    base64Encoded: content.base64Encoded
                )
            }
        } catch {
            throw webInspectorCommandError(
                error,
                featureID: .network,
                phase: "Network.responseBody"
            )
        }
        guard self.canonicalStore?.isCurrent(lease) == true else {
            throw WebInspectorCommandError.staleIdentifier
        }
        return body
    }

    private func runOrderedScope() async throws {
        guard let connection, let storeSink else { throw CancellationError() }
        precondition(
            !isConsumingOrderedScopeEvents,
            "Only one Network ordered scope may reduce live events at a time."
        )
        let descriptor = WebInspectorOrderedScopeDescriptor<WebInspectorNetworkWireEvent>(
            decoders: [
                NetworkWireCoding.eventDecoder.routed().map(WebInspectorNetworkWireEvent.network),
                PageWireCoding.eventDecoder.routed().map(WebInspectorNetworkWireEvent.page),
            ],
            capabilities: [
                NetworkWireCoding.capability,
                PageWireCoding.capability,
            ]
        )
        let previousScope = orderedScope
        let scope = try await connection.page.orderedScope(
            descriptor: descriptor,
            buffering: .bounded(4_096)
        )
        if closeRequested {
            await scope.close()
            throw CancellationError()
        }
        var didActivateReplacement = false
        do {
            let reply = try await scope.command(PageWireCoding.resourceTree())
            let prefix = try await scope.drain(through: reply.boundary)
            if closeRequested { throw CancellationError() }
            if prefix.contains(where: {
                invalidatesBootstrap($0, resourceTree: reply.value)
            }) {
                throw recovery(
                    code: "network.bootstrap.invalidated",
                    phase: "bootstrap",
                    reason: .targetChanged
                )
            }
            let route = try featureScope(from: reply)
            let timeline = await storeSink.metadataValue(
                for: webInspectorDOMBindingTimelineKey,
                default: WebInspectorDOMBindingTimeline()
            )
            let oldSnapshot = canonicalStore?.snapshot
            var staged = canonicalStore
                ?? CanonicalNetworkStore(storeID: connection.storeID)
            try staged.prepareBootstrap(
                attachmentGeneration: connection.attachmentGeneration,
                pageGeneration: route.generation
            )
            var stagedLocators = bodyLocators

            // The previous scope's stream has already stopped at the recovery
            // boundary. The replacement scope alone owns these buffered events,
            // and bootstrap publishes their reduced union exactly once below.
            for event in prefix {
                try await reduce(
                    event,
                    timeline: timeline,
                    staged: &staged,
                    locators: &stagedLocators,
                    origin: .enableReplay,
                    publishesTransaction: false,
                    duringBootstrap: true
                )
            }
            if closeRequested { throw CancellationError() }
            for resource in snapshotResources(reply.value) {
                let resourceScope = snapshotScope(
                    for: resource,
                    route: route
                )
                let result = try staged.reconcileSnapshotResource(
                    resource,
                    scope: resourceScope
                )
                if staged.rawRequestAlias(for: result.requestID) == nil {
                    stagedLocators[result.requestID] = .page(
                        frameID: resource.frameID,
                        url: resource.url
                    )
                }
            }
            installLiveLocators(from: staged, into: &stagedLocators)
            removeMissingLocators(staged: staged, locators: &stagedLocators)
            staged.finishBootstrap()

            let newSnapshot = staged.snapshot
            var transaction = WebInspectorModelTransaction()
            appendReplacement(
                previous: oldSnapshot,
                current: newSnapshot,
                to: &transaction
            )
            transaction.setFeatureState(
                .ready(
                    generation: route.generation,
                    revision: WebInspectorStoreRevision(rawValue: 0)
                ),
                for: .network
            )
            let revision = try await storeSink.commit(transaction)
            canonicalStore = staged
            bodyLocators = stagedLocators
            if closeRequested { throw CancellationError() }
            orderedScope = scope
            didActivateReplacement = true
            transition(
                to: .ready(generation: route.generation, revision: revision)
            )
            await previousScope?.close()

            precondition(!isConsumingOrderedScopeEvents)
            isConsumingOrderedScopeEvents = true
            defer { isConsumingOrderedScopeEvents = false }
            for try await event in scope.events {
                if closeRequested { return }
                let currentTimeline = await storeSink.metadataValue(
                    for: webInspectorDOMBindingTimelineKey,
                    default: WebInspectorDOMBindingTimeline()
                )
                guard var staged = canonicalStore else { continue }
                var stagedLocators = bodyLocators
                do {
                    try await reduce(
                        event,
                        timeline: currentTimeline,
                        staged: &staged,
                        locators: &stagedLocators,
                        origin: .live,
                        publishesTransaction: true,
                        duringBootstrap: false
                    )
                } catch let error as CanonicalNetworkProtocolViolation {
                    throw recovery(
                        code: "network.protocol.\(String(describing: error))",
                        phase: "events",
                        reason: .malformedDomainEvent(
                            webInspectorFailureDescription(
                                error,
                                code: "network.protocol",
                                phase: "events"
                            )
                        )
                    )
                }
                canonicalStore = staged
                bodyLocators = stagedLocators
            }
        } catch {
            if !didActivateReplacement {
                // The failed candidate owns only its lease. The previous
                // scope remains the capability lease until a replacement
                // publishes, avoiding a disable/enable replay gap.
                await scope.close()
            }
            throw error
        }
    }

    private func reduce(
        _ pageEvent: WebInspectorPageEvent<WebInspectorNetworkWireEvent>,
        timeline: WebInspectorDOMBindingTimeline,
        staged: inout CanonicalNetworkStore,
        locators: inout [CanonicalNetworkRequestIDStorage: WebInspectorNetworkBodyLocator],
        origin: CanonicalNetworkEventOrigin,
        publishesTransaction: Bool,
        duringBootstrap: Bool
    ) async throws {
        switch pageEvent {
        case .reset:
            throw recovery(
                code: "network.generation.reset",
                phase: "events",
                reason: .targetChanged
            )
        case let .event(_, .page(routed)):
            if case let .frameNavigated(frame) = routed.value, frame.parentID == nil {
                if duringBootstrap { return }
                throw recovery(
                    code: "network.main-frame.navigated",
                    phase: "events",
                    reason: .targetChanged
                )
            }
            if case let .frameDetached(frameID) = routed.value {
                let transaction = try staged.targetWasLost(
                    WebInspectorTarget.ID(frameID.rawValue)
                )
                if let transaction {
                    if publishesTransaction {
                        try await commit(transaction, staged: staged)
                    }
                    removeMissingLocators(staged: staged, locators: &locators)
                }
            }
        case let .event(_, .network(routed)):
            let route = try featureScope(from: routed)
            let canonicalScope = networkScope(
                for: routed,
                route: route,
                timeline: timeline,
                staged: staged
            )
            guard let transaction = try staged.reduce(
                routed.value,
                scope: canonicalScope,
                origin: origin
            ) else {
                installLiveLocators(from: staged, into: &locators)
                return
            }
            if publishesTransaction {
                try await commit(transaction, staged: staged)
            }
            installLiveLocators(from: staged, into: &locators)
        }
    }

    private func commit(
        _ canonical: CanonicalNetworkTransaction,
        staged: CanonicalNetworkStore
    ) async throws {
        guard let storeSink else { throw WebInspectorCommandError.containerClosed }
        var transaction = WebInspectorModelTransaction()
        append(canonical, staged: staged, to: &transaction)
        guard !transaction.isEmpty else { return }
        let revision = try await storeSink.commit(transaction)
        refreshReadyRevision(revision)
    }

    private func append(
        _ canonical: CanonicalNetworkTransaction,
        staged: CanonicalNetworkStore,
        to transaction: inout WebInspectorModelTransaction
    ) {
        let mutations = webInspectorNetworkMutations(canonical, staged: staged)
        transaction.append(contentsOf: mutations.requests)
        transaction.append(contentsOf: mutations.entries)
    }

    private func appendReplacement(
        previous: CanonicalNetworkSnapshot?,
        current: CanonicalNetworkSnapshot,
        to transaction: inout WebInspectorModelTransaction
    ) {
        let currentRequestIDs = Set(current.requests.map { NetworkRequest.ID(canonical: $0.record.id) })
        let currentEntryIDs = Set(current.entries.map { NetworkEntry.ID(canonical: $0.record.id) })
        if let previous {
            transaction.append(contentsOf: previous.requests.compactMap { entry in
                let id = NetworkRequest.ID(canonical: entry.record.id)
                return currentRequestIDs.contains(id)
                    ? nil
                    : webInspectorNetworkRequestSchema.delete(id: id)
            })
            transaction.append(contentsOf: previous.entries.compactMap { entry in
                let id = NetworkEntry.ID(canonical: entry.record.id)
                return currentEntryIDs.contains(id)
                    ? nil
                    : webInspectorNetworkEntrySchema.delete(id: id)
            })
        }
        let mutations = webInspectorNetworkSnapshotMutations(current)
        transaction.append(contentsOf: mutations.requests)
        transaction.append(contentsOf: mutations.entries)
    }

    private func snapshotResources(
        _ root: Page.ResourceTree
    ) -> [CanonicalNetworkSnapshotResource] {
        var result: [CanonicalNetworkSnapshotResource] = []
        func append(tree: Page.ResourceTree) {
            if !tree.frame.url.isEmpty {
                result.append(
                    CanonicalNetworkSnapshotResource(
                        frameID: tree.frame.id,
                        loaderID: tree.frame.loaderID,
                        url: tree.frame.url,
                        type: .document,
                        mimeType: tree.frame.mimeType ?? "text/html",
                        failed: false,
                        canceled: false,
                        sourceMapURL: nil
                    )
                )
            }
            for resource in tree.resources where !resource.url.isEmpty {
                result.append(
                    CanonicalNetworkSnapshotResource(
                        frameID: tree.frame.id,
                        loaderID: tree.frame.loaderID,
                        url: resource.url,
                        type: resource.type,
                        mimeType: resource.mimeType,
                        failed: resource.failed,
                        canceled: resource.canceled,
                        sourceMapURL: resource.sourceMapURL
                    )
                )
            }
            for child in tree.childFrames { append(tree: child) }
        }
        append(tree: root)
        return result
    }

    private func snapshotScope(
        for resource: CanonicalNetworkSnapshotResource,
        route: WebInspectorFeatureEventScope
    ) -> WebInspectorCanonicalNetworkEventScope {
        WebInspectorCanonicalNetworkEventScope(
            modelScope: route,
            membership: CanonicalNetworkRequestMembership(
                pageGeneration: route.generation,
                agentTargetID: route.agentTargetID,
                origin: .mappedFrame(
                    frameID: resource.frameID,
                    targetID: route.semanticTargetID
                ),
                targetAuthority: CanonicalNetworkRegisteredTargetAuthority(
                    targetID: route.semanticTargetID,
                    navigationEpoch: route.generation,
                    domBindingEpoch: nil
                ),
                frameID: resource.frameID,
                loaderID: resource.loaderID
            )
        )
    }

    private func installLiveLocators(
        from staged: CanonicalNetworkStore,
        into locators: inout [CanonicalNetworkRequestIDStorage: WebInspectorNetworkBodyLocator]
    ) {
        for record in staged.requests {
            guard let alias = staged.rawRequestAlias(for: record.id) else {
                continue
            }
            let request = record.currentHop.request
            let rawID = Network.Request.ID(
                alias.rawRequestID.unscopedRawValue,
                scopedToTargetRawValue: alias.agentTargetID.rawValue
            )
            let backend = request.backendResourceIdentifier.map {
                Network.BackendResourceID(
                    sourceProcessID: $0.sourceProcessID,
                    resourceID: $0.resourceID
                )
            }
            locators[record.id] = .network(
                rawID: rawID,
                backendResourceIdentifier: backend
            )
        }
    }

    private func removeMissingLocators(
        staged: CanonicalNetworkStore,
        locators: inout [CanonicalNetworkRequestIDStorage: WebInspectorNetworkBodyLocator]
    ) {
        let current = Set(staged.requests.map(\.id))
        locators = locators.filter { current.contains($0.key) }
    }

    private func networkScope(
        for event: WebInspectorRoutedEvent<Network.Event>,
        route: WebInspectorFeatureEventScope,
        timeline: WebInspectorDOMBindingTimeline,
        staged: CanonicalNetworkStore
    ) -> WebInspectorCanonicalNetworkEventScope {
        if case let .requestWillBeSent(_, request, _, _, _, _) = event.value,
            let rawOrigin = request.origin
        {
            let semanticTargetID = rawOrigin.targetID.map(WebInspectorTarget.ID.init)
                ?? route.semanticTargetID
            let origin: CanonicalNetworkRequestOrigin = rawOrigin.targetID == nil
                ? .mappedFrame(frameID: rawOrigin.frameID, targetID: semanticTargetID)
                : .protocolTarget(semanticTargetID)
            let binding = timeline.scope(
                at: event.sequence.rawValue,
                generation: route.generation,
                semanticTargetID: semanticTargetID,
                agentTargetID: route.agentTargetID
            )
            let membership = CanonicalNetworkRequestMembership(
                pageGeneration: route.generation,
                agentTargetID: route.agentTargetID,
                origin: origin,
                targetAuthority: CanonicalNetworkRegisteredTargetAuthority(
                    targetID: semanticTargetID,
                    navigationEpoch: route.generation,
                    domBindingEpoch: binding?.bindingScopeID
                ),
                frameID: rawOrigin.frameID,
                loaderID: rawOrigin.loaderID
            )
            return WebInspectorCanonicalNetworkEventScope(
                modelScope: route,
                membership: membership
            )
        }
        if let rawID = rawRequestID(in: event.value),
            case let .existing(membership) = staged.requestOriginResolution(
                forRawRequestID: rawID,
                scope: WebInspectorCanonicalNetworkEventScope(modelScope: route)
            )
        {
            return WebInspectorCanonicalNetworkEventScope(
                modelScope: route,
                membership: membership
            )
        }
        return WebInspectorCanonicalNetworkEventScope(modelScope: route)
    }

    private func rawRequestID(in event: Network.Event) -> Network.Request.ID? {
        switch event {
        case let .requestWillBeSent(id, _, _, _, _, _),
            let .responseReceived(id, _, _, _),
            let .dataReceived(id, _, _, _),
            let .loadingFinished(id, _, _, _),
            let .loadingFailed(id, _, _, _),
            let .requestServedFromMemoryCache(id, _, _, _, _):
            id
        case let .webSocket(event):
            switch event {
            case let .created(id, _),
                let .handshakeRequest(id, _, _),
                let .handshakeResponse(id, _, _),
                let .closed(id, _),
                let .frameSent(id, _, _),
                let .frameReceived(id, _, _),
                let .error(id, _, _):
                id
            case .other:
                nil
            }
        case .unknown:
            nil
        }
    }

    private func featureScope<Value: Sendable>(
        from event: WebInspectorRoutedEvent<Value>
    ) throws -> WebInspectorFeatureEventScope {
        guard let semantic = event.semanticTarget, let agent = event.agentTarget else {
            throw recovery(
                code: "network.route.missing",
                phase: "events",
                reason: .malformedDomainEvent(
                    WebInspectorFailureDescription(
                        code: "network.route.missing",
                        phase: "events",
                        message: "Network event lacked semantic or agent target authority."
                    )
                )
            )
        }
        return WebInspectorFeatureEventScope(
            generation: WebInspectorPageGeneration(rawValue: event.generation.rawValue),
            semanticTarget: WebInspectorFeatureTarget(semantic),
            agentTarget: WebInspectorFeatureTarget(agent)
        )
    }

    private func featureScope<Value: Sendable>(
        from reply: WebInspectorScopedReply<Value>
    ) throws -> WebInspectorFeatureEventScope {
        guard let semantic = reply.semanticTarget, let agent = reply.agentTarget else {
            throw WebInspectorFeatureError.bootstrap(
                WebInspectorFailureDescription(
                    code: "network.bootstrap.route",
                    phase: "bootstrap",
                    message: "Page.getResourceTree reply lacked target authority."
                )
            )
        }
        return WebInspectorFeatureEventScope(
            generation: WebInspectorPageGeneration(rawValue: reply.generation.rawValue),
            semanticTarget: WebInspectorFeatureTarget(semantic),
            agentTarget: WebInspectorFeatureTarget(agent)
        )
    }

    private func invalidatesBootstrap(
        _ event: WebInspectorPageEvent<WebInspectorNetworkWireEvent>,
        resourceTree: Page.ResourceTree
    ) -> Bool {
        switch event {
        case .reset:
            return true
        case let .event(_, .page(routed)):
            if case let .frameNavigated(frame) = routed.value {
                guard frame.parentID == nil else { return false }
                guard frame.id == resourceTree.frame.id,
                    let eventLoaderID = frame.loaderID,
                    let snapshotLoaderID = resourceTree.frame.loaderID
                else { return true }
                return eventLoaderID != snapshotLoaderID
            } else {
                return false
            }
        case .event:
            return false
        }
    }

    private func recovery(
        code: String,
        phase: String,
        reason: WebInspectorRecoveryReason
    ) -> WebInspectorNetworkRecoveryRequest {
        WebInspectorNetworkRecoveryRequest(
            reason: reason,
            fingerprint: WebInspectorRecoveryFingerprint(
                code: code,
                phase: phase
            )
        )
    }

    private func transition(to newState: WebInspectorFeatureState) {
        webInspectorLogFeatureTransition(feature: .network, from: state, to: newState)
        state = newState
        registry.publish(newState, for: .network)
    }

    private func publish(_ newState: WebInspectorFeatureState) async {
        if let storeSink {
            var transaction = WebInspectorModelTransaction()
            transaction.setFeatureState(newState, for: .network)
            if let revision = try? await storeSink.commit(transaction),
                case let .ready(generation, _) = newState
            {
                transition(to: .ready(generation: generation, revision: revision))
                return
            }
        }
        transition(to: newState)
    }

    private func refreshReadyRevision(_ revision: WebInspectorStoreRevision) {
        guard case let .ready(generation, _) = state else { return }
        transition(to: .ready(generation: generation, revision: revision))
    }

    private func currentGeneration() async -> WebInspectorPageGeneration {
        guard let connection,
            let generation = try? await connection.page.generation
        else { return WebInspectorPageGeneration(rawValue: 0) }
        return WebInspectorPageGeneration(rawValue: generation.rawValue)
    }

    private func isConnectionTerminal(_ error: any Error) -> Bool {
        guard let proxy = error as? WebInspectorProxyError else { return false }
        switch proxy {
        case .closed, .disconnected, .transportFailure:
            return true
        default:
            return false
        }
    }

    private func termination(for error: any Error) -> WebInspectorFeatureTermination {
        if error is CancellationError { return .detached }
        return .connectionFailed(
            connectionFailure(
                code: "network.connection",
                phase: "events",
                message: String(describing: error)
            )
        )
    }

    private func becomeUnavailable(
        _ error: WebInspectorFeatureError,
        generation: WebInspectorPageGeneration? = nil
    ) async -> WebInspectorFeatureTermination {
        await orderedScope?.close()
        orderedScope = nil
        guard !closeRequested else { return .detached }
        let unavailableGeneration: WebInspectorPageGeneration
        if let generation {
            unavailableGeneration = generation
        } else {
            unavailableGeneration = await currentGeneration()
        }
        await publish(
            .unavailable(
                generation: unavailableGeneration,
                error: error
            )
        )
        return .detached
    }

    private func connectionFailure(
        code: String,
        phase: String,
        message: String
    ) -> WebInspectorConnectionFailure {
        .native(WebInspectorFailureDescription(code: code, phase: phase, message: message))
    }
}

/// Public typed facade over the container-owned Network feature actor.
public final class WebInspectorNetwork: WebInspectorFeatureHandle, Sendable {
    private let owner: WebInspectorNetworkFeature
    private let registry: WebInspectorFeatureRegistry

    package init(
        owner: WebInspectorNetworkFeature,
        registry: WebInspectorFeatureRegistry
    ) {
        self.owner = owner
        self.registry = registry
    }

    public var state: WebInspectorFeatureState { registry.state(for: .network) }
    public var stateUpdates: WebInspectorStateUpdates<WebInspectorFeatureState> {
        registry.updates(for: .network)
    }

    public func clear() async throws { try await owner.clear() }
    public func responseBody(for id: NetworkRequest.ID) async throws -> Network.Body {
        try await owner.responseBody(for: id)
    }
}
