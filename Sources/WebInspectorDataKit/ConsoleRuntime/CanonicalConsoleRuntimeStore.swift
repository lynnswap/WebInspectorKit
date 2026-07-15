import WebInspectorProxyKit

package enum CanonicalConsoleRuntimeProtocolViolation: Error, Equatable, Sendable {
    case missingRuntimeBindingEpoch(event: String)
    case missingConsoleBindingEpoch(event: String)
    case runtimeProjectionDisabled(event: String)
    case runtimeContextIdentityReuse(CanonicalRuntimeContextIDStorage)
    case tombstonedRuntimeContextIdentityReuse(CanonicalRuntimeContextIDStorage)
    case missingRuntimeContext(
        agentTargetID: WebInspectorTarget.ID,
        rawContextID: Runtime.ExecutionContext.ID
    )
    case runtimeContextLookupCollision(
        existing: CanonicalRuntimeContextIDStorage,
        proposed: CanonicalRuntimeContextIDStorage
    )
    case missingPreviousConsoleMessage(agentTargetID: WebInspectorTarget.ID)
    case invalidInitialRepeatCount(Int)
    case nonmonotonicRepeatCount(
        id: CanonicalConsoleMessageIDStorage,
        current: Int,
        proposed: Int
    )
    case consoleBindingMismatch(
        id: CanonicalConsoleMessageIDStorage,
        expected: WebInspectorConsoleBindingGeneration,
        actual: WebInspectorConsoleBindingGeneration
    )
    case unexpectedNetworkResolution(event: String)
    case networkResolutionRawIdentifierMismatch(
        referenced: Network.Request.ID,
        resolved: Network.Request.ID
    )
    case networkResolutionStoreMismatch(
        messageStoreID: WebInspectorContainerStoreID,
        requestStoreID: WebInspectorContainerStoreID
    )
    case networkResolutionAttachmentMismatch(
        active: WebInspectorAttachmentGeneration,
        resolved: WebInspectorAttachmentGeneration
    )
    case networkResolutionPageMismatch(
        active: WebInspectorPageGeneration,
        resolved: WebInspectorPageGeneration
    )
}

package enum CanonicalConsoleRuntimeStoreError: Error, Equatable, Sendable {
    case consoleOrdinalExhausted
    case runtimeContextOrdinalExhausted
    case nonmonotonicAttachmentGeneration(
        current: WebInspectorAttachmentGeneration,
        proposed: WebInspectorAttachmentGeneration
    )
    case nonmonotonicPageGeneration(
        current: WebInspectorPageGeneration,
        proposed: WebInspectorPageGeneration
    )
    case nonmonotonicNavigationEpoch(
        semanticTargetID: WebInspectorTarget.ID,
        current: WebInspectorNavigationEpoch,
        proposed: WebInspectorNavigationEpoch
    )
}

/// Pure Sendable canonical Console and Runtime state owned by the model
/// container Core.
///
/// This reducer contains no Observable object, actor, task, Proxy handle,
/// query registration, or UI selection. Every throwing operation validates a
/// complete mutation before committing it, so callers can retry or terminate
/// without observing partial canonical state.
package struct CanonicalConsoleRuntimeStore: Equatable, Sendable {
    private struct RuntimeLookupKey: Hashable, Sendable {
        let agentTargetID: WebInspectorTarget.ID
        let rawContextID: Runtime.ExecutionContext.ID
    }

    package let storeID: WebInspectorContainerStoreID
    package let projectsRuntimeContexts: Bool

    private var activeAttachmentGeneration: WebInspectorAttachmentGeneration?
    private var activePageGeneration: WebInspectorPageGeneration?

    private var runtimeContextsByID: [CanonicalRuntimeContextIDStorage: CanonicalRuntimeContextRecord]
    private var runtimeContextIDByLookupKey: [RuntimeLookupKey: CanonicalRuntimeContextIDStorage]
    private var runtimeContextIDsByAgentTargetID: [WebInspectorTarget.ID: Set<CanonicalRuntimeContextIDStorage>]
    private var runtimeContextIDsBySemanticTargetID: [WebInspectorTarget.ID: Set<CanonicalRuntimeContextIDStorage>]
    private var runtimeContextIDsByFrameID: [FrameID: Set<CanonicalRuntimeContextIDStorage>]
    private var runtimeContextTombstones: Set<CanonicalRuntimeContextIDStorage>
    private var lastRuntimeContextOrdinal: UInt64

    private var consoleMessagesByID: [CanonicalConsoleMessageIDStorage: CanonicalConsoleMessageRecord]
    private var consoleMessageIDsByAgentTargetID: [WebInspectorTarget.ID: Set<CanonicalConsoleMessageIDStorage>]
    private var consoleMessageIDsBySemanticTargetID: [WebInspectorTarget.ID: Set<CanonicalConsoleMessageIDStorage>]
    private var lastConsoleMessageIDByAgentTargetID: [WebInspectorTarget.ID: CanonicalConsoleMessageIDStorage]
    private var unresolvedConsoleMessageIDsByRawRequestID: [Network.Request.ID: Set<CanonicalConsoleMessageIDStorage>]
    private var lastConsoleOrdinal: UInt64

    #if DEBUG
        package struct PerformanceCounters: Equatable, Sendable {
            package fileprivate(set) var fullSnapshotBuildCount = 0
            package fileprivate(set) var fullSnapshotRecordVisitCount = 0
            package fileprivate(set) var incrementalRecordVisitCount = 0
            package fileprivate(set) var unrelatedRecordScanCount = 0
        }

        package private(set) var performanceCounters = PerformanceCounters()
    #endif

    package init(
        storeID: WebInspectorContainerStoreID,
        projectsRuntimeContexts: Bool = true
    ) {
        self.storeID = storeID
        self.projectsRuntimeContexts = projectsRuntimeContexts
        activeAttachmentGeneration = nil
        activePageGeneration = nil
        runtimeContextsByID = [:]
        runtimeContextIDByLookupKey = [:]
        runtimeContextIDsByAgentTargetID = [:]
        runtimeContextIDsBySemanticTargetID = [:]
        runtimeContextIDsByFrameID = [:]
        runtimeContextTombstones = []
        lastRuntimeContextOrdinal = 0
        consoleMessagesByID = [:]
        consoleMessageIDsByAgentTargetID = [:]
        consoleMessageIDsBySemanticTargetID = [:]
        lastConsoleMessageIDByAgentTargetID = [:]
        unresolvedConsoleMessageIDsByRawRequestID = [:]
        lastConsoleOrdinal = 0
    }

    package var attachmentGeneration: WebInspectorAttachmentGeneration? {
        activeAttachmentGeneration
    }

    package var pageGeneration: WebInspectorPageGeneration? {
        activePageGeneration
    }

    package var consoleOrdinal: UInt64 {
        lastConsoleOrdinal
    }

    package var runtimeContextCount: Int {
        runtimeContextsByID.count
    }

    package var consoleMessageCount: Int {
        consoleMessagesByID.count
    }

    package func runtimeContext(
        for id: CanonicalRuntimeContextIDStorage
    ) -> CanonicalRuntimeContextRecord? {
        runtimeContextsByID[id]
    }

    package func consoleMessage(
        for id: CanonicalConsoleMessageIDStorage
    ) -> CanonicalConsoleMessageRecord? {
        consoleMessagesByID[id]
    }

    package func runtimeContextID(
        agentTargetID: WebInspectorTarget.ID,
        rawContextID: Runtime.ExecutionContext.ID
    ) -> CanonicalRuntimeContextIDStorage? {
        runtimeContextIDByLookupKey[
            RuntimeLookupKey(
                agentTargetID: agentTargetID,
                rawContextID: rawContextID
            )
        ]
    }

    package func unresolvedConsoleMessageIDs(
        for rawRequestID: Network.Request.ID
    ) -> Set<CanonicalConsoleMessageIDStorage> {
        unresolvedConsoleMessageIDsByRawRequestID[rawRequestID] ?? []
    }

    package mutating func snapshot() -> CanonicalConsoleRuntimeSnapshot {
        let runtimeRecords = runtimeContextsByID.values.sorted {
            $0.insertionOrdinal < $1.insertionOrdinal
        }
        let consoleRecords = consoleMessagesByID.values.sorted {
            $0.id.ordinal < $1.id.ordinal
        }
        #if DEBUG
            performanceCounters.fullSnapshotBuildCount += 1
            performanceCounters.fullSnapshotRecordVisitCount +=
                runtimeRecords.count + consoleRecords.count
        #endif
        return CanonicalConsoleRuntimeSnapshot(
            runtimeContexts: runtimeRecords.map {
                CanonicalRuntimeContextSnapshotEntry(
                    record: $0,
                    query: $0.queryProjection
                )
            },
            consoleMessages: consoleRecords.map {
                CanonicalConsoleMessageSnapshotEntry(
                    record: $0,
                    query: $0.queryProjection
                )
            }
        )
    }

    #if DEBUG
        package var runtimeContextOrdinalForTesting: UInt64 {
            lastRuntimeContextOrdinal
        }

        package mutating func resetPerformanceCountersForTesting() {
            performanceCounters = PerformanceCounters()
        }

        package mutating func setLastRuntimeContextOrdinalForTesting(
            _ ordinal: UInt64
        ) {
            precondition(runtimeContextsByID.isEmpty)
            lastRuntimeContextOrdinal = ordinal
        }
    #endif

    /// Replaces attachment/page authority while retaining the container-wide
    /// Console ordinal allocator.
    @discardableResult
    package mutating func reset(
        attachmentGeneration: WebInspectorAttachmentGeneration,
        pageGeneration: WebInspectorPageGeneration
    ) throws -> CanonicalConsoleRuntimeTransaction {
        try validateReset(
            attachmentGeneration: attachmentGeneration,
            pageGeneration: pageGeneration
        )
        let previousAttachment = activeAttachmentGeneration
        let runtimeIDs = runtimeContextIDsInInsertionOrder(runtimeContextsByID.keys)
        let consoleIDs = consoleMessagesByID.keys.sorted { $0.ordinal < $1.ordinal }
        let transaction = CanonicalConsoleRuntimeTransaction(
            runtimeContextChanges: runtimeIDs.map(CanonicalRuntimeContextChange.delete),
            consoleMessageChanges: consoleIDs.map(CanonicalConsoleMessageChange.delete),
            resourceInvalidations: [
                .attachmentReset(
                    previous: previousAttachment,
                    current: attachmentGeneration,
                    pageGeneration: pageGeneration
                )
            ]
        )

        activeAttachmentGeneration = attachmentGeneration
        activePageGeneration = pageGeneration
        runtimeContextsByID.removeAll(keepingCapacity: true)
        runtimeContextIDByLookupKey.removeAll(keepingCapacity: true)
        runtimeContextIDsByAgentTargetID.removeAll(keepingCapacity: true)
        runtimeContextIDsBySemanticTargetID.removeAll(keepingCapacity: true)
        runtimeContextIDsByFrameID.removeAll(keepingCapacity: true)
        runtimeContextTombstones.removeAll(keepingCapacity: true)
        consoleMessagesByID.removeAll(keepingCapacity: true)
        consoleMessageIDsByAgentTargetID.removeAll(keepingCapacity: true)
        consoleMessageIDsBySemanticTargetID.removeAll(keepingCapacity: true)
        lastConsoleMessageIDByAgentTargetID.removeAll(keepingCapacity: true)
        unresolvedConsoleMessageIDsByRawRequestID.removeAll(keepingCapacity: true)
        return transaction
    }

    /// Clears attachment-owned membership while preserving generation and
    /// never-reused Console ordinal authority for a later reattachment.
    @discardableResult
    package mutating func clearForDetach() -> CanonicalConsoleRuntimeTransaction {
        guard let attachmentGeneration = activeAttachmentGeneration,
            let pageGeneration = activePageGeneration
        else {
            preconditionFailure(
                "Canonical Console/Runtime detach requires active attachment authority."
            )
        }

        let runtimeIDs = runtimeContextIDsInInsertionOrder(runtimeContextsByID.keys)
        let consoleIDs = consoleMessagesByID.keys.sorted {
            $0.ordinal < $1.ordinal
        }
        let transaction = CanonicalConsoleRuntimeTransaction(
            runtimeContextChanges: runtimeIDs.map(
                CanonicalRuntimeContextChange.delete
            ),
            consoleMessageChanges: consoleIDs.map(
                CanonicalConsoleMessageChange.delete
            ),
            resourceInvalidations: [
                .attachmentDetached(
                    attachmentGeneration: attachmentGeneration,
                    pageGeneration: pageGeneration
                )
            ]
        )

        runtimeContextTombstones.formUnion(runtimeIDs)
        runtimeContextsByID.removeAll(keepingCapacity: true)
        runtimeContextIDByLookupKey.removeAll(keepingCapacity: true)
        runtimeContextIDsByAgentTargetID.removeAll(keepingCapacity: true)
        runtimeContextIDsBySemanticTargetID.removeAll(keepingCapacity: true)
        runtimeContextIDsByFrameID.removeAll(keepingCapacity: true)
        consoleMessagesByID.removeAll(keepingCapacity: true)
        consoleMessageIDsByAgentTargetID.removeAll(keepingCapacity: true)
        consoleMessageIDsBySemanticTargetID.removeAll(keepingCapacity: true)
        lastConsoleMessageIDByAgentTargetID.removeAll(keepingCapacity: true)
        unresolvedConsoleMessageIDsByRawRequestID.removeAll(keepingCapacity: true)
        return transaction
    }

    package mutating func reduceRuntime(
        _ event: Runtime.Event,
        scope: WebInspectorConsoleRuntimeEventScope
    ) throws -> CanonicalConsoleRuntimeTransaction? {
        guard isActive(scope) else {
            return nil
        }

        switch event {
        case let .executionContextCreated(context):
            guard projectsRuntimeContexts else {
                throw CanonicalConsoleRuntimeProtocolViolation.runtimeProjectionDisabled(
                    event: "Runtime.executionContextCreated"
                )
            }
            return try insertRuntimeContext(context, scope: scope)
        case let .executionContextDestroyed(rawContextID):
            guard projectsRuntimeContexts else {
                throw CanonicalConsoleRuntimeProtocolViolation.runtimeProjectionDisabled(
                    event: "Runtime.executionContextDestroyed"
                )
            }
            return try destroyRuntimeContext(rawContextID, scope: scope)
        case .executionContextsCleared:
            return try clearRuntimeContexts(scope: scope)
        case .unknown:
            return nil
        }
    }

    package mutating func reduceConsole(
        _ event: Console.Event,
        scope: WebInspectorConsoleRuntimeEventScope,
        networkRequestResolution: CanonicalConsoleNetworkRequestResolution? = nil
    ) throws -> CanonicalConsoleRuntimeTransaction? {
        guard isActive(scope) else {
            return nil
        }

        switch event {
        case let .messageAdded(message):
            return try insertConsoleMessage(
                message,
                scope: scope,
                networkRequestResolution: networkRequestResolution
            )
        case let .messageRepeatCountUpdated(count, timestamp):
            guard networkRequestResolution == nil else {
                throw CanonicalConsoleRuntimeProtocolViolation.unexpectedNetworkResolution(
                    event: "Console.messageRepeatCountUpdated"
                )
            }
            return try updateConsoleRepeatCount(
                count,
                timestamp: timestamp,
                scope: scope
            )
        case .messagesCleared:
            guard networkRequestResolution == nil else {
                throw CanonicalConsoleRuntimeProtocolViolation.unexpectedNetworkResolution(
                    event: "Console.messagesCleared"
                )
            }
            return try clearConsoleMessages(scope: scope)
        case .unknown:
            guard networkRequestResolution == nil else {
                throw CanonicalConsoleRuntimeProtocolViolation.unexpectedNetworkResolution(
                    event: "Console.unknown"
                )
            }
            return nil
        }
    }

    /// Resolves messages that arrived before their canonical Network request.
    /// The Network reducer remains the only owner that may construct the exact
    /// scoped request identity passed here.
    package mutating func resolveNetworkRequest(
        _ resolution: CanonicalConsoleNetworkRequestResolution
    ) throws -> CanonicalConsoleRuntimeTransaction? {
        try validateNetworkResolutionAuthority(resolution)
        guard
            let messageIDs = unresolvedConsoleMessageIDsByRawRequestID[
                resolution.rawRequestID
            ],
            !messageIDs.isEmpty
        else {
            return nil
        }

        let orderedIDs = messageIDs.sorted { $0.ordinal < $1.ordinal }
        var replacements: [CanonicalConsoleMessageIDStorage: CanonicalConsoleMessageRecord] = [:]
        var changes: [CanonicalConsoleMessageChange] = []
        for id in orderedIDs {
            guard var record = consoleMessagesByID[id],
                record.networkRequestReference
                    == .unresolved(rawRequestID: resolution.rawRequestID)
            else {
                preconditionFailure(
                    "Canonical Console unresolved Network index lost record authority."
                )
            }
            let reference = CanonicalConsoleNetworkRequestReference.resolved(
                rawRequestID: resolution.rawRequestID,
                requestID: resolution.requestID
            )
            let patch = CanonicalConsoleMessagePatch.networkRequestReference(reference)
            record.apply(patch)
            replacements[id] = record
            changes.append(.update(id: id, patch: patch, query: nil))
        }

        for (id, record) in replacements {
            consoleMessagesByID[id] = record
        }
        unresolvedConsoleMessageIDsByRawRequestID[resolution.rawRequestID] = nil
        recordIncrementalVisits(replacements.count)
        return CanonicalConsoleRuntimeTransaction(consoleMessageChanges: changes)
    }

    /// Invalidates resolved references after the Network owner clears its
    /// canonical membership while retaining the Console message and raw ID.
    package mutating func invalidateNetworkRequestReferences()
        -> CanonicalConsoleRuntimeTransaction?
    {
        var replacements: [CanonicalConsoleMessageIDStorage: CanonicalConsoleMessageRecord] = [:]
        var changes: [CanonicalConsoleMessageChange] = []
        for id in consoleMessagesByID.keys.sorted(by: { $0.ordinal < $1.ordinal }) {
            guard var record = consoleMessagesByID[id],
                case let .resolved(rawRequestID, _)? = record.networkRequestReference
            else {
                continue
            }
            let reference = CanonicalConsoleNetworkRequestReference.unresolved(
                rawRequestID: rawRequestID
            )
            let patch = CanonicalConsoleMessagePatch.networkRequestReference(reference)
            record.apply(patch)
            replacements[id] = record
            changes.append(.update(id: id, patch: patch, query: nil))
            unresolvedConsoleMessageIDsByRawRequestID[rawRequestID, default: []]
                .insert(id)
        }
        guard changes.isEmpty == false else {
            return nil
        }
        for (id, record) in replacements {
            consoleMessagesByID[id] = record
        }
        recordIncrementalVisits(replacements.count)
        return CanonicalConsoleRuntimeTransaction(consoleMessageChanges: changes)
    }

    /// Invalidates agent-owned Runtime resources when the transport observes a
    /// new document loader. Persistent RuntimeContext membership is handled by
    /// the frame or semantic-target navigation boundary separately.
    package func runtimeBindingDidAdvance(
        scope: WebInspectorConsoleRuntimeEventScope
    ) throws -> CanonicalConsoleRuntimeTransaction? {
        guard isActive(scope) else {
            return nil
        }
        let runtimeBindingEpoch = try requireRuntimeBindingEpoch(
            scope,
            event: "Page.frameNavigated"
        )
        return CanonicalConsoleRuntimeTransaction(
            resourceInvalidations: [
                .runtimeBinding(
                    agentTargetID: scope.agentTarget.id,
                    epoch: runtimeBindingEpoch
                )
            ]
        )
    }

    /// Applies a semantic-target navigation boundary without guessing
    /// membership from an identifier-only Runtime event.
    package mutating func semanticTargetNavigated(
        scope: WebInspectorConsoleRuntimeEventScope
    ) throws -> CanonicalConsoleRuntimeTransaction? {
        guard isActive(scope) else {
            return nil
        }
        let candidateIDs = runtimeContextIDsBySemanticTargetID[scope.target.id] ?? []
        var removedIDs: [CanonicalRuntimeContextIDStorage] = []
        for id in candidateIDs {
            guard let record = runtimeContextsByID[id] else {
                preconditionFailure(
                    "Canonical Runtime semantic-target index lost a record."
                )
            }
            if record.membership.navigationEpoch.rawValue > scope.navigationEpoch.rawValue {
                throw CanonicalConsoleRuntimeStoreError.nonmonotonicNavigationEpoch(
                    semanticTargetID: scope.target.id,
                    current: record.membership.navigationEpoch,
                    proposed: scope.navigationEpoch
                )
            }
            if record.membership.navigationEpoch != scope.navigationEpoch {
                removedIDs.append(id)
            }
        }
        removedIDs = runtimeContextIDsInInsertionOrder(removedIDs)

        for id in removedIDs {
            removeRuntimeContext(id, tombstone: true)
        }
        recordIncrementalVisits(removedIDs.count)
        return CanonicalConsoleRuntimeTransaction(
            runtimeContextChanges: removedIDs.map(CanonicalRuntimeContextChange.delete),
            resourceInvalidations: [
                .semanticNavigation(
                    semanticTargetID: scope.target.id,
                    navigationEpoch: scope.navigationEpoch
                )
            ]
        )
    }

    /// Removes Runtime contexts for an ordinary frame whose document changed
    /// while its owning protocol target remained the same.
    @discardableResult
    package mutating func frameWasNavigated(
        _ frameID: FrameID
    ) -> CanonicalConsoleRuntimeTransaction {
        return CanonicalConsoleRuntimeTransaction(
            runtimeContextChanges: removeRuntimeContexts(inFrame: frameID)
        )
    }

    /// Removes canonical membership whose physical or semantic target no
    /// longer exists. Target loss is idempotent; its resource invalidation is
    /// still delivered even when no persistent record was materialized.
    @discardableResult
    package mutating func targetWasLost(
        _ targetID: WebInspectorTarget.ID
    ) -> CanonicalConsoleRuntimeTransaction {
        let runtimeIDs = (runtimeContextIDsByAgentTargetID[targetID] ?? []).union(
            runtimeContextIDsBySemanticTargetID[targetID] ?? [])
        let consoleIDs = (consoleMessageIDsByAgentTargetID[targetID] ?? [])
            .union(consoleMessageIDsBySemanticTargetID[targetID] ?? [])
        let orderedRuntimeIDs = runtimeContextIDsInInsertionOrder(runtimeIDs)
        let orderedConsoleIDs = consoleIDs.sorted { $0.ordinal < $1.ordinal }

        for id in orderedRuntimeIDs {
            guard runtimeContextsByID[id] != nil else {
                preconditionFailure(
                    "Canonical Runtime target index lost a record."
                )
            }
        }
        for id in orderedConsoleIDs {
            guard consoleMessagesByID[id] != nil else {
                preconditionFailure(
                    "Canonical Console target index lost a record."
                )
            }
        }

        for id in orderedRuntimeIDs {
            removeRuntimeContext(id, tombstone: true)
        }
        for id in orderedConsoleIDs {
            removeConsoleMessage(id)
        }
        recordIncrementalVisits(orderedRuntimeIDs.count + orderedConsoleIDs.count)
        return CanonicalConsoleRuntimeTransaction(
            runtimeContextChanges: orderedRuntimeIDs.map(
                CanonicalRuntimeContextChange.delete
            ),
            consoleMessageChanges: orderedConsoleIDs.map(
                CanonicalConsoleMessageChange.delete
            ),
            resourceInvalidations: [.targetLost(targetID)]
        )
    }

    /// Removes Runtime contexts whose protocol payload names an ordinary
    /// frame that detached without a dedicated target-destroyed event.
    @discardableResult
    package mutating func frameWasDetached(
        _ frameID: FrameID
    ) -> CanonicalConsoleRuntimeTransaction {
        return CanonicalConsoleRuntimeTransaction(
            runtimeContextChanges: removeRuntimeContexts(inFrame: frameID),
            resourceInvalidations: [.frameDetached(frameID)]
        )
    }
}

private extension CanonicalConsoleRuntimeStore {
    mutating func removeRuntimeContexts(
        inFrame frameID: FrameID
    ) -> [CanonicalRuntimeContextChange] {
        let ids = runtimeContextIDsInInsertionOrder(
            runtimeContextIDsByFrameID[frameID] ?? []
        )
        for id in ids {
            guard runtimeContextsByID[id]?.frameID == frameID else {
                preconditionFailure("Canonical Runtime frame index lost record authority.")
            }
        }
        for id in ids {
            removeRuntimeContext(id, tombstone: true)
        }
        recordIncrementalVisits(ids.count)
        return ids.map(CanonicalRuntimeContextChange.delete)
    }

    func isActive(_ scope: WebInspectorConsoleRuntimeEventScope) -> Bool {
        activeAttachmentGeneration != nil
            && scope.generation == activePageGeneration
    }

    func validateReset(
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
                throw CanonicalConsoleRuntimeStoreError.nonmonotonicPageGeneration(
                    current: currentPage,
                    proposed: pageGeneration
                )
            }
            return
        }
        guard attachmentGeneration > currentAttachment else {
            throw CanonicalConsoleRuntimeStoreError.nonmonotonicAttachmentGeneration(
                current: currentAttachment,
                proposed: attachmentGeneration
            )
        }
    }

    func requireRuntimeBindingEpoch(
        _ scope: WebInspectorConsoleRuntimeEventScope,
        event: String
    ) throws -> WebInspectorRuntimeBindingGeneration {
        guard let epoch = scope.runtimeBindingEpoch else {
            throw CanonicalConsoleRuntimeProtocolViolation.missingRuntimeBindingEpoch(
                event: event
            )
        }
        return epoch
    }

    func requireConsoleBindingEpoch(
        _ scope: WebInspectorConsoleRuntimeEventScope,
        event: String
    ) throws -> WebInspectorConsoleBindingGeneration {
        guard let epoch = scope.consoleBindingEpoch else {
            throw CanonicalConsoleRuntimeProtocolViolation.missingConsoleBindingEpoch(
                event: event
            )
        }
        return epoch
    }

    func canonicalRuntimeContextID(
        rawContextID: Runtime.ExecutionContext.ID,
        scope: WebInspectorConsoleRuntimeEventScope
    ) -> CanonicalRuntimeContextIDStorage {
        guard let attachmentGeneration = activeAttachmentGeneration else {
            preconditionFailure(
                "Canonical Runtime reduction requires active attachment authority."
            )
        }
        return CanonicalRuntimeContextIDStorage(
            storeID: storeID,
            attachmentGeneration: attachmentGeneration,
            pageGeneration: scope.generation,
            agentTargetID: scope.agentTarget.id,
            rawContextID: rawContextID
        )
    }

    func runtimeContextIDsInInsertionOrder<IDs: Sequence>(
        _ ids: IDs
    ) -> [CanonicalRuntimeContextIDStorage]
    where IDs.Element == CanonicalRuntimeContextIDStorage {
        ids.sorted { lhs, rhs in
            guard let lhsRecord = runtimeContextsByID[lhs],
                let rhsRecord = runtimeContextsByID[rhs]
            else {
                preconditionFailure(
                    "Canonical Runtime order referenced a missing record."
                )
            }
            return lhsRecord.insertionOrdinal < rhsRecord.insertionOrdinal
        }
    }
}

private extension CanonicalConsoleRuntimeStore {
    mutating func insertRuntimeContext(
        _ context: Runtime.ExecutionContext,
        scope: WebInspectorConsoleRuntimeEventScope
    ) throws -> CanonicalConsoleRuntimeTransaction {
        let runtimeBindingEpoch = try requireRuntimeBindingEpoch(
            scope,
            event: "Runtime.executionContextCreated"
        )
        let id = canonicalRuntimeContextID(
            rawContextID: context.id,
            scope: scope
        )
        if runtimeContextTombstones.contains(id) {
            throw
                CanonicalConsoleRuntimeProtocolViolation
                .tombstonedRuntimeContextIdentityReuse(id)
        }
        guard runtimeContextsByID[id] == nil else {
            throw CanonicalConsoleRuntimeProtocolViolation.runtimeContextIdentityReuse(id)
        }
        let lookupKey = RuntimeLookupKey(
            agentTargetID: scope.agentTarget.id,
            rawContextID: context.id
        )
        if let existing = runtimeContextIDByLookupKey[lookupKey] {
            throw CanonicalConsoleRuntimeProtocolViolation.runtimeContextLookupCollision(
                existing: existing,
                proposed: id
            )
        }
        let insertionOrdinal = try nextRuntimeContextOrdinal()
        let record = CanonicalRuntimeContextRecord(
            id: id,
            insertionOrdinal: insertionOrdinal,
            membership: CanonicalRuntimeContextMembership(
                semanticTargetID: scope.target.id,
                navigationEpoch: scope.navigationEpoch,
                runtimeBindingEpoch: runtimeBindingEpoch
            ),
            name: context.name,
            frameID: context.frameID,
            kind: context.kind
        )

        lastRuntimeContextOrdinal = insertionOrdinal
        runtimeContextsByID[id] = record
        runtimeContextIDByLookupKey[lookupKey] = id
        runtimeContextIDsByAgentTargetID[scope.agentTarget.id, default: []].insert(id)
        runtimeContextIDsBySemanticTargetID[scope.target.id, default: []].insert(id)
        if let frameID = context.frameID {
            runtimeContextIDsByFrameID[frameID, default: []].insert(id)
        }
        recordIncrementalVisits(1)
        return CanonicalConsoleRuntimeTransaction(
            runtimeContextChanges: [
                .insert(record: record, query: record.queryProjection)
            ]
        )
    }

    func nextRuntimeContextOrdinal() throws -> UInt64 {
        let (ordinal, overflow) = lastRuntimeContextOrdinal.addingReportingOverflow(1)
        guard !overflow else {
            throw CanonicalConsoleRuntimeStoreError.runtimeContextOrdinalExhausted
        }
        return ordinal
    }

    mutating func destroyRuntimeContext(
        _ rawContextID: Runtime.ExecutionContext.ID,
        scope: WebInspectorConsoleRuntimeEventScope
    ) throws -> CanonicalConsoleRuntimeTransaction? {
        _ = try requireRuntimeBindingEpoch(
            scope,
            event: "Runtime.executionContextDestroyed"
        )
        let lookupKey = RuntimeLookupKey(
            agentTargetID: scope.agentTarget.id,
            rawContextID: rawContextID
        )
        guard let id = runtimeContextIDByLookupKey[lookupKey] else {
            let tombstonedID = canonicalRuntimeContextID(
                rawContextID: rawContextID,
                scope: scope
            )
            if runtimeContextTombstones.contains(tombstonedID) {
                return nil
            }
            throw CanonicalConsoleRuntimeProtocolViolation.missingRuntimeContext(
                agentTargetID: scope.agentTarget.id,
                rawContextID: rawContextID
            )
        }
        guard runtimeContextsByID[id] != nil else {
            preconditionFailure(
                "Canonical Runtime lookup index referenced a missing record."
            )
        }

        removeRuntimeContext(id, tombstone: true)
        recordIncrementalVisits(1)
        return CanonicalConsoleRuntimeTransaction(
            runtimeContextChanges: [.delete(id)]
        )
    }

    mutating func clearRuntimeContexts(
        scope: WebInspectorConsoleRuntimeEventScope
    ) throws -> CanonicalConsoleRuntimeTransaction {
        let runtimeBindingEpoch = try requireRuntimeBindingEpoch(
            scope,
            event: "Runtime.executionContextsCleared"
        )
        let ids = runtimeContextIDsInInsertionOrder(
            runtimeContextIDsByAgentTargetID[scope.agentTarget.id] ?? []
        )
        for id in ids {
            guard runtimeContextsByID[id] != nil else {
                preconditionFailure(
                    "Canonical Runtime agent index referenced a missing record."
                )
            }
        }

        for id in ids {
            removeRuntimeContext(id, tombstone: true)
        }
        recordIncrementalVisits(ids.count)
        return CanonicalConsoleRuntimeTransaction(
            runtimeContextChanges: ids.map(CanonicalRuntimeContextChange.delete),
            resourceInvalidations: [
                .runtimeBinding(
                    agentTargetID: scope.agentTarget.id,
                    epoch: runtimeBindingEpoch
                )
            ]
        )
    }

    mutating func removeRuntimeContext(
        _ id: CanonicalRuntimeContextIDStorage,
        tombstone: Bool
    ) {
        guard let record = runtimeContextsByID.removeValue(forKey: id) else {
            preconditionFailure(
                "Canonical Runtime removal referenced a missing record."
            )
        }
        let lookupKey = RuntimeLookupKey(
            agentTargetID: id.agentTargetID,
            rawContextID: id.rawContextID
        )
        guard runtimeContextIDByLookupKey.removeValue(forKey: lookupKey) == id else {
            preconditionFailure(
                "Canonical Runtime removal lost raw-ID lookup authority."
            )
        }
        remove(
            id,
            from: &runtimeContextIDsByAgentTargetID,
            key: id.agentTargetID
        )
        remove(
            id,
            from: &runtimeContextIDsBySemanticTargetID,
            key: record.membership.semanticTargetID
        )
        if let frameID = record.frameID {
            remove(
                id,
                from: &runtimeContextIDsByFrameID,
                key: frameID
            )
        }
        if tombstone {
            runtimeContextTombstones.insert(id)
        }
    }

    func remove<Key: Hashable, Value: Hashable>(
        _ value: Value,
        from index: inout [Key: Set<Value>],
        key: Key
    ) {
        guard var values = index[key], values.remove(value) != nil else {
            preconditionFailure("Canonical index removal lost membership.")
        }
        index[key] = values.isEmpty ? nil : values
    }
}

private extension CanonicalConsoleRuntimeStore {
    mutating func insertConsoleMessage(
        _ message: Console.Message,
        scope: WebInspectorConsoleRuntimeEventScope,
        networkRequestResolution: CanonicalConsoleNetworkRequestResolution?
    ) throws -> CanonicalConsoleRuntimeTransaction {
        guard message.repeatCount > 0 else {
            throw CanonicalConsoleRuntimeProtocolViolation.invalidInitialRepeatCount(
                message.repeatCount
            )
        }
        let runtimeBindingEpoch = try requireRuntimeBindingEpoch(
            scope,
            event: "Console.messageAdded"
        )
        let consoleBindingEpoch = try requireConsoleBindingEpoch(
            scope,
            event: "Console.messageAdded"
        )
        guard lastConsoleOrdinal < UInt64.max else {
            throw CanonicalConsoleRuntimeStoreError.consoleOrdinalExhausted
        }
        guard let attachmentGeneration = activeAttachmentGeneration else {
            preconditionFailure(
                "Canonical Console reduction requires active attachment authority."
            )
        }
        let ordinal = lastConsoleOrdinal + 1
        let id = CanonicalConsoleMessageIDStorage(
            storeID: storeID,
            attachmentGeneration: attachmentGeneration,
            ordinal: ordinal
        )
        guard consoleMessagesByID[id] == nil else {
            preconditionFailure("Canonical Console ordinal allocator reused an identity.")
        }
        let networkReference = try initialNetworkReference(
            rawRequestID: message.networkRequestID,
            resolution: networkRequestResolution
        )
        let membership = CanonicalConsoleMessageMembership(
            pageGeneration: scope.generation,
            semanticTargetID: scope.target.id,
            agentTargetID: scope.agentTarget.id,
            navigationEpoch: scope.navigationEpoch,
            runtimeBindingEpoch: runtimeBindingEpoch,
            consoleBindingEpoch: consoleBindingEpoch
        )
        let authority = CanonicalConsoleParameterAuthority(
            ownerMessageID: id,
            pageGeneration: scope.generation,
            semanticTargetID: scope.target.id,
            agentTargetID: scope.agentTarget.id,
            navigationEpoch: scope.navigationEpoch,
            runtimeBindingEpoch: runtimeBindingEpoch,
            consoleBindingEpoch: consoleBindingEpoch
        )
        let record = CanonicalConsoleMessageRecord(
            id: id,
            membership: membership,
            source: message.source,
            level: message.level,
            kind: message.type,
            text: message.text,
            url: message.url,
            line: message.line,
            column: message.column,
            repeatCount: message.repeatCount,
            parameters: message.parameters.map {
                CanonicalConsoleParameterResourceSeed(
                    payload: CanonicalRuntimeRemoteObjectPayload($0),
                    authority: authority
                )
            },
            stackTrace: message.stackTrace.map(CanonicalConsoleStackTrace.init),
            networkRequestReference: networkReference,
            timestamp: message.timestamp
        )

        lastConsoleOrdinal = ordinal
        consoleMessagesByID[id] = record
        consoleMessageIDsByAgentTargetID[scope.agentTarget.id, default: []].insert(id)
        consoleMessageIDsBySemanticTargetID[scope.target.id, default: []].insert(id)
        lastConsoleMessageIDByAgentTargetID[scope.agentTarget.id] = id
        if case let .unresolved(rawRequestID)? = networkReference {
            unresolvedConsoleMessageIDsByRawRequestID[rawRequestID, default: []].insert(id)
        }
        recordIncrementalVisits(1)
        return CanonicalConsoleRuntimeTransaction(
            consoleMessageChanges: [
                .insert(record: record, query: record.queryProjection)
            ]
        )
    }

    mutating func updateConsoleRepeatCount(
        _ count: Int,
        timestamp: Double?,
        scope: WebInspectorConsoleRuntimeEventScope
    ) throws -> CanonicalConsoleRuntimeTransaction {
        _ = try requireRuntimeBindingEpoch(
            scope,
            event: "Console.messageRepeatCountUpdated"
        )
        let consoleBindingEpoch = try requireConsoleBindingEpoch(
            scope,
            event: "Console.messageRepeatCountUpdated"
        )
        guard
            let id = lastConsoleMessageIDByAgentTargetID[scope.agentTarget.id],
            var record = consoleMessagesByID[id]
        else {
            throw CanonicalConsoleRuntimeProtocolViolation.missingPreviousConsoleMessage(
                agentTargetID: scope.agentTarget.id
            )
        }
        guard record.membership.consoleBindingEpoch == consoleBindingEpoch else {
            throw CanonicalConsoleRuntimeProtocolViolation.consoleBindingMismatch(
                id: id,
                expected: record.membership.consoleBindingEpoch,
                actual: consoleBindingEpoch
            )
        }
        guard count > record.repeatCount else {
            throw CanonicalConsoleRuntimeProtocolViolation.nonmonotonicRepeatCount(
                id: id,
                current: record.repeatCount,
                proposed: count
            )
        }
        let patch = CanonicalConsoleMessagePatch.repeatCount(
            count: count,
            timestamp: timestamp
        )
        record.apply(patch)

        consoleMessagesByID[id] = record
        recordIncrementalVisits(1)
        return CanonicalConsoleRuntimeTransaction(
            consoleMessageChanges: [
                .update(
                    id: id,
                    patch: patch,
                    query: record.queryProjection
                )
            ]
        )
    }

    mutating func clearConsoleMessages(
        scope: WebInspectorConsoleRuntimeEventScope
    ) throws -> CanonicalConsoleRuntimeTransaction {
        _ = try requireRuntimeBindingEpoch(
            scope,
            event: "Console.messagesCleared"
        )
        let consoleBindingEpoch = try requireConsoleBindingEpoch(
            scope,
            event: "Console.messagesCleared"
        )
        let ids = (consoleMessageIDsByAgentTargetID[scope.agentTarget.id] ?? [])
            .sorted { $0.ordinal < $1.ordinal }
        for id in ids {
            guard consoleMessagesByID[id] != nil else {
                preconditionFailure(
                    "Canonical Console agent index referenced a missing record."
                )
            }
        }

        for id in ids {
            removeConsoleMessage(id)
        }
        lastConsoleMessageIDByAgentTargetID[scope.agentTarget.id] = nil
        recordIncrementalVisits(ids.count)
        return CanonicalConsoleRuntimeTransaction(
            consoleMessageChanges: ids.map(CanonicalConsoleMessageChange.delete),
            resourceInvalidations: [
                .consoleBinding(
                    agentTargetID: scope.agentTarget.id,
                    epoch: consoleBindingEpoch
                )
            ]
        )
    }

    mutating func removeConsoleMessage(
        _ id: CanonicalConsoleMessageIDStorage
    ) {
        guard let record = consoleMessagesByID.removeValue(forKey: id) else {
            preconditionFailure(
                "Canonical Console removal referenced a missing record."
            )
        }
        remove(
            id,
            from: &consoleMessageIDsByAgentTargetID,
            key: record.membership.agentTargetID
        )
        remove(
            id,
            from: &consoleMessageIDsBySemanticTargetID,
            key: record.membership.semanticTargetID
        )
        if lastConsoleMessageIDByAgentTargetID[record.membership.agentTargetID] == id {
            lastConsoleMessageIDByAgentTargetID[record.membership.agentTargetID] =
                consoleMessageIDsByAgentTargetID[record.membership.agentTargetID]?
                .max { $0.ordinal < $1.ordinal }
        }
        if case let .unresolved(rawRequestID)? = record.networkRequestReference {
            remove(
                id,
                from: &unresolvedConsoleMessageIDsByRawRequestID,
                key: rawRequestID
            )
        }
    }

    func initialNetworkReference(
        rawRequestID: Network.Request.ID?,
        resolution: CanonicalConsoleNetworkRequestResolution?
    ) throws -> CanonicalConsoleNetworkRequestReference? {
        guard let rawRequestID else {
            guard resolution == nil else {
                throw CanonicalConsoleRuntimeProtocolViolation.unexpectedNetworkResolution(
                    event: "Console.messageAdded"
                )
            }
            return nil
        }
        guard let resolution else {
            return .unresolved(rawRequestID: rawRequestID)
        }
        guard resolution.rawRequestID == rawRequestID else {
            throw
                CanonicalConsoleRuntimeProtocolViolation
                .networkResolutionRawIdentifierMismatch(
                    referenced: rawRequestID,
                    resolved: resolution.rawRequestID
                )
        }
        try validateNetworkResolutionAuthority(resolution)
        return .resolved(
            rawRequestID: rawRequestID,
            requestID: resolution.requestID
        )
    }

    func validateNetworkResolutionAuthority(
        _ resolution: CanonicalConsoleNetworkRequestResolution
    ) throws {
        guard resolution.requestID.storeID == storeID else {
            throw CanonicalConsoleRuntimeProtocolViolation.networkResolutionStoreMismatch(
                messageStoreID: storeID,
                requestStoreID: resolution.requestID.storeID
            )
        }
        guard let activeAttachmentGeneration else {
            preconditionFailure(
                "Canonical Console Network resolution requires active attachment authority."
            )
        }
        guard resolution.requestID.attachmentGeneration == activeAttachmentGeneration else {
            throw
                CanonicalConsoleRuntimeProtocolViolation
                .networkResolutionAttachmentMismatch(
                    active: activeAttachmentGeneration,
                    resolved: resolution.requestID.attachmentGeneration
                )
        }
        guard let activePageGeneration else {
            preconditionFailure(
                "Canonical Console Network resolution requires active page authority."
            )
        }
        guard resolution.rawAlias.pageGeneration == activePageGeneration else {
            throw CanonicalConsoleRuntimeProtocolViolation.networkResolutionPageMismatch(
                active: activePageGeneration,
                resolved: resolution.rawAlias.pageGeneration
            )
        }
    }

    mutating func recordIncrementalVisits(_ count: Int) {
        #if DEBUG
            performanceCounters.incrementalRecordVisitCount += count
        #endif
    }
}
