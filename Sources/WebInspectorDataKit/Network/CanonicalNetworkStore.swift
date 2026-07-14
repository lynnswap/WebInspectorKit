import Foundation
import WebInspectorProxyKit

package enum CanonicalNetworkEventOrigin: Equatable, Sendable {
    case live
    case enableReplay
}

package enum CanonicalNetworkRequestOriginResolution: Equatable, Sendable {
    case required
    case existing(CanonicalNetworkRequestMembership)
    case notRequired
}

/// A protocol invariant rejected before canonical state is mutated.
package enum CanonicalNetworkProtocolViolation: Error, Equatable, Sendable {
    case eventPayloadIdentifierMismatch(
        event: String,
        eventID: Network.Request.ID,
        payloadID: Network.Request.ID
    )
    case identityReuse(
        event: String,
        id: CanonicalNetworkRequestIDStorage
    )
    case tombstonedIdentityReuse(
        event: String,
        id: CanonicalNetworkRequestIDStorage
    )
    case rawRequestIdentifierCollision(
        rawID: Network.Request.ID,
        existingID: CanonicalNetworkRequestIDStorage,
        proposedID: CanonicalNetworkRequestIDStorage
    )
    case invalidRedirect(
        id: CanonicalNetworkRequestIDStorage,
        lifecycle: CanonicalNetworkLifecycle
    )
    case contentAfterTerminal(
        event: String,
        id: CanonicalNetworkRequestIDStorage,
        lifecycle: CanonicalNetworkLifecycle
    )
    case duplicateTerminal(
        event: String,
        id: CanonicalNetworkRequestIDStorage,
        lifecycle: CanonicalNetworkLifecycle
    )
    case conflictingReplay(
        event: String,
        id: CanonicalNetworkRequestIDStorage
    )
    case duplicateWebSocketEvent(
        event: String,
        id: CanonicalNetworkRequestIDStorage
    )
    case missingWebSocket(
        event: String,
        id: CanonicalNetworkRequestIDStorage
    )
    case invalidLength(
        event: String,
        field: String,
        value: Int
    )
}

package enum CanonicalNetworkStoreError: Error, Equatable, Sendable {
    package enum Counter: Equatable, Sendable {
        case requestOrdinal
        case entryOrdinal
        case responseBodyRevision
        case decodedDataLength
        case encodedDataLength
        case entryDecodedDataLength
        case entryEncodedDataLength
        case entryActiveRequestCount
        case entryFailedRequestCount
        case entryStatusSeverityCount
        case entryRequestCount
    }

    case counterExhausted(Counter)
    case nonmonotonicAttachmentGeneration(
        current: WebInspectorAttachmentGeneration,
        proposed: WebInspectorAttachmentGeneration
    )
    case nonmonotonicPageGeneration(
        current: WebInspectorPageGeneration,
        proposed: WebInspectorPageGeneration
    )
}

/// Pure Sendable canonical Network state owned by
/// `WebInspectorModelContainerCore`.
///
/// Contexts consume its complete snapshots and authoritative transactions;
/// they never repeat Network protocol semantics.
package struct CanonicalNetworkStore: Equatable, Sendable {
    private struct PendingWebSocket: Equatable, Sendable {
        let creationURL: String
        let membership: CanonicalNetworkRequestMembership
    }

    private struct EntryAggregateState: Equatable, Sendable {
        var activeRequestCount: Int
        var failedRequestCount: Int
        var decodedDataLength: Int
        var encodedDataLength: Int
        var statusSeverityCounts: [CanonicalNetworkEntryStatusSeverity: Int]
        var resourceCategoryCounts: [CanonicalNetworkResourceCategory: Int]
    }

    private struct PreparedEntryMutation: Equatable, Sendable {
        let record: CanonicalNetworkEntryRecord
        let query: CanonicalNetworkEntryQueryProjection
        let aggregate: EntryAggregateState
        let change: CanonicalNetworkEntryChange
        let isInsertion: Bool
        let didFullRebuild: Bool
        let didQueryRebuild: Bool
    }

    private struct PreparedInsertion: Equatable, Sendable {
        let request: CanonicalNetworkRequestRecord
        let requestQuery: CanonicalNetworkRequestQueryProjection
        let requestChange: CanonicalNetworkRequestChange
        let entry: PreparedEntryMutation
        let groupKey: CanonicalNetworkGroupKey
        let requestOrdinal: UInt64
        let entryOrdinal: UInt64?
        let memberIndexUpdates: [CanonicalNetworkRequestIDStorage: Int]
    }

    private struct PreparedUpdate: Equatable, Sendable {
        let request: CanonicalNetworkRequestRecord
        let requestQuery: CanonicalNetworkRequestQueryProjection
        let requestChange: CanonicalNetworkRequestChange
        let entry: PreparedEntryMutation?
    }

    package let storeID: WebInspectorContainerStoreID

    private var activeAttachmentGeneration: WebInspectorAttachmentGeneration?
    private var activePageGeneration: WebInspectorPageGeneration?
    private var requestsByID: [CanonicalNetworkRequestIDStorage: CanonicalNetworkRequestRecord]
    private var requestQueriesByID:
        [CanonicalNetworkRequestIDStorage:
            CanonicalNetworkRequestQueryProjection]
    private var entriesByID: [CanonicalNetworkEntryIDStorage: CanonicalNetworkEntryRecord]
    private var entryQueriesByID: [CanonicalNetworkEntryIDStorage: CanonicalNetworkEntryQueryProjection]
    private var entryAggregatesByID: [CanonicalNetworkEntryIDStorage: EntryAggregateState]
    private var entryIDByGroupKey: [CanonicalNetworkGroupKey: CanonicalNetworkEntryIDStorage]
    private var entryIDByRequestID: [CanonicalNetworkRequestIDStorage: CanonicalNetworkEntryIDStorage]
    private var memberIndexByRequestID: [CanonicalNetworkRequestIDStorage: Int]
    private var groupKeyByRequestID: [CanonicalNetworkRequestIDStorage: CanonicalNetworkGroupKey]
    private var scopedRequestIDByRawRequestID: [Network.Request.ID: CanonicalNetworkRequestIDStorage]
    private var requestIDsByAgentTargetID: [WebInspectorTarget.ID: Set<CanonicalNetworkRequestIDStorage>]
    private var requestIDsBySemanticTargetID: [WebInspectorTarget.ID: Set<CanonicalNetworkRequestIDStorage>]
    private var pendingWebSocketByID: [CanonicalNetworkRequestIDStorage: PendingWebSocket]
    private var tombstones: Set<CanonicalNetworkRequestIDStorage>
    private var lastRequestOrdinal: UInt64
    private var lastEntryOrdinal: UInt64
    #if DEBUG
        package struct PerformanceCounters: Equatable, Sendable {
            package var entryFullRebuildCount = 0
            package var entryFullRebuildMemberVisitCount = 0
            package var entryIncrementalUpdateCount = 0
            package var entryQueryRebuildCount = 0
            package var targetLossIndexLookupCount = 0
            package var targetLossFullScanCount = 0
        }

        private var performanceCounters: PerformanceCounters
    #endif

    package init(storeID: WebInspectorContainerStoreID) {
        self.storeID = storeID
        activeAttachmentGeneration = nil
        activePageGeneration = nil
        requestsByID = [:]
        requestQueriesByID = [:]
        entriesByID = [:]
        entryQueriesByID = [:]
        entryAggregatesByID = [:]
        entryIDByGroupKey = [:]
        entryIDByRequestID = [:]
        memberIndexByRequestID = [:]
        groupKeyByRequestID = [:]
        scopedRequestIDByRawRequestID = [:]
        requestIDsByAgentTargetID = [:]
        requestIDsBySemanticTargetID = [:]
        pendingWebSocketByID = [:]
        tombstones = []
        lastRequestOrdinal = 0
        lastEntryOrdinal = 0
        #if DEBUG
            performanceCounters = PerformanceCounters()
        #endif
    }

    package var attachmentGeneration: WebInspectorAttachmentGeneration? {
        activeAttachmentGeneration
    }

    package var pageGeneration: WebInspectorPageGeneration? {
        activePageGeneration
    }

    package var requests: [CanonicalNetworkRequestRecord] {
        requestsByID.values.sorted {
            $0.insertionOrdinal < $1.insertionOrdinal
        }
    }

    package var entries: [CanonicalNetworkEntryRecord] {
        entriesByID.values.sorted {
            $0.id.ordinal < $1.id.ordinal
        }
    }

    package var snapshot: CanonicalNetworkSnapshot {
        let requests = self.requests.map { record in
            guard let query = requestQueriesByID[record.id] else {
                preconditionFailure(
                    "Canonical Network snapshot lost a request query projection."
                )
            }
            return CanonicalNetworkRequestSnapshotEntry(
                record: record,
                query: query
            )
        }
        return CanonicalNetworkSnapshot(
            requests: requests,
            entries: entries.map {
                guard let query = entryQueriesByID[$0.id] else {
                    preconditionFailure(
                        "Canonical Network snapshot lost an entry query projection."
                    )
                }
                return CanonicalNetworkEntrySnapshotEntry(
                    record: $0,
                    query: query
                )
            }
        )
    }

    package var tombstonedRequestIDs: Set<CanonicalNetworkRequestIDStorage> {
        tombstones
    }

    #if DEBUG
        package var performanceCountersForTesting: PerformanceCounters {
            performanceCounters
        }

        package mutating func resetPerformanceCountersForTesting() {
            performanceCounters = PerformanceCounters()
        }
    #endif

    package func request(
        for id: CanonicalNetworkRequestIDStorage
    ) -> CanonicalNetworkRequestRecord? {
        requestsByID[id]
    }

    package func requestQuery(
        for id: CanonicalNetworkRequestIDStorage
    ) -> CanonicalNetworkRequestQueryProjection? {
        requestQueriesByID[id]
    }

    /// Resolves the active attachment/page raw identifier used by Console
    /// payloads.
    ///
    /// The returned identity may be reserved by `webSocketCreated` before its
    /// handshake inserts a request record.
    package func requestID(
        forRawRequestID rawID: Network.Request.ID
    ) -> CanonicalNetworkRequestIDStorage? {
        scopedRequestIDByRawRequestID[rawID]
    }

    package func requestOriginResolution(
        forRawRequestID rawID: Network.Request.ID,
        scope: WebInspectorCanonicalNetworkEventScope
    ) -> CanonicalNetworkRequestOriginResolution {
        if let id = scopedRequestIDByRawRequestID[rawID] {
            if let membership = requestsByID[id]?.membership {
                return .existing(membership)
            }
            return .notRequired
        }
        let id = canonicalID(rawID: rawID, scope: scope)
        return tombstones.contains(id) ? .notRequired : .required
    }

    package func entry(
        for id: CanonicalNetworkEntryIDStorage
    ) -> CanonicalNetworkEntryRecord? {
        entriesByID[id]
    }

    package func entryQuery(
        for id: CanonicalNetworkEntryIDStorage
    ) -> CanonicalNetworkEntryQueryProjection? {
        entryQueriesByID[id]
    }

    package func entry(
        containing requestID: CanonicalNetworkRequestIDStorage
    ) -> CanonicalNetworkEntryRecord? {
        guard let entryID = entryIDByRequestID[requestID] else {
            return nil
        }
        return entriesByID[entryID]
    }

    package func responseBodyLease(
        for id: CanonicalNetworkRequestIDStorage
    ) -> CanonicalNetworkResponseBodyLease? {
        guard let record = requestsByID[id],
            record.currentHop.response != nil,
            record.webSocket == nil
        else {
            return nil
        }
        return CanonicalNetworkResponseBodyLease(
            requestID: id,
            responseRevision: record.responseBodyRevision
        )
    }

    package func isCurrent(
        _ lease: CanonicalNetworkResponseBodyLease
    ) -> Bool {
        requestsByID[lease.requestID]?.responseBodyRevision
            == lease.responseRevision
    }

    /// Replaces attachment/page authority while preserving never-reused
    /// request and entry ordinal allocation.
    @discardableResult
    package mutating func reset(
        attachmentGeneration: WebInspectorAttachmentGeneration,
        pageGeneration: WebInspectorPageGeneration
    ) throws -> CanonicalNetworkTransaction {
        try validateReset(
            attachmentGeneration: attachmentGeneration,
            pageGeneration: pageGeneration
        )
        let transaction = deletionTransaction(
            requestIDs: Set(requestsByID.keys)
        )
        activeAttachmentGeneration = attachmentGeneration
        activePageGeneration = pageGeneration
        requestsByID.removeAll(keepingCapacity: true)
        requestQueriesByID.removeAll(keepingCapacity: true)
        entriesByID.removeAll(keepingCapacity: true)
        entryQueriesByID.removeAll(keepingCapacity: true)
        entryAggregatesByID.removeAll(keepingCapacity: true)
        entryIDByGroupKey.removeAll(keepingCapacity: true)
        entryIDByRequestID.removeAll(keepingCapacity: true)
        memberIndexByRequestID.removeAll(keepingCapacity: true)
        groupKeyByRequestID.removeAll(keepingCapacity: true)
        scopedRequestIDByRawRequestID.removeAll(keepingCapacity: true)
        requestIDsByAgentTargetID.removeAll(keepingCapacity: true)
        requestIDsBySemanticTargetID.removeAll(keepingCapacity: true)
        pendingWebSocketByID.removeAll(keepingCapacity: true)
        tombstones.removeAll(keepingCapacity: true)
        return transaction
    }

    /// Clears current membership and retains full scoped tombstones until the
    /// next Proxy generation reset.
    @discardableResult
    package mutating func clear() -> CanonicalNetworkTransaction {
        let removedIDs = Set(requestsByID.keys)
        let transaction = deletionTransaction(requestIDs: removedIDs)
        tombstones.formUnion(removedIDs)
        tombstones.formUnion(pendingWebSocketByID.keys)
        requestsByID.removeAll(keepingCapacity: true)
        requestQueriesByID.removeAll(keepingCapacity: true)
        entriesByID.removeAll(keepingCapacity: true)
        entryQueriesByID.removeAll(keepingCapacity: true)
        entryAggregatesByID.removeAll(keepingCapacity: true)
        entryIDByGroupKey.removeAll(keepingCapacity: true)
        entryIDByRequestID.removeAll(keepingCapacity: true)
        memberIndexByRequestID.removeAll(keepingCapacity: true)
        groupKeyByRequestID.removeAll(keepingCapacity: true)
        scopedRequestIDByRawRequestID.removeAll(keepingCapacity: true)
        requestIDsByAgentTargetID.removeAll(keepingCapacity: true)
        requestIDsBySemanticTargetID.removeAll(keepingCapacity: true)
        pendingWebSocketByID.removeAll(keepingCapacity: true)
        return transaction
    }

    /// Removes membership owned by a lost physical agent or semantic target
    /// without weakening tombstone authority.
    @discardableResult
    package mutating func targetWasLost(
        _ targetID: WebInspectorTarget.ID
    ) throws -> CanonicalNetworkTransaction? {
        let indexedIDs = (requestIDsByAgentTargetID[targetID] ?? [])
            .union(requestIDsBySemanticTargetID[targetID] ?? [])
        let removedIDs = Set(indexedIDs.filter { requestsByID[$0] != nil })
        let removedPendingWebSocketIDs = Set(
            indexedIDs.filter { pendingWebSocketByID[$0] != nil }
        )
        #if DEBUG
            performanceCounters.targetLossIndexLookupCount += 2
        #endif
        guard !removedIDs.isEmpty || !removedPendingWebSocketIDs.isEmpty else {
            return nil
        }
        let transaction =
            removedIDs.isEmpty
            ? nil
            : deletionTransaction(requestIDs: removedIDs)
        let removedEntryIDs = Set(
            removedIDs.compactMap {
                entryIDByRequestID[$0]
            })
        for entryID in removedEntryIDs {
            guard let entry = entriesByID[entryID],
                entry.requestIDs.allSatisfy(removedIDs.contains)
            else {
                preconditionFailure(
                    "A target-scoped Network entry crossed target-loss membership."
                )
            }
        }

        tombstones.formUnion(removedIDs)
        tombstones.formUnion(removedPendingWebSocketIDs)
        for requestID in removedIDs.union(removedPendingWebSocketIDs) {
            guard
                scopedRequestIDByRawRequestID[requestID.rawRequestID]
                    == requestID
            else {
                preconditionFailure(
                    "Canonical Network raw request lookup lost target authority."
                )
            }
            scopedRequestIDByRawRequestID[requestID.rawRequestID] = nil
        }
        for requestID in removedPendingWebSocketIDs {
            guard let pending = pendingWebSocketByID.removeValue(forKey: requestID) else {
                preconditionFailure(
                    "Canonical Network pending target index lost membership."
                )
            }
            removeFromTargetIndexes(
                requestID,
                membership: pending.membership
            )
        }
        for requestID in removedIDs {
            guard let record = requestsByID.removeValue(forKey: requestID) else {
                preconditionFailure(
                    "Canonical Network target index lost request membership."
                )
            }
            removeFromTargetIndexes(
                requestID,
                membership: record.membership
            )
            requestQueriesByID[requestID] = nil
            entryIDByRequestID[requestID] = nil
            memberIndexByRequestID[requestID] = nil
            groupKeyByRequestID[requestID] = nil
        }
        for entryID in removedEntryIDs {
            guard let entry = entriesByID.removeValue(forKey: entryID) else {
                preconditionFailure(
                    "Canonical Network target loss lost an entry record."
                )
            }
            entryQueriesByID[entryID] = nil
            entryAggregatesByID[entryID] = nil
            entryIDByGroupKey[entry.groupKey] = nil
        }
        return transaction
    }

    package mutating func reduce(
        _ event: Network.Event,
        scope: WebInspectorCanonicalNetworkEventScope,
        origin: CanonicalNetworkEventOrigin = .live
    ) throws -> CanonicalNetworkTransaction? {
        guard scope.generation == activePageGeneration,
            activeAttachmentGeneration != nil
        else {
            return nil
        }

        switch event {
        case let .requestWillBeSent(
            rawID,
            request,
            initiator,
            resourceType,
            redirectResponse,
            timestamp
        ):
            return try reduceRequestWillBeSent(
                rawID: rawID,
                request: request,
                initiator: initiator,
                resourceType: resourceType,
                redirectResponse: redirectResponse,
                timestamp: timestamp,
                scope: scope
            )
        case let .responseReceived(
            rawID,
            response,
            resourceType,
            timestamp
        ):
            return try reduceResponseReceived(
                rawID: rawID,
                response: response,
                resourceType: resourceType,
                timestamp: timestamp,
                scope: scope
            )
        case let .dataReceived(
            rawID,
            dataLength,
            encodedDataLength,
            timestamp
        ):
            return try reduceDataReceived(
                rawID: rawID,
                dataLength: dataLength,
                encodedDataLength: encodedDataLength,
                timestamp: timestamp,
                scope: scope
            )
        case let .loadingFinished(rawID, timestamp, sourceMapURL, metrics):
            return try reduceLoadingFinished(
                rawID: rawID,
                timestamp: timestamp,
                sourceMapURL: sourceMapURL,
                metrics: metrics,
                scope: scope
            )
        case let .loadingFailed(
            rawID,
            errorText,
            canceled,
            timestamp
        ):
            return try reduceLoadingFailed(
                rawID: rawID,
                errorText: errorText,
                canceled: canceled,
                timestamp: timestamp,
                scope: scope
            )
        case let .requestServedFromMemoryCache(
            rawID,
            response,
            initiator,
            resourceType,
            timestamp
        ):
            return try reduceMemoryCache(
                rawID: rawID,
                response: response,
                initiator: initiator,
                resourceType: resourceType,
                timestamp: timestamp,
                scope: scope
            )
        case let .webSocket(event):
            return try reduceWebSocket(
                event,
                scope: scope,
                origin: origin
            )
        case .unknown:
            return nil
        }
    }

    private func validateReset(
        attachmentGeneration: WebInspectorAttachmentGeneration,
        pageGeneration: WebInspectorPageGeneration
    ) throws {
        guard let currentAttachment = activeAttachmentGeneration else {
            return
        }
        if attachmentGeneration == currentAttachment {
            if let currentPage = activePageGeneration,
                pageGeneration.rawValue <= currentPage.rawValue
            {
                throw CanonicalNetworkStoreError.nonmonotonicPageGeneration(
                    current: currentPage,
                    proposed: pageGeneration
                )
            }
            return
        }
        guard attachmentGeneration > currentAttachment else {
            throw CanonicalNetworkStoreError.nonmonotonicAttachmentGeneration(
                current: currentAttachment,
                proposed: attachmentGeneration
            )
        }
    }

    private func canonicalID(
        rawID: Network.Request.ID,
        scope: WebInspectorCanonicalNetworkEventScope
    ) -> CanonicalNetworkRequestIDStorage {
        guard let attachmentGeneration = activeAttachmentGeneration else {
            preconditionFailure(
                "Canonical Network reduction requires active attachment authority."
            )
        }
        return CanonicalNetworkRequestIDStorage(
            storeID: storeID,
            attachmentGeneration: attachmentGeneration,
            pageGeneration: scope.generation,
            agentTargetID: scope.agentTargetID,
            rawRequestID: rawID
        )
    }

    private func requestMembership(
        for scope: WebInspectorCanonicalNetworkEventScope
    ) -> CanonicalNetworkRequestMembership {
        CanonicalNetworkRequestMembership(
            origin: scope.origin,
            targetAuthority: scope.targetAuthority,
            frameID: scope.frameID,
            loaderID: scope.loaderID
        )
    }

    private func validateRawRequestIDReservation(
        _ id: CanonicalNetworkRequestIDStorage
    ) throws {
        guard
            let existingID = scopedRequestIDByRawRequestID[
                id.rawRequestID
            ]
        else {
            return
        }
        guard existingID == id else {
            throw
                CanonicalNetworkProtocolViolation
                .rawRequestIdentifierCollision(
                    rawID: id.rawRequestID,
                    existingID: existingID,
                    proposedID: id
                )
        }
    }
}

private extension CanonicalNetworkStore {
    mutating func reduceRequestWillBeSent(
        rawID: Network.Request.ID,
        request: Network.Request,
        initiator: Network.Initiator,
        resourceType: Network.ResourceType?,
        redirectResponse: Network.Response?,
        timestamp: Double,
        scope: WebInspectorCanonicalNetworkEventScope
    ) throws -> CanonicalNetworkTransaction? {
        guard rawID == request.id else {
            throw
                CanonicalNetworkProtocolViolation
                .eventPayloadIdentifierMismatch(
                    event: "Network.requestWillBeSent",
                    eventID: rawID,
                    payloadID: request.id
                )
        }
        let id = canonicalID(rawID: rawID, scope: scope)
        if tombstones.contains(id) {
            if redirectResponse != nil {
                return nil
            }
            throw CanonicalNetworkProtocolViolation.tombstonedIdentityReuse(
                event: "Network.requestWillBeSent",
                id: id
            )
        }
        guard pendingWebSocketByID[id] == nil else {
            throw CanonicalNetworkProtocolViolation.identityReuse(
                event: "Network.requestWillBeSent",
                id: id
            )
        }

        if let existing = requestsByID[id] {
            guard let redirectResponse else {
                throw CanonicalNetworkProtocolViolation.identityReuse(
                    event: "Network.requestWillBeSent",
                    id: id
                )
            }
            let response = try normalizedResponse(
                redirectResponse,
                event: "Network.requestWillBeSent"
            )
            guard !existing.lifecycle.isTerminal else {
                throw CanonicalNetworkProtocolViolation.invalidRedirect(
                    id: id,
                    lifecycle: existing.lifecycle
                )
            }
            let revision = try incrementedResponseRevision(
                existing.responseBodyRevision
            )
            let redirect = CanonicalNetworkRedirectHop(
                currentHop: existing.currentHop,
                response: response,
                redirectTimestamp: timestamp
            )
            let resolvedResourceType =
                resourceType?.rawValue
                ?? existing.currentHop.resourceType
            let currentHop = CanonicalNetworkCurrentHop(
                request: CanonicalNetworkRequestPayload(request),
                resourceType: resolvedResourceType,
                requestSentTimestamp: timestamp
            )
            let patch = CanonicalNetworkRequestPatch.redirect(
                appendedHop: redirect,
                currentHop: currentHop,
                lifecycle: .pending,
                allowsMultipartContinuation: false,
                responseBodyRevision: revision
            )
            var replacement = existing
            replacement.apply(patch)
            return commit(
                try prepareUpdate(
                    replacement,
                    patch: patch
                ))
        }

        // A replay may begin in the middle of a redirect chain. Without the
        // prior request payload there is no complete hop to invent, so the
        // current request becomes the first authoritative record.
        let insertion = try prepareNewRequest(
            id: id,
            request: CanonicalNetworkRequestPayload(request),
            initiator: CanonicalNetworkInitiator(initiator),
            resourceType: resourceType?.rawValue,
            timestamp: timestamp,
            scope: scope
        )
        return commit(insertion)
    }

    mutating func reduceResponseReceived(
        rawID: Network.Request.ID,
        response: Network.Response,
        resourceType: Network.ResourceType?,
        timestamp: Double,
        scope: WebInspectorCanonicalNetworkEventScope
    ) throws -> CanonicalNetworkTransaction? {
        let id = canonicalID(rawID: rawID, scope: scope)
        guard !tombstones.contains(id) else {
            return nil
        }
        guard pendingWebSocketByID[id] == nil else {
            throw CanonicalNetworkProtocolViolation.identityReuse(
                event: "Network.responseReceived",
                id: id
            )
        }
        if requestsByID[id] == nil, response.url == nil {
            return nil
        }
        let normalizedResponse = try normalizedResponse(
            response,
            event: "Network.responseReceived"
        )
        guard let existing = requestsByID[id] else {
            guard let url = normalizedResponse.url else {
                preconditionFailure(
                    "A URL-bearing Network response lost its normalized URL."
                )
            }
            let request = CanonicalNetworkRequestPayload(
                rawID: rawID,
                url: url,
                method: "GET",
                headers: normalizedResponse.requestHeaders ?? [:]
            )
            let insertion = try prepareNewRequest(
                id: id,
                request: request,
                initiator: nil,
                resourceType: resourceType?.rawValue,
                timestamp: timestamp,
                scope: scope,
                response: normalizedResponse
            )
            return commit(insertion)
        }

        if existing.lifecycle.isTerminal {
            guard existing.lifecycle == .finished,
                existing.allowsMultipartContinuation
            else {
                throw CanonicalNetworkProtocolViolation.contentAfterTerminal(
                    event: "Network.responseReceived",
                    id: id,
                    lifecycle: existing.lifecycle
                )
            }
        }
        let revision = try incrementedResponseRevision(
            existing.responseBodyRevision
        )
        var currentHop = existing.currentHop
        currentHop.resourceType =
            resourceType?.rawValue
            ?? currentHop.resourceType
        currentHop.response = normalizedResponse
        currentHop.responseReceivedTimestamp = timestamp
        if let requestHeaders = normalizedResponse.requestHeaders {
            currentHop.request.headers = requestHeaders
        }
        let lifecycle: CanonicalNetworkLifecycle =
            existing.lifecycle.isTerminal
            ? existing.lifecycle
            : .responded
        let allowsMultipartContinuation =
            existing.allowsMultipartContinuation
            || normalizedResponse.isMultipartMixedReplace
        let patch = CanonicalNetworkRequestPatch.response(
            currentHop: currentHop,
            lifecycle: lifecycle,
            allowsMultipartContinuation: allowsMultipartContinuation,
            responseBodyRevision: revision
        )
        var replacement = existing
        replacement.apply(patch)
        return commit(try prepareUpdate(replacement, patch: patch))
    }

    mutating func reduceDataReceived(
        rawID: Network.Request.ID,
        dataLength: Int,
        encodedDataLength: Int,
        timestamp: Double,
        scope: WebInspectorCanonicalNetworkEventScope
    ) throws -> CanonicalNetworkTransaction? {
        let id = canonicalID(rawID: rawID, scope: scope)
        guard !tombstones.contains(id),
            let existing = requestsByID[id]
        else {
            return nil
        }
        try validateLength(
            dataLength,
            event: "Network.dataReceived",
            field: "dataLength"
        )
        guard encodedDataLength >= -1 else {
            throw CanonicalNetworkProtocolViolation.invalidLength(
                event: "Network.dataReceived",
                field: "encodedDataLength",
                value: encodedDataLength
            )
        }
        if existing.lifecycle.isTerminal {
            guard existing.lifecycle == .finished,
                existing.allowsMultipartContinuation
            else {
                throw CanonicalNetworkProtocolViolation.contentAfterTerminal(
                    event: "Network.dataReceived",
                    id: id,
                    lifecycle: existing.lifecycle
                )
            }
        }
        var transfer = existing.currentHop.transfer
        transfer.decodedDataLength = try adding(
            transfer.decodedDataLength,
            dataLength,
            counter: .decodedDataLength
        )
        transfer.encodedDataLength = try adding(
            transfer.encodedDataLength,
            max(encodedDataLength, 0),
            counter: .encodedDataLength
        )
        transfer.lastDataReceivedTimestamp = timestamp
        let lifecycle: CanonicalNetworkLifecycle
        if existing.lifecycle == .pending {
            lifecycle = .responded
        } else {
            lifecycle = existing.lifecycle
        }
        let patch = CanonicalNetworkRequestPatch.transfer(
            transfer: transfer,
            lifecycle: lifecycle
        )
        var replacement = existing
        replacement.apply(patch)
        return commit(try prepareUpdate(replacement, patch: patch))
    }

    mutating func reduceLoadingFinished(
        rawID: Network.Request.ID,
        timestamp: Double,
        sourceMapURL: String?,
        metrics: Network.Metrics?,
        scope: WebInspectorCanonicalNetworkEventScope
    ) throws -> CanonicalNetworkTransaction? {
        let id = canonicalID(rawID: rawID, scope: scope)
        guard !tombstones.contains(id),
            let existing = requestsByID[id]
        else {
            return nil
        }
        let normalizedMetrics: CanonicalNetworkMetrics?
        if let metrics {
            normalizedMetrics = try self.normalizedMetrics(
                metrics,
                event: "Network.loadingFinished"
            )
        } else {
            normalizedMetrics = nil
        }
        guard !existing.lifecycle.isTerminal else {
            throw CanonicalNetworkProtocolViolation.duplicateTerminal(
                event: "Network.loadingFinished",
                id: id,
                lifecycle: existing.lifecycle
            )
        }
        var currentHop = existing.currentHop
        currentHop.sourceMapURL = sourceMapURL
        currentHop.metrics = normalizedMetrics
        currentHop.terminalTimestamp = timestamp
        if let encodedDataLength = normalizedMetrics?.encodedDataLength {
            currentHop.transfer.encodedDataLength = encodedDataLength
        }
        if let decodedBodyLength = normalizedMetrics?.decodedBodyLength {
            currentHop.transfer.decodedDataLength = decodedBodyLength
        }
        let patch = CanonicalNetworkRequestPatch.terminal(
            currentHop: currentHop,
            lifecycle: .finished
        )
        var replacement = existing
        replacement.apply(patch)
        return commit(try prepareUpdate(replacement, patch: patch))
    }

    mutating func reduceLoadingFailed(
        rawID: Network.Request.ID,
        errorText: String,
        canceled: Bool,
        timestamp: Double,
        scope: WebInspectorCanonicalNetworkEventScope
    ) throws -> CanonicalNetworkTransaction? {
        let id = canonicalID(rawID: rawID, scope: scope)
        guard !tombstones.contains(id),
            let existing = requestsByID[id]
        else {
            return nil
        }
        guard !existing.lifecycle.isTerminal else {
            throw CanonicalNetworkProtocolViolation.duplicateTerminal(
                event: "Network.loadingFailed",
                id: id,
                lifecycle: existing.lifecycle
            )
        }
        var currentHop = existing.currentHop
        currentHop.terminalTimestamp = timestamp
        let lifecycle = CanonicalNetworkLifecycle.failed(
            errorText: errorText,
            canceled: canceled
        )
        let patch = CanonicalNetworkRequestPatch.terminal(
            currentHop: currentHop,
            lifecycle: lifecycle
        )
        var replacement = existing
        replacement.apply(patch)
        return commit(try prepareUpdate(replacement, patch: patch))
    }

    mutating func reduceMemoryCache(
        rawID: Network.Request.ID,
        response: Network.Response,
        initiator: Network.Initiator,
        resourceType: Network.ResourceType?,
        timestamp: Double,
        scope: WebInspectorCanonicalNetworkEventScope
    ) throws -> CanonicalNetworkTransaction? {
        let id = canonicalID(rawID: rawID, scope: scope)
        if tombstones.contains(id) {
            throw CanonicalNetworkProtocolViolation.tombstonedIdentityReuse(
                event: "Network.requestServedFromMemoryCache",
                id: id
            )
        }
        guard requestsByID[id] == nil,
            pendingWebSocketByID[id] == nil
        else {
            throw CanonicalNetworkProtocolViolation.identityReuse(
                event: "Network.requestServedFromMemoryCache",
                id: id
            )
        }
        guard response.url != nil else {
            return nil
        }
        let response = try normalizedResponse(
            response,
            event: "Network.requestServedFromMemoryCache"
        )
        guard let url = response.url else {
            preconditionFailure(
                "A URL-bearing memory-cache response lost its normalized URL."
            )
        }
        let bodySize = response.bodySize ?? 0
        let request = CanonicalNetworkRequestPayload(
            rawID: rawID,
            url: url,
            method: "GET",
            headers: response.requestHeaders ?? [:]
        )
        let insertion = try prepareNewRequest(
            id: id,
            request: request,
            initiator: CanonicalNetworkInitiator(initiator),
            resourceType: resourceType?.rawValue,
            timestamp: timestamp,
            scope: scope,
            response: response,
            lifecycle: .finished,
            transfer: CanonicalNetworkTransfer(
                decodedDataLength: bodySize,
                encodedDataLength: bodySize
            ),
            terminalTimestamp: timestamp,
            servedFromMemoryCache: true
        )
        return commit(insertion)
    }
}

private extension CanonicalNetworkStore {
    func normalizedResponse(
        _ response: Network.Response,
        event: String
    ) throws -> CanonicalNetworkResponsePayload {
        if let bodySize = response.bodySize {
            try validateLength(
                bodySize,
                event: event,
                field: "bodySize"
            )
        }
        return CanonicalNetworkResponsePayload(response)
    }

    func normalizedMetrics(
        _ metrics: Network.Metrics,
        event: String
    ) throws -> CanonicalNetworkMetrics {
        if let encodedDataLength = metrics.encodedDataLength {
            try validateLength(
                encodedDataLength,
                event: event,
                field: "metrics.encodedDataLength"
            )
        }
        if let decodedBodyLength = metrics.decodedBodyLength {
            try validateLength(
                decodedBodyLength,
                event: event,
                field: "metrics.decodedBodyLength"
            )
        }
        return CanonicalNetworkMetrics(metrics)
    }

    func validateLength(
        _ value: Int,
        event: String,
        field: String
    ) throws {
        guard value >= 0 else {
            throw CanonicalNetworkProtocolViolation.invalidLength(
                event: event,
                field: field,
                value: value
            )
        }
    }

    func effectiveMIMEType(
        mimeType: String?,
        headers: [String: String]
    ) -> String? {
        if let mimeType,
            !mimeType.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        {
            return mimeType
        }
        return headers.first { key, _ in
            key.caseInsensitiveCompare("content-type") == .orderedSame
        }?.value
    }

    func resourceCategory(
        resourceType: String?,
        mimeType: String?,
        url: String,
        hasResponse: Bool
    ) -> CanonicalNetworkResourceCategory {
        let resourceType = resourceType?.lowercased()
        let mimeType = normalizedMIMEType(mimeType)
        let pathExtension = pathExtension(in: url)

        if hasResponse {
            if isPreviewableImage(
                mimeType: mimeType,
                pathExtension: ""
            ) {
                return .image
            }
            if isPreviewableMedia(
                mimeType: mimeType,
                pathExtension: ""
            ) {
                return .media
            }
        }
        switch resourceType {
        case "document":
            return .document
        case "stylesheet":
            return .stylesheet
        case "script":
            return .script
        case "font":
            return .font
        case "websocket":
            return .webSocket
        default:
            break
        }
        if hasResponse || resourceType == nil {
            if isPreviewableImage(
                mimeType: mimeType,
                pathExtension: pathExtension
            ) {
                return .image
            }
            if isPreviewableMedia(
                mimeType: mimeType,
                pathExtension: pathExtension
            ) {
                return .media
            }
        }
        switch resourceType {
        case "image":
            return .image
        case "media":
            return .media
        case "xhr", "fetch", "ping", "beacon", "eventsource":
            return .xhrFetch
        default:
            break
        }
        if mimeType == "text/css" || pathExtension == "css" {
            return .stylesheet
        }
        if mimeType.contains("javascript")
            || ["js", "mjs", "cjs"].contains(pathExtension)
        {
            return .script
        }
        if mimeType.hasPrefix("image/"), mimeType != "image/svg+xml" {
            return .image
        }
        if mimeType.hasPrefix("font/")
            || ["woff", "woff2", "ttf", "otf"].contains(pathExtension)
        {
            return .font
        }
        if mimeType.hasPrefix("audio/")
            || mimeType.hasPrefix("video/")
            || ["mp3", "mp4", "m4a", "mov", "webm", "m3u8"]
                .contains(pathExtension)
        {
            return .media
        }
        if mimeType.contains("html") {
            return .document
        }
        return .other
    }

    func normalizedMIMEType(_ mimeType: String?) -> String {
        mimeType?
            .split(
                separator: ";",
                maxSplits: 1,
                omittingEmptySubsequences: true
            )
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    func isPreviewableImage(
        mimeType: String,
        pathExtension: String
    ) -> Bool {
        let mimeTypes: Set<String> = [
            "image/apng",
            "image/avif",
            "image/bmp",
            "image/gif",
            "image/heic",
            "image/heif",
            "image/jpeg",
            "image/jpg",
            "image/pjpeg",
            "image/png",
            "image/tiff",
            "image/webp",
            "image/x-png",
        ]
        let pathExtensions: Set<String> = [
            "apng", "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg",
            "png", "tif", "tiff", "webp",
        ]
        return mimeTypes.contains(mimeType)
            || pathExtensions.contains(pathExtension)
    }

    func isPreviewableMedia(
        mimeType: String,
        pathExtension: String
    ) -> Bool {
        let mimeTypes: Set<String> = [
            "application/vnd.apple.mpegurl",
            "application/x-mpegurl",
            "application/mpegurl",
            "audio/aac",
            "audio/aiff",
            "audio/mp3",
            "audio/mp4",
            "audio/mpeg",
            "audio/mpegurl",
            "audio/wav",
            "audio/x-aiff",
            "audio/x-m4a",
            "audio/x-mpegurl",
            "audio/x-wav",
            "video/mp4",
            "video/quicktime",
            "video/webm",
            "video/x-m4v",
        ]
        let pathExtensions: Set<String> = [
            "aac", "aif", "aiff", "caf", "m3u8", "m4a", "m4v", "mov",
            "mp3", "mp4", "wav", "webm",
        ]
        return mimeTypes.contains(mimeType)
            || pathExtensions.contains(pathExtension)
    }

    func pathExtension(in rawURL: String) -> String {
        guard
            rawURL.range(
                of: "data:",
                options: [.anchored, .caseInsensitive]
            ) == nil
        else {
            return ""
        }
        if let components = URLComponents(
            string: rawURL,
            encodingInvalidCharacters: false
        )
            ?? URLComponents(
                string: rawURL,
                encodingInvalidCharacters: true
            )
        {
            let path =
                components.percentEncodedPath.removingPercentEncoding
                ?? components.percentEncodedPath
            return URL(fileURLWithPath: path).pathExtension.lowercased()
        }
        return URL(fileURLWithPath: rawURL).pathExtension.lowercased()
    }

    func urlSearchText(_ rawURL: String) -> String {
        guard
            rawURL.range(
                of: "data:",
                options: [.anchored, .caseInsensitive]
            ) == nil,
            let components = URLComponents(
                string: rawURL,
                encodingInvalidCharacters: false
            )
                ?? URLComponents(
                    string: rawURL,
                    encodingInvalidCharacters: true
                )
        else {
            return rawURL
        }
        return uniqueNonEmpty([
            components.host,
            components.percentEncodedPath.removingPercentEncoding,
            pathExtension(in: rawURL),
        ]).joined(separator: "\n")
    }

    func uniqueNonEmpty(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard let value else {
                continue
            }
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                continue
            }
            result.append(trimmed)
        }
        return result
    }
}

private extension CanonicalNetworkRequestPatch {
    var affectsQueryProjection: Bool {
        switch self {
        case .redirect, .response, .webSocketHandshakeResponse:
            true
        case .transfer, .terminal, .webSocketContentAppended,
            .webSocketClosed:
            false
        }
    }
}

private extension CanonicalNetworkStore {
    mutating func reduceWebSocket(
        _ event: Network.WebSocketEvent,
        scope: WebInspectorCanonicalNetworkEventScope,
        origin: CanonicalNetworkEventOrigin
    ) throws -> CanonicalNetworkTransaction? {
        switch event {
        case let .created(rawID, url):
            return try reduceWebSocketCreated(
                rawID: rawID,
                url: url,
                scope: scope,
                origin: origin
            )
        case let .handshakeRequest(rawID, request, timestamp):
            return try reduceWebSocketHandshakeRequest(
                rawID: rawID,
                request: request,
                timestamp: timestamp,
                scope: scope,
                origin: origin
            )
        case let .handshakeResponse(rawID, response, timestamp):
            return try reduceWebSocketHandshakeResponse(
                rawID: rawID,
                response: response,
                timestamp: timestamp,
                scope: scope,
                origin: origin
            )
        case let .closed(rawID, timestamp):
            return try reduceWebSocketClosed(
                rawID: rawID,
                timestamp: timestamp,
                scope: scope,
                origin: origin
            )
        case let .frameSent(rawID, frame, timestamp):
            return try reduceWebSocketFrame(
                rawID: rawID,
                frame: frame,
                direction: .sent,
                timestamp: timestamp,
                scope: scope
            )
        case let .frameReceived(rawID, frame, timestamp):
            return try reduceWebSocketFrame(
                rawID: rawID,
                frame: frame,
                direction: .received,
                timestamp: timestamp,
                scope: scope
            )
        case let .error(rawID, message, timestamp):
            return try reduceWebSocketError(
                rawID: rawID,
                message: message,
                timestamp: timestamp,
                scope: scope
            )
        case .other:
            return nil
        }
    }

    mutating func reduceWebSocketCreated(
        rawID: Network.Request.ID,
        url: String,
        scope: WebInspectorCanonicalNetworkEventScope,
        origin: CanonicalNetworkEventOrigin
    ) throws -> CanonicalNetworkTransaction? {
        let id = canonicalID(rawID: rawID, scope: scope)
        if tombstones.contains(id) {
            throw CanonicalNetworkProtocolViolation.tombstonedIdentityReuse(
                event: "Network.webSocketCreated",
                id: id
            )
        }
        if let pending = pendingWebSocketByID[id] {
            guard origin == .enableReplay else {
                throw
                    CanonicalNetworkProtocolViolation
                    .duplicateWebSocketEvent(
                        event: "Network.webSocketCreated",
                        id: id
                    )
            }
            guard pending.creationURL == url else {
                throw CanonicalNetworkProtocolViolation.conflictingReplay(
                    event: "Network.webSocketCreated",
                    id: id
                )
            }
            return nil
        }
        if let existing = requestsByID[id] {
            guard let webSocket = existing.webSocket else {
                throw CanonicalNetworkProtocolViolation.identityReuse(
                    event: "Network.webSocketCreated",
                    id: id
                )
            }
            guard origin == .enableReplay else {
                throw
                    CanonicalNetworkProtocolViolation
                    .duplicateWebSocketEvent(
                        event: "Network.webSocketCreated",
                        id: id
                    )
            }
            guard webSocket.creationURL == url else {
                throw CanonicalNetworkProtocolViolation.conflictingReplay(
                    event: "Network.webSocketCreated",
                    id: id
                )
            }
            return nil
        }

        try validateRawRequestIDReservation(id)
        scopedRequestIDByRawRequestID[rawID] = id
        let pending = PendingWebSocket(
            creationURL: url,
            membership: requestMembership(for: scope)
        )
        pendingWebSocketByID[id] = pending
        insertIntoTargetIndexes(id, membership: pending.membership)
        return nil
    }

    mutating func reduceWebSocketHandshakeRequest(
        rawID: Network.Request.ID,
        request: Network.Request,
        timestamp: Double?,
        scope: WebInspectorCanonicalNetworkEventScope,
        origin: CanonicalNetworkEventOrigin
    ) throws -> CanonicalNetworkTransaction? {
        let id = canonicalID(rawID: rawID, scope: scope)
        guard !tombstones.contains(id) else {
            return nil
        }
        let existing = requestsByID[id]
        let pending = pendingWebSocketByID[id]
        guard existing != nil || pending != nil else {
            return nil
        }
        guard rawID == request.id else {
            throw
                CanonicalNetworkProtocolViolation
                .eventPayloadIdentifierMismatch(
                    event: "Network.webSocketWillSendHandshakeRequest",
                    eventID: rawID,
                    payloadID: request.id
                )
        }
        if existing == nil {
            guard let pending else {
                preconditionFailure(
                    "A tracked WebSocket handshake lost its creation URL."
                )
            }
            var normalizedRequest = CanonicalNetworkRequestPayload(request)
            if normalizedRequest.url.isEmpty {
                normalizedRequest.url = pending.creationURL
            }
            let handshake = CanonicalNetworkWebSocketHandshakeRequest(
                request: normalizedRequest,
                timestamp: timestamp
            )
            var webSocket = CanonicalNetworkWebSocketRecord(
                creationURL: pending.creationURL
            )
            webSocket.handshakeRequest = handshake
            let insertion = try prepareNewRequest(
                id: id,
                request: normalizedRequest,
                initiator: nil,
                resourceType: Network.ResourceType.webSocket.rawValue,
                timestamp: timestamp,
                scope: scope,
                membership: pending.membership,
                webSocket: webSocket
            )
            let transaction = commit(insertion)
            pendingWebSocketByID[id] = nil
            return transaction
        }
        guard let existing else {
            preconditionFailure(
                "A tracked WebSocket handshake lost its request record."
            )
        }
        guard let webSocket = existing.webSocket else {
            throw CanonicalNetworkProtocolViolation.missingWebSocket(
                event: "Network.webSocketWillSendHandshakeRequest",
                id: id
            )
        }
        if existing.lifecycle.isTerminal
            || webSocket.readyState == .closed
        {
            guard origin == .enableReplay else {
                throw CanonicalNetworkProtocolViolation.contentAfterTerminal(
                    event: "Network.webSocketWillSendHandshakeRequest",
                    id: id,
                    lifecycle: existing.lifecycle
                )
            }
        }
        var normalizedRequest = CanonicalNetworkRequestPayload(request)
        if normalizedRequest.url.isEmpty {
            normalizedRequest.url = webSocket.creationURL
        }
        if let current = webSocket.handshakeRequest {
            guard origin == .enableReplay,
                current.request == normalizedRequest
            else {
                if origin == .enableReplay {
                    throw CanonicalNetworkProtocolViolation.conflictingReplay(
                        event: "Network.webSocketWillSendHandshakeRequest",
                        id: id
                    )
                }
                throw
                    CanonicalNetworkProtocolViolation
                    .duplicateWebSocketEvent(
                        event: "Network.webSocketWillSendHandshakeRequest",
                        id: id
                    )
            }
            return nil
        }
        preconditionFailure(
            "A canonical WebSocket record must be inserted by its handshake request."
        )
    }

    mutating func reduceWebSocketHandshakeResponse(
        rawID: Network.Request.ID,
        response: Network.Response,
        timestamp: Double?,
        scope: WebInspectorCanonicalNetworkEventScope,
        origin: CanonicalNetworkEventOrigin
    ) throws -> CanonicalNetworkTransaction? {
        let id = canonicalID(rawID: rawID, scope: scope)
        guard !tombstones.contains(id),
            let existing = requestsByID[id]
        else {
            return nil
        }
        let response = try normalizedResponse(
            response,
            event: "Network.webSocketHandshakeResponseReceived"
        )
        guard let webSocket = existing.webSocket else {
            throw CanonicalNetworkProtocolViolation.missingWebSocket(
                event: "Network.webSocketHandshakeResponseReceived",
                id: id
            )
        }
        if existing.lifecycle.isTerminal
            || webSocket.readyState == .closed
        {
            guard origin == .enableReplay else {
                throw CanonicalNetworkProtocolViolation.contentAfterTerminal(
                    event: "Network.webSocketHandshakeResponseReceived",
                    id: id,
                    lifecycle: existing.lifecycle
                )
            }
        }
        let handshake = CanonicalNetworkWebSocketHandshakeResponse(
            response: response,
            timestamp: timestamp
        )
        if let current = webSocket.handshakeResponse {
            guard origin == .enableReplay,
                current.response == response
            else {
                if origin == .enableReplay {
                    throw CanonicalNetworkProtocolViolation.conflictingReplay(
                        event: "Network.webSocketHandshakeResponseReceived",
                        id: id
                    )
                }
                throw
                    CanonicalNetworkProtocolViolation
                    .duplicateWebSocketEvent(
                        event: "Network.webSocketHandshakeResponseReceived",
                        id: id
                    )
            }
            return nil
        }
        let revision = try incrementedResponseRevision(
            existing.responseBodyRevision
        )
        let readyState: CanonicalNetworkWebSocketReadyState =
            webSocket.readyState == .closed ? .closed : .open
        let lifecycle: CanonicalNetworkLifecycle =
            existing.lifecycle.isTerminal
            ? existing.lifecycle
            : .responded
        let patch =
            CanonicalNetworkRequestPatch
            .webSocketHandshakeResponse(
                handshake: handshake,
                response: response,
                responseReceivedTimestamp: origin == .enableReplay
                    && existing.lifecycle.isTerminal
                    ? existing.currentHop.responseReceivedTimestamp
                    : existing.currentHop.responseReceivedTimestamp
                        ?? timestamp,
                readyState: readyState,
                lifecycle: lifecycle,
                responseBodyRevision: revision
            )
        var replacement = existing
        replacement.apply(patch)
        return commit(try prepareUpdate(replacement, patch: patch))
    }

    mutating func reduceWebSocketFrame(
        rawID: Network.Request.ID,
        frame: Network.WebSocketFrame,
        direction: CanonicalNetworkWebSocketContent.Direction,
        timestamp: Double,
        scope: WebInspectorCanonicalNetworkEventScope
    ) throws -> CanonicalNetworkTransaction? {
        let id = canonicalID(rawID: rawID, scope: scope)
        guard !tombstones.contains(id),
            let existing = requestsByID[id]
        else {
            return nil
        }
        try validateLength(
            frame.payloadLength,
            event: "Network.webSocketFrame",
            field: "payloadLength"
        )
        guard existing.webSocket != nil else {
            throw CanonicalNetworkProtocolViolation.missingWebSocket(
                event: "Network.webSocketFrame",
                id: id
            )
        }
        guard !existing.lifecycle.isTerminal else {
            throw CanonicalNetworkProtocolViolation.contentAfterTerminal(
                event: "Network.webSocketFrame",
                id: id,
                lifecycle: existing.lifecycle
            )
        }
        let content = CanonicalNetworkWebSocketContent.frame(
            direction: direction,
            opcode: frame.opcode,
            mask: frame.mask,
            payloadData: frame.payloadData,
            payloadLength: frame.payloadLength,
            timestamp: timestamp
        )
        var transfer = existing.currentHop.transfer
        transfer.decodedDataLength = try adding(
            transfer.decodedDataLength,
            frame.payloadLength,
            counter: .decodedDataLength
        )
        transfer.lastDataReceivedTimestamp = timestamp
        let patch =
            CanonicalNetworkRequestPatch
            .webSocketContentAppended(
                content: content,
                transfer: transfer
            )
        var replacement = existing
        replacement.apply(patch)
        return commit(try prepareUpdate(replacement, patch: patch))
    }

    mutating func reduceWebSocketError(
        rawID: Network.Request.ID,
        message: String,
        timestamp: Double,
        scope: WebInspectorCanonicalNetworkEventScope
    ) throws -> CanonicalNetworkTransaction? {
        let id = canonicalID(rawID: rawID, scope: scope)
        guard !tombstones.contains(id),
            let existing = requestsByID[id]
        else {
            return nil
        }
        guard existing.webSocket != nil else {
            throw CanonicalNetworkProtocolViolation.missingWebSocket(
                event: "Network.webSocketFrameError",
                id: id
            )
        }
        guard !existing.lifecycle.isTerminal else {
            throw CanonicalNetworkProtocolViolation.contentAfterTerminal(
                event: "Network.webSocketFrameError",
                id: id,
                lifecycle: existing.lifecycle
            )
        }
        let content = CanonicalNetworkWebSocketContent.error(
            message: message,
            timestamp: timestamp
        )
        var transfer = existing.currentHop.transfer
        transfer.lastDataReceivedTimestamp = timestamp
        let patch =
            CanonicalNetworkRequestPatch
            .webSocketContentAppended(
                content: content,
                transfer: transfer
            )
        var replacement = existing
        replacement.apply(patch)
        return commit(try prepareUpdate(replacement, patch: patch))
    }

    mutating func reduceWebSocketClosed(
        rawID: Network.Request.ID,
        timestamp: Double,
        scope: WebInspectorCanonicalNetworkEventScope,
        origin: CanonicalNetworkEventOrigin
    ) throws -> CanonicalNetworkTransaction? {
        let id = canonicalID(rawID: rawID, scope: scope)
        guard !tombstones.contains(id),
            let existing = requestsByID[id]
        else {
            return nil
        }
        guard let webSocket = existing.webSocket else {
            throw CanonicalNetworkProtocolViolation.missingWebSocket(
                event: "Network.webSocketClosed",
                id: id
            )
        }
        if existing.lifecycle.isTerminal || webSocket.readyState == .closed {
            if origin == .enableReplay,
                webSocket.readyState == .closed
            {
                return nil
            }
            throw CanonicalNetworkProtocolViolation.duplicateTerminal(
                event: "Network.webSocketClosed",
                id: id,
                lifecycle: existing.lifecycle
            )
        }
        let patch = CanonicalNetworkRequestPatch.webSocketClosed(
            timestamp: timestamp,
            lifecycle: .finished
        )
        var replacement = existing
        replacement.apply(patch)
        return commit(try prepareUpdate(replacement, patch: patch))
    }
}

private extension CanonicalNetworkStore {
    private func prepareNewRequest(
        id: CanonicalNetworkRequestIDStorage,
        request: CanonicalNetworkRequestPayload,
        initiator: CanonicalNetworkInitiator?,
        resourceType: String?,
        timestamp: Double?,
        scope: WebInspectorCanonicalNetworkEventScope,
        membership: CanonicalNetworkRequestMembership? = nil,
        response: CanonicalNetworkResponsePayload? = nil,
        lifecycle: CanonicalNetworkLifecycle? = nil,
        transfer: CanonicalNetworkTransfer = .init(),
        terminalTimestamp: Double? = nil,
        servedFromMemoryCache: Bool = false,
        webSocket: CanonicalNetworkWebSocketRecord? = nil
    ) throws -> PreparedInsertion {
        precondition(requestsByID[id] == nil)
        try validateRawRequestIDReservation(id)
        let requestOrdinal = try nextRequestOrdinal()
        let resolvedLifecycle =
            lifecycle
            ?? (response == nil ? .pending : .responded)
        let responseRevision: UInt64 = response == nil ? 0 : 1
        let currentHop = CanonicalNetworkCurrentHop(
            request: request,
            resourceType: resourceType,
            requestSentTimestamp: timestamp,
            response: response,
            responseReceivedTimestamp: response == nil ? nil : timestamp,
            transfer: transfer,
            terminalTimestamp: terminalTimestamp,
            servedFromMemoryCache: servedFromMemoryCache
        )
        let membership = membership ?? requestMembership(for: scope)
        let record = CanonicalNetworkRequestRecord(
            id: id,
            insertionOrdinal: requestOrdinal,
            membership: membership,
            initialInitiator: initiator,
            logicalStartTimestamp: timestamp,
            currentHop: currentHop,
            lifecycle: resolvedLifecycle,
            allowsMultipartContinuation: response?.isMultipartMixedReplace
                == true,
            webSocket: webSocket,
            responseBodyRevision: responseRevision
        )
        let groupKey = groupKey(
            requestID: id,
            initiator: initiator,
            membership: membership
        )
        let requestQuery = queryProjection(
            for: record,
            groupKey: groupKey
        )

        if let entryID = entryIDByGroupKey[groupKey] {
            guard let oldEntry = entriesByID[entryID],
                let oldEntryQuery = entryQueriesByID[entryID],
                let oldAggregate = entryAggregatesByID[entryID]
            else {
                preconditionFailure(
                    "Canonical Network group lookup lost its entry."
                )
            }
            var requestIDs = oldEntry.requestIDs
            let insertionIndex = chronologicalInsertionIndex(
                in: requestIDs,
                for: record
            )
            requestIDs.insert(id, at: insertionIndex)
            let newEntryAggregate = try adding(
                record,
                category: requestQuery.resourceCategory,
                to: oldAggregate
            )
            let primary: CanonicalNetworkRequestRecord
            if requestIDs.first == record.id {
                primary = record
            } else {
                guard
                    let primaryRequest = requestsByID[
                        oldEntry.summary.primaryRequestID
                    ]
                else {
                    preconditionFailure(
                        "Canonical Network entry lost its primary request."
                    )
                }
                primary = primaryRequest
            }
            let newEntry = CanonicalNetworkEntryRecord(
                id: entryID,
                groupKey: groupKey,
                requestIDs: requestIDs,
                summary: entrySummary(
                    primary: primary,
                    requestCount: requestIDs.count,
                    aggregate: newEntryAggregate
                )
            )
            let newEntryQuery = incrementallyAdding(
                requestQuery,
                to: oldEntryQuery,
                at: insertionIndex
            )
            let entryChange = CanonicalNetworkEntryChange.update(
                id: entryID,
                patch: CanonicalNetworkEntryPatch(
                    requestIDs: newEntry.requestIDs,
                    summary: newEntry.summary
                ),
                query: newEntryQuery
            )
            return PreparedInsertion(
                request: record,
                requestQuery: requestQuery,
                requestChange: .insert(
                    record: record,
                    query: requestQuery
                ),
                entry: PreparedEntryMutation(
                    record: newEntry,
                    query: newEntryQuery,
                    aggregate: newEntryAggregate,
                    change: entryChange,
                    isInsertion: false,
                    didFullRebuild: false,
                    didQueryRebuild: false
                ),
                groupKey: groupKey,
                requestOrdinal: requestOrdinal,
                entryOrdinal: nil,
                memberIndexUpdates: memberIndexUpdates(
                    requestIDs,
                    startingAt: insertionIndex
                )
            )
        }

        let entryOrdinal = try nextEntryOrdinal()
        guard let attachmentGeneration = activeAttachmentGeneration else {
            preconditionFailure(
                "Canonical Network insertion requires active attachment authority."
            )
        }
        let entryID = CanonicalNetworkEntryIDStorage(
            storeID: storeID,
            attachmentGeneration: attachmentGeneration,
            ordinal: entryOrdinal
        )
        let (entry, entryQuery, entryAggregate) = try makeEntryState(
            id: entryID,
            groupKey: groupKey,
            requestIDs: [id],
            replacementRequest: record
        )
        return PreparedInsertion(
            request: record,
            requestQuery: requestQuery,
            requestChange: .insert(
                record: record,
                query: requestQuery
            ),
            entry: PreparedEntryMutation(
                record: entry,
                query: entryQuery,
                aggregate: entryAggregate,
                change: .insert(record: entry, query: entryQuery),
                isInsertion: true,
                didFullRebuild: true,
                didQueryRebuild: true
            ),
            groupKey: groupKey,
            requestOrdinal: requestOrdinal,
            entryOrdinal: entryOrdinal,
            memberIndexUpdates: [id: 0]
        )
    }

    private func prepareUpdate(
        _ replacement: CanonicalNetworkRequestRecord,
        patch: CanonicalNetworkRequestPatch
    ) throws -> PreparedUpdate {
        guard let oldRecord = requestsByID[replacement.id],
            let oldQuery = requestQueriesByID[replacement.id],
            let groupKey = groupKeyByRequestID[replacement.id],
            let entryID = entryIDByRequestID[replacement.id],
            let oldEntry = entriesByID[entryID],
            let oldEntryQuery = entryQueriesByID[entryID],
            let oldAggregate = entryAggregatesByID[entryID]
        else {
            preconditionFailure(
                "Canonical Network update lost request or entry membership."
            )
        }
        precondition(oldRecord.id == oldQuery.id)
        let newQuery =
            patch.affectsQueryProjection
            ? queryProjection(for: replacement, groupKey: groupKey)
            : oldQuery
        let requestChange = CanonicalNetworkRequestChange.update(
            id: replacement.id,
            patch: patch,
            query: oldQuery == newQuery ? nil : newQuery
        )
        precondition(
            oldQuery.chronology == newQuery.chronology,
            "Canonical Network request chronology is fixed at insertion."
        )
        guard let oldMemberIndex = memberIndexByRequestID[replacement.id],
            oldEntryQuery.methods.count == oldEntry.requestIDs.count,
            oldEntryQuery.searchTexts.count == oldEntry.requestIDs.count,
            oldEntry.requestIDs.indices.contains(oldMemberIndex),
            oldEntry.requestIDs[oldMemberIndex] == replacement.id,
            oldEntryQuery.methods.indices.contains(oldMemberIndex)
        else {
            preconditionFailure(
                "Canonical Network entry lost its member index."
            )
        }
        let requestIDs = oldEntry.requestIDs
        var methods = oldEntryQuery.methods
        if oldQuery.method != newQuery.method {
            methods[oldMemberIndex] = newQuery.method
        }
        var searchTexts = oldEntryQuery.searchTexts
        if oldQuery.searchableText != newQuery.searchableText {
            searchTexts[oldMemberIndex] = newQuery.searchableText
        }
        let newAggregate = try updatingAggregate(
            oldAggregate,
            replacing: oldRecord,
            oldQuery: oldQuery,
            with: replacement,
            newQuery: newQuery
        )
        guard let primaryID = requestIDs.first else {
            preconditionFailure(
                "Canonical Network entry cannot lose all membership on update."
            )
        }
        let primary: CanonicalNetworkRequestRecord
        if primaryID == replacement.id {
            primary = replacement
        } else {
            guard let existingPrimary = requestsByID[primaryID] else {
                preconditionFailure(
                    "Canonical Network entry lost its primary request."
                )
            }
            primary = existingPrimary
        }
        let newEntry = CanonicalNetworkEntryRecord(
            id: oldEntry.id,
            groupKey: oldEntry.groupKey,
            requestIDs: requestIDs,
            summary: entrySummary(
                primary: primary,
                requestCount: requestIDs.count,
                aggregate: newAggregate
            )
        )
        let newEntryQuery = CanonicalNetworkEntryQueryProjection(
            id: entryID,
            chronology: oldEntryQuery.chronology,
            methods: methods,
            resourceCategories: Set(
                newAggregate.resourceCategoryCounts.keys
            ),
            searchTexts: searchTexts
        )
        let entryMutation: PreparedEntryMutation?
        if newEntry == oldEntry && newEntryQuery == oldEntryQuery {
            entryMutation = nil
        } else {
            entryMutation = PreparedEntryMutation(
                record: newEntry,
                query: newEntryQuery,
                aggregate: newAggregate,
                change: .update(
                    id: entryID,
                    patch: CanonicalNetworkEntryPatch(
                        requestIDs: newEntry.requestIDs,
                        summary: newEntry.summary
                    ),
                    query: oldEntryQuery == newEntryQuery
                        ? nil
                        : newEntryQuery
                ),
                isInsertion: false,
                didFullRebuild: false,
                didQueryRebuild: false
            )
        }
        return PreparedUpdate(
            request: replacement,
            requestQuery: newQuery,
            requestChange: requestChange,
            entry: entryMutation
        )
    }

    private mutating func commit(
        _ insertion: PreparedInsertion
    ) -> CanonicalNetworkTransaction {
        precondition(lastRequestOrdinal < insertion.requestOrdinal)
        lastRequestOrdinal = insertion.requestOrdinal
        if let entryOrdinal = insertion.entryOrdinal {
            precondition(lastEntryOrdinal < entryOrdinal)
            lastEntryOrdinal = entryOrdinal
        }
        requestsByID[insertion.request.id] = insertion.request
        insertIntoTargetIndexes(
            insertion.request.id,
            membership: insertion.request.membership
        )
        scopedRequestIDByRawRequestID[
            insertion.request.id.rawRequestID
        ] = insertion.request.id
        requestQueriesByID[insertion.request.id] = insertion.requestQuery
        groupKeyByRequestID[insertion.request.id] = insertion.groupKey
        entryIDByRequestID[insertion.request.id] = insertion.entry.record.id
        for (requestID, index) in insertion.memberIndexUpdates {
            memberIndexByRequestID[requestID] = index
        }
        entriesByID[insertion.entry.record.id] = insertion.entry.record
        entryQueriesByID[insertion.entry.record.id] = insertion.entry.query
        entryAggregatesByID[insertion.entry.record.id] =
            insertion.entry.aggregate
        if insertion.entry.isInsertion {
            entryIDByGroupKey[insertion.groupKey] = insertion.entry.record.id
        }
        #if DEBUG
            recordPerformance(of: insertion.entry)
        #endif
        return CanonicalNetworkTransaction(
            requestChanges: [insertion.requestChange],
            entryChanges: [insertion.entry.change]
        )
    }

    private mutating func commit(
        _ update: PreparedUpdate
    ) -> CanonicalNetworkTransaction {
        requestsByID[update.request.id] = update.request
        requestQueriesByID[update.request.id] = update.requestQuery
        if let entry = update.entry {
            entriesByID[entry.record.id] = entry.record
            entryQueriesByID[entry.record.id] = entry.query
            entryAggregatesByID[entry.record.id] = entry.aggregate
            #if DEBUG
                recordPerformance(of: entry)
            #endif
        }
        return CanonicalNetworkTransaction(
            requestChanges: [update.requestChange],
            entryChanges: update.entry.map { [$0.change] } ?? []
        )
    }

    private mutating func insertIntoTargetIndexes(
        _ id: CanonicalNetworkRequestIDStorage,
        membership: CanonicalNetworkRequestMembership
    ) {
        requestIDsByAgentTargetID[id.agentTargetID, default: []].insert(id)
        requestIDsBySemanticTargetID[
            membership.semanticTargetID,
            default: []
        ].insert(id)
    }

    private mutating func removeFromTargetIndexes(
        _ id: CanonicalNetworkRequestIDStorage,
        membership: CanonicalNetworkRequestMembership
    ) {
        remove(
            id,
            from: &requestIDsByAgentTargetID,
            targetID: id.agentTargetID
        )
        remove(
            id,
            from: &requestIDsBySemanticTargetID,
            targetID: membership.semanticTargetID
        )
    }

    private func remove(
        _ id: CanonicalNetworkRequestIDStorage,
        from index: inout [WebInspectorTarget.ID: Set<CanonicalNetworkRequestIDStorage>],
        targetID: WebInspectorTarget.ID
    ) {
        guard var ids = index[targetID], ids.remove(id) != nil else {
            preconditionFailure("Canonical Network target index lost membership.")
        }
        index[targetID] = ids.isEmpty ? nil : ids
    }

    #if DEBUG
        private mutating func recordPerformance(
            of entry: PreparedEntryMutation
        ) {
            if entry.didFullRebuild {
                performanceCounters.entryFullRebuildCount += 1
                performanceCounters.entryFullRebuildMemberVisitCount +=
                    entry.record.requestIDs.count
            } else {
                performanceCounters.entryIncrementalUpdateCount += 1
            }
            if entry.didQueryRebuild {
                performanceCounters.entryQueryRebuildCount += 1
            }
        }
    #endif

    func nextRequestOrdinal() throws -> UInt64 {
        let (ordinal, overflow) = lastRequestOrdinal.addingReportingOverflow(1)
        guard !overflow else {
            throw CanonicalNetworkStoreError.counterExhausted(
                .requestOrdinal
            )
        }
        return ordinal
    }

    func nextEntryOrdinal() throws -> UInt64 {
        let (ordinal, overflow) = lastEntryOrdinal.addingReportingOverflow(1)
        guard !overflow else {
            throw CanonicalNetworkStoreError.counterExhausted(.entryOrdinal)
        }
        return ordinal
    }

    func incrementedResponseRevision(_ revision: UInt64) throws -> UInt64 {
        let (next, overflow) = revision.addingReportingOverflow(1)
        guard !overflow else {
            throw CanonicalNetworkStoreError.counterExhausted(
                .responseBodyRevision
            )
        }
        return next
    }

    func adding(
        _ lhs: Int,
        _ rhs: Int,
        counter: CanonicalNetworkStoreError.Counter
    ) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw CanonicalNetworkStoreError.counterExhausted(counter)
        }
        return sum
    }
}

private extension CanonicalNetworkStore {
    func groupKey(
        requestID: CanonicalNetworkRequestIDStorage,
        initiator: CanonicalNetworkInitiator?,
        membership: CanonicalNetworkRequestMembership
    ) -> CanonicalNetworkGroupKey {
        guard let rawNodeID = initiator?.rawNodeID else {
            return .request(requestID)
        }
        if let domBindingEpoch = membership.domBindingEpoch {
            return .dom(
                WebInspectorDOMNodeIdentityStorage(
                    documentScope: WebInspectorDOMDocumentScopeStorage(
                        storeID: requestID.storeID,
                        attachmentGeneration: requestID.attachmentGeneration,
                        pageGeneration: requestID.pageGeneration,
                        semanticTargetID: membership.semanticTargetID,
                        agentTargetID: requestID.agentTargetID,
                        domBindingEpoch: domBindingEpoch
                    ),
                    rawNodeID: rawNodeID
                ))
        }
        return .opaqueInitiator(
            CanonicalNetworkOpaqueInitiatorKey(
                storeID: requestID.storeID,
                attachmentGeneration: requestID.attachmentGeneration,
                pageGeneration: requestID.pageGeneration,
                semanticTargetID: membership.semanticTargetID,
                agentTargetID: requestID.agentTargetID,
                targetAuthority: membership.targetAuthority,
                rawNodeID: rawNodeID
            ))
    }

    private func makeEntryState(
        id: CanonicalNetworkEntryIDStorage,
        groupKey: CanonicalNetworkGroupKey,
        requestIDs: [CanonicalNetworkRequestIDStorage],
        replacementRequest: CanonicalNetworkRequestRecord
    ) throws -> (
        record: CanonicalNetworkEntryRecord,
        query: CanonicalNetworkEntryQueryProjection,
        aggregate: EntryAggregateState
    ) {
        var records = requestIDs.map { requestID in
            if requestID == replacementRequest.id {
                return replacementRequest
            }
            guard let record = requestsByID[requestID] else {
                preconditionFailure(
                    "Canonical Network entry lost a member request."
                )
            }
            return record
        }
        records.sort {
            chronologyKey(for: $0) < chronologyKey(for: $1)
        }
        let orderedIDs = records.map(\.id)
        guard let primary = records.first else {
            preconditionFailure(
                "Canonical Network entries cannot have empty membership."
            )
        }
        let requestQueries = records.map { record in
            if record.id == replacementRequest.id {
                return queryProjection(for: record, groupKey: groupKey)
            }
            guard let query = requestQueriesByID[record.id] else {
                preconditionFailure(
                    "Canonical Network entry lost a request query projection."
                )
            }
            return query
        }
        var aggregate = EntryAggregateState(
            activeRequestCount: 0,
            failedRequestCount: 0,
            decodedDataLength: 0,
            encodedDataLength: 0,
            statusSeverityCounts: [:],
            resourceCategoryCounts: [:]
        )
        for (record, query) in zip(records, requestQueries) {
            aggregate = try adding(
                record,
                category: query.resourceCategory,
                to: aggregate
            )
        }
        let query = makeEntryQuery(
            id: id,
            requestQueries: requestQueries
        )
        return (
            record: CanonicalNetworkEntryRecord(
                id: id,
                groupKey: groupKey,
                requestIDs: orderedIDs,
                summary: entrySummary(
                    primary: primary,
                    requestCount: records.count,
                    aggregate: aggregate
                )
            ),
            query: query,
            aggregate: aggregate
        )
    }

    func chronologicalInsertionIndex(
        in requestIDs: [CanonicalNetworkRequestIDStorage],
        for record: CanonicalNetworkRequestRecord
    ) -> Int {
        let key = chronologyKey(for: record)
        var lowerBound = 0
        var upperBound = requestIDs.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            guard let member = requestsByID[requestIDs[midpoint]] else {
                preconditionFailure(
                    "Canonical Network entry lost a chronology member."
                )
            }
            if chronologyKey(for: member) < key {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }

    func memberIndexUpdates(
        _ requestIDs: [CanonicalNetworkRequestIDStorage],
        startingAt startIndex: Int
    ) -> [CanonicalNetworkRequestIDStorage: Int] {
        guard startIndex < requestIDs.count else {
            return [:]
        }
        return Dictionary(
            uniqueKeysWithValues: requestIDs[startIndex...]
                .enumerated()
                .map { offset, requestID in
                    (requestID, startIndex + offset)
                })
    }

    private func adding(
        _ record: CanonicalNetworkRequestRecord,
        category: CanonicalNetworkResourceCategory,
        to aggregate: EntryAggregateState
    ) throws -> EntryAggregateState {
        var aggregate = aggregate
        if !record.lifecycle.isTerminal {
            aggregate.activeRequestCount = try adding(
                aggregate.activeRequestCount,
                1,
                counter: .entryActiveRequestCount
            )
        }
        if isFailed(record.lifecycle) {
            aggregate.failedRequestCount = try adding(
                aggregate.failedRequestCount,
                1,
                counter: .entryFailedRequestCount
            )
        }
        aggregate.decodedDataLength = try adding(
            aggregate.decodedDataLength,
            record.currentHop.transfer.decodedDataLength,
            counter: .entryDecodedDataLength
        )
        aggregate.encodedDataLength = try adding(
            aggregate.encodedDataLength,
            record.currentHop.transfer.encodedDataLength,
            counter: .entryEncodedDataLength
        )
        let severity = statusSeverity(for: record)
        aggregate.statusSeverityCounts[severity] = try adding(
            aggregate.statusSeverityCounts[severity] ?? 0,
            1,
            counter: .entryStatusSeverityCount
        )
        aggregate.resourceCategoryCounts[category] = try adding(
            aggregate.resourceCategoryCounts[category] ?? 0,
            1,
            counter: .entryRequestCount
        )
        return aggregate
    }

    private func updatingAggregate(
        _ aggregate: EntryAggregateState,
        replacing oldRecord: CanonicalNetworkRequestRecord,
        oldQuery: CanonicalNetworkRequestQueryProjection,
        with newRecord: CanonicalNetworkRequestRecord,
        newQuery: CanonicalNetworkRequestQueryProjection
    ) throws -> EntryAggregateState {
        var aggregate = aggregate
        if oldRecord.lifecycle.isTerminal != newRecord.lifecycle.isTerminal {
            aggregate.activeRequestCount +=
                newRecord.lifecycle.isTerminal
                ? -1
                : 1
        }
        if isFailed(oldRecord.lifecycle) != isFailed(newRecord.lifecycle) {
            aggregate.failedRequestCount +=
                isFailed(newRecord.lifecycle)
                ? 1
                : -1
        }
        precondition(
            aggregate.activeRequestCount >= 0
                && aggregate.failedRequestCount >= 0
                && aggregate.decodedDataLength
                    >= oldRecord.currentHop.transfer.decodedDataLength
                && aggregate.encodedDataLength
                    >= oldRecord.currentHop.transfer.encodedDataLength,
            "Canonical Network entry aggregate lost a member contribution."
        )
        aggregate.decodedDataLength -=
            oldRecord.currentHop.transfer.decodedDataLength
        aggregate.encodedDataLength -=
            oldRecord.currentHop.transfer.encodedDataLength
        aggregate.decodedDataLength = try adding(
            aggregate.decodedDataLength,
            newRecord.currentHop.transfer.decodedDataLength,
            counter: .entryDecodedDataLength
        )
        aggregate.encodedDataLength = try adding(
            aggregate.encodedDataLength,
            newRecord.currentHop.transfer.encodedDataLength,
            counter: .entryEncodedDataLength
        )
        let oldSeverity = statusSeverity(for: oldRecord)
        let newSeverity = statusSeverity(for: newRecord)
        if oldSeverity != newSeverity {
            guard
                let oldSeverityCount = aggregate.statusSeverityCounts[
                    oldSeverity
                ], oldSeverityCount > 0
            else {
                preconditionFailure(
                    "Canonical Network entry lost a status severity contribution."
                )
            }
            if oldSeverityCount == 1 {
                aggregate.statusSeverityCounts[oldSeverity] = nil
            } else {
                aggregate.statusSeverityCounts[oldSeverity] =
                    oldSeverityCount - 1
            }
            aggregate.statusSeverityCounts[newSeverity] = try adding(
                aggregate.statusSeverityCounts[newSeverity] ?? 0,
                1,
                counter: .entryStatusSeverityCount
            )
        }
        if oldQuery.resourceCategory != newQuery.resourceCategory {
            guard
                let oldCategoryCount = aggregate.resourceCategoryCounts[
                    oldQuery.resourceCategory
                ], oldCategoryCount > 0
            else {
                preconditionFailure(
                    "Canonical Network entry lost a category contribution."
                )
            }
            if oldCategoryCount == 1 {
                aggregate.resourceCategoryCounts[oldQuery.resourceCategory] = nil
            } else {
                aggregate.resourceCategoryCounts[oldQuery.resourceCategory] =
                    oldCategoryCount - 1
            }
            aggregate.resourceCategoryCounts[newQuery.resourceCategory] =
                try adding(
                    aggregate.resourceCategoryCounts[
                        newQuery.resourceCategory
                    ] ?? 0,
                    1,
                    counter: .entryRequestCount
                )
        }
        return aggregate
    }

    private func entrySummary(
        primary: CanonicalNetworkRequestRecord,
        requestCount: Int,
        aggregate: EntryAggregateState
    ) -> CanonicalNetworkEntrySummary {
        let lifecycle: CanonicalNetworkEntryLifecycleSummary
        if aggregate.activeRequestCount > 0 {
            lifecycle = .loading
        } else if aggregate.failedRequestCount > 0 {
            lifecycle = .failed
        } else {
            lifecycle = .finished
        }
        return CanonicalNetworkEntrySummary(
            primaryRequestID: primary.id,
            requestCount: requestCount,
            url: primary.currentHop.request.url,
            method: primary.currentHop.request.method,
            resourceType: primary.currentHop.resourceType,
            mimeType: primary.currentHop.response?.mimeType,
            statusCode: primary.currentHop.response?.status,
            statusSeverity: highestStatusSeverity(in: aggregate),
            decodedDataLength: aggregate.decodedDataLength,
            encodedDataLength: aggregate.encodedDataLength,
            lifecycle: lifecycle
        )
    }

    func makeEntryQuery(
        id: CanonicalNetworkEntryIDStorage,
        requestQueries: [CanonicalNetworkRequestQueryProjection]
    ) -> CanonicalNetworkEntryQueryProjection {
        guard let chronology = requestQueries.first?.chronology else {
            preconditionFailure(
                "Canonical Network entry query cannot be empty."
            )
        }
        return CanonicalNetworkEntryQueryProjection(
            id: id,
            chronology: chronology,
            methods: requestQueries.map(\.method),
            resourceCategories: Set(
                requestQueries.map(\.resourceCategory)
            ),
            searchTexts: requestQueries.map(\.searchableText)
        )
    }

    func incrementallyAdding(
        _ request: CanonicalNetworkRequestQueryProjection,
        to entry: CanonicalNetworkEntryQueryProjection,
        at index: Int
    ) -> CanonicalNetworkEntryQueryProjection {
        precondition(
            entry.methods.count == entry.searchTexts.count
                && (entry.methods.indices.contains(index)
                    || index == entry.methods.endIndex),
            "Canonical Network entry query lost ordered member alignment."
        )
        var categories = entry.resourceCategories
        categories.insert(request.resourceCategory)
        var methods = entry.methods
        methods.insert(request.method, at: index)
        var searchTexts = entry.searchTexts
        searchTexts.insert(request.searchableText, at: index)
        return CanonicalNetworkEntryQueryProjection(
            id: entry.id,
            chronology: min(entry.chronology, request.chronology),
            methods: methods,
            resourceCategories: categories,
            searchTexts: searchTexts
        )
    }

    func isFailed(_ lifecycle: CanonicalNetworkLifecycle) -> Bool {
        if case .failed = lifecycle {
            return true
        }
        return false
    }

    func statusSeverity(
        for record: CanonicalNetworkRequestRecord
    ) -> CanonicalNetworkEntryStatusSeverity {
        if isFailed(record.lifecycle) {
            return .error
        }
        if let statusCode = record.currentHop.response?.status {
            if statusCode >= 500 {
                return .error
            }
            if statusCode >= 400 {
                return .warning
            }
            if statusCode >= 300 {
                return .notice
            }
            return .success
        }
        if record.lifecycle == .finished {
            return .success
        }
        return .neutral
    }

    private func highestStatusSeverity(
        in aggregate: EntryAggregateState
    ) -> CanonicalNetworkEntryStatusSeverity {
        if aggregate.statusSeverityCounts[.error, default: 0] > 0 {
            return .error
        }
        if aggregate.statusSeverityCounts[.warning, default: 0] > 0 {
            return .warning
        }
        if aggregate.statusSeverityCounts[.notice, default: 0] > 0 {
            return .notice
        }
        if aggregate.statusSeverityCounts[.success, default: 0] > 0 {
            return .success
        }
        if aggregate.statusSeverityCounts[.neutral, default: 0] > 0 {
            return .neutral
        }
        preconditionFailure(
            "Canonical Network entry cannot have an empty status aggregate."
        )
    }

    func chronologyKey(
        for record: CanonicalNetworkRequestRecord
    ) -> CanonicalNetworkChronologyKey {
        CanonicalNetworkChronologyKey(
            timestamp: record.logicalStartTimestamp,
            insertionOrdinal: record.insertionOrdinal
        )
    }

    func queryProjection(
        for record: CanonicalNetworkRequestRecord,
        groupKey: CanonicalNetworkGroupKey
    ) -> CanonicalNetworkRequestQueryProjection {
        let response = record.currentHop.response
        let mimeType = effectiveMIMEType(
            mimeType: response?.mimeType,
            headers: response?.headers ?? [:]
        )
        let category = resourceCategory(
            resourceType: record.currentHop.resourceType,
            mimeType: mimeType,
            url: response?.url ?? record.currentHop.request.url,
            hasResponse: response != nil
        )
        let currentFields: [String?] = [
            record.currentHop.request.url,
            response?.url,
            urlSearchText(record.currentHop.request.url),
            response?.url.map(urlSearchText),
            record.currentHop.request.method,
            response?.status.map(String.init),
            response?.statusText,
            response?.mimeType,
            record.currentHop.resourceType,
            category.rawValue,
        ]
        let redirectFields: [String?] = record.redirects.flatMap { redirect in
            [
                redirect.request.url,
                urlSearchText(redirect.request.url),
                redirect.request.method,
                redirect.response.url,
                redirect.response.url.map(urlSearchText),
                redirect.response.status.map(String.init),
                redirect.response.statusText,
                redirect.response.mimeType,
            ]
        }
        return CanonicalNetworkRequestQueryProjection(
            id: record.id,
            insertionOrdinal: record.insertionOrdinal,
            chronology: chronologyKey(for: record),
            url: record.currentHop.request.url,
            method: record.currentHop.request.method,
            resourceType: record.currentHop.resourceType,
            mimeType: response?.mimeType,
            resourceCategory: category,
            searchableText: uniqueNonEmpty(
                currentFields + redirectFields
            ).joined(separator: "\n"),
            statusCode: response?.status,
            groupKey: groupKey
        )
    }

}

private extension CanonicalNetworkStore {
    func deletionTransaction(
        requestIDs: Set<CanonicalNetworkRequestIDStorage>
    ) -> CanonicalNetworkTransaction {
        let orderedRequestIDs = requestIDs.sorted { lhs, rhs in
            guard let lhsRecord = requestsByID[lhs],
                let rhsRecord = requestsByID[rhs]
            else {
                preconditionFailure(
                    "Canonical Network deletion lost a request record."
                )
            }
            return lhsRecord.insertionOrdinal < rhsRecord.insertionOrdinal
        }
        let entryIDs = Set(
            requestIDs.compactMap {
                entryIDByRequestID[$0]
            }
        ).sorted { $0.ordinal < $1.ordinal }
        for entryID in entryIDs {
            guard let entry = entriesByID[entryID],
                entry.requestIDs.allSatisfy(requestIDs.contains)
            else {
                preconditionFailure(
                    "A canonical deletion crossed a Network entry boundary."
                )
            }
        }
        return CanonicalNetworkTransaction(
            requestChanges: orderedRequestIDs.map(
                CanonicalNetworkRequestChange.delete
            ),
            entryChanges: entryIDs.map(CanonicalNetworkEntryChange.delete)
        )
    }
}
