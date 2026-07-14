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
    static func initial(metadata: DOMTreeRenderMetadata) -> DOMTreeRenderInvalidation {
        DOMTreeRenderInvalidation(
            kind: .root,
            revision: metadata.revision,
            startRevision: metadata.revision,
            affectedNodeIDs: Set(metadata.rootNodeID.map { [$0] } ?? []),
            parentNodeIDs: [],
            resetsLocalDocumentState: false
        )
    }

}
#endif
