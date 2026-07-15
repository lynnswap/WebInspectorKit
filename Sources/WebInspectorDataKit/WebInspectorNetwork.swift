import Foundation
import WebInspectorProxyKit

package enum WebInspectorNetworkWireEvent: Sendable {
    case network(WebInspectorRoutedEvent<Network.Event>)
    case page(WebInspectorRoutedEvent<Page.Event>)
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

    private struct FrameLoaderKey: Hashable, Sendable {
        let agentTargetID: WebInspectorTarget.ID
        let frameID: FrameID
    }

    private let registry: WebInspectorFeatureRegistry
    private var connection: WebInspectorFeatureConnection?
    private var storeSink: WebInspectorModelStoreSink?
    private var orderedScope: WebInspectorOrderedEventScope<WebInspectorNetworkWireEvent>?
    private var canonicalStore: CanonicalNetworkStore?
    private var bodyLocators: [CanonicalNetworkRequestIDStorage: WebInspectorNetworkBodyLocator] = [:]
    private var navigationEpochs: [WebInspectorTarget.ID: WebInspectorNavigationEpoch] = [:]
    private var frameLoaderIDs: [FrameLoaderKey: String] = [:]
    private var state: WebInspectorFeatureState = .disabled
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
        navigationEpochs.removeAll(keepingCapacity: true)
        frameLoaderIDs.removeAll(keepingCapacity: true)
        if let canonicalStore {
            precondition(
                canonicalStore.storeID == connection.storeID,
                "A Network feature cannot move between container stores."
            )
        } else {
            canonicalStore = CanonicalNetworkStore(storeID: connection.storeID)
        }
        do {
            try await publish(.synchronizing(generation: try await currentGeneration()))
            try await runOrderedScope()
            return closeRequested
                ? .detached
                : .connectionFailed(
                    connectionFailure(
                        code: "network.scope.ended",
                        phase: "events",
                        message: "The Network event scope ended unexpectedly."
                    )
                )
        } catch is CancellationError {
            return .detached
        } catch let WebInspectorProxyError.unsupported(requirements) {
            await orderedScope?.close()
            orderedScope = nil
            guard !closeRequested else { return .detached }
            do {
                try await publish(
                    .unsupported(requirements: requirements.sorted())
                )
                return .detached
            } catch {
                return termination(for: error)
            }
        } catch {
            await orderedScope?.close()
            orderedScope = nil
            return closeRequested ? .detached : termination(for: error)
        }
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
            buffering: .unbounded
        )
        if closeRequested {
            await scope.close()
            throw CancellationError()
        }
        var didActivateReplacement = false
        do {
            try await bootstrapCurrentTarget(in: scope, storeSink: storeSink)
            orderedScope = scope
            didActivateReplacement = true
            await previousScope?.close()

            precondition(!isConsumingOrderedScopeEvents)
            isConsumingOrderedScopeEvents = true
            defer { isConsumingOrderedScopeEvents = false }
            for try await event in scope.events {
                if closeRequested { return }
                if case let .reset(generation) = event {
                    try await publish(
                        .synchronizing(
                            generation: WebInspectorPageGeneration(
                                rawValue: generation.rawValue
                            )
                        )
                    )
                    try await bootstrapCurrentTarget(
                        in: scope,
                        storeSink: storeSink
                    )
                    continue
                }
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
                        publishesTransaction: true
                    )
                } catch let error as CanonicalNetworkProtocolViolation {
                    throw connectionFailure(
                        code: "network.protocol.\(String(describing: error))",
                        phase: "events",
                        message: String(describing: error)
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

    private func bootstrapCurrentTarget(
        in scope: WebInspectorOrderedEventScope<WebInspectorNetworkWireEvent>,
        storeSink: WebInspectorModelStoreSink
    ) async throws {
        guard let connection else { throw CancellationError() }
        while !closeRequested {
            let reply = try await scope.command(PageWireCoding.resourceTree())
            let prefix = try await scope.drain(through: reply.boundary)
            if closeRequested { throw CancellationError() }
            if prefix.contains(where: invalidatesBootstrap) {
                try await publish(.synchronizing(generation: try await currentGeneration()))
                continue
            }

            let route = try featureScope(from: reply)
            navigationEpochs = [
                route.semanticTargetID: WebInspectorNavigationEpoch(rawValue: 0)
            ]
            frameLoaderIDs.removeAll(keepingCapacity: true)
            installFrameLoaders(
                from: reply.value,
                agentTargetID: route.agentTargetID
            )
            let timeline = await storeSink.metadataValue(
                for: webInspectorDOMBindingTimelineKey,
                default: WebInspectorDOMBindingTimeline()
            )
            let oldSnapshot = canonicalStore?.snapshot
            var staged =
                canonicalStore
                ?? CanonicalNetworkStore(storeID: connection.storeID)
            try staged.prepareBootstrap(
                attachmentGeneration: connection.attachmentGeneration,
                pageGeneration: route.generation
            )
            var stagedLocators = bodyLocators

            for event in prefix {
                try await reduce(
                    event,
                    timeline: timeline,
                    staged: &staged,
                    locators: &stagedLocators,
                    origin: .enableReplay,
                    publishesTransaction: false
                )
            }
            if closeRequested { throw CancellationError() }
            for resource in snapshotResources(reply.value) {
                let resourceScope = snapshotScope(for: resource, route: route)
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
            transition(to: .ready(generation: route.generation, revision: revision))
            return
        }
        throw CancellationError()
    }

    private func reduce(
        _ pageEvent: WebInspectorPageEvent<WebInspectorNetworkWireEvent>,
        timeline: WebInspectorDOMBindingTimeline,
        staged: inout CanonicalNetworkStore,
        locators: inout [CanonicalNetworkRequestIDStorage: WebInspectorNetworkBodyLocator],
        origin: CanonicalNetworkEventOrigin,
        publishesTransaction: Bool
    ) async throws {
        switch pageEvent {
        case .reset:
            return
        case let .event(_, .page(routed)):
            let route = try featureScope(from: routed)
            switch routed.value {
            case let .frameNavigated(frame):
                if origin == .live {
                    observeNavigation(frame, route: route)
                }
            case let .frameDetached(frameID):
                frameLoaderIDs = frameLoaderIDs.filter {
                    $0.key.frameID != frameID
                }
                let lostTargetID =
                    route.agentTarget.frameID == frameID
                    ? route.semanticTargetID
                    : WebInspectorTarget.ID(frameID.rawValue)
                let transaction = try staged.targetWasLost(
                    lostTargetID
                )
                if let transaction {
                    if publishesTransaction {
                        try await commit(transaction, staged: staged)
                    }
                    removeMissingLocators(staged: staged, locators: &locators)
                }
            case .unknown:
                break
            }
        case let .event(_, .network(routed)):
            let route = try featureScope(from: routed)
            let canonicalScope = networkScope(
                for: routed,
                route: route,
                timeline: timeline,
                staged: staged
            )
            guard
                let transaction = try staged.reduce(
                    routed.value,
                scope: canonicalScope,
                origin: origin
                )
            else {
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
            transaction.append(
                contentsOf: previous.requests.compactMap { entry in
                    let id = NetworkRequest.ID(canonical: entry.record.id)
                return currentRequestIDs.contains(id)
                    ? nil
                    : webInspectorNetworkRequestSchema.delete(id: id)
            })
            transaction.append(
                contentsOf: previous.entries.compactMap { entry in
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
                    navigationEpoch: navigationEpoch(
                        for: route.semanticTargetID
                    ),
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
            let semanticTargetID: WebInspectorTarget.ID
            if rawOrigin.targetID == route.agentTargetID.rawValue {
                semanticTargetID = route.semanticTargetID
            } else {
                semanticTargetID =
                    rawOrigin.targetID.map(WebInspectorTarget.ID.init)
                    ?? route.semanticTargetID
            }
            let origin: CanonicalNetworkRequestOrigin =
                rawOrigin.targetID == nil
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
                    navigationEpoch: navigationEpoch(for: semanticTargetID),
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
        return WebInspectorCanonicalNetworkEventScope(
            modelScope: route,
            membership: CanonicalNetworkRequestMembership(
                pageGeneration: route.generation,
                agentTargetID: route.agentTargetID,
                origin: .eventTarget(route.semanticTargetID),
                targetAuthority: CanonicalNetworkRegisteredTargetAuthority(
                    targetID: route.semanticTargetID,
                    navigationEpoch: navigationEpoch(
                        for: route.semanticTargetID
                    ),
                    domBindingEpoch: nil
                ),
                frameID: nil,
                loaderID: nil
            )
        )
    }

    private func navigationEpoch(
        for targetID: WebInspectorTarget.ID
    ) -> WebInspectorNavigationEpoch {
        navigationEpochs[targetID] ?? WebInspectorNavigationEpoch(rawValue: 0)
    }

    private func observeNavigation(
        _ frame: Page.Frame,
        route: WebInspectorFeatureEventScope
    ) {
        let key = FrameLoaderKey(
            agentTargetID: route.agentTargetID,
            frameID: frame.id
        )
        let previous = frameLoaderIDs.updateValue(frame.loaderID, forKey: key)
        guard previous != frame.loaderID,
            route.agentTarget.frameID == frame.id
        else {
            return
        }
        let current = navigationEpoch(for: route.semanticTargetID)
        let (next, overflow) = current.rawValue.addingReportingOverflow(1)
        precondition(!overflow, "Network navigation epoch exhausted.")
        navigationEpochs[route.semanticTargetID] = WebInspectorNavigationEpoch(
            rawValue: next
        )
    }

    private func installFrameLoaders(
        from tree: Page.ResourceTree,
        agentTargetID: WebInspectorTarget.ID
    ) {
        frameLoaderIDs[
            FrameLoaderKey(
                agentTargetID: agentTargetID,
                frameID: tree.frame.id
            )
        ] = tree.frame.loaderID
        for child in tree.childFrames {
            installFrameLoaders(
                from: child,
                agentTargetID: agentTargetID
            )
        }
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
            throw connectionFailure(
                code: "network.route.missing",
                        phase: "events",
                        message: "Network event lacked semantic or agent target authority."
            )
        }
        let agentTarget = WebInspectorFeatureTarget(agent)
        let semanticTarget =
            agentTarget.kind == .frame
            ? agentTarget
            : WebInspectorFeatureTarget(semantic)
        return WebInspectorFeatureEventScope(
            generation: WebInspectorPageGeneration(rawValue: event.generation.rawValue),
            semanticTarget: semanticTarget,
            agentTarget: agentTarget
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
            return true
        case .event:
            return false
        }
    }

    private func transition(to newState: WebInspectorFeatureState) {
        webInspectorLogFeatureTransition(feature: .network, from: state, to: newState)
        state = newState
        registry.publish(newState, for: .network)
    }

    private func publish(_ newState: WebInspectorFeatureState) async throws {
        if let storeSink {
            var transaction = WebInspectorModelTransaction()
            transaction.setFeatureState(newState, for: .network)
            let revision = try await storeSink.commit(transaction)
            if case let .ready(generation, _) = newState {
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

    private func currentGeneration() async throws -> WebInspectorPageGeneration {
        guard let connection else { throw CancellationError() }
        let generation = try await connection.page.generation
        return WebInspectorPageGeneration(rawValue: generation.rawValue)
    }

    private func termination(for error: any Error) -> WebInspectorFeatureTermination {
        if error is CancellationError { return .detached }
        if let failure = error as? WebInspectorConnectionFailure {
            return .connectionFailed(failure)
        }
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

    public func clear() async throws { try await owner.clear() }
    public func responseBody(for id: NetworkRequest.ID) async throws -> Network.Body {
        try await owner.responseBody(for: id)
    }
}
