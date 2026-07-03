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

    init(transaction: DOMTreeTransaction) {
        var kind: Kind = .content
        var affectedNodeIDs: Set<DOMNode.ID> = []
        var parentNodeIDs: Set<DOMNode.ID> = []
        var resetsLocalDocumentState = false

        for change in transaction.changes {
            switch change {
            case let .rootChanged(rootNodeID):
                kind = .root
                resetsLocalDocumentState = true
                if let rootNodeID {
                    affectedNodeIDs.insert(rootNodeID)
                }
            case let .childrenReplaced(parentID),
                 let .childInserted(parentID),
                 let .childRemoved(parentID):
                if kind != .root {
                    kind = .structure
                }
                parentNodeIDs.insert(parentID)
                affectedNodeIDs.insert(parentID)
            case let .childCountChanged(nodeID),
                 let .nodeChanged(nodeID):
                if kind != .root, kind != .structure {
                    kind = .content
                }
                affectedNodeIDs.insert(nodeID)
            case .selectionChanged:
                break
            }
        }

        self.init(
            kind: kind,
            revision: transaction.revision,
            startRevision: transaction.oldSnapshot.revision,
            affectedNodeIDs: affectedNodeIDs,
            parentNodeIDs: parentNodeIDs,
            resetsLocalDocumentState: resetsLocalDocumentState
        )
    }
}

extension DOMTreeTransaction.Change {
    var isSelectionChange: Bool {
        if case .selectionChanged = self {
            return true
        }
        return false
    }
}
#endif
