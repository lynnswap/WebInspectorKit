import Foundation
import WebInspectorProxyKit

package enum WebInspectorNetworkWireEvent: Sendable {
    case network(WebInspectorRoutedEvent<Network.Event>)
    case page(WebInspectorRoutedEvent<Page.Event>)
    case domDocumentUpdated(WebInspectorRoutedEvent<DOM.Event>)
}

private struct WebInspectorNetworkFrameNavigationTimeline: Sendable {
    private struct Visit: Sendable {
        let loaderID: String
        let epoch: WebInspectorNavigationEpoch
    }

    private var committed: Visit?
    private var pendingEpochByLoaderID: [String: WebInspectorNavigationEpoch] = [:]
    private var lastAllocatedEpoch: WebInspectorNavigationEpoch

    init(initialLoaderID: String) {
        let initial = WebInspectorNavigationEpoch(rawValue: 0)
        committed = Visit(loaderID: initialLoaderID, epoch: initial)
        lastAllocatedEpoch = initial
    }

    mutating func epoch(for loaderID: String) -> WebInspectorNavigationEpoch {
        if let committed, committed.loaderID == loaderID {
            return committed.epoch
        }
        if let pending = pendingEpochByLoaderID[loaderID] {
            return pending
        }
        let epoch = allocateEpoch()
        pendingEpochByLoaderID[loaderID] = epoch
        return epoch
    }

    mutating func commit(loaderID: String) -> WebInspectorNavigationEpoch {
        if let committed, committed.loaderID == loaderID {
            pendingEpochByLoaderID.removeAll(keepingCapacity: true)
            return committed.epoch
        }
        let epoch: WebInspectorNavigationEpoch
        if let pending = pendingEpochByLoaderID[loaderID] {
            epoch = pending
        } else {
            epoch = allocateEpoch()
        }
        committed = Visit(loaderID: loaderID, epoch: epoch)
        pendingEpochByLoaderID.removeAll(keepingCapacity: true)
        return epoch
    }

    mutating func retire() {
        committed = nil
        pendingEpochByLoaderID.removeAll(keepingCapacity: true)
    }

    private mutating func allocateEpoch() -> WebInspectorNavigationEpoch {
        let (next, overflow) = lastAllocatedEpoch.rawValue.addingReportingOverflow(1)
        precondition(!overflow, "Network navigation epoch exhausted.")
        let epoch = WebInspectorNavigationEpoch(rawValue: next)
        lastAllocatedEpoch = epoch
        return epoch
    }
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

    private struct DOMBindingRouteKey: Hashable, Sendable {
        let attachmentGeneration: WebInspectorAttachmentGeneration
        let pageGeneration: WebInspectorPageGeneration
        let semanticTargetID: WebInspectorTarget.ID
        let agentTargetID: WebInspectorTarget.ID
    }

    private let registry: WebInspectorFeatureRegistry
    private let bindingBarrier: WebInspectorDOMBindingBarrier
    private let usesDOMBinding: Bool
    private var connection: WebInspectorFeatureConnection?
    private var storeSink: WebInspectorModelStoreSink?
    private var orderedScope: WebInspectorOrderedEventScope<WebInspectorNetworkWireEvent>?
    private var canonicalStore: CanonicalNetworkStore?
    private var bodyLocators: [CanonicalNetworkRequestIDStorage: WebInspectorNetworkBodyLocator] = [:]
    private var navigationTimelines: [
        FrameLoaderKey: WebInspectorNetworkFrameNavigationTimeline
    ] = [:]
    private var domDocumentCutByRoute: [DOMBindingRouteKey: UInt64] = [:]
    private var state: WebInspectorFeatureState = .disabled
    private var closeRequested = false
    private var isConsumingOrderedScopeEvents = false

    #if DEBUG
        package private(set) var liveLocatorRecordVisitCountForTesting = 0
        package private(set) var requestStartProcessingCountForTesting = 0

        package func resetLiveLocatorRecordVisitCountForTesting() {
            liveLocatorRecordVisitCountForTesting = 0
        }
    #endif

    package init(
        registry: WebInspectorFeatureRegistry,
        bindingBarrier: WebInspectorDOMBindingBarrier,
        usesDOMBinding: Bool
    ) {
        self.registry = registry
        self.bindingBarrier = bindingBarrier
        self.usesDOMBinding = usesDOMBinding
    }

    package func run(
        connection: WebInspectorFeatureConnection,
        store: WebInspectorModelStoreSink
    ) async -> WebInspectorFeatureTermination {
        self.connection = connection
        storeSink = store
        closeRequested = false
        navigationTimelines.removeAll(keepingCapacity: true)
        domDocumentCutByRoute.removeAll(keepingCapacity: true)
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
        var decoders = [
            NetworkWireCoding.eventDecoder.routed().map(WebInspectorNetworkWireEvent.network),
            PageWireCoding.eventDecoder.routed().map(WebInspectorNetworkWireEvent.page),
        ]
        let capabilities = [
            NetworkWireCoding.capability,
            PageWireCoding.capability,
        ]
        if usesDOMBinding {
            decoders.append(
                DOMWireCoding.eventDecoder
                    .filtering(
                        method: WebInspectorProtocolMethod(
                            rawValue: "DOM.documentUpdated"
                        )
                    )
                    .routed()
                    .map(WebInspectorNetworkWireEvent.domDocumentUpdated)
            )
        }
        let descriptor = WebInspectorOrderedScopeDescriptor<WebInspectorNetworkWireEvent>(
            decoders: decoders,
            capabilities: capabilities
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
                guard var staged = canonicalStore else { continue }
                var stagedLocators = bodyLocators
                do {
                    try await reduce(
                        event,
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
            navigationTimelines.removeAll(keepingCapacity: true)
            domDocumentCutByRoute.removeAll(keepingCapacity: true)
            installSnapshotNavigationTimelines(
                from: reply.value,
                agentTargetID: route.agentTargetID
            )
            let invalidatedSnapshotFrameIDs = try snapshotFrameIDsInvalidated(
                in: reply.value,
                by: prefix,
                agentTargetID: route.agentTargetID
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
                    staged: &staged,
                    locators: &stagedLocators,
                    origin: .enableReplay,
                    publishesTransaction: false
                )
            }
            if closeRequested { throw CancellationError() }
            for resource in snapshotResources(reply.value)
            where !invalidatedSnapshotFrameIDs.contains(resource.frameID)
            {
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
        staged: inout CanonicalNetworkStore,
        locators: inout [CanonicalNetworkRequestIDStorage: WebInspectorNetworkBodyLocator],
        origin: CanonicalNetworkEventOrigin,
        publishesTransaction: Bool
    ) async throws {
        switch pageEvent {
        case .reset:
            return
        case let .event(_, .domDocumentUpdated(routed)):
            guard case .documentUpdated = routed.value else { return }
            let route = try featureScope(from: routed)
            guard let connection else { throw CancellationError() }
            let key = domBindingRouteKey(
                attachmentGeneration: connection.attachmentGeneration,
                route: route
            )
            domDocumentCutByRoute[key] = max(
                domDocumentCutByRoute[key] ?? 0,
                routed.sequence.rawValue
            )
        case let .event(_, .page(routed)):
            let route = try featureScope(from: routed)
            switch routed.value {
            case let .frameNavigated(frame):
                commitNavigation(frame, route: route)
            case let .frameDetached(frameID):
                retireNavigation(
                    frameID: frameID
                )
            case .unknown:
                break
            }
        case let .event(_, .network(routed)):
            let route = try featureScope(from: routed)
            #if DEBUG
                if case .requestWillBeSent = routed.value {
                    requestStartProcessingCountForTesting += 1
                }
            #endif
            let canonicalScope = try await networkScope(
                for: routed,
                route: route,
                staged: staged
            )
            guard
                let transaction = try staged.reduce(
                    routed.value,
                scope: canonicalScope,
                origin: origin
                )
            else {
                return
            }
            if publishesTransaction {
                try await commit(transaction, staged: staged)
            }
            updateLiveLocators(
                for: transaction,
                staged: staged,
                locators: &locators
            )
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
        let epoch = navigationEpoch(
            agentTargetID: route.agentTargetID,
            frameID: resource.frameID,
            loaderID: resource.loaderID
        )
        return WebInspectorCanonicalNetworkEventScope(
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
                    navigationEpoch: epoch,
                    domBindingEpoch: nil
                ),
                frameID: resource.frameID,
                loaderID: resource.loaderID
            )
        )
    }

    private func updateLiveLocators(
        for transaction: CanonicalNetworkTransaction,
        staged: CanonicalNetworkStore,
        locators: inout [CanonicalNetworkRequestIDStorage: WebInspectorNetworkBodyLocator]
    ) {
        for change in transaction.requestChanges {
            let requestID: CanonicalNetworkRequestIDStorage
            switch change {
            case let .insert(record, _):
                requestID = record.id
            case let .update(id, _, _):
                requestID = id
            case let .delete(id):
                locators[id] = nil
                continue
            }
            guard let record = staged.request(for: requestID) else {
                preconditionFailure(
                    "A non-delete Network change lost its canonical request."
                )
            }
            #if DEBUG
                liveLocatorRecordVisitCountForTesting += 1
            #endif
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
        staged: CanonicalNetworkStore
    ) async throws -> WebInspectorCanonicalNetworkEventScope {
        if case let .requestWillBeSent(_, request, _, _, _, _) = event.value,
            let rawOrigin = request.origin
        {
            let canMapFrame: Bool
            switch route.agentTarget.kind {
            case .page, .frame:
                canMapFrame = true
            case .worker, .other:
                canMapFrame = false
            }
            let mapsToRoutedPage = canMapFrame
                && (
                    rawOrigin.targetID == nil
                        || rawOrigin.targetID == route.agentTargetID.rawValue
                        || rawOrigin.targetID == route.semanticTargetID.rawValue
                )
            let origin: CanonicalNetworkRequestOrigin
            let targetAuthority: CanonicalNetworkRegisteredTargetAuthority?
            if mapsToRoutedPage {
                origin = .mappedFrame(
                    frameID: rawOrigin.frameID,
                    targetID: route.semanticTargetID
                )
                let binding = try await domBindingScope(
                    at: event.sequence.rawValue,
                    route: route
                )
                targetAuthority = CanonicalNetworkRegisteredTargetAuthority(
                    targetID: route.semanticTargetID,
                    navigationEpoch: navigationEpoch(
                        agentTargetID: route.agentTargetID,
                        frameID: rawOrigin.frameID,
                        loaderID: rawOrigin.loaderID
                    ),
                    domBindingEpoch: binding?.bindingScopeID
                )
            } else {
                let protocolTargetID = rawOrigin.targetID.map(
                    WebInspectorTarget.ID.init
                ) ?? route.agentTargetID
                origin = .protocolTarget(protocolTargetID)
                targetAuthority = protocolTargetID == route.agentTargetID
                    ? CanonicalNetworkRegisteredTargetAuthority(
                        targetID: protocolTargetID,
                        navigationEpoch: WebInspectorNavigationEpoch(rawValue: 0),
                        domBindingEpoch: nil
                    )
                    : nil
            }
            let membership = CanonicalNetworkRequestMembership(
                pageGeneration: route.generation,
                agentTargetID: route.agentTargetID,
                origin: origin,
                targetAuthority: targetAuthority,
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
                    navigationEpoch: WebInspectorNavigationEpoch(rawValue: 0),
                    domBindingEpoch: nil
                ),
                frameID: nil,
                loaderID: nil
            )
        )
    }

    private func navigationEpoch(
        agentTargetID: WebInspectorTarget.ID,
        frameID: FrameID,
        loaderID: String?
    ) -> WebInspectorNavigationEpoch {
        guard let loaderID else {
            return WebInspectorNavigationEpoch(rawValue: 0)
        }
        let key = FrameLoaderKey(
            agentTargetID: agentTargetID,
            frameID: frameID
        )
        var timeline = navigationTimelines[key]
            ?? WebInspectorNetworkFrameNavigationTimeline(
                initialLoaderID: loaderID
            )
        let epoch = timeline.epoch(for: loaderID)
        navigationTimelines[key] = timeline
        return epoch
    }

    private func commitNavigation(
        _ frame: Page.Frame,
        route: WebInspectorFeatureEventScope
    ) {
        let key = FrameLoaderKey(
            agentTargetID: route.agentTargetID,
            frameID: frame.id
        )
        var timeline = navigationTimelines[key]
            ?? WebInspectorNetworkFrameNavigationTimeline(
                initialLoaderID: frame.loaderID
            )
        _ = timeline.commit(loaderID: frame.loaderID)
        navigationTimelines[key] = timeline
    }

    private func retireNavigation(
        frameID: FrameID
    ) {
        for key in navigationTimelines.keys where key.frameID == frameID {
            navigationTimelines[key]?.retire()
        }
    }

    private func installSnapshotNavigationTimelines(
        from tree: Page.ResourceTree,
        agentTargetID: WebInspectorTarget.ID
    ) {
        installNavigationTimelineIfNeeded(
            agentTargetID: agentTargetID,
            frameID: tree.frame.id,
            loaderID: tree.frame.loaderID
        )
        for child in tree.childFrames {
            installSnapshotNavigationTimelines(
                from: child,
                agentTargetID: agentTargetID
            )
        }
    }

    private func installNavigationTimelineIfNeeded(
        agentTargetID: WebInspectorTarget.ID,
        frameID: FrameID,
        loaderID: String
    ) {
        let key = FrameLoaderKey(
            agentTargetID: agentTargetID,
            frameID: frameID
        )
        if navigationTimelines[key] == nil {
            navigationTimelines[key] = WebInspectorNetworkFrameNavigationTimeline(
                initialLoaderID: loaderID
            )
        }
    }

    private func snapshotFrameIDsInvalidated(
        in tree: Page.ResourceTree,
        by events: [WebInspectorPageEvent<WebInspectorNetworkWireEvent>],
        agentTargetID: WebInspectorTarget.ID
    ) throws -> Set<FrameID> {
        var loaderIDByFrameID: [FrameID: String] = [:]
        var childFrameIDsByFrameID: [FrameID: [FrameID]] = [:]
        func record(_ tree: Page.ResourceTree) {
            loaderIDByFrameID[tree.frame.id] = tree.frame.loaderID
            childFrameIDsByFrameID[tree.frame.id] = tree.childFrames.map(\.frame.id)
            for child in tree.childFrames {
                record(child)
            }
        }
        record(tree)

        var invalidated: Set<FrameID> = []
        func invalidate(_ frameID: FrameID) {
            guard invalidated.insert(frameID).inserted else { return }
            for childFrameID in childFrameIDsByFrameID[frameID] ?? [] {
                invalidate(childFrameID)
            }
        }

        for event in events {
            guard case let .event(_, .page(routed)) = event else { continue }
            let route = try featureScope(from: routed)
            guard route.agentTargetID == agentTargetID else { continue }
            switch routed.value {
            case let .frameNavigated(frame):
                if let snapshotLoaderID = loaderIDByFrameID[frame.id],
                    snapshotLoaderID != frame.loaderID
                {
                    invalidate(frame.id)
                }
                loaderIDByFrameID[frame.id] = frame.loaderID
            case let .frameDetached(frameID):
                if loaderIDByFrameID[frameID] != nil {
                    invalidate(frameID)
                }
            case .unknown:
                continue
            }
        }
        return invalidated
    }

    private func domBindingScope(
        at sequence: UInt64,
        route: WebInspectorFeatureEventScope
    ) async throws -> WebInspectorCanonicalDOMEventScope? {
        guard usesDOMBinding, let connection, let storeSink else { return nil }
        let routeKey = domBindingRouteKey(
            attachmentGeneration: connection.attachmentGeneration,
            route: route
        )
        let requiredBoundary = domDocumentCutByRoute[routeKey]
        while true {
            try Task.checkCancellation()
            let observation = bindingBarrier.observation(
                for: connection.attachmentGeneration
            )
            if observation.isUnavailable { return nil }
            let timeline = await storeSink.metadataValue(
                for: webInspectorDOMBindingTimelineKey,
                default: WebInspectorDOMBindingTimeline()
            )
            if timeline.hasProcessed(
                through: requiredBoundary,
                attachmentGeneration: connection.attachmentGeneration,
                generation: route.generation,
                semanticTargetID: route.semanticTargetID,
                agentTargetID: route.agentTargetID
            ) {
                return timeline.scope(
                    at: sequence,
                    attachmentGeneration: connection.attachmentGeneration,
                    generation: route.generation,
                    semanticTargetID: route.semanticTargetID,
                    agentTargetID: route.agentTargetID
                )
            }
            if requiredBoundary == nil,
                case let .ready(generation, _) = registry.state(for: .dom),
                generation == route.generation
            {
                return nil
            }
            try await bindingBarrier.waitForChange(after: observation.version)
        }
    }

    private func domBindingRouteKey(
        attachmentGeneration: WebInspectorAttachmentGeneration,
        route: WebInspectorFeatureEventScope
    ) -> DOMBindingRouteKey {
        DOMBindingRouteKey(
            attachmentGeneration: attachmentGeneration,
            pageGeneration: route.generation,
            semanticTargetID: route.semanticTargetID,
            agentTargetID: route.agentTargetID
        )
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
