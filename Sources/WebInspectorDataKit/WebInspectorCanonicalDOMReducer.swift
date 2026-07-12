import Foundation
import WebInspectorProxyKit

package enum WebInspectorCanonicalResourceInvalidation: Hashable, Sendable {
    case target(WebInspectorDOMDocumentScopeStorage)
    case subtree(WebInspectorDOMNodeIdentityStorage)
    case nodes(Set<WebInspectorDOMNodeIdentityStorage>)
}

package enum WebInspectorCanonicalDOMChildren: Equatable, Sendable {
    case unrequested(count: Int)
    case loaded([WebInspectorDOMNodeIdentityStorage])

    package var count: Int {
        switch self {
        case let .unrequested(count):
            count
        case let .loaded(ids):
            ids.count
        }
    }
}

package struct WebInspectorCanonicalDOMQueryValue: Equatable, Sendable {
    package let id: WebInspectorDOMNodeIdentityStorage
    package let nodeName: String
    package let localName: String
    package let nodeValue: String
    package let nodeType: Int
    package let frameID: FrameID?
    package let documentURL: String?
    package let baseURL: String?
    package let attributes: [String: String]
    package let childNodeCount: Int
    package let pseudoType: DOM.PseudoType?
    package let shadowRootType: DOM.ShadowRootType?
}

package struct WebInspectorCanonicalDOMRecord: Equatable, Sendable {
    package let id: WebInspectorDOMNodeIdentityStorage
    package let insertionOrdinal: UInt64
    package var nodeName: String
    package var localName: String
    package var nodeValue: String
    package var nodeType: Int
    package var frameID: FrameID?
    package var documentURL: String?
    package var baseURL: String?
    package var attributes: [DOM.Attribute]
    package var children: WebInspectorCanonicalDOMChildren
    package var contentDocumentID: WebInspectorDOMNodeIdentityStorage?
    package var shadowRootIDs: [WebInspectorDOMNodeIdentityStorage]
    package var templateContentID: WebInspectorDOMNodeIdentityStorage?
    package var beforePseudoElementID: WebInspectorDOMNodeIdentityStorage?
    package var otherPseudoElementIDs: [WebInspectorDOMNodeIdentityStorage]
    package var afterPseudoElementID: WebInspectorDOMNodeIdentityStorage?
    package var pseudoType: DOM.PseudoType?
    package var shadowRootType: DOM.ShadowRootType?

    package var queryValue: WebInspectorCanonicalDOMQueryValue {
        WebInspectorCanonicalDOMQueryValue(
            id: id,
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            nodeType: nodeType,
            frameID: frameID,
            documentURL: documentURL,
            baseURL: baseURL,
            attributes: Dictionary(uniqueKeysWithValues: attributes.map { ($0.name, $0.value) }),
            childNodeCount: children.count,
            pseudoType: pseudoType,
            shadowRootType: shadowRootType
        )
    }

    fileprivate var ownedRelationshipIDs: [WebInspectorDOMNodeIdentityStorage] {
        var result: [WebInspectorDOMNodeIdentityStorage] = []
        if case let .loaded(children) = children {
            result.append(contentsOf: children)
        }
        if let contentDocumentID,
            contentDocumentID.documentScope == id.documentScope
        {
            result.append(contentDocumentID)
        }
        result.append(contentsOf: shadowRootIDs)
        if let templateContentID {
            result.append(templateContentID)
        }
        if let beforePseudoElementID {
            result.append(beforePseudoElementID)
        }
        result.append(contentsOf: otherPseudoElementIDs)
        if let afterPseudoElementID {
            result.append(afterPseudoElementID)
        }
        return result
    }

    fileprivate var frameOwnerID: FrameID? {
        guard let frameID else {
            return nil
        }
        let normalizedLocalName = localName.lowercased()
        let normalizedNodeName = nodeName.lowercased()
        switch (normalizedLocalName, normalizedNodeName) {
        case ("iframe", _), ("frame", _), (_, "iframe"), (_, "frame"):
            return frameID
        default:
            return nil
        }
    }
}

package struct WebInspectorCanonicalDOMRecordPatch: Equatable, Sendable {
    package enum Field: Equatable, Sendable {
        case nodeName(String)
        case localName(String)
        case nodeValue(String)
        case nodeType(Int)
        case frameID(FrameID?)
        case documentURL(String?)
        case baseURL(String?)
        case attributes([DOM.Attribute])
        case children(WebInspectorCanonicalDOMChildren)
        case contentDocument(WebInspectorDOMNodeIdentityStorage?)
        case shadowRoots([WebInspectorDOMNodeIdentityStorage])
        case templateContent(WebInspectorDOMNodeIdentityStorage?)
        case beforePseudoElement(WebInspectorDOMNodeIdentityStorage?)
        case otherPseudoElements([WebInspectorDOMNodeIdentityStorage])
        case afterPseudoElement(WebInspectorDOMNodeIdentityStorage?)
        case pseudoType(DOM.PseudoType?)
        case shadowRootType(DOM.ShadowRootType?)
    }

    package let id: WebInspectorDOMNodeIdentityStorage
    package let fields: [Field]
}

package extension WebInspectorCanonicalDOMRecord {
    mutating func apply(_ patch: WebInspectorCanonicalDOMRecordPatch) {
        precondition(
            patch.id == id,
            "A canonical DOM patch must target its record identity."
        )
        for field in patch.fields {
            switch field {
            case let .nodeName(value):
                nodeName = value
            case let .localName(value):
                localName = value
            case let .nodeValue(value):
                nodeValue = value
            case let .nodeType(value):
                nodeType = value
            case let .frameID(value):
                frameID = value
            case let .documentURL(value):
                documentURL = value
            case let .baseURL(value):
                baseURL = value
            case let .attributes(value):
                attributes = value
            case let .children(value):
                children = value
            case let .contentDocument(value):
                contentDocumentID = value
            case let .shadowRoots(value):
                shadowRootIDs = value
            case let .templateContent(value):
                templateContentID = value
            case let .beforePseudoElement(value):
                beforePseudoElementID = value
            case let .otherPseudoElements(value):
                otherPseudoElementIDs = value
            case let .afterPseudoElement(value):
                afterPseudoElementID = value
            case let .pseudoType(value):
                pseudoType = value
            case let .shadowRootType(value):
                shadowRootType = value
            }
        }
    }
}

package struct WebInspectorCanonicalDOMRootChange: Equatable, Sendable {
    package let scope: WebInspectorDOMDocumentScopeStorage
    package let rootID: WebInspectorDOMNodeIdentityStorage?
}

package struct WebInspectorCanonicalDOMParentChange: Equatable, Sendable {
    package let nodeID: WebInspectorDOMNodeIdentityStorage
    package let parentID: WebInspectorDOMNodeIdentityStorage?
}

package struct WebInspectorCanonicalDOMTransaction: Equatable, Sendable {
    package var insertedRecords: [WebInspectorCanonicalDOMRecord] = []
    package var recordPatches: [WebInspectorCanonicalDOMRecordPatch] = []
    package var deletedRecordIDs: Set<WebInspectorDOMNodeIdentityStorage> = []
    package var parentChanges: [WebInspectorCanonicalDOMParentChange] = []
    package var rootChanges: [WebInspectorCanonicalDOMRootChange] = []
    package var queryValueUpserts: [WebInspectorDOMNodeIdentityStorage: WebInspectorCanonicalDOMQueryValue] = [:]
    package var queryValueDeletes: Set<WebInspectorDOMNodeIdentityStorage> = []
    package var resourceInvalidations: Set<WebInspectorCanonicalResourceInvalidation> = []

    package var isEmpty: Bool {
        insertedRecords.isEmpty
            && recordPatches.isEmpty
            && deletedRecordIDs.isEmpty
            && parentChanges.isEmpty
            && rootChanges.isEmpty
            && queryValueUpserts.isEmpty
            && queryValueDeletes.isEmpty
            && resourceInvalidations.isEmpty
    }
}

package struct WebInspectorCanonicalDOMSnapshot: Equatable, Sendable {
    package let records: [WebInspectorCanonicalDOMRecord]
    package let parentByNodeID: [WebInspectorDOMNodeIdentityStorage: WebInspectorDOMNodeIdentityStorage]
    package let rootByDocumentScope: [WebInspectorDOMDocumentScopeStorage: WebInspectorDOMNodeIdentityStorage]

    package var recordsByID: [WebInspectorDOMNodeIdentityStorage: WebInspectorCanonicalDOMRecord] {
        Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    package init(
        recordsByID: [WebInspectorDOMNodeIdentityStorage: WebInspectorCanonicalDOMRecord],
        parentByNodeID: [WebInspectorDOMNodeIdentityStorage: WebInspectorDOMNodeIdentityStorage],
        rootByDocumentScope: [WebInspectorDOMDocumentScopeStorage: WebInspectorDOMNodeIdentityStorage]
    ) {
        precondition(
            recordsByID.allSatisfy { id, record in
                id == record.id && record.insertionOrdinal > 0
            },
            "Canonical DOM snapshots require matching identities and allocated insertion ordinals."
        )
        precondition(
            Set(recordsByID.values.map(\.insertionOrdinal)).count
                == recordsByID.count,
            "Canonical DOM snapshot insertion ordinals must be unique."
        )
        records = recordsByID.values.sorted {
            $0.insertionOrdinal < $1.insertionOrdinal
        }
        self.parentByNodeID = parentByNodeID
        self.rootByDocumentScope = rootByDocumentScope
    }
}

package struct WebInspectorCanonicalDOMPerformanceCounters: Equatable, Sendable {
    package fileprivate(set) var fullGraphBuildCount = 0
    package fileprivate(set) var fullGraphNodeVisitCount = 0
    package fileprivate(set) var fullSnapshotBuildCount = 0
    package fileprivate(set) var incrementalNodeVisitCount = 0
    package fileprivate(set) var subtreeDeletionNodeVisitCount = 0
    package fileprivate(set) var unrelatedRecordScanCount = 0
    package fileprivate(set) var recordMutationCount = 0
}

package enum WebInspectorCanonicalDOMError: Error, Equatable, Sendable {
    case missingDOMBindingEpoch
    case inactiveTarget(WebInspectorDOMTargetRouteStorage)
    case scopeMismatch(WebInspectorDOMTargetRouteStorage)
    case bootstrapAlreadyExists(WebInspectorDOMDocumentScopeStorage)
    case invalidDocumentTransition(WebInspectorDOMTargetRouteStorage)
    case duplicateNode(WebInspectorDOMNodeIdentityStorage)
    case reusedNode(WebInspectorDOMNodeIdentityStorage)
    case missingNode(WebInspectorDOMNodeIdentityStorage)
    case invalidParent(WebInspectorDOMNodeIdentityStorage)
    case invalidPreviousSibling(WebInspectorDOMNodeIdentityStorage)
    case invalidChildCount(WebInspectorDOMNodeIdentityStorage)
    case invalidAttributes(WebInspectorDOMNodeIdentityStorage)
    case invalidRelationship(WebInspectorDOMNodeIdentityStorage)
    case ambiguousFrameOwner(FrameID)
    case ambiguousFrameRoot(FrameID)
    case documentUpdatedRequiresInvalidationBoundary
    case insertionOrdinalExhausted
}

package struct WebInspectorCanonicalDOMReducer: Sendable {
    fileprivate enum ParentAssignment {
        case parent(WebInspectorDOMNodeIdentityStorage)
        case none
    }

    fileprivate struct BuiltGraph {
        var recordsByID: [WebInspectorDOMNodeIdentityStorage: WebInspectorCanonicalDOMRecord] = [:]
        var parentAssignments: [WebInspectorDOMNodeIdentityStorage: ParentAssignment] = [:]
        var insertionOrder: [WebInspectorDOMNodeIdentityStorage] = []
        var frameOwners: [FrameID: WebInspectorDOMNodeIdentityStorage] = [:]
        var lastAllocatedInsertionOrdinal: UInt64?
        var visitCount = 0
    }

    fileprivate struct MutationPlan {
        var upserts: [WebInspectorDOMNodeIdentityStorage: WebInspectorCanonicalDOMRecord] = [:]
        var upsertOrder: [WebInspectorDOMNodeIdentityStorage] = []
        var parentAssignments: [WebInspectorDOMNodeIdentityStorage: ParentAssignment] = [:]
        var deletes: Set<WebInspectorDOMNodeIdentityStorage> = []
        var tombstones: Set<WebInspectorDOMNodeIdentityStorage> = []
        var incrementalVisits = 0
        var deletionVisits = 0
        var resourceInvalidations: Set<WebInspectorCanonicalResourceInvalidation> = []
    }

    package let storeID: WebInspectorContainerStoreID
    package let attachmentGeneration: WebInspectorContainerAttachmentGeneration

    private var recordsByID: [WebInspectorDOMNodeIdentityStorage: WebInspectorCanonicalDOMRecord] = [:]
    private var parentByNodeID: [WebInspectorDOMNodeIdentityStorage: WebInspectorDOMNodeIdentityStorage] = [:]
    private var rootByDocumentScope: [WebInspectorDOMDocumentScopeStorage: WebInspectorDOMNodeIdentityStorage] = [:]
    private var nodeIDsByDocumentScope: [WebInspectorDOMDocumentScopeStorage: Set<WebInspectorDOMNodeIdentityStorage>] =
        [:]
    private var activeScopeByTargetRoute: [WebInspectorDOMTargetRouteStorage: WebInspectorDOMDocumentScopeStorage] =
        [:]
    private var activeSemanticTargetByTargetRoute: [WebInspectorDOMTargetRouteStorage: ModelTarget] = [:]
    private var frameOwnerByFrameID: [FrameID: WebInspectorDOMNodeIdentityStorage] = [:]
    private var frameRootByFrameID: [FrameID: WebInspectorDOMNodeIdentityStorage] = [:]
    private var frameIDByFrameRootID: [WebInspectorDOMNodeIdentityStorage: FrameID] = [:]
    private var retiredRawNodeIDsByScope: [WebInspectorDOMDocumentScopeStorage: Set<DOM.Node.ID>] = [:]
    private var lastInsertionOrdinal: UInt64 = 0

    package private(set) var performanceCounters = WebInspectorCanonicalDOMPerformanceCounters()

    #if DEBUG
        package mutating func setLastInsertionOrdinalForTesting(_ ordinal: UInt64) {
            precondition(recordsByID.isEmpty)
            lastInsertionOrdinal = ordinal
        }
    #endif

    package init(
        storeID: WebInspectorContainerStoreID,
        attachmentGeneration: WebInspectorContainerAttachmentGeneration
    ) {
        self.storeID = storeID
        self.attachmentGeneration = attachmentGeneration
    }

    package func record(
        for id: WebInspectorDOMNodeIdentityStorage
    ) -> WebInspectorCanonicalDOMRecord? {
        recordsByID[id]
    }

    package func parent(
        of id: WebInspectorDOMNodeIdentityStorage
    ) -> WebInspectorDOMNodeIdentityStorage? {
        parentByNodeID[id]
    }

    package func root(
        in scope: WebInspectorDOMDocumentScopeStorage
    ) -> WebInspectorDOMNodeIdentityStorage? {
        rootByDocumentScope[scope]
    }

    package mutating func snapshot() -> WebInspectorCanonicalDOMSnapshot {
        performanceCounters.fullSnapshotBuildCount += 1
        return WebInspectorCanonicalDOMSnapshot(
            recordsByID: recordsByID,
            parentByNodeID: parentByNodeID,
            rootByDocumentScope: rootByDocumentScope
        )
    }

    package mutating func bootstrap(
        scope eventScope: WebInspectorCanonicalDOMEventScope,
        root: DOM.Node
    ) throws -> WebInspectorCanonicalDOMTransaction {
        let scope = try documentScope(for: eventScope)
        let targetRoute = scope.targetRoute
        if let activeScope = activeScopeByTargetRoute[targetRoute] {
            guard activeScope == scope else {
                throw WebInspectorCanonicalDOMError.scopeMismatch(targetRoute)
            }
            guard activeSemanticTargetByTargetRoute[targetRoute] == eventScope.modelScope.target else {
                throw WebInspectorCanonicalDOMError.scopeMismatch(targetRoute)
            }
            if rootByDocumentScope[scope] != nil || !(nodeIDsByDocumentScope[scope] ?? []).isEmpty {
                throw WebInspectorCanonicalDOMError.bootstrapAlreadyExists(scope)
            }
        }

        var graph = BuiltGraph()
        try build(root, scope: scope, parent: nil, into: &graph)
        let rootID = nodeID(root.id, in: scope)
        let suppressedEmbeddedDocumentIDs = try prepareNewGraph(&graph, replacing: [])

        var frameRootID: FrameID?
        var embeddedDocumentIDs: Set<WebInspectorDOMNodeIdentityStorage> = []
        if eventScope.modelScope.target.kind == .frame {
            guard let frameID = eventScope.modelScope.target.frameID else {
                throw WebInspectorCanonicalDOMError.invalidRelationship(rootID)
            }
            if let payloadFrameID = root.frameID, payloadFrameID != frameID {
                throw WebInspectorCanonicalDOMError.invalidRelationship(rootID)
            }
            if frameRootByFrameID[frameID] != nil {
                throw WebInspectorCanonicalDOMError.ambiguousFrameRoot(frameID)
            }
            try validateFrameLink(owner: frameOwnerByFrameID[frameID], root: rootID)
            if let ownerID = frameOwnerByFrameID[frameID],
                let contentDocumentID = recordsByID[ownerID]?.contentDocumentID,
                contentDocumentID != rootID
            {
                guard contentDocumentID.documentScope == ownerID.documentScope else {
                    throw WebInspectorCanonicalDOMError.invalidRelationship(ownerID)
                }
                embeddedDocumentIDs = try collectSubtrees([contentDocumentID])
            }
            frameRootID = frameID
        }

        let committedInsertionOrdinal = validatedInsertionOrdinal(
            upserts: graph.recordsByID,
            upsertOrder: graph.insertionOrder
        )

        var touchedFrames = Set(graph.frameOwners.keys)
        lastInsertionOrdinal = committedInsertionOrdinal
        for id in embeddedDocumentIDs {
            if let frameID = recordsByID[id]?.frameOwnerID,
                frameOwnerByFrameID[frameID] == id
            {
                frameOwnerByFrameID.removeValue(forKey: frameID)
                touchedFrames.insert(frameID)
            }
            recordsByID.removeValue(forKey: id)
            parentByNodeID.removeValue(forKey: id)
            nodeIDsByDocumentScope[id.documentScope]?.remove(id)
            retiredRawNodeIDsByScope[id.documentScope, default: []].insert(id.rawNodeID)
        }
        for id in suppressedEmbeddedDocumentIDs {
            retiredRawNodeIDsByScope[id.documentScope, default: []].insert(id.rawNodeID)
        }
        recordsByID.merge(graph.recordsByID) { _, _ in
            preconditionFailure("Validated DOM bootstrap unexpectedly collided during commit.")
        }
        for (id, assignment) in graph.parentAssignments {
            apply(assignment, to: id)
        }
        nodeIDsByDocumentScope[scope] = Set(graph.recordsByID.keys)
        activeScopeByTargetRoute[targetRoute] = scope
        activeSemanticTargetByTargetRoute[targetRoute] = eventScope.modelScope.target
        rootByDocumentScope[scope] = rootID
        for (frameID, ownerID) in graph.frameOwners {
            frameOwnerByFrameID[frameID] = ownerID
        }
        if let frameRootID {
            frameRootByFrameID[frameRootID] = rootID
            frameIDByFrameRootID[rootID] = frameRootID
            touchedFrames.insert(frameRootID)
        }

        var transaction = WebInspectorCanonicalDOMTransaction()
        transaction.insertedRecords = graph.insertionOrder.compactMap { graph.recordsByID[$0] }
        transaction.deletedRecordIDs = embeddedDocumentIDs
        transaction.parentChanges = graph.insertionOrder.map { id in
            WebInspectorCanonicalDOMParentChange(
                nodeID: id,
                parentID: Self.parentID(from: graph.parentAssignments[id])
            )
        }
        transaction.rootChanges = [WebInspectorCanonicalDOMRootChange(scope: scope, rootID: rootID)]
        transaction.queryValueUpserts = graph.recordsByID.mapValues(\.queryValue)
        transaction.queryValueDeletes = embeddedDocumentIDs
        transaction.resourceInvalidations = [.target(scope)]
        for embeddedDocumentID in embeddedDocumentIDs {
            transaction.resourceInvalidations.insert(.target(embeddedDocumentID.documentScope))
        }
        for frameID in touchedFrames.sorted(by: { $0.rawValue < $1.rawValue }) {
            reconcileFrame(frameID, transaction: &transaction)
        }

        performanceCounters.fullGraphBuildCount += 1
        performanceCounters.fullGraphNodeVisitCount += graph.visitCount
        performanceCounters.subtreeDeletionNodeVisitCount += embeddedDocumentIDs.count
        performanceCounters.recordMutationCount += graph.recordsByID.count + embeddedDocumentIDs.count
        return transaction
    }

    package mutating func apply(
        scope eventScope: WebInspectorCanonicalDOMEventScope,
        event: DOM.Event
    ) throws -> WebInspectorCanonicalDOMTransaction {
        let scope = try requireActiveScope(eventScope)
        switch event {
        case .documentUpdated:
            throw WebInspectorCanonicalDOMError.documentUpdatedRequiresInvalidationBoundary
        case let .setChildNodes(parent, nodes):
            return try setChildNodes(parent, nodes: nodes, scope: scope)
        case let .detachedRoot(node):
            return try insertDetachedRoot(node, scope: scope)
        case let .childNodeInserted(parent, previous, node):
            return try insertChild(node, parent: parent, previous: previous, scope: scope)
        case let .childNodeRemoved(parent, node):
            return try removeChild(node, parent: parent, scope: scope)
        case let .childNodeCountUpdated(rawID, count):
            return try updateChildCount(rawID, count: count, scope: scope)
        case let .attributeModified(rawID, name, value):
            return try modifyAttribute(rawID, name: name, value: value, scope: scope)
        case let .attributeRemoved(rawID, name):
            return try removeAttribute(rawID, name: name, scope: scope)
        case let .inlineStyleInvalidated(rawIDs):
            return try invalidateInlineStyles(rawIDs, scope: scope)
        case let .characterDataModified(rawID, value):
            return try modifyCharacterData(rawID, value: value, scope: scope)
        case let .shadowRootPushed(host, root):
            return try pushShadowRoot(root, host: host, scope: scope)
        case let .shadowRootPopped(host, root):
            return try popShadowRoot(root, host: host, scope: scope)
        case let .pseudoElementAdded(parent, element):
            return try addPseudoElement(element, parent: parent, scope: scope)
        case let .pseudoElementRemoved(parent, element):
            return try removePseudoElement(element, parent: parent, scope: scope)
        case let .willDestroyDOMNode(rawID):
            return try destroyDetachedNode(rawID, scope: scope)
        case .inspect, .unknown:
            return WebInspectorCanonicalDOMTransaction()
        }
    }

    package mutating func invalidateDocument(
        _ newEventScope: WebInspectorCanonicalDOMEventScope
    ) throws -> WebInspectorCanonicalDOMTransaction {
        let newScope = try documentScope(for: newEventScope)
        let targetRoute = newScope.targetRoute
        guard let oldScope = activeScopeByTargetRoute[targetRoute] else {
            throw WebInspectorCanonicalDOMError.inactiveTarget(targetRoute)
        }
        guard oldScope.pageGeneration == newScope.pageGeneration,
            activeSemanticTargetByTargetRoute[targetRoute] == newEventScope.modelScope.target,
            oldScope.domBindingEpoch.rawValue != UInt64.max,
            oldScope.domBindingEpoch.rawValue + 1 == newScope.domBindingEpoch.rawValue
        else {
            throw WebInspectorCanonicalDOMError.invalidDocumentTransition(targetRoute)
        }

        var transaction = removeDocumentScope(oldScope)
        transaction.rootChanges.append(WebInspectorCanonicalDOMRootChange(scope: newScope, rootID: nil))
        transaction.resourceInvalidations.insert(.target(oldScope))
        activeScopeByTargetRoute[targetRoute] = newScope
        activeSemanticTargetByTargetRoute[targetRoute] = newEventScope.modelScope.target
        nodeIDsByDocumentScope[newScope] = []
        retiredRawNodeIDsByScope.removeValue(forKey: oldScope)
        return transaction
    }

    package mutating func targetLost(
        scope eventScope: WebInspectorCanonicalDOMEventScope
    ) throws -> WebInspectorCanonicalDOMTransaction {
        let scope = try requireActiveScope(eventScope)
        var transaction = removeDocumentScope(scope)
        transaction.resourceInvalidations.insert(.target(scope))
        activeScopeByTargetRoute.removeValue(forKey: scope.targetRoute)
        activeSemanticTargetByTargetRoute.removeValue(forKey: scope.targetRoute)
        retiredRawNodeIDsByScope.removeValue(forKey: scope)
        return transaction
    }

    /// Removes an ordinary frame's embedded document while retaining the
    /// frame-owner element in its enclosing document.
    ///
    /// A site-isolated frame has a distinct document scope and is removed by
    /// `targetLost(scope:)`. `Page.frameDetached` can also describe an
    /// ordinary frame whose document was allocated by its parent Page agent;
    /// that case has no dedicated model target to destroy.
    package mutating func frameWasDetached(
        _ frameID: FrameID
    ) throws -> WebInspectorCanonicalDOMTransaction {
        guard let ownerID = frameOwnerByFrameID[frameID],
            var owner = recordsByID[ownerID],
            let documentID = owner.contentDocumentID,
            documentID.documentScope == ownerID.documentScope,
            frameRootByFrameID[frameID] == nil
        else {
            return WebInspectorCanonicalDOMTransaction()
        }

        let deletedIDs = try collectSubtrees([documentID])
        owner.contentDocumentID = nil
        let plan = MutationPlan(
            upserts: [ownerID: owner],
            upsertOrder: [ownerID],
            parentAssignments: [
                ownerID: parentByNodeID[ownerID].map(ParentAssignment.parent)
                    ?? ParentAssignment.none
            ],
            deletes: deletedIDs,
            tombstones: deletedIDs,
            deletionVisits: deletedIDs.count,
            resourceInvalidations: [.subtree(ownerID)]
        )
        return try commit(plan)
    }

    package mutating func reset() -> WebInspectorCanonicalDOMTransaction {
        var transaction = WebInspectorCanonicalDOMTransaction()
        transaction.deletedRecordIDs = Set(recordsByID.keys)
        transaction.queryValueDeletes = transaction.deletedRecordIDs
        transaction.rootChanges = rootByDocumentScope.keys.sorted(
            by: WebInspectorDOMDocumentScopeStorage.precedesInCanonicalOrder
        ).map {
            WebInspectorCanonicalDOMRootChange(scope: $0, rootID: nil)
        }
        transaction.resourceInvalidations = Set(
            rootByDocumentScope.keys.map {
                WebInspectorCanonicalResourceInvalidation.target($0)
            })
        performanceCounters.recordMutationCount += recordsByID.count
        recordsByID.removeAll(keepingCapacity: true)
        parentByNodeID.removeAll(keepingCapacity: true)
        rootByDocumentScope.removeAll(keepingCapacity: true)
        nodeIDsByDocumentScope.removeAll(keepingCapacity: true)
        activeScopeByTargetRoute.removeAll(keepingCapacity: true)
        activeSemanticTargetByTargetRoute.removeAll(keepingCapacity: true)
        frameOwnerByFrameID.removeAll(keepingCapacity: true)
        frameRootByFrameID.removeAll(keepingCapacity: true)
        frameIDByFrameRootID.removeAll(keepingCapacity: true)
        retiredRawNodeIDsByScope.removeAll(keepingCapacity: true)
        return transaction
    }
}

private extension WebInspectorCanonicalDOMReducer {
    mutating func setChildNodes(
        _ rawParentID: DOM.Node.ID,
        nodes: [DOM.Node],
        scope: WebInspectorDOMDocumentScopeStorage
    ) throws -> WebInspectorCanonicalDOMTransaction {
        let parentID = nodeID(rawParentID, in: scope)
        guard var parentRecord = recordsByID[parentID] else {
            throw WebInspectorCanonicalDOMError.missingNode(parentID)
        }
        let oldChildIDs: [WebInspectorDOMNodeIdentityStorage]
        switch parentRecord.children {
        case .unrequested:
            oldChildIDs = []
        case let .loaded(ids):
            oldChildIDs = ids
        }

        let oldSubtreeIDs = try collectSubtrees(oldChildIDs)
        var graph = BuiltGraph()
        for node in nodes {
            try build(node, scope: scope, parent: parentID, into: &graph)
        }
        let suppressedIDs = try prepareNewGraph(&graph, replacing: oldSubtreeIDs)

        let newIDs = Set(graph.recordsByID.keys)
        let removedIDs = oldSubtreeIDs.subtracting(newIDs)
        parentRecord.children = .loaded(nodes.map { nodeID($0.id, in: scope) })

        var plan = MutationPlan()
        plan.upserts = graph.recordsByID
        plan.upserts[parentID] = parentRecord
        plan.upsertOrder = graph.insertionOrder + [parentID]
        plan.parentAssignments = graph.parentAssignments
        plan.parentAssignments[parentID] =
            parentByNodeID[parentID].map(ParentAssignment.parent) ?? ParentAssignment.none
        plan.deletes = removedIDs
        plan.tombstones = removedIDs.union(suppressedIDs)
        plan.incrementalVisits = graph.visitCount + 1
        plan.deletionVisits = oldSubtreeIDs.count
        plan.resourceInvalidations = [.target(scope)]
        return try commit(plan)
    }

    mutating func insertDetachedRoot(
        _ node: DOM.Node,
        scope: WebInspectorDOMDocumentScopeStorage
    ) throws -> WebInspectorCanonicalDOMTransaction {
        var graph = BuiltGraph()
        try build(node, scope: scope, parent: nil, into: &graph)
        let suppressedIDs = try prepareNewGraph(&graph, replacing: [])
        var plan = mutationPlan(for: graph)
        plan.tombstones = suppressedIDs
        plan.incrementalVisits = graph.visitCount
        plan.resourceInvalidations = [.target(scope)]
        return try commit(plan)
    }

    mutating func insertChild(
        _ node: DOM.Node,
        parent rawParentID: DOM.Node.ID,
        previous rawPreviousID: DOM.Node.ID?,
        scope: WebInspectorDOMDocumentScopeStorage
    ) throws -> WebInspectorCanonicalDOMTransaction {
        let parentID = nodeID(rawParentID, in: scope)
        guard var parentRecord = recordsByID[parentID] else {
            throw WebInspectorCanonicalDOMError.missingNode(parentID)
        }
        guard case var .loaded(childIDs) = parentRecord.children else {
            throw WebInspectorCanonicalDOMError.invalidParent(parentID)
        }
        let insertionIndex: Int
        if let rawPreviousID {
            let previousID = nodeID(rawPreviousID, in: scope)
            guard let previousIndex = childIDs.firstIndex(of: previousID) else {
                throw WebInspectorCanonicalDOMError.invalidPreviousSibling(previousID)
            }
            insertionIndex = previousIndex + 1
        } else {
            insertionIndex = 0
        }

        var graph = BuiltGraph()
        try build(node, scope: scope, parent: parentID, into: &graph)
        let suppressedIDs = try prepareNewGraph(&graph, replacing: [])
        childIDs.insert(nodeID(node.id, in: scope), at: insertionIndex)
        parentRecord.children = .loaded(childIDs)

        var plan = mutationPlan(for: graph)
        plan.tombstones = suppressedIDs
        plan.upserts[parentID] = parentRecord
        plan.upsertOrder.append(parentID)
        plan.parentAssignments[parentID] =
            parentByNodeID[parentID].map(ParentAssignment.parent) ?? ParentAssignment.none
        plan.incrementalVisits = graph.visitCount + 1
        plan.resourceInvalidations = [.target(scope)]
        return try commit(plan)
    }

    mutating func removeChild(
        _ rawChildID: DOM.Node.ID,
        parent rawParentID: DOM.Node.ID,
        scope: WebInspectorDOMDocumentScopeStorage
    ) throws -> WebInspectorCanonicalDOMTransaction {
        let parentID = nodeID(rawParentID, in: scope)
        let childID = nodeID(rawChildID, in: scope)
        guard var parentRecord = recordsByID[parentID] else {
            throw WebInspectorCanonicalDOMError.missingNode(parentID)
        }
        guard case var .loaded(childIDs) = parentRecord.children,
            let childIndex = childIDs.firstIndex(of: childID),
            parentByNodeID[childID] == parentID
        else {
            throw WebInspectorCanonicalDOMError.invalidParent(childID)
        }
        let deletedIDs = try collectSubtrees([childID])
        childIDs.remove(at: childIndex)
        parentRecord.children = .loaded(childIDs)

        var plan = MutationPlan()
        plan.upserts[parentID] = parentRecord
        plan.upsertOrder = [parentID]
        plan.parentAssignments[parentID] =
            parentByNodeID[parentID].map(ParentAssignment.parent) ?? ParentAssignment.none
        plan.deletes = deletedIDs
        plan.tombstones = deletedIDs
        plan.incrementalVisits = 1
        plan.deletionVisits = deletedIDs.count
        plan.resourceInvalidations = [.target(scope)]
        return try commit(plan)
    }

    mutating func updateChildCount(
        _ rawID: DOM.Node.ID,
        count: Int,
        scope: WebInspectorDOMDocumentScopeStorage
    ) throws -> WebInspectorCanonicalDOMTransaction {
        let id = nodeID(rawID, in: scope)
        guard var record = recordsByID[id] else {
            throw WebInspectorCanonicalDOMError.missingNode(id)
        }
        guard count >= 0 else {
            throw WebInspectorCanonicalDOMError.invalidChildCount(id)
        }
        switch record.children {
        case let .unrequested(oldCount):
            guard oldCount != count else {
                performanceCounters.incrementalNodeVisitCount += 1
                return WebInspectorCanonicalDOMTransaction()
            }
            record.children = .unrequested(count: count)
        case let .loaded(ids):
            guard ids.count == count else {
                throw WebInspectorCanonicalDOMError.invalidChildCount(id)
            }
            performanceCounters.incrementalNodeVisitCount += 1
            return WebInspectorCanonicalDOMTransaction()
        }
        var plan = singleRecordPlan(record)
        plan.resourceInvalidations = [.target(scope)]
        return try commit(plan)
    }

    mutating func modifyAttribute(
        _ rawID: DOM.Node.ID,
        name: String,
        value: String,
        scope: WebInspectorDOMDocumentScopeStorage
    ) throws -> WebInspectorCanonicalDOMTransaction {
        let id = nodeID(rawID, in: scope)
        guard var record = recordsByID[id] else {
            throw WebInspectorCanonicalDOMError.missingNode(id)
        }
        if let index = record.attributes.firstIndex(where: { $0.name == name }) {
            guard record.attributes[index].value != value else {
                performanceCounters.incrementalNodeVisitCount += 1
                return WebInspectorCanonicalDOMTransaction()
            }
            record.attributes[index] = DOM.Attribute(name: name, value: value)
        } else {
            record.attributes.append(DOM.Attribute(name: name, value: value))
        }
        var plan = singleRecordPlan(record)
        plan.resourceInvalidations = [.subtree(id)]
        return try commit(plan)
    }

    mutating func removeAttribute(
        _ rawID: DOM.Node.ID,
        name: String,
        scope: WebInspectorDOMDocumentScopeStorage
    ) throws -> WebInspectorCanonicalDOMTransaction {
        let id = nodeID(rawID, in: scope)
        guard var record = recordsByID[id] else {
            throw WebInspectorCanonicalDOMError.missingNode(id)
        }
        guard let index = record.attributes.firstIndex(where: { $0.name == name }) else {
            throw WebInspectorCanonicalDOMError.invalidAttributes(id)
        }
        record.attributes.remove(at: index)
        var plan = singleRecordPlan(record)
        plan.resourceInvalidations = [.subtree(id)]
        return try commit(plan)
    }

    mutating func invalidateInlineStyles(
        _ rawIDs: [DOM.Node.ID],
        scope: WebInspectorDOMDocumentScopeStorage
    ) throws -> WebInspectorCanonicalDOMTransaction {
        let ids = rawIDs.map { nodeID($0, in: scope) }
        for id in ids where recordsByID[id] == nil {
            throw WebInspectorCanonicalDOMError.missingNode(id)
        }
        performanceCounters.incrementalNodeVisitCount += ids.count
        var transaction = WebInspectorCanonicalDOMTransaction()
        transaction.resourceInvalidations = Set(
            ids.map {
                WebInspectorCanonicalResourceInvalidation.subtree($0)
            })
        return transaction
    }

    mutating func modifyCharacterData(
        _ rawID: DOM.Node.ID,
        value: String,
        scope: WebInspectorDOMDocumentScopeStorage
    ) throws -> WebInspectorCanonicalDOMTransaction {
        let id = nodeID(rawID, in: scope)
        guard var record = recordsByID[id] else {
            throw WebInspectorCanonicalDOMError.missingNode(id)
        }
        guard record.nodeValue != value else {
            performanceCounters.incrementalNodeVisitCount += 1
            return WebInspectorCanonicalDOMTransaction()
        }
        record.nodeValue = value
        var plan = singleRecordPlan(record)
        plan.resourceInvalidations = [.target(scope)]
        return try commit(plan)
    }

    mutating func pushShadowRoot(
        _ root: DOM.Node,
        host rawHostID: DOM.Node.ID,
        scope: WebInspectorDOMDocumentScopeStorage
    ) throws -> WebInspectorCanonicalDOMTransaction {
        let hostID = nodeID(rawHostID, in: scope)
        guard var hostRecord = recordsByID[hostID] else {
            throw WebInspectorCanonicalDOMError.missingNode(hostID)
        }
        let rootID = nodeID(root.id, in: scope)
        let previousSubtreeIDs: Set<WebInspectorDOMNodeIdentityStorage>
        if hostRecord.shadowRootIDs.contains(rootID) {
            previousSubtreeIDs = try collectSubtrees([rootID])
        } else {
            previousSubtreeIDs = []
        }
        var graph = BuiltGraph()
        try build(root, scope: scope, parent: hostID, into: &graph)
        let suppressedIDs = try prepareNewGraph(&graph, replacing: previousSubtreeIDs)
        let removedIDs = previousSubtreeIDs.subtracting(graph.recordsByID.keys)
        hostRecord.shadowRootIDs.removeAll(where: { $0 == rootID })
        hostRecord.shadowRootIDs.append(rootID)
        var plan = mutationPlan(for: graph)
        plan.deletes = removedIDs
        plan.tombstones = removedIDs.union(suppressedIDs)
        plan.upserts[hostID] = hostRecord
        plan.upsertOrder.append(hostID)
        plan.parentAssignments[hostID] = parentByNodeID[hostID].map(ParentAssignment.parent) ?? ParentAssignment.none
        plan.incrementalVisits = graph.visitCount + 1
        plan.deletionVisits = previousSubtreeIDs.count
        plan.resourceInvalidations = [.target(scope)]
        return try commit(plan)
    }

    mutating func popShadowRoot(
        _ rawRootID: DOM.Node.ID,
        host rawHostID: DOM.Node.ID,
        scope: WebInspectorDOMDocumentScopeStorage
    ) throws -> WebInspectorCanonicalDOMTransaction {
        let hostID = nodeID(rawHostID, in: scope)
        let rootID = nodeID(rawRootID, in: scope)
        guard var hostRecord = recordsByID[hostID],
            let index = hostRecord.shadowRootIDs.firstIndex(of: rootID),
            parentByNodeID[rootID] == hostID
        else {
            throw WebInspectorCanonicalDOMError.invalidParent(rootID)
        }
        let deletedIDs = try collectSubtrees([rootID])
        hostRecord.shadowRootIDs.remove(at: index)
        var plan = MutationPlan()
        plan.upserts[hostID] = hostRecord
        plan.upsertOrder = [hostID]
        plan.parentAssignments[hostID] = parentByNodeID[hostID].map(ParentAssignment.parent) ?? ParentAssignment.none
        plan.deletes = deletedIDs
        plan.tombstones = deletedIDs
        plan.incrementalVisits = 1
        plan.deletionVisits = deletedIDs.count
        plan.resourceInvalidations = [.target(scope)]
        return try commit(plan)
    }

    mutating func addPseudoElement(
        _ element: DOM.Node,
        parent rawParentID: DOM.Node.ID,
        scope: WebInspectorDOMDocumentScopeStorage
    ) throws -> WebInspectorCanonicalDOMTransaction {
        let parentID = nodeID(rawParentID, in: scope)
        guard var parentRecord = recordsByID[parentID] else {
            throw WebInspectorCanonicalDOMError.missingNode(parentID)
        }
        let elementID = nodeID(element.id, in: scope)
        let previousID: WebInspectorDOMNodeIdentityStorage?
        switch element.pseudoType {
        case .before:
            previousID = parentRecord.beforePseudoElementID
        case .after:
            previousID = parentRecord.afterPseudoElementID
        case .other, nil:
            previousID = parentRecord.otherPseudoElementIDs.first(where: { $0 == elementID })
        }
        let previousSubtreeIDs = try previousID.map { try collectSubtrees([$0]) } ?? []

        var graph = BuiltGraph()
        try build(element, scope: scope, parent: parentID, into: &graph)
        let suppressedIDs = try prepareNewGraph(&graph, replacing: previousSubtreeIDs)
        let removedIDs = previousSubtreeIDs.subtracting(graph.recordsByID.keys)
        switch element.pseudoType {
        case .before:
            parentRecord.beforePseudoElementID = elementID
        case .after:
            parentRecord.afterPseudoElementID = elementID
        case .other, nil:
            if let index = parentRecord.otherPseudoElementIDs.firstIndex(of: elementID) {
                parentRecord.otherPseudoElementIDs[index] = elementID
            } else {
                parentRecord.otherPseudoElementIDs.append(elementID)
            }
        }
        var plan = mutationPlan(for: graph)
        plan.deletes = removedIDs
        plan.tombstones = removedIDs.union(suppressedIDs)
        plan.upserts[parentID] = parentRecord
        plan.upsertOrder.append(parentID)
        plan.parentAssignments[parentID] =
            parentByNodeID[parentID].map(ParentAssignment.parent) ?? ParentAssignment.none
        plan.incrementalVisits = graph.visitCount + 1
        plan.deletionVisits = previousSubtreeIDs.count
        plan.resourceInvalidations = [.target(scope)]
        return try commit(plan)
    }

    mutating func removePseudoElement(
        _ rawElementID: DOM.Node.ID,
        parent rawParentID: DOM.Node.ID,
        scope: WebInspectorDOMDocumentScopeStorage
    ) throws -> WebInspectorCanonicalDOMTransaction {
        let parentID = nodeID(rawParentID, in: scope)
        let elementID = nodeID(rawElementID, in: scope)
        guard var parentRecord = recordsByID[parentID],
            parentByNodeID[elementID] == parentID
        else {
            throw WebInspectorCanonicalDOMError.invalidParent(elementID)
        }
        if parentRecord.beforePseudoElementID == elementID {
            parentRecord.beforePseudoElementID = nil
        } else if parentRecord.afterPseudoElementID == elementID {
            parentRecord.afterPseudoElementID = nil
        } else if let index = parentRecord.otherPseudoElementIDs.firstIndex(of: elementID) {
            parentRecord.otherPseudoElementIDs.remove(at: index)
        } else {
            throw WebInspectorCanonicalDOMError.invalidRelationship(elementID)
        }
        let deletedIDs = try collectSubtrees([elementID])
        var plan = MutationPlan()
        plan.upserts[parentID] = parentRecord
        plan.upsertOrder = [parentID]
        plan.parentAssignments[parentID] =
            parentByNodeID[parentID].map(ParentAssignment.parent) ?? ParentAssignment.none
        plan.deletes = deletedIDs
        plan.tombstones = deletedIDs
        plan.incrementalVisits = 1
        plan.deletionVisits = deletedIDs.count
        plan.resourceInvalidations = [.target(scope)]
        return try commit(plan)
    }

    mutating func destroyDetachedNode(
        _ rawID: DOM.Node.ID,
        scope: WebInspectorDOMDocumentScopeStorage
    ) throws -> WebInspectorCanonicalDOMTransaction {
        let id = nodeID(rawID, in: scope)
        guard recordsByID[id] != nil else {
            throw WebInspectorCanonicalDOMError.missingNode(id)
        }
        guard parentByNodeID[id] == nil, rootByDocumentScope[scope] != id else {
            throw WebInspectorCanonicalDOMError.invalidParent(id)
        }
        let deletedIDs = try collectSubtrees([id])
        var plan = MutationPlan()
        plan.deletes = deletedIDs
        plan.tombstones = deletedIDs
        plan.incrementalVisits = 1
        plan.deletionVisits = deletedIDs.count
        plan.resourceInvalidations = [.target(scope)]
        return try commit(plan)
    }

    func documentScope(
        for eventScope: WebInspectorCanonicalDOMEventScope
    ) throws -> WebInspectorDOMDocumentScopeStorage {
        guard
            let scope = WebInspectorDOMDocumentScopeStorage(
                storeID: storeID,
                attachmentGeneration: attachmentGeneration,
                eventScope: eventScope
            )
        else {
            throw WebInspectorCanonicalDOMError.missingDOMBindingEpoch
        }
        return scope
    }

    func requireActiveScope(
        _ eventScope: WebInspectorCanonicalDOMEventScope
    ) throws -> WebInspectorDOMDocumentScopeStorage {
        let scope = try documentScope(for: eventScope)
        let targetRoute = scope.targetRoute
        guard let activeScope = activeScopeByTargetRoute[targetRoute] else {
            throw WebInspectorCanonicalDOMError.inactiveTarget(targetRoute)
        }
        guard activeScope == scope else {
            throw WebInspectorCanonicalDOMError.scopeMismatch(targetRoute)
        }
        guard activeSemanticTargetByTargetRoute[targetRoute] == eventScope.modelScope.target else {
            throw WebInspectorCanonicalDOMError.scopeMismatch(targetRoute)
        }
        return scope
    }

    func nodeID(
        _ rawID: DOM.Node.ID,
        in scope: WebInspectorDOMDocumentScopeStorage
    ) -> WebInspectorDOMNodeIdentityStorage {
        WebInspectorDOMNodeIdentityStorage(documentScope: scope, rawNodeID: rawID)
    }

    func build(
        _ node: DOM.Node,
        scope: WebInspectorDOMDocumentScopeStorage,
        parent: WebInspectorDOMNodeIdentityStorage?,
        into graph: inout BuiltGraph
    ) throws {
        let id = nodeID(node.id, in: scope)
        guard graph.recordsByID[id] == nil else {
            throw WebInspectorCanonicalDOMError.duplicateNode(id)
        }
        guard node.childNodeCount >= 0 else {
            throw WebInspectorCanonicalDOMError.invalidChildCount(id)
        }
        var attributeNames = Set<String>()
        for attribute in node.attributeList where !attributeNames.insert(attribute.name).inserted {
            throw WebInspectorCanonicalDOMError.invalidAttributes(id)
        }
        let orderedAttributes = Dictionary(uniqueKeysWithValues: node.attributeList.map { ($0.name, $0.value) })
        guard orderedAttributes == node.attributes else {
            throw WebInspectorCanonicalDOMError.invalidAttributes(id)
        }

        let children: WebInspectorCanonicalDOMChildren
        if let payloadChildren = node.children {
            guard payloadChildren.count == node.childNodeCount else {
                throw WebInspectorCanonicalDOMError.invalidChildCount(id)
            }
            children = .loaded(payloadChildren.map { nodeID($0.id, in: scope) })
        } else {
            children = .unrequested(count: node.childNodeCount)
        }

        let record = WebInspectorCanonicalDOMRecord(
            id: id,
            insertionOrdinal: try insertionOrdinal(for: id, in: &graph),
            nodeName: node.nodeName,
            localName: node.localName,
            nodeValue: node.nodeValue,
            nodeType: node.nodeType,
            frameID: node.frameID,
            documentURL: node.documentURL,
            baseURL: node.baseURL,
            attributes: node.attributeList,
            children: children,
            contentDocumentID: node.contentDocument.map { nodeID($0.id, in: scope) },
            shadowRootIDs: node.shadowRoots.map { nodeID($0.id, in: scope) },
            templateContentID: node.templateContent.map { nodeID($0.id, in: scope) },
            beforePseudoElementID: node.beforePseudoElement.map { nodeID($0.id, in: scope) },
            otherPseudoElementIDs: node.otherPseudoElements.map { nodeID($0.id, in: scope) },
            afterPseudoElementID: node.afterPseudoElement.map { nodeID($0.id, in: scope) },
            pseudoType: node.pseudoType,
            shadowRootType: node.shadowRootType
        )
        graph.recordsByID[id] = record
        graph.insertionOrder.append(id)
        graph.parentAssignments[id] = parent.map(ParentAssignment.parent) ?? ParentAssignment.none
        graph.visitCount += 1
        if let frameID = record.frameOwnerID {
            guard graph.frameOwners.updateValue(id, forKey: frameID) == nil else {
                throw WebInspectorCanonicalDOMError.ambiguousFrameOwner(frameID)
            }
        }

        if let payloadChildren = node.children {
            for child in payloadChildren {
                try build(child, scope: scope, parent: id, into: &graph)
            }
        }
        if let contentDocument = node.contentDocument {
            try build(contentDocument, scope: scope, parent: id, into: &graph)
        }
        for shadowRoot in node.shadowRoots {
            try build(shadowRoot, scope: scope, parent: id, into: &graph)
        }
        if let templateContent = node.templateContent {
            try build(templateContent, scope: scope, parent: id, into: &graph)
        }
        if let beforePseudoElement = node.beforePseudoElement {
            try build(beforePseudoElement, scope: scope, parent: id, into: &graph)
        }
        for otherPseudoElement in node.otherPseudoElements {
            try build(otherPseudoElement, scope: scope, parent: id, into: &graph)
        }
        if let afterPseudoElement = node.afterPseudoElement {
            try build(afterPseudoElement, scope: scope, parent: id, into: &graph)
        }
    }

    func prepareNewGraph(
        _ graph: inout BuiltGraph,
        replacing replacedIDs: Set<WebInspectorDOMNodeIdentityStorage>
    ) throws -> Set<WebInspectorDOMNodeIdentityStorage> {
        let suppressedIDs = try suppressEmbeddedDocumentsReplacedByFrameRoots(
            in: &graph,
            replacing: replacedIDs
        )
        try validateNewGraph(graph, replacing: replacedIDs)
        return suppressedIDs
    }

    func validateNewGraph(
        _ graph: BuiltGraph,
        replacing replacedIDs: Set<WebInspectorDOMNodeIdentityStorage>
    ) throws {
        for id in graph.recordsByID.keys {
            if recordsByID[id] != nil, !replacedIDs.contains(id) {
                throw WebInspectorCanonicalDOMError.duplicateNode(id)
            }
            if retiredRawNodeIDsByScope[id.documentScope]?.contains(id.rawNodeID) == true {
                throw WebInspectorCanonicalDOMError.reusedNode(id)
            }
        }
        for (frameID, ownerID) in graph.frameOwners {
            if let existingOwner = frameOwnerByFrameID[frameID],
                !replacedIDs.contains(existingOwner),
                existingOwner != ownerID
            {
                throw WebInspectorCanonicalDOMError.ambiguousFrameOwner(frameID)
            }
            try validateFrameLink(owner: ownerID, root: frameRootByFrameID[frameID])
            if let root = frameRootByFrameID[frameID],
                let contentDocumentID = graph.recordsByID[ownerID]?.contentDocumentID,
                contentDocumentID != root,
                contentDocumentID.documentScope != ownerID.documentScope
            {
                throw WebInspectorCanonicalDOMError.invalidRelationship(ownerID)
            }
        }
    }

    func suppressEmbeddedDocumentsReplacedByFrameRoots(
        in graph: inout BuiltGraph,
        replacing replacedIDs: Set<WebInspectorDOMNodeIdentityStorage>
    ) throws -> Set<WebInspectorDOMNodeIdentityStorage> {
        var suppressedIDs = Set<WebInspectorDOMNodeIdentityStorage>()
        let insertionIndexByID = Dictionary(
            uniqueKeysWithValues: graph.insertionOrder.enumerated().map { ($0.element, $0.offset) }
        )
        let frameOwners = graph.frameOwners.sorted {
            insertionIndexByID[$0.value, default: .max] < insertionIndexByID[$1.value, default: .max]
        }
        for (frameID, ownerID) in frameOwners {
            guard let frameRootID = frameRootByFrameID[frameID],
                var owner = graph.recordsByID[ownerID],
                let contentDocumentID = owner.contentDocumentID,
                contentDocumentID != frameRootID
            else {
                continue
            }
            guard contentDocumentID.documentScope == ownerID.documentScope else {
                throw WebInspectorCanonicalDOMError.invalidRelationship(ownerID)
            }
            let embeddedIDs = try collectSubtrees([contentDocumentID], in: graph)
            for id in embeddedIDs {
                if recordsByID[id] != nil, !replacedIDs.contains(id) {
                    throw WebInspectorCanonicalDOMError.duplicateNode(id)
                }
                if retiredRawNodeIDsByScope[id.documentScope]?.contains(id.rawNodeID) == true {
                    throw WebInspectorCanonicalDOMError.reusedNode(id)
                }
                if let embeddedFrameID = graph.recordsByID[id]?.frameOwnerID,
                    graph.frameOwners[embeddedFrameID] == id
                {
                    graph.frameOwners.removeValue(forKey: embeddedFrameID)
                }
                graph.recordsByID.removeValue(forKey: id)
                graph.parentAssignments.removeValue(forKey: id)
            }
            graph.insertionOrder.removeAll(where: embeddedIDs.contains)
            owner.contentDocumentID = frameRootID
            graph.recordsByID[ownerID] = owner
            suppressedIDs.formUnion(embeddedIDs)
        }
        return suppressedIDs
    }

    func validateFrameLink(
        owner: WebInspectorDOMNodeIdentityStorage?,
        root: WebInspectorDOMNodeIdentityStorage?
    ) throws {
        guard let owner, let root else {
            return
        }
        let ownerRecord = recordsByID[owner]
        if let contentDocumentID = ownerRecord?.contentDocumentID,
            contentDocumentID != root,
            contentDocumentID.documentScope != owner.documentScope
        {
            throw WebInspectorCanonicalDOMError.invalidRelationship(owner)
        }
        if let parentID = parentByNodeID[root], parentID != owner {
            throw WebInspectorCanonicalDOMError.invalidRelationship(root)
        }
    }

    func collectSubtrees(
        _ roots: [WebInspectorDOMNodeIdentityStorage]
    ) throws -> Set<WebInspectorDOMNodeIdentityStorage> {
        var result = Set<WebInspectorDOMNodeIdentityStorage>()
        var stack = roots
        while let id = stack.popLast() {
            guard result.insert(id).inserted else {
                throw WebInspectorCanonicalDOMError.invalidRelationship(id)
            }
            guard let record = recordsByID[id] else {
                throw WebInspectorCanonicalDOMError.missingNode(id)
            }
            stack.append(contentsOf: record.ownedRelationshipIDs)
        }
        return result
    }

    func collectSubtrees(
        _ roots: [WebInspectorDOMNodeIdentityStorage],
        in graph: BuiltGraph
    ) throws -> Set<WebInspectorDOMNodeIdentityStorage> {
        var result = Set<WebInspectorDOMNodeIdentityStorage>()
        var stack = roots
        while let id = stack.popLast() {
            guard result.insert(id).inserted else {
                throw WebInspectorCanonicalDOMError.invalidRelationship(id)
            }
            guard let record = graph.recordsByID[id] else {
                throw WebInspectorCanonicalDOMError.missingNode(id)
            }
            stack.append(contentsOf: record.ownedRelationshipIDs)
        }
        return result
    }

    func mutationPlan(for graph: BuiltGraph) -> MutationPlan {
        MutationPlan(
            upserts: graph.recordsByID,
            upsertOrder: graph.insertionOrder,
            parentAssignments: graph.parentAssignments,
            incrementalVisits: graph.visitCount
        )
    }

    func singleRecordPlan(_ record: WebInspectorCanonicalDOMRecord) -> MutationPlan {
        MutationPlan(
            upserts: [record.id: record],
            upsertOrder: [record.id],
            parentAssignments: [
                record.id: parentByNodeID[record.id].map(ParentAssignment.parent) ?? ParentAssignment.none
            ],
            incrementalVisits: 1
        )
    }

    mutating func commit(
        _ plan: MutationPlan
    ) throws -> WebInspectorCanonicalDOMTransaction {
        let touchedFrames = try validateFrameOwnerChanges(plan)
        let committedInsertionOrdinal = validatedInsertionOrdinal(
            upserts: plan.upserts,
            upsertOrder: plan.upsertOrder
        )
        var transaction = transaction(for: plan)

        lastInsertionOrdinal = committedInsertionOrdinal
        for id in plan.deletes {
            if let oldRecord = recordsByID[id], let frameID = oldRecord.frameOwnerID,
                frameOwnerByFrameID[frameID] == id
            {
                frameOwnerByFrameID.removeValue(forKey: frameID)
            }
            recordsByID.removeValue(forKey: id)
            parentByNodeID.removeValue(forKey: id)
            nodeIDsByDocumentScope[id.documentScope]?.remove(id)
        }
        for id in plan.tombstones {
            retiredRawNodeIDsByScope[id.documentScope, default: []].insert(id.rawNodeID)
        }
        for id in plan.upsertOrder {
            guard let record = plan.upserts[id] else {
                continue
            }
            if let oldRecord = recordsByID[id],
                let oldFrameID = oldRecord.frameOwnerID,
                oldFrameID != record.frameOwnerID,
                frameOwnerByFrameID[oldFrameID] == id
            {
                frameOwnerByFrameID.removeValue(forKey: oldFrameID)
            }
            recordsByID[id] = record
            nodeIDsByDocumentScope[id.documentScope, default: []].insert(id)
            if let assignment = plan.parentAssignments[id] {
                apply(assignment, to: id)
            }
            if let frameID = record.frameOwnerID {
                frameOwnerByFrameID[frameID] = id
            }
        }
        for frameID in touchedFrames.sorted(by: { $0.rawValue < $1.rawValue }) {
            reconcileFrame(frameID, transaction: &transaction)
        }
        performanceCounters.incrementalNodeVisitCount += plan.incrementalVisits
        performanceCounters.subtreeDeletionNodeVisitCount += plan.deletionVisits
        performanceCounters.recordMutationCount +=
            plan.deletes.count
            + transaction.insertedRecords.count
            + transaction.recordPatches.count
        return transaction
    }

    func validateFrameOwnerChanges(
        _ plan: MutationPlan
    ) throws -> Set<FrameID> {
        var touchedFrames = Set<FrameID>()
        for id in plan.deletes {
            if let frameID = recordsByID[id]?.frameOwnerID {
                touchedFrames.insert(frameID)
            }
        }
        for (id, record) in plan.upserts {
            if let frameID = recordsByID[id]?.frameOwnerID {
                touchedFrames.insert(frameID)
            }
            if let frameID = record.frameOwnerID {
                touchedFrames.insert(frameID)
            }
        }

        for frameID in touchedFrames.sorted(by: { $0.rawValue < $1.rawValue }) {
            var finalOwner = frameOwnerByFrameID[frameID]
            if let owner = finalOwner,
                plan.deletes.contains(owner)
                    || plan.upserts[owner]?.frameOwnerID != frameID && plan.upserts[owner] != nil
            {
                finalOwner = nil
            }
            for record in plan.upserts.values where record.frameOwnerID == frameID {
                if let finalOwner, finalOwner != record.id {
                    throw WebInspectorCanonicalDOMError.ambiguousFrameOwner(frameID)
                }
                finalOwner = record.id
            }
            let ownerRecord = finalOwner.flatMap { plan.upserts[$0] ?? recordsByID[$0] }
            if let root = frameRootByFrameID[frameID],
                let contentDocumentID = ownerRecord?.contentDocumentID,
                contentDocumentID != root
            {
                throw WebInspectorCanonicalDOMError.invalidRelationship(ownerRecord!.id)
            }
        }
        return touchedFrames
    }

    func transaction(
        for plan: MutationPlan
    ) -> WebInspectorCanonicalDOMTransaction {
        var transaction = WebInspectorCanonicalDOMTransaction()
        transaction.deletedRecordIDs = plan.deletes
        transaction.queryValueDeletes = plan.deletes
        transaction.resourceInvalidations = plan.resourceInvalidations
        for id in plan.upsertOrder {
            guard let newRecord = plan.upserts[id] else {
                continue
            }
            if let oldRecord = recordsByID[id] {
                precondition(
                    oldRecord.insertionOrdinal == newRecord.insertionOrdinal,
                    "A canonical DOM patch cannot change insertion order."
                )
                let fields = Self.patchFields(from: oldRecord, to: newRecord)
                if !fields.isEmpty {
                    transaction.recordPatches.append(
                        WebInspectorCanonicalDOMRecordPatch(id: id, fields: fields)
                    )
                }
                if oldRecord.queryValue != newRecord.queryValue {
                    transaction.queryValueUpserts[id] = newRecord.queryValue
                }
            } else {
                transaction.insertedRecords.append(newRecord)
                transaction.queryValueUpserts[id] = newRecord.queryValue
            }
            if let assignment = plan.parentAssignments[id] {
                let newParentID = Self.parentID(from: assignment)
                if recordsByID[id] == nil || parentByNodeID[id] != newParentID {
                    transaction.parentChanges.append(
                        WebInspectorCanonicalDOMParentChange(
                            nodeID: id,
                            parentID: newParentID
                        )
                    )
                }
            }
        }
        return transaction
    }

    func insertionOrdinal(
        for id: WebInspectorDOMNodeIdentityStorage,
        in graph: inout BuiltGraph
    ) throws -> UInt64 {
        if let existing = recordsByID[id] {
            return existing.insertionOrdinal
        }
        let previous = graph.lastAllocatedInsertionOrdinal ?? lastInsertionOrdinal
        let (ordinal, overflow) = previous.addingReportingOverflow(1)
        guard !overflow else {
            throw WebInspectorCanonicalDOMError.insertionOrdinalExhausted
        }
        graph.lastAllocatedInsertionOrdinal = ordinal
        return ordinal
    }

    func validatedInsertionOrdinal(
        upserts: [WebInspectorDOMNodeIdentityStorage: WebInspectorCanonicalDOMRecord],
        upsertOrder: [WebInspectorDOMNodeIdentityStorage]
    ) -> UInt64 {
        var committedOrdinal = lastInsertionOrdinal
        var visitedNewIDs = Set<WebInspectorDOMNodeIdentityStorage>()
        for id in upsertOrder {
            guard let record = upserts[id] else {
                continue
            }
            if let existing = recordsByID[id] {
                precondition(
                    existing.insertionOrdinal == record.insertionOrdinal,
                    "A canonical DOM update cannot replace its insertion ordinal."
                )
                continue
            }
            precondition(
                visitedNewIDs.insert(id).inserted,
                "A canonical DOM mutation cannot insert one identity twice."
            )
            precondition(
                record.insertionOrdinal > committedOrdinal,
                "Canonical DOM insertion ordinals must advance in protocol order."
            )
            committedOrdinal = record.insertionOrdinal
        }
        precondition(
            upserts.allSatisfy { id, _ in
                recordsByID[id] != nil || visitedNewIDs.contains(id)
            },
            "Every canonical DOM insertion must appear in mutation order."
        )
        return committedOrdinal
    }

    static func patchFields(
        from old: WebInspectorCanonicalDOMRecord,
        to new: WebInspectorCanonicalDOMRecord
    ) -> [WebInspectorCanonicalDOMRecordPatch.Field] {
        var fields: [WebInspectorCanonicalDOMRecordPatch.Field] = []
        if old.nodeName != new.nodeName { fields.append(.nodeName(new.nodeName)) }
        if old.localName != new.localName { fields.append(.localName(new.localName)) }
        if old.nodeValue != new.nodeValue { fields.append(.nodeValue(new.nodeValue)) }
        if old.nodeType != new.nodeType { fields.append(.nodeType(new.nodeType)) }
        if old.frameID != new.frameID { fields.append(.frameID(new.frameID)) }
        if old.documentURL != new.documentURL { fields.append(.documentURL(new.documentURL)) }
        if old.baseURL != new.baseURL { fields.append(.baseURL(new.baseURL)) }
        if old.attributes != new.attributes { fields.append(.attributes(new.attributes)) }
        if old.children != new.children { fields.append(.children(new.children)) }
        if old.contentDocumentID != new.contentDocumentID { fields.append(.contentDocument(new.contentDocumentID)) }
        if old.shadowRootIDs != new.shadowRootIDs { fields.append(.shadowRoots(new.shadowRootIDs)) }
        if old.templateContentID != new.templateContentID { fields.append(.templateContent(new.templateContentID)) }
        if old.beforePseudoElementID != new.beforePseudoElementID {
            fields.append(.beforePseudoElement(new.beforePseudoElementID))
        }
        if old.otherPseudoElementIDs != new.otherPseudoElementIDs {
            fields.append(.otherPseudoElements(new.otherPseudoElementIDs))
        }
        if old.afterPseudoElementID != new.afterPseudoElementID {
            fields.append(.afterPseudoElement(new.afterPseudoElementID))
        }
        if old.pseudoType != new.pseudoType { fields.append(.pseudoType(new.pseudoType)) }
        if old.shadowRootType != new.shadowRootType { fields.append(.shadowRootType(new.shadowRootType)) }
        return fields
    }

    static func parentID(
        from assignment: ParentAssignment?
    ) -> WebInspectorDOMNodeIdentityStorage? {
        guard let assignment else {
            return nil
        }
        switch assignment {
        case let .parent(parentID):
            return parentID
        case .none:
            return nil
        }
    }

    mutating func apply(
        _ assignment: ParentAssignment,
        to id: WebInspectorDOMNodeIdentityStorage
    ) {
        switch assignment {
        case let .parent(parentID):
            parentByNodeID[id] = parentID
        case .none:
            parentByNodeID.removeValue(forKey: id)
        }
    }

    mutating func reconcileFrame(
        _ frameID: FrameID,
        transaction: inout WebInspectorCanonicalDOMTransaction
    ) {
        let ownerID = frameOwnerByFrameID[frameID]
        let rootID = frameRootByFrameID[frameID]
        if let ownerID, let rootID {
            if var owner = recordsByID[ownerID], owner.contentDocumentID != rootID {
                let old = owner
                owner.contentDocumentID = rootID
                recordsByID[ownerID] = owner
                transaction.recordPatches.append(
                    WebInspectorCanonicalDOMRecordPatch(
                        id: ownerID,
                        fields: Self.patchFields(from: old, to: owner)
                    )
                )
            }
            if parentByNodeID[rootID] != ownerID {
                parentByNodeID[rootID] = ownerID
                transaction.parentChanges.append(
                    WebInspectorCanonicalDOMParentChange(
                        nodeID: rootID,
                        parentID: ownerID
                    )
                )
            }
        } else if let ownerID,
            var owner = recordsByID[ownerID],
            let contentDocumentID = owner.contentDocumentID,
            contentDocumentID.documentScope != ownerID.documentScope
        {
            let old = owner
            owner.contentDocumentID = nil
            recordsByID[ownerID] = owner
            transaction.recordPatches.append(
                WebInspectorCanonicalDOMRecordPatch(
                    id: ownerID,
                    fields: Self.patchFields(from: old, to: owner)
                )
            )
        } else if let rootID,
            let parentID = parentByNodeID[rootID],
            parentID.documentScope != rootID.documentScope
        {
            parentByNodeID.removeValue(forKey: rootID)
            transaction.parentChanges.append(
                WebInspectorCanonicalDOMParentChange(
                    nodeID: rootID,
                    parentID: nil
                )
            )
        }
    }

    mutating func removeDocumentScope(
        _ scope: WebInspectorDOMDocumentScopeStorage
    ) -> WebInspectorCanonicalDOMTransaction {
        let ids = nodeIDsByDocumentScope.removeValue(forKey: scope) ?? []
        var touchedFrames = Set<FrameID>()
        for id in ids {
            if let frameID = recordsByID[id]?.frameOwnerID,
                frameOwnerByFrameID[frameID] == id
            {
                frameOwnerByFrameID.removeValue(forKey: frameID)
                touchedFrames.insert(frameID)
            }
            recordsByID.removeValue(forKey: id)
            parentByNodeID.removeValue(forKey: id)
        }
        if let rootID = rootByDocumentScope.removeValue(forKey: scope) {
            if let frameID = frameIDByFrameRootID.removeValue(forKey: rootID) {
                frameRootByFrameID.removeValue(forKey: frameID)
                touchedFrames.insert(frameID)
            }
        }
        var transaction = WebInspectorCanonicalDOMTransaction()
        transaction.deletedRecordIDs = ids
        transaction.queryValueDeletes = ids
        transaction.rootChanges = [WebInspectorCanonicalDOMRootChange(scope: scope, rootID: nil)]
        for frameID in touchedFrames.sorted(by: { $0.rawValue < $1.rawValue }) {
            reconcileFrame(frameID, transaction: &transaction)
        }
        performanceCounters.subtreeDeletionNodeVisitCount += ids.count
        performanceCounters.recordMutationCount += ids.count
        return transaction
    }

}
