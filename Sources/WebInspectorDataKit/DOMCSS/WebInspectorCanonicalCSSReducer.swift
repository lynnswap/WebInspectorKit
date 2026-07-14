import WebInspectorProxyKit

package struct WebInspectorCanonicalCSSStyleSheetSnapshotRecord: Sendable {
    package let scope: WebInspectorCanonicalDOMEventScope
    package let header: CSS.StyleSheetHeader

    package init(
        scope: WebInspectorCanonicalDOMEventScope,
        header: CSS.StyleSheetHeader
    ) {
        self.scope = scope
        self.header = header
    }
}

package struct WebInspectorCanonicalCSSStyleSheetRecord: Equatable, Sendable {
    package let id: WebInspectorCSSStyleSheetIdentityStorage
    package var frameID: FrameID?
    package var sourceURL: String?
    package var origin: String
    package var title: String?
    package var disabled: Bool
    package var isInline: Bool
    package var startLine: Int
    package var startColumn: Int
}

package struct WebInspectorCanonicalCSSCascadeRevisionChange: Equatable, Sendable {
    package let scope: WebInspectorDOMDocumentScopeStorage
    package let revision: UInt64
}

package struct WebInspectorCanonicalCSSTransaction: Equatable, Sendable {
    package var insertedRecords: [WebInspectorCanonicalCSSStyleSheetRecord] = []
    package var updatedRecords: [WebInspectorCanonicalCSSStyleSheetRecord] = []
    package var deletedRecordIDs: Set<WebInspectorCSSStyleSheetIdentityStorage> = []
    package var cascadeRevisionChanges: [WebInspectorCanonicalCSSCascadeRevisionChange] = []
    package var resourceInvalidations: Set<WebInspectorCanonicalResourceInvalidation> = []

    package var isEmpty: Bool {
        insertedRecords.isEmpty
            && updatedRecords.isEmpty
            && deletedRecordIDs.isEmpty
            && cascadeRevisionChanges.isEmpty
            && resourceInvalidations.isEmpty
    }
}

package struct WebInspectorCanonicalCSSSnapshot: Equatable, Sendable {
    package let recordsByID: [WebInspectorCSSStyleSheetIdentityStorage: WebInspectorCanonicalCSSStyleSheetRecord]
    package let cascadeRevisionByScope: [WebInspectorDOMDocumentScopeStorage: UInt64]
}

package struct WebInspectorCanonicalCSSPerformanceCounters: Equatable, Sendable {
    package fileprivate(set) var fullSnapshotBuildCount = 0
    package fileprivate(set) var fullSnapshotHeaderVisitCount = 0
    package fileprivate(set) var incrementalLookupCount = 0
    package fileprivate(set) var unrelatedCollectionScanCount = 0
    package fileprivate(set) var recordMutationCount = 0
}

package enum WebInspectorCanonicalCSSError: Error, Equatable, Sendable {
    case missingDOMBindingEpoch
    case inactiveTarget(WebInspectorDOMTargetRouteStorage)
    case scopeMismatch(WebInspectorDOMTargetRouteStorage)
    case duplicateBootstrapScope(WebInspectorDOMTargetRouteStorage)
    case invalidDocumentTransition(WebInspectorDOMTargetRouteStorage)
    case duplicateStyleSheet(WebInspectorCSSStyleSheetIdentityStorage)
    case reusedStyleSheet(WebInspectorCSSStyleSheetIdentityStorage)
    case missingStyleSheet(WebInspectorCSSStyleSheetIdentityStorage)
    case invalidStyleSheetHeader(WebInspectorCSSStyleSheetIdentityStorage)
}

package struct WebInspectorCanonicalCSSReducer: Sendable {
    package let storeID: WebInspectorContainerStoreID
    package let attachmentGeneration: WebInspectorAttachmentGeneration

    private var recordsByID: [WebInspectorCSSStyleSheetIdentityStorage: WebInspectorCanonicalCSSStyleSheetRecord] = [:]
    private var styleSheetIDsByScope:
        [WebInspectorDOMDocumentScopeStorage: Set<WebInspectorCSSStyleSheetIdentityStorage>] = [:]
    private var styleSheetIDsByFrameID: [FrameID: Set<WebInspectorCSSStyleSheetIdentityStorage>] = [:]
    private var retiredStyleSheetIDsByScope: [WebInspectorDOMDocumentScopeStorage: Set<CSS.StyleSheet.ID>] = [:]
    private var cascadeRevisionByScope: [WebInspectorDOMDocumentScopeStorage: UInt64] = [:]
    private var activeScopeByTargetRoute: [WebInspectorDOMTargetRouteStorage: WebInspectorDOMDocumentScopeStorage] =
        [:]
    private var activeSemanticTargetByTargetRoute: [WebInspectorDOMTargetRouteStorage: WebInspectorFeatureTarget] = [:]

    package private(set) var performanceCounters = WebInspectorCanonicalCSSPerformanceCounters()

    package init(
        storeID: WebInspectorContainerStoreID,
        attachmentGeneration: WebInspectorAttachmentGeneration
    ) {
        self.storeID = storeID
        self.attachmentGeneration = attachmentGeneration
    }

    package func record(
        for id: WebInspectorCSSStyleSheetIdentityStorage
    ) -> WebInspectorCanonicalCSSStyleSheetRecord? {
        recordsByID[id]
    }

    package func cascadeRevision(
        in scope: WebInspectorDOMDocumentScopeStorage
    ) -> UInt64 {
        cascadeRevisionByScope[scope, default: 0]
    }

    package mutating func snapshot() -> WebInspectorCanonicalCSSSnapshot {
        performanceCounters.fullSnapshotBuildCount += 1
        return WebInspectorCanonicalCSSSnapshot(
            recordsByID: recordsByID,
            cascadeRevisionByScope: cascadeRevisionByScope
        )
    }

    package mutating func bootstrap(
        scopes eventScopes: [WebInspectorCanonicalDOMEventScope],
        styleSheets: [WebInspectorCanonicalCSSStyleSheetSnapshotRecord]
    ) throws -> WebInspectorCanonicalCSSTransaction {
        var incomingByID: [WebInspectorCSSStyleSheetIdentityStorage: WebInspectorCanonicalCSSStyleSheetRecord] = [:]
        var incomingOrder: [WebInspectorCSSStyleSheetIdentityStorage] = []
        var incomingScopesByRoute: [WebInspectorDOMTargetRouteStorage: WebInspectorDOMDocumentScopeStorage] = [:]
        var incomingSemanticTargetsByRoute: [WebInspectorDOMTargetRouteStorage: WebInspectorFeatureTarget] = [:]

        for eventScope in eventScopes {
            let scope = try documentScope(for: eventScope)
            let targetRoute = scope.targetRoute
            let semanticTarget = eventScope.modelScope.semanticTarget
            if let activeScope = activeScopeByTargetRoute[targetRoute], activeScope != scope {
                throw WebInspectorCanonicalCSSError.scopeMismatch(targetRoute)
            }
            if let activeTarget = activeSemanticTargetByTargetRoute[targetRoute],
                activeTarget != semanticTarget
            {
                throw WebInspectorCanonicalCSSError.scopeMismatch(targetRoute)
            }
            guard incomingScopesByRoute.updateValue(scope, forKey: targetRoute) == nil else {
                throw WebInspectorCanonicalCSSError.duplicateBootstrapScope(targetRoute)
            }
            incomingSemanticTargetsByRoute[targetRoute] = semanticTarget
        }

        for styleSheet in styleSheets {
            let scope = try documentScope(for: styleSheet.scope)
            let targetRoute = scope.targetRoute
            guard incomingScopesByRoute[targetRoute] == scope,
                incomingSemanticTargetsByRoute[targetRoute] == styleSheet.scope.modelScope.semanticTarget
            else {
                throw WebInspectorCanonicalCSSError.scopeMismatch(targetRoute)
            }
            let record = try makeRecord(header: styleSheet.header, scope: scope)
            guard incomingByID.updateValue(record, forKey: record.id) == nil else {
                throw WebInspectorCanonicalCSSError.duplicateStyleSheet(record.id)
            }
            if recordsByID[record.id] == nil,
                retiredStyleSheetIDsByScope[scope]?.contains(record.id.rawStyleSheetID) == true
            {
                throw WebInspectorCanonicalCSSError.reusedStyleSheet(record.id)
            }
            incomingOrder.append(record.id)
        }

        let incomingIDs = Set(incomingByID.keys)
        let removedIDs = Set(recordsByID.keys).subtracting(incomingIDs)
        var affectedScopes = Set(incomingScopesByRoute.values)
        affectedScopes.formUnion(removedIDs.map(\.documentScope))

        var transaction = WebInspectorCanonicalCSSTransaction()
        transaction.deletedRecordIDs = removedIDs
        for id in incomingOrder {
            guard let record = incomingByID[id] else {
                continue
            }
            if let existing = recordsByID[id] {
                if existing != record {
                    transaction.updatedRecords.append(record)
                }
            } else {
                transaction.insertedRecords.append(record)
            }
        }

        for id in removedIDs {
            guard let removed = recordsByID.removeValue(forKey: id) else {
                preconditionFailure("Canonical CSS bootstrap lost a removed record.")
            }
            styleSheetIDsByScope[id.documentScope]?.remove(id)
            removeFromFrameIndex(removed)
            retiredStyleSheetIDsByScope[id.documentScope, default: []].insert(id.rawStyleSheetID)
        }
        for id in incomingOrder {
            guard let record = incomingByID[id] else {
                continue
            }
            if let previous = recordsByID[id], previous.frameID != record.frameID {
                removeFromFrameIndex(previous)
            }
            recordsByID[id] = record
            styleSheetIDsByScope[id.documentScope, default: []].insert(id)
            insertIntoFrameIndex(record)
        }
        for (targetRoute, scope) in incomingScopesByRoute {
            activeScopeByTargetRoute[targetRoute] = scope
            activeSemanticTargetByTargetRoute[targetRoute] = incomingSemanticTargetsByRoute[targetRoute]
        }
        for scope in affectedScopes.sorted(
            by: WebInspectorDOMDocumentScopeStorage.precedesInCanonicalOrder
        ) {
            advanceCascadeRevision(scope, transaction: &transaction)
            transaction.resourceInvalidations.insert(.target(scope))
        }

        performanceCounters.fullSnapshotBuildCount += 1
        performanceCounters.fullSnapshotHeaderVisitCount += styleSheets.count
        performanceCounters.recordMutationCount +=
            removedIDs.count
            + transaction.insertedRecords.count
            + transaction.updatedRecords.count
        return transaction
    }

    package mutating func apply(
        scope eventScope: WebInspectorCanonicalDOMEventScope,
        event: CSS.Event
    ) throws -> WebInspectorCanonicalCSSTransaction {
        let scope = try documentScope(for: eventScope)
        let targetRoute = scope.targetRoute
        if let activeScope = activeScopeByTargetRoute[targetRoute], activeScope != scope {
            throw WebInspectorCanonicalCSSError.scopeMismatch(targetRoute)
        }
        if let activeTarget = activeSemanticTargetByTargetRoute[targetRoute],
            activeTarget != eventScope.modelScope.semanticTarget
        {
            throw WebInspectorCanonicalCSSError.scopeMismatch(targetRoute)
        }
        switch event {
        case let .styleSheetChanged(rawID):
            let id = styleSheetID(rawID, in: scope)
            guard recordsByID[id] != nil else {
                throw WebInspectorCanonicalCSSError.missingStyleSheet(id)
            }
            performanceCounters.incrementalLookupCount += 1
            var transaction = WebInspectorCanonicalCSSTransaction()
            advanceCascadeRevision(scope, transaction: &transaction)
            transaction.resourceInvalidations.insert(.target(scope))
            establish(scope, semanticTarget: eventScope.modelScope.semanticTarget)
            return transaction
        case let .styleSheetAdded(header):
            let record = try makeRecord(header: header, scope: scope)
            guard recordsByID[record.id] == nil else {
                throw WebInspectorCanonicalCSSError.duplicateStyleSheet(record.id)
            }
            guard retiredStyleSheetIDsByScope[scope]?.contains(record.id.rawStyleSheetID) != true else {
                throw WebInspectorCanonicalCSSError.reusedStyleSheet(record.id)
            }
            var transaction = WebInspectorCanonicalCSSTransaction()
            transaction.insertedRecords = [record]
            advanceCascadeRevision(scope, transaction: &transaction)
            transaction.resourceInvalidations.insert(.target(scope))
            recordsByID[record.id] = record
            styleSheetIDsByScope[scope, default: []].insert(record.id)
            insertIntoFrameIndex(record)
            establish(scope, semanticTarget: eventScope.modelScope.semanticTarget)
            performanceCounters.incrementalLookupCount += 1
            performanceCounters.recordMutationCount += 1
            return transaction
        case let .styleSheetRemoved(rawID):
            let id = styleSheetID(rawID, in: scope)
            guard recordsByID[id] != nil else {
                throw WebInspectorCanonicalCSSError.missingStyleSheet(id)
            }
            var transaction = WebInspectorCanonicalCSSTransaction()
            transaction.deletedRecordIDs = [id]
            advanceCascadeRevision(scope, transaction: &transaction)
            transaction.resourceInvalidations.insert(.target(scope))
            guard let removed = recordsByID.removeValue(forKey: id) else {
                preconditionFailure("Canonical CSS removal lost its validated record.")
            }
            styleSheetIDsByScope[scope]?.remove(id)
            removeFromFrameIndex(removed)
            retiredStyleSheetIDsByScope[scope, default: []].insert(rawID)
            establish(scope, semanticTarget: eventScope.modelScope.semanticTarget)
            performanceCounters.incrementalLookupCount += 1
            performanceCounters.recordMutationCount += 1
            return transaction
        case .mediaQueryResultChanged:
            var transaction = WebInspectorCanonicalCSSTransaction()
            advanceCascadeRevision(scope, transaction: &transaction)
            transaction.resourceInvalidations.insert(.target(scope))
            establish(scope, semanticTarget: eventScope.modelScope.semanticTarget)
            return transaction
        case let .nodeLayoutFlagsChanged(rawNodeID):
            let nodeID = WebInspectorDOMNodeIdentityStorage(
                documentScope: scope,
                rawNodeID: rawNodeID
            )
            var transaction = WebInspectorCanonicalCSSTransaction()
            transaction.resourceInvalidations = [.nodes([nodeID])]
            establish(scope, semanticTarget: eventScope.modelScope.semanticTarget)
            return transaction
        case .unknown:
            return WebInspectorCanonicalCSSTransaction()
        }
    }

    package mutating func invalidateDocument(
        _ newEventScope: WebInspectorCanonicalDOMEventScope
    ) throws -> WebInspectorCanonicalCSSTransaction {
        let newScope = try documentScope(for: newEventScope)
        let targetRoute = newScope.targetRoute
        guard let oldScope = activeScopeByTargetRoute[targetRoute] else {
            throw WebInspectorCanonicalCSSError.inactiveTarget(targetRoute)
        }
        guard oldScope.pageGeneration == newScope.pageGeneration,
            activeSemanticTargetByTargetRoute[targetRoute] == newEventScope.modelScope.semanticTarget,
            oldScope.domBindingEpoch.rawValue != UInt64.max,
            oldScope.domBindingEpoch.rawValue + 1 == newScope.domBindingEpoch.rawValue
        else {
            throw WebInspectorCanonicalCSSError.invalidDocumentTransition(targetRoute)
        }
        var transaction = removeScope(oldScope)
        activeScopeByTargetRoute[targetRoute] = newScope
        activeSemanticTargetByTargetRoute[targetRoute] = newEventScope.modelScope.semanticTarget
        styleSheetIDsByScope[newScope] = []
        retiredStyleSheetIDsByScope.removeValue(forKey: oldScope)
        cascadeRevisionByScope.removeValue(forKey: oldScope)
        advanceCascadeRevision(newScope, transaction: &transaction)
        transaction.resourceInvalidations.insert(.target(oldScope))
        return transaction
    }

    package mutating func targetLost(
        scope eventScope: WebInspectorCanonicalDOMEventScope
    ) throws -> WebInspectorCanonicalCSSTransaction {
        let scope = try requireActiveScope(eventScope)
        var transaction = removeScope(scope)
        transaction.resourceInvalidations.insert(.target(scope))
        activeScopeByTargetRoute.removeValue(forKey: scope.targetRoute)
        activeSemanticTargetByTargetRoute.removeValue(forKey: scope.targetRoute)
        retiredStyleSheetIDsByScope.removeValue(forKey: scope)
        cascadeRevisionByScope.removeValue(forKey: scope)
        return transaction
    }

    /// Removes style sheets allocated for an ordinary frame that has no
    /// dedicated model target. Site-isolated frame sheets are removed with
    /// their document scope by `targetLost(scope:)`.
    package mutating func frameWasDetached(
        _ frameID: FrameID
    ) -> WebInspectorCanonicalCSSTransaction {
        let ids = styleSheetIDsByFrameID[frameID] ?? []
        guard !ids.isEmpty else {
            return WebInspectorCanonicalCSSTransaction()
        }

        var affectedScopes = Set<WebInspectorDOMDocumentScopeStorage>()
        for id in ids {
            guard let record = recordsByID.removeValue(forKey: id),
                record.frameID == frameID
            else {
                preconditionFailure("Canonical CSS frame index lost record authority.")
            }
            styleSheetIDsByScope[id.documentScope]?.remove(id)
            retiredStyleSheetIDsByScope[id.documentScope, default: []].insert(
                id.rawStyleSheetID
            )
            affectedScopes.insert(id.documentScope)
        }
        styleSheetIDsByFrameID[frameID] = nil

        var transaction = WebInspectorCanonicalCSSTransaction(
            deletedRecordIDs: ids
        )
        for scope in affectedScopes.sorted(
            by: WebInspectorDOMDocumentScopeStorage.precedesInCanonicalOrder
        ) {
            advanceCascadeRevision(scope, transaction: &transaction)
            transaction.resourceInvalidations.insert(.target(scope))
        }
        performanceCounters.recordMutationCount += ids.count
        return transaction
    }

    package mutating func reset() -> WebInspectorCanonicalCSSTransaction {
        var transaction = WebInspectorCanonicalCSSTransaction()
        transaction.deletedRecordIDs = Set(recordsByID.keys)
        transaction.resourceInvalidations = Set(
            activeScopeByTargetRoute.values.map {
                WebInspectorCanonicalResourceInvalidation.target($0)
            })
        performanceCounters.recordMutationCount += recordsByID.count
        recordsByID.removeAll(keepingCapacity: true)
        styleSheetIDsByScope.removeAll(keepingCapacity: true)
        styleSheetIDsByFrameID.removeAll(keepingCapacity: true)
        retiredStyleSheetIDsByScope.removeAll(keepingCapacity: true)
        cascadeRevisionByScope.removeAll(keepingCapacity: true)
        activeScopeByTargetRoute.removeAll(keepingCapacity: true)
        activeSemanticTargetByTargetRoute.removeAll(keepingCapacity: true)
        return transaction
    }
}

private extension WebInspectorCanonicalCSSReducer {
    func documentScope(
        for eventScope: WebInspectorCanonicalDOMEventScope
    ) throws -> WebInspectorDOMDocumentScopeStorage {
        WebInspectorDOMDocumentScopeStorage(
            storeID: storeID,
            attachmentGeneration: attachmentGeneration,
            eventScope: eventScope
        )
    }

    func requireActiveScope(
        _ eventScope: WebInspectorCanonicalDOMEventScope
    ) throws -> WebInspectorDOMDocumentScopeStorage {
        let scope = try documentScope(for: eventScope)
        let targetRoute = scope.targetRoute
        guard let activeScope = activeScopeByTargetRoute[targetRoute] else {
            throw WebInspectorCanonicalCSSError.inactiveTarget(targetRoute)
        }
        guard activeScope == scope else {
            throw WebInspectorCanonicalCSSError.scopeMismatch(targetRoute)
        }
        guard activeSemanticTargetByTargetRoute[targetRoute] == eventScope.modelScope.semanticTarget else {
            throw WebInspectorCanonicalCSSError.scopeMismatch(targetRoute)
        }
        return scope
    }

    mutating func establish(
        _ scope: WebInspectorDOMDocumentScopeStorage,
        semanticTarget: WebInspectorFeatureTarget
    ) {
        activeScopeByTargetRoute[scope.targetRoute] = scope
        activeSemanticTargetByTargetRoute[scope.targetRoute] = semanticTarget
        if styleSheetIDsByScope[scope] == nil {
            styleSheetIDsByScope[scope] = []
        }
    }

    func styleSheetID(
        _ rawID: CSS.StyleSheet.ID,
        in scope: WebInspectorDOMDocumentScopeStorage
    ) -> WebInspectorCSSStyleSheetIdentityStorage {
        WebInspectorCSSStyleSheetIdentityStorage(
            documentScope: scope,
            rawStyleSheetID: rawID
        )
    }

    func makeRecord(
        header: CSS.StyleSheetHeader,
        scope: WebInspectorDOMDocumentScopeStorage
    ) throws -> WebInspectorCanonicalCSSStyleSheetRecord {
        let id = styleSheetID(header.styleSheetID, in: scope)
        guard header.startLine >= 0, header.startColumn >= 0 else {
            throw WebInspectorCanonicalCSSError.invalidStyleSheetHeader(id)
        }
        return WebInspectorCanonicalCSSStyleSheetRecord(
            id: id,
            frameID: header.frameID,
            sourceURL: header.sourceURL,
            origin: header.origin.rawValue,
            title: header.title,
            disabled: header.disabled,
            isInline: header.isInline,
            startLine: header.startLine,
            startColumn: header.startColumn
        )
    }

    mutating func advanceCascadeRevision(
        _ scope: WebInspectorDOMDocumentScopeStorage,
        transaction: inout WebInspectorCanonicalCSSTransaction
    ) {
        let current = cascadeRevisionByScope[scope, default: 0]
        precondition(current != UInt64.max, "CSS cascade revision exhausted UInt64.")
        let revision = current + 1
        cascadeRevisionByScope[scope] = revision
        transaction.cascadeRevisionChanges.append(
            WebInspectorCanonicalCSSCascadeRevisionChange(scope: scope, revision: revision)
        )
    }

    mutating func removeScope(
        _ scope: WebInspectorDOMDocumentScopeStorage
    ) -> WebInspectorCanonicalCSSTransaction {
        let ids = styleSheetIDsByScope.removeValue(forKey: scope) ?? []
        for id in ids {
            guard let record = recordsByID.removeValue(forKey: id) else {
                preconditionFailure("Canonical CSS scope index lost record authority.")
            }
            removeFromFrameIndex(record)
        }
        performanceCounters.recordMutationCount += ids.count
        return WebInspectorCanonicalCSSTransaction(deletedRecordIDs: ids)
    }

    mutating func insertIntoFrameIndex(
        _ record: WebInspectorCanonicalCSSStyleSheetRecord
    ) {
        guard let frameID = record.frameID else {
            return
        }
        styleSheetIDsByFrameID[frameID, default: []].insert(record.id)
    }

    mutating func removeFromFrameIndex(
        _ record: WebInspectorCanonicalCSSStyleSheetRecord
    ) {
        guard let frameID = record.frameID,
            var ids = styleSheetIDsByFrameID[frameID],
            ids.remove(record.id) != nil
        else {
            if record.frameID != nil {
                preconditionFailure("Canonical CSS frame index lost membership.")
            }
            return
        }
        styleSheetIDsByFrameID[frameID] = ids.isEmpty ? nil : ids
    }

}
