#if canImport(UIKit)
import WebInspectorDataKit

struct DOMTreeRenderInvalidation: Sendable {
    enum Kind: Equatable, Sendable {
        case root
        case structure
        case content
    }

    let kind: Kind
    let revision: UInt64
    let startRevision: UInt64
    let affectedNodeIDs: Set<DOMNode.ID>
    let parentNodeIDs: Set<DOMNode.ID>
    let resetsLocalDocumentState: Bool

    var requiresFragmentReset: Bool {
        switch kind {
        case .root:
            return true
        case .structure,
             .content:
            return false
        }
    }

    var hasScopedNodes: Bool {
        !affectedNodeIDs.isEmpty || !parentNodeIDs.isEmpty
    }

    func intersects(nodeIDs: Set<DOMNode.ID>) -> Bool {
        !affectedNodeIDs.isDisjoint(with: nodeIDs) || !parentNodeIDs.isDisjoint(with: nodeIDs)
    }

    func merging(with other: DOMTreeRenderInvalidation) -> DOMTreeRenderInvalidation {
        DOMTreeRenderInvalidation(
            kind: mergedKind(with: other.kind),
            revision: max(revision, other.revision),
            startRevision: min(startRevision, other.startRevision),
            affectedNodeIDs: affectedNodeIDs.union(other.affectedNodeIDs),
            parentNodeIDs: parentNodeIDs.union(other.parentNodeIDs),
            resetsLocalDocumentState: resetsLocalDocumentState || other.resetsLocalDocumentState
        )
    }

    private func mergedKind(with other: Kind) -> Kind {
        if kind == .root || other == .root {
            return .root
        }
        if kind == .structure || other == .structure {
            return .structure
        }
        return .content
    }
}

extension DOMTreeRenderInvalidation {
    static func initial(snapshot: DOMTreeSnapshot) -> DOMTreeRenderInvalidation {
        DOMTreeRenderInvalidation(
            kind: .root,
            revision: snapshot.revision,
            startRevision: snapshot.revision,
            affectedNodeIDs: Set(snapshot.rootNodeID.map { [$0] } ?? []),
            parentNodeIDs: [],
            resetsLocalDocumentState: false
        )
    }

    static func snapshot(_ snapshot: DOMTreeSnapshot, reason: DOMTreeSnapshotReason) -> DOMTreeRenderInvalidation {
        DOMTreeRenderInvalidation(
            kind: .root,
            revision: snapshot.revision,
            startRevision: snapshot.revision,
            affectedNodeIDs: Set(snapshot.rootNodeID.map { [$0] } ?? []),
            parentNodeIDs: [],
            resetsLocalDocumentState: reason != .initialDocument
        )
    }

    init(delta: DOMTreeDelta, revision: UInt64, startRevision: UInt64) {
        let kind: Kind
        var affectedNodeIDs: Set<DOMNode.ID> = []
        var parentNodeIDs: Set<DOMNode.ID> = []

        switch delta {
        case let .childInserted(parentID, nodeID, _):
            kind = .structure
            parentNodeIDs.insert(parentID)
            affectedNodeIDs.insert(parentID)
            affectedNodeIDs.insert(nodeID)
        case let .childRemoved(parentID, nodeID):
            kind = .structure
            parentNodeIDs.insert(parentID)
            affectedNodeIDs.insert(parentID)
            affectedNodeIDs.insert(nodeID)
        case let .childrenReplaced(parentID, childIDs):
            kind = .structure
            parentNodeIDs.insert(parentID)
            affectedNodeIDs.insert(parentID)
            affectedNodeIDs.formUnion(childIDs)
        case let .childCountChanged(nodeID),
             let .nodeChanged(nodeID):
            kind = .content
            affectedNodeIDs.insert(nodeID)
        case .selectionChanged:
            kind = .content
        }

        self.init(
            kind: kind,
            revision: revision,
            startRevision: startRevision,
            affectedNodeIDs: affectedNodeIDs,
            parentNodeIDs: parentNodeIDs,
            resetsLocalDocumentState: false
        )
    }
}

extension DOMTreeDelta {
    var isSelectionChange: Bool {
        if case .selectionChanged = self {
            return true
        }
        return false
    }
}
#endif
