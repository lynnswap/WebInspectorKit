#if canImport(UIKit)
import WebInspectorDataKit

struct DOMTreeRenderMetadata: Equatable, Sendable {
    let revision: UInt64
    let rootNodeID: DOMNode.ID?

    static let empty = DOMTreeRenderMetadata(revision: 0, rootNodeID: nil)
}

struct DOMTreeRenderProjection: Sendable {
    let metadata: DOMTreeRenderMetadata
    let invalidation: DOMTreeRenderInvalidation
}

enum DOMTreeRenderProjectionError: Error, Sendable {
    case ambiguousDocumentRoots
    case duplicateNodeID
    case missingDocumentRoot
    case missingUpdatedQueryValue
    case revisionMismatch(expected: UInt64, actual: UInt64)
}

actor DOMTreeRenderProjector {
    struct Node: Equatable, Sendable {
        enum Children: Equatable, Sendable {
            case unrequested(count: Int)
            case loaded([DOMNode.ID])
        }

        let id: DOMNode.ID
        let primaryDocumentRootID: DOMNode.ID?
        let documentRootID: DOMNode.ID?
        let parentID: DOMNode.ID?
        let nodeName: String
        let localName: String
        let nodeValue: String
        let nodeType: Int
        let frameID: WebInspectorFrameID?
        let documentURL: String?
        let baseURL: String?
        let attributes: [String: String]
        let attributeList: [DOMNode.Attribute]
        let children: Children
        let contentDocumentID: DOMNode.ID?
        let shadowRootIDs: [DOMNode.ID]
        let templateContentID: DOMNode.ID?
        let beforePseudoElementID: DOMNode.ID?
        let otherPseudoElementIDs: [DOMNode.ID]
        let afterPseudoElementID: DOMNode.ID?
        let pseudoType: DOMPseudoElementKind?
        let shadowRootType: DOMShadowRootKind?

        var kind: DOMNode.Kind {
            DOMNode.Kind(rawValue: nodeType)
        }

        var childNodeCount: Int {
            switch children {
            case let .unrequested(count):
                count
            case let .loaded(ids):
                ids.count
            }
        }

        var hasUnloadedRegularChildren: Bool {
            if case let .unrequested(count) = children {
                return count > 0
            }
            return false
        }

        var displayName: String {
            if localName.isEmpty == false {
                return localName
            }
            if nodeName.isEmpty == false {
                return nodeName
            }
            return nodeValue.isEmpty ? nodeName : nodeValue
        }

        var topology: Topology {
            Topology(
                parentID: parentID,
                children: children,
                contentDocumentID: contentDocumentID,
                shadowRootIDs: shadowRootIDs,
                templateContentID: templateContentID,
                beforePseudoElementID: beforePseudoElementID,
                otherPseudoElementIDs: otherPseudoElementIDs,
                afterPseudoElementID: afterPseudoElementID
            )
        }

        struct Topology: Equatable, Sendable {
            let parentID: DOMNode.ID?
            let children: Children
            let contentDocumentID: DOMNode.ID?
            let shadowRootIDs: [DOMNode.ID]
            let templateContentID: DOMNode.ID?
            let beforePseudoElementID: DOMNode.ID?
            let otherPseudoElementIDs: [DOMNode.ID]
            let afterPseudoElementID: DOMNode.ID?
        }
    }

    struct VisibleChildren {
        let nodeIDs: [DOMNode.ID]
        let hasRenderableChildren: Bool
    }

    private(set) var revision: UInt64 = 0
    private(set) var rootNodeID: DOMNode.ID?
    var nodesByID: [DOMNode.ID: Node] = [:]
    var parentByNodeID: [DOMNode.ID: DOMNode.ID] = [:]
    var markupCache: [DOMTreeTextView.MarkupCacheKey: DOMTreeTextView.CachedMarkup] = [:]

    func replace(
        revision: UInt64,
        queryValues: [DOMNode.QueryValue]
    ) throws -> DOMTreeRenderProjection {
        var nextNodesByID: [DOMNode.ID: Node] = [:]
        nextNodesByID.reserveCapacity(queryValues.count)
        var nextParentByNodeID: [DOMNode.ID: DOMNode.ID] = [:]
        nextParentByNodeID.reserveCapacity(queryValues.count)

        for value in queryValues {
            let node = Self.makeNode(value)
            guard nextNodesByID.updateValue(node, forKey: value.id) == nil else {
                throw DOMTreeRenderProjectionError.duplicateNodeID
            }
            if let parentID = node.parentID {
                nextParentByNodeID[node.id] = parentID
            }
        }

        let nextRootNodeID = try Self.resolveRootNodeID(in: nextNodesByID)
        let previousMetadata = metadata
        let nextMetadata = DOMTreeRenderMetadata(
            revision: revision,
            rootNodeID: nextRootNodeID
        )
        let invalidation = Self.makeReplacementInvalidation(
            previousRevision: self.revision,
            previousRootNodeID: rootNodeID,
            previousNodesByID: nodesByID,
            nextMetadata: nextMetadata,
            nextNodesByID: nextNodesByID
        )

        self.revision = revision
        rootNodeID = nextRootNodeID
        nodesByID = nextNodesByID
        parentByNodeID = nextParentByNodeID
        if previousMetadata.rootNodeID != nextRootNodeID {
            markupCache.removeAll(keepingCapacity: true)
        }
        return DOMTreeRenderProjection(
            metadata: nextMetadata,
            invalidation: invalidation
        )
    }

    func apply(
        fromRevision: UInt64,
        toRevision: UInt64,
        deletedNodeIDs: Set<DOMNode.ID>,
        upsertedQueryValues: [DOMNode.QueryValue]
    ) throws -> DOMTreeRenderProjection {
        guard revision == fromRevision else {
            throw DOMTreeRenderProjectionError.revisionMismatch(
                expected: revision,
                actual: fromRevision
            )
        }

        var upsertedNodes: [Node] = []
        upsertedNodes.reserveCapacity(upsertedQueryValues.count)
        var upsertedNodeIDs: Set<DOMNode.ID> = []
        upsertedNodeIDs.reserveCapacity(upsertedQueryValues.count)
        for value in upsertedQueryValues {
            guard upsertedNodeIDs.insert(value.id).inserted else {
                throw DOMTreeRenderProjectionError.duplicateNodeID
            }
            upsertedNodes.append(Self.makeNode(value))
        }

        let removedExistingNodeCount = deletedNodeIDs.reduce(into: 0) { count, id in
            if nodesByID[id] != nil, !upsertedNodeIDs.contains(id) {
                count += 1
            }
        }
        let insertedNodeCount = upsertedNodes.reduce(into: 0) { count, node in
            if nodesByID[node.id] == nil {
                count += 1
            }
        }
        let nextNodeCount = nodesByID.count - removedExistingNodeCount + insertedNodeCount
        let nextRootNodeID = try validatedRootNodeID(
            nextNodeCount: nextNodeCount,
            deletedNodeIDs: deletedNodeIDs,
            upsertedNodes: upsertedNodes,
            upsertedNodeIDs: upsertedNodeIDs
        )

        var affectedNodeIDs: Set<DOMNode.ID> = []
        var parentNodeIDs: Set<DOMNode.ID> = []
        var hasStructuralChanges = false

        for id in deletedNodeIDs {
            guard let removedNode = nodesByID.removeValue(forKey: id) else {
                continue
            }
            parentByNodeID.removeValue(forKey: id)
            markupCache.removeValue(forKey: .init(nodeID: id, isClosingTag: false))
            markupCache.removeValue(forKey: .init(nodeID: id, isClosingTag: true))
            affectedNodeIDs.insert(id)
            if let parentID = removedNode.parentID {
                parentNodeIDs.insert(parentID)
            }
            hasStructuralChanges = true
        }

        for nextNode in upsertedNodes {
            let previousNode = nodesByID.updateValue(nextNode, forKey: nextNode.id)
            if let parentID = nextNode.parentID {
                parentByNodeID[nextNode.id] = parentID
            } else {
                parentByNodeID.removeValue(forKey: nextNode.id)
            }

            guard previousNode != nextNode else {
                continue
            }
            affectedNodeIDs.insert(nextNode.id)
            if let previousNode {
                if previousNode.topology != nextNode.topology {
                    hasStructuralChanges = true
                    if let parentID = previousNode.parentID {
                        parentNodeIDs.insert(parentID)
                    }
                    if let parentID = nextNode.parentID {
                        parentNodeIDs.insert(parentID)
                    }
                }
            } else {
                hasStructuralChanges = true
                if let parentID = nextNode.parentID {
                    parentNodeIDs.insert(parentID)
                }
            }
        }

        let previousRootNodeID = rootNodeID
        let rootChanged = previousRootNodeID != nextRootNodeID
        if rootChanged {
            markupCache.removeAll(keepingCapacity: true)
        }

        revision = toRevision
        rootNodeID = nextRootNodeID
        let nextMetadata = metadata
        return DOMTreeRenderProjection(
            metadata: nextMetadata,
            invalidation: DOMTreeRenderInvalidation(
                kind: rootChanged ? .root : hasStructuralChanges ? .structure : .content,
                revision: toRevision,
                startRevision: fromRevision,
                affectedNodeIDs: affectedNodeIDs,
                parentNodeIDs: parentNodeIDs,
                resetsLocalDocumentState: previousRootNodeID != nil && rootChanged
            )
        )
    }

    private func validatedRootNodeID(
        nextNodeCount: Int,
        deletedNodeIDs: Set<DOMNode.ID>,
        upsertedNodes: [Node],
        upsertedNodeIDs: Set<DOMNode.ID>
    ) throws -> DOMNode.ID? {
        guard nextNodeCount > 0 else {
            return nil
        }

        let candidateRootNodeID: DOMNode.ID
        if let rootNodeID,
           !deletedNodeIDs.contains(rootNodeID) || upsertedNodeIDs.contains(rootNodeID) {
            candidateRootNodeID = rootNodeID
        } else if rootNodeID != nil {
            // A primary document replacement is delivered as a reset. Applying it
            // as a delta would leave unchanged nodes bound to the previous root.
            throw DOMTreeRenderProjectionError.missingDocumentRoot
        } else {
            let projectedRootNodeIDs = Set(
                upsertedNodes.compactMap(\.primaryDocumentRootID)
            )
            guard projectedRootNodeIDs.count == 1,
                  let projectedRootNodeID = projectedRootNodeIDs.first else {
                throw DOMTreeRenderProjectionError.ambiguousDocumentRoots
            }
            candidateRootNodeID = projectedRootNodeID
        }

        let rootRemains = (
            nodesByID[candidateRootNodeID] != nil
                && !deletedNodeIDs.contains(candidateRootNodeID)
        ) || upsertedNodeIDs.contains(candidateRootNodeID)
        guard rootRemains else {
            throw DOMTreeRenderProjectionError.missingDocumentRoot
        }
        for node in upsertedNodes {
            if let projectedRootNodeID = node.primaryDocumentRootID,
               projectedRootNodeID != candidateRootNodeID {
                throw DOMTreeRenderProjectionError.ambiguousDocumentRoots
            }
        }
        return candidateRootNodeID
    }

    var metadata: DOMTreeRenderMetadata {
        DOMTreeRenderMetadata(revision: revision, rootNodeID: rootNodeID)
    }

    private static func resolveRootNodeID(
        in nodesByID: [DOMNode.ID: Node]
    ) throws -> DOMNode.ID? {
        guard nodesByID.isEmpty == false else {
            return nil
        }
        let rootIDs = Set(nodesByID.values.compactMap(\.primaryDocumentRootID))
        guard rootIDs.count == 1,
              let rootNodeID = rootIDs.first else {
            throw DOMTreeRenderProjectionError.ambiguousDocumentRoots
        }
        guard nodesByID[rootNodeID] != nil else {
            throw DOMTreeRenderProjectionError.missingDocumentRoot
        }
        return rootNodeID
    }

    private static func makeNode(_ value: DOMNode.QueryValue) -> Node {
        Node(
            id: value.id,
            primaryDocumentRootID: value.primaryDocumentRootID,
            documentRootID: value.documentRootID,
            parentID: value.parentID,
            nodeName: value.nodeName,
            localName: value.localName,
            nodeValue: value.nodeValue,
            nodeType: value.nodeType,
            frameID: value.frameID,
            documentURL: value.documentURL,
            baseURL: value.baseURL,
            attributes: value.attributes,
            attributeList: value.attributeList,
            children: makeChildren(value.children),
            contentDocumentID: value.contentDocumentID,
            shadowRootIDs: value.shadowRootIDs,
            templateContentID: value.templateContentID,
            beforePseudoElementID: value.beforePseudoElementID,
            otherPseudoElementIDs: value.otherPseudoElementIDs,
            afterPseudoElementID: value.afterPseudoElementID,
            pseudoType: value.pseudoType,
            shadowRootType: value.shadowRootType
        )
    }

    private static func makeChildren(
        _ children: DOMNode.QueryValue.Children
    ) -> Node.Children {
        switch children {
        case let .unrequested(count):
            .unrequested(count: count)
        case let .loaded(ids):
            .loaded(ids)
        }
    }

    private static func makeReplacementInvalidation(
        previousRevision: UInt64,
        previousRootNodeID: DOMNode.ID?,
        previousNodesByID: [DOMNode.ID: Node],
        nextMetadata: DOMTreeRenderMetadata,
        nextNodesByID: [DOMNode.ID: Node]
    ) -> DOMTreeRenderInvalidation {
        let previousIDs = Set(previousNodesByID.keys)
        let nextIDs = Set(nextNodesByID.keys)
        var affectedNodeIDs = previousIDs.symmetricDifference(nextIDs)
        var parentNodeIDs: Set<DOMNode.ID> = []
        var hasStructuralChanges = previousIDs != nextIDs

        for id in previousIDs.intersection(nextIDs) {
            guard let oldNode = previousNodesByID[id],
                  let newNode = nextNodesByID[id],
                  oldNode != newNode else {
                continue
            }
            affectedNodeIDs.insert(id)
            if oldNode.topology != newNode.topology {
                hasStructuralChanges = true
            }
        }

        for id in affectedNodeIDs {
            if let parentID = previousNodesByID[id]?.parentID {
                parentNodeIDs.insert(parentID)
            }
            if let parentID = nextNodesByID[id]?.parentID {
                parentNodeIDs.insert(parentID)
            }
        }

        let rootChanged = previousRootNodeID != nextMetadata.rootNodeID
        return DOMTreeRenderInvalidation(
            kind: rootChanged ? .root : hasStructuralChanges ? .structure : .content,
            revision: nextMetadata.revision,
            startRevision: previousRevision,
            affectedNodeIDs: affectedNodeIDs,
            parentNodeIDs: parentNodeIDs,
            resetsLocalDocumentState: previousRootNodeID != nil && rootChanged
        )
    }
}

#endif
