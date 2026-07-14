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

    private struct SnapshotResource: Sendable {
        let rawID: Network.Request.ID
        let frameID: FrameID
        let loaderID: String
        let url: String
        let type: Network.ResourceType
        let mimeType: String
        let failed: Bool
        let canceled: Bool
        let sourceMapURL: String?
    }

    private let registry: WebInspectorFeatureRegistry
    private var connection: WebInspectorFeatureConnection?
    private var storeSink: WebInspectorModelStoreSink?
    private var orderedScope: WebInspectorOrderedEventScope<WebInspectorNetworkWireEvent>?
    private var canonicalStore: CanonicalNetworkStore?
    private var bodyLocators: [CanonicalNetworkRequestIDStorage: WebInspectorNetworkBodyLocator] = [:]
    private var state: WebInspectorFeatureState = .disabled
    private var recoveryBudget = WebInspectorFeatureRecoveryBudget()
    private var closeRequested = false
    private var explicitRetryRequested = false
    private var retryWaiter: CheckedContinuation<Void, Never>?

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
        explicitRetryRequested = false
        recoveryBudget = WebInspectorFeatureRecoveryBudget()
        canonicalStore = CanonicalNetworkStore(storeID: connection.storeID)
        bodyLocators.removeAll(keepingCapacity: true)
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
                await orderedScope?.close()
                orderedScope = nil
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
                    await publish(
                        .unavailable(
                            generation: generation,
                            error: .recoveryBudgetExhausted(summary)
                        )
                    )
                    await waitForExplicitRetry()
                    recoveryBudget.begin(
                        generation: await currentGeneration(),
                        explicitRetry: true
                    )
                }
            } catch {
                await orderedScope?.close()
                orderedScope = nil
                if isConnectionTerminal(error) {
                    return termination(for: error)
                }
                let generation = await currentGeneration()
                await publish(
                    .unavailable(
                        generation: generation,
                        error: .bootstrap(
                            webInspectorFailureDescription(
                                error,
                                code: "network.bootstrap.failed",
                                phase: "bootstrap"
                            )
                        )
                    )
                )
                await waitForExplicitRetry()
                recoveryBudget.begin(
                    generation: await currentGeneration(),
                    explicitRetry: true
                )
            }
        }
        return .detached
    }

    package func retry() async {
        guard case .unavailable = state else { return }
        explicitRetryRequested = true
        retryWaiter?.resume()
        retryWaiter = nil
    }

    package func close() async {
        guard !closeRequested else { return }
        closeRequested = true
        explicitRetryRequested = true
        retryWaiter?.resume()
        retryWaiter = nil
        await orderedScope?.close()
        orderedScope = nil
        if var canonicalStore, let storeSink {
            let transaction = canonicalStore.clear()
            var modelTransaction = WebInspectorModelTransaction()
            append(transaction, staged: canonicalStore, to: &modelTransaction)
            modelTransaction.setFeatureState(.disabled, for: .network)
            _ = try? await storeSink.commit(modelTransaction)
            self.canonicalStore = canonicalStore
        }
        bodyLocators.removeAll(keepingCapacity: true)
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
        let scope = try await connection.page.orderedScope(
            descriptor: descriptor,
            buffering: .bounded(4_096)
        )
        orderedScope = scope
        let reply = try await scope.command(PageWireCoding.resourceTree())
        let prefix = try await scope.drain(through: reply.boundary)
        if prefix.contains(where: invalidatesBootstrap) {
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
        var staged = CanonicalNetworkStore(storeID: connection.storeID)
        _ = try staged.reset(
            attachmentGeneration: connection.attachmentGeneration,
            pageGeneration: route.generation
        )
        var stagedLocators: [CanonicalNetworkRequestIDStorage: WebInspectorNetworkBodyLocator] = [:]
        let observedResources = prefixResourceKeys(prefix)
        for resource in snapshotResources(reply.value)
        where !observedResources.contains(resourceKey(frameID: resource.frameID, url: resource.url)) {
            try reduceSnapshotResource(
                resource,
                route: route,
                staged: &staged,
                locators: &stagedLocators
            )
        }
        for event in prefix {
            try await reduce(
                event,
                timeline: timeline,
                staged: &staged,
                locators: &stagedLocators,
                origin: .enableReplay
            )
        }

        let oldSnapshot = canonicalStore?.snapshot
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
        transition(to: .ready(generation: route.generation, revision: revision))

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
                    origin: .live
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
    }

    private func reduce(
        _ pageEvent: WebInspectorPageEvent<WebInspectorNetworkWireEvent>,
        timeline: WebInspectorDOMBindingTimeline,
        staged: inout CanonicalNetworkStore,
        locators: inout [CanonicalNetworkRequestIDStorage: WebInspectorNetworkBodyLocator],
        origin: CanonicalNetworkEventOrigin
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
                    try await commit(transaction, staged: staged)
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
            ) else { return }
            try await commit(transaction, staged: staged)
            installLiveLocators(from: staged, into: &locators)
        }
    }

    private func reduceSnapshotResource(
        _ resource: SnapshotResource,
        route: WebInspectorFeatureEventScope,
        staged: inout CanonicalNetworkStore,
        locators: inout [CanonicalNetworkRequestIDStorage: WebInspectorNetworkBodyLocator]
    ) throws {
        let membership = CanonicalNetworkRequestMembership(
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
        let scope = WebInspectorCanonicalNetworkEventScope(
            modelScope: route,
            membership: membership
        )
        let request = Network.Request(
            id: resource.rawID,
            url: resource.url,
            method: "GET"
        )
        let initiator = Network.Initiator(kind: "other")
        if let transaction = try staged.reduce(
            .requestWillBeSent(
                id: resource.rawID,
                request: request,
                initiator: initiator,
                resourceType: resource.type,
                redirectResponse: nil,
                timestamp: 0
            ),
            scope: scope,
            origin: .enableReplay
        ) {
            _ = transaction
        }
        let response = Network.Response(
            url: resource.url,
            mimeType: resource.mimeType
        )
        _ = try staged.reduce(
            .responseReceived(
                id: resource.rawID,
                response: response,
                resourceType: resource.type,
                timestamp: 0
            ),
            scope: scope,
            origin: .enableReplay
        )
        if resource.failed || resource.canceled {
            _ = try staged.reduce(
                .loadingFailed(
                    id: resource.rawID,
                    errorText: "Page.getResourceTree reported an unavailable resource.",
                    canceled: resource.canceled,
                    timestamp: 0
                ),
                scope: scope,
                origin: .enableReplay
            )
        } else {
            _ = try staged.reduce(
                .loadingFinished(
                    id: resource.rawID,
                    timestamp: 0,
                    sourceMapURL: resource.sourceMapURL,
                    metrics: nil
                ),
                scope: scope,
                origin: .enableReplay
            )
        }
        if let id = staged.requestID(forRawRequestID: resource.rawID) {
            locators[id] = .page(frameID: resource.frameID, url: resource.url)
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

    private func snapshotResources(_ root: Page.ResourceTree) -> [SnapshotResource] {
        var ordinal: UInt64 = 0
        var result: [SnapshotResource] = []
        func append(tree: Page.ResourceTree) {
            let loaderID = tree.frame.loaderID ?? "resource-tree"
            func makeID(_ url: String) -> Network.Request.ID {
                ordinal &+= 1
                return Network.Request.ID(
                    "resource-tree:\(tree.frame.id.rawValue):\(ordinal):\(url)"
                )
            }
            if !tree.frame.url.isEmpty {
                result.append(
                    SnapshotResource(
                        rawID: makeID(tree.frame.url),
                        frameID: tree.frame.id,
                        loaderID: loaderID,
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
                    SnapshotResource(
                        rawID: makeID(resource.url),
                        frameID: tree.frame.id,
                        loaderID: loaderID,
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

    private func prefixResourceKeys(
        _ events: [WebInspectorPageEvent<WebInspectorNetworkWireEvent>]
    ) -> Set<String> {
        Set(events.compactMap { event in
            guard case let .event(_, .network(routed)) = event,
                case let .requestWillBeSent(_, request, _, _, _, _) = routed.value,
                let origin = request.origin
            else { return nil }
            return resourceKey(frameID: origin.frameID, url: request.url)
        })
    }

    private func resourceKey(frameID: FrameID, url: String) -> String {
        "\(frameID.rawValue)\u{1F}\(url)"
    }

    private func installLiveLocators(
        from staged: CanonicalNetworkStore,
        into locators: inout [CanonicalNetworkRequestIDStorage: WebInspectorNetworkBodyLocator]
    ) {
        for record in staged.requests where locators[record.id] == nil {
            let request = record.currentHop.request
            let rawID = Network.Request.ID(
                request.rawID.unscopedRawValue,
                scopedToTargetRawValue: record.id.agentTargetID.rawValue
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
        _ event: WebInspectorPageEvent<WebInspectorNetworkWireEvent>
    ) -> Bool {
        switch event {
        case .reset:
            true
        case let .event(_, .page(routed)):
            if case let .frameNavigated(frame) = routed.value {
                frame.parentID == nil
            } else {
                false
            }
        case .event:
            false
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

    private func waitForExplicitRetry() async {
        if explicitRetryRequested {
            explicitRetryRequested = false
            return
        }
        await withCheckedContinuation { retryWaiter = $0 }
        explicitRetryRequested = false
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

    public func retry() async { await owner.retry() }
    public func clear() async throws { try await owner.clear() }
    public func responseBody(for id: NetworkRequest.ID) async throws -> Network.Body {
        try await owner.responseBody(for: id)
    }
}
