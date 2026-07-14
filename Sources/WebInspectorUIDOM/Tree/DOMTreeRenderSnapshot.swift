#if canImport(UIKit)
import WebInspectorDataKit

struct DOMTreeRenderSnapshot: Sendable {
    struct Node: Equatable, Sendable {
        enum Children: Equatable, Sendable {
            case unrequested(count: Int)
            case loaded([DOMNode.ID])
        }

        let id: DOMNode.ID
        let primaryDocumentRootID: DOMNode.ID?
        let documentRootID: DOMNode.ID
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

        var displayName: String {
            if localName.isEmpty == false {
                return localName
            }
            if nodeName.isEmpty == false {
                return nodeName
            }
            return nodeValue.isEmpty ? nodeName : nodeValue
        }

        fileprivate var topology: Topology {
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

        fileprivate struct Topology: Equatable {
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

    struct VisibleChildren: Sendable {
        let nodeIDs: [DOMNode.ID]
        let hasUnloadedChildren: Bool
        let hasRenderableChildren: Bool
    }

    let revision: UInt64
    let rootNodeID: DOMNode.ID?
    let selectedNodeID: DOMNode.ID?
    let nodesByID: [DOMNode.ID: Node]
    let parentByNodeID: [DOMNode.ID: DOMNode.ID]

    init(
        revision: UInt64,
        rootNodeID: DOMNode.ID?,
        selectedNodeID: DOMNode.ID?,
        nodesByID: [DOMNode.ID: Node]
    ) {
        self.revision = revision
        self.rootNodeID = rootNodeID.flatMap { nodesByID[$0] == nil ? nil : $0 }
        self.selectedNodeID = selectedNodeID.flatMap {
            nodesByID[$0] == nil ? nil : $0
        }
        self.nodesByID = nodesByID
        self.parentByNodeID = nodesByID.reduce(into: [:]) { result, element in
            if let parentID = element.value.parentID {
                result[element.key] = parentID
            }
        }
    }

    func node(for id: DOMNode.ID) -> Node? {
        nodesByID[id]
    }

    func visibleChildren(of id: DOMNode.ID) -> VisibleChildren {
        guard let node = nodesByID[id] else {
            return VisibleChildren(
                nodeIDs: [],
                hasUnloadedChildren: false,
                hasRenderableChildren: false
            )
        }

        var nodeIDs: [DOMNode.ID] = []
        if let templateContentID = node.templateContentID {
            nodeIDs.append(templateContentID)
        }
        if let beforePseudoElementID = node.beforePseudoElementID {
            nodeIDs.append(beforePseudoElementID)
        }
        nodeIDs.append(contentsOf: node.otherPseudoElementIDs)
        if let contentDocumentID = node.contentDocumentID {
            nodeIDs.append(contentDocumentID)
        } else {
            nodeIDs.append(contentsOf: node.shadowRootIDs)
            if case let .loaded(childIDs) = node.children {
                nodeIDs.append(contentsOf: childIDs)
            }
        }
        if let afterPseudoElementID = node.afterPseudoElementID {
            nodeIDs.append(afterPseudoElementID)
        }

        let hasUnloadedChildren: Bool
        switch node.children {
        case let .unrequested(count):
            hasUnloadedChildren = count > 0
        case .loaded:
            hasUnloadedChildren = false
        }
        return VisibleChildren(
            nodeIDs: nodeIDs,
            hasUnloadedChildren: hasUnloadedChildren,
            hasRenderableChildren: nodeIDs.isEmpty == false || node.childNodeCount > 0
        )
    }

    func displayRootIDs() -> [DOMNode.ID] {
        guard let rootNodeID,
              let root = nodesByID[rootNodeID] else {
            return []
        }
        return root.kind == .document
            ? visibleChildren(of: rootNodeID).nodeIDs
            : [rootNodeID]
    }

    func isTemplateContent(_ id: DOMNode.ID) -> Bool {
        guard let parentID = parentByNodeID[id],
              let parent = nodesByID[parentID] else {
            return false
        }
        return parent.templateContentID == id
    }

    func parent(of id: DOMNode.ID) -> DOMNode.ID? {
        parentByNodeID[id]
    }

    func ancestorNodeIDs(of id: DOMNode.ID) -> [DOMNode.ID] {
        var result: [DOMNode.ID] = []
        var visited: Set<DOMNode.ID> = []
        var current = parentByNodeID[id]
        while let id = current,
              visited.insert(id).inserted {
            result.append(id)
            current = parentByNodeID[id]
        }
        return result
    }
}

struct DOMTreeRenderProjection: Sendable {
    let snapshot: DOMTreeRenderSnapshot
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
    private var acceptedSnapshot = DOMTreeRenderSnapshot(
        revision: 0,
        rootNodeID: nil,
        selectedNodeID: nil,
        nodesByID: [:]
    )

    func replace(
        revision: UInt64,
        queryValues: [DOMNode.QueryValue],
        selectedNodeID: DOMNode.ID?
    ) throws -> DOMTreeRenderProjection {
        let nextSnapshot = try Self.makeSnapshot(
            revision: revision,
            queryValues: queryValues,
            selectedNodeID: selectedNodeID
        )
        let previousSnapshot = acceptedSnapshot
        let invalidation = Self.makeInvalidation(
            from: previousSnapshot,
            to: nextSnapshot
        )
        acceptedSnapshot = nextSnapshot
        return DOMTreeRenderProjection(
            snapshot: nextSnapshot,
            invalidation: invalidation
        )
    }

    func apply(
        fromRevision: UInt64,
        toRevision: UInt64,
        deletedNodeIDs: Set<DOMNode.ID>,
        upsertedQueryValues: [DOMNode.QueryValue],
        selectedNodeID: DOMNode.ID?
    ) throws -> DOMTreeRenderProjection {
        guard acceptedSnapshot.revision == fromRevision else {
            throw DOMTreeRenderProjectionError.revisionMismatch(
                expected: acceptedSnapshot.revision,
                actual: fromRevision
            )
        }

        var nodesByID = acceptedSnapshot.nodesByID
        for id in deletedNodeIDs {
            nodesByID.removeValue(forKey: id)
        }
        for value in upsertedQueryValues {
            nodesByID[value.id] = Self.makeNode(value)
        }
        let nextSnapshot = try Self.makeSnapshot(
            revision: toRevision,
            nodesByID: nodesByID,
            selectedNodeID: selectedNodeID
        )
        let invalidation = Self.makeInvalidation(
            from: acceptedSnapshot,
            to: nextSnapshot
        )
        acceptedSnapshot = nextSnapshot
        return DOMTreeRenderProjection(
            snapshot: nextSnapshot,
            invalidation: invalidation
        )
    }

    private static func makeSnapshot(
        revision: UInt64,
        queryValues: [DOMNode.QueryValue],
        selectedNodeID: DOMNode.ID?
    ) throws -> DOMTreeRenderSnapshot {
        guard queryValues.isEmpty == false else {
            return DOMTreeRenderSnapshot(
                revision: revision,
                rootNodeID: nil,
                selectedNodeID: nil,
                nodesByID: [:]
            )
        }

        var nodesByID: [DOMNode.ID: DOMTreeRenderSnapshot.Node] = [:]
        nodesByID.reserveCapacity(queryValues.count)
        for value in queryValues {
            guard nodesByID.updateValue(makeNode(value), forKey: value.id) == nil else {
                throw DOMTreeRenderProjectionError.duplicateNodeID
            }
        }
        return try makeSnapshot(
            revision: revision,
            nodesByID: nodesByID,
            selectedNodeID: selectedNodeID,
        )
    }

    private static func makeSnapshot(
        revision: UInt64,
        nodesByID: [DOMNode.ID: DOMTreeRenderSnapshot.Node],
        selectedNodeID: DOMNode.ID?
    ) throws -> DOMTreeRenderSnapshot {
        guard nodesByID.isEmpty == false else {
            return DOMTreeRenderSnapshot(
                revision: revision,
                rootNodeID: nil,
                selectedNodeID: nil,
                nodesByID: [:]
            )
        }
        let rootIDs = Set(nodesByID.values.compactMap(\.primaryDocumentRootID))
        guard rootIDs.count == 1,
              let rootNodeID = rootIDs.first else {
            throw DOMTreeRenderProjectionError.ambiguousDocumentRoots
        }
        guard nodesByID[rootNodeID] != nil else {
            throw DOMTreeRenderProjectionError.missingDocumentRoot
        }
        return DOMTreeRenderSnapshot(
            revision: revision,
            rootNodeID: rootNodeID,
            selectedNodeID: selectedNodeID,
            nodesByID: nodesByID
        )
    }

    private static func makeNode(
        _ value: DOMNode.QueryValue
    ) -> DOMTreeRenderSnapshot.Node {
        DOMTreeRenderSnapshot.Node(
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
    ) -> DOMTreeRenderSnapshot.Node.Children {
        switch children {
        case let .unrequested(count):
            .unrequested(count: count)
        case let .loaded(ids):
            .loaded(ids)
        }
    }

    private static func makeInvalidation(
        from previous: DOMTreeRenderSnapshot,
        to next: DOMTreeRenderSnapshot
    ) -> DOMTreeRenderInvalidation {
        let previousIDs = Set(previous.nodesByID.keys)
        let nextIDs = Set(next.nodesByID.keys)
        var affectedNodeIDs = previousIDs.symmetricDifference(nextIDs)
        var parentNodeIDs: Set<DOMNode.ID> = []
        var hasStructuralChanges = previousIDs != nextIDs

        for id in previousIDs.intersection(nextIDs) {
            guard let oldNode = previous.nodesByID[id],
                  let newNode = next.nodesByID[id],
                  oldNode != newNode else {
                continue
            }
            affectedNodeIDs.insert(id)
            if oldNode.topology != newNode.topology {
                hasStructuralChanges = true
            }
        }

        for id in affectedNodeIDs {
            if let parentID = previous.nodesByID[id]?.parentID {
                parentNodeIDs.insert(parentID)
            }
            if let parentID = next.nodesByID[id]?.parentID {
                parentNodeIDs.insert(parentID)
            }
        }

        let rootChanged = previous.rootNodeID != next.rootNodeID
        return DOMTreeRenderInvalidation(
            kind: rootChanged ? .root : hasStructuralChanges ? .structure : .content,
            revision: next.revision,
            startRevision: previous.revision,
            affectedNodeIDs: affectedNodeIDs,
            parentNodeIDs: parentNodeIDs,
            resetsLocalDocumentState: previous.rootNodeID != nil && rootChanged
        )
    }
}

@MainActor
final class DOMTreeRenderState {
    private(set) var snapshot: DOMTreeRenderSnapshot

    init(selectedNodeID: DOMNode.ID? = nil) {
        snapshot = DOMTreeRenderSnapshot(
            revision: 0,
            rootNodeID: nil,
            selectedNodeID: selectedNodeID,
            nodesByID: [:]
        )
    }

    func accept(_ nextSnapshot: DOMTreeRenderSnapshot) {
        snapshot = nextSnapshot
    }

    @discardableResult
    func setSelectedNodeID(
        _ selectedNodeID: DOMNode.ID?
    ) -> Bool {
        let liveSelectedNodeID = selectedNodeID.flatMap {
            snapshot.nodesByID[$0] == nil ? nil : $0
        }
        guard snapshot.selectedNodeID != liveSelectedNodeID else {
            return false
        }
        snapshot = DOMTreeRenderSnapshot(
            revision: snapshot.revision,
            rootNodeID: snapshot.rootNodeID,
            selectedNodeID: liveSelectedNodeID,
            nodesByID: snapshot.nodesByID
        )
        return true
    }
}
#endif
