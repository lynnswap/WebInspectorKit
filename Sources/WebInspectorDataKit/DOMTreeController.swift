import Foundation
import WebInspectorProxyKit

public struct DOMTreeSnapshot: Hashable, Sendable {
    public struct Node: Hashable, Identifiable, Sendable {
        public enum Children: Hashable, Sendable {
            case unrequested(count: Int)
            case loaded([DOMNode.ID])
        }

        public let id: DOMNode.ID
        public let nodeName: String
        public let localName: String
        public let nodeValue: String
        public let nodeType: Int
        public let kind: DOMNode.Kind
        public let frameID: FrameID?
        public let documentURL: String?
        public let baseURL: String?
        public let attributes: [String: String]
        public let attributeList: [DOMNode.Attribute]
        public let childNodeCount: Int
        public let children: Children
        public let contentDocumentID: DOMNode.ID?
        public let shadowRootIDs: [DOMNode.ID]
        public let templateContentID: DOMNode.ID?
        public let beforePseudoElementID: DOMNode.ID?
        public let otherPseudoElementIDs: [DOMNode.ID]
        public let afterPseudoElementID: DOMNode.ID?
        public let pseudoType: DOM.PseudoType?
        public let shadowRootType: DOM.ShadowRootType?

        public var displayName: String {
            if !localName.isEmpty {
                return localName
            }
            if !nodeName.isEmpty {
                return nodeName
            }
            return nodeValue.isEmpty ? nodeName : nodeValue
        }
    }

    public struct VisibleChildren: Hashable, Sendable {
        public let nodeIDs: [DOMNode.ID]
        public let hasUnloadedChildren: Bool
        public let hasRenderableChildren: Bool
    }

    public let revision: UInt64
    public let rootNodeID: DOMNode.ID?
    public let selectedNodeID: DOMNode.ID?
    public let nodesByID: [DOMNode.ID: Node]
    public let parentByNodeID: [DOMNode.ID: DOMNode.ID]

    public func node(for id: DOMNode.ID) -> Node? {
        nodesByID[id]
    }

    public func children(of id: DOMNode.ID) -> [DOMNode.ID] {
        guard case let .loaded(children) = nodesByID[id]?.children else {
            return []
        }
        return children
    }

    public func visibleChildren(of id: DOMNode.ID) -> VisibleChildren {
        guard let node = nodesByID[id] else {
            return VisibleChildren(nodeIDs: [], hasUnloadedChildren: false, hasRenderableChildren: false)
        }

        var children: [DOMNode.ID] = []
        if let templateContentID = node.templateContentID {
            children.append(templateContentID)
        }
        if let beforePseudoElementID = node.beforePseudoElementID {
            children.append(beforePseudoElementID)
        }
        children.append(contentsOf: node.otherPseudoElementIDs)
        if let contentDocumentID = node.contentDocumentID {
            children.append(contentDocumentID)
        } else {
            children.append(contentsOf: node.shadowRootIDs)
            children.append(contentsOf: self.children(of: id))
        }
        if let afterPseudoElementID = node.afterPseudoElementID {
            children.append(afterPseudoElementID)
        }

        return VisibleChildren(
            nodeIDs: children,
            hasUnloadedChildren: node.hasUnloadedRegularChildren,
            hasRenderableChildren: !children.isEmpty || node.childNodeCount > 0
        )
    }

    public func displayRootIDs() -> [DOMNode.ID] {
        guard let rootNodeID,
              let rootNode = nodesByID[rootNodeID] else {
            return []
        }
        if rootNode.kind == .document {
            return visibleChildren(of: rootNodeID).nodeIDs
        }
        return [rootNodeID]
    }

    public func isTemplateContent(_ id: DOMNode.ID) -> Bool {
        guard let parentID = parentByNodeID[id],
              let parent = nodesByID[parentID] else {
            return false
        }
        return parent.templateContentID == id
    }

    public func parent(of id: DOMNode.ID) -> DOMNode.ID? {
        parentByNodeID[id]
    }

    public func ancestorNodeIDs(of id: DOMNode.ID) -> [DOMNode.ID] {
        var ancestors: [DOMNode.ID] = []
        var visited = Set<DOMNode.ID>()
        var current = parentByNodeID[id]
        while let ancestorID = current,
            visited.insert(ancestorID).inserted
        {
            ancestors.append(ancestorID)
            current = parentByNodeID[ancestorID]
        }
        return ancestors
    }
}

public struct DOMTreeTransaction: Hashable, Sendable {
    public enum Change: Hashable, Sendable {
        case rootChanged(rootNodeID: DOMNode.ID?)
        case childrenReplaced(parentID: DOMNode.ID)
        case childInserted(parentID: DOMNode.ID)
        case childRemoved(parentID: DOMNode.ID)
        case childCountChanged(nodeID: DOMNode.ID)
        case nodeChanged(nodeID: DOMNode.ID)
        case selectionChanged(nodeID: DOMNode.ID?)
    }

    public let revision: UInt64
    public let oldSnapshot: DOMTreeSnapshot
    public let newSnapshot: DOMTreeSnapshot
    public let changes: [Change]
}

public final class DOMTreeController {
    public var snapshot: DOMTreeSnapshot {
        tree.snapshot
    }

    public var transactions: AsyncStream<DOMTreeTransaction> {
        tree.transactions
    }

    private let tree: DOMTreeState

    init(tree: DOMTreeState) {
        self.tree = tree
    }
}

final class DOMTreeState {
    private(set) var snapshot: DOMTreeSnapshot

    private var revision: UInt64
    private let transactionRelay = WebInspectorAsyncStreamRelay<DOMTreeTransaction>()

    var transactions: AsyncStream<DOMTreeTransaction> {
        transactionRelay.makeStream()
    }

    init(rootNode: DOMNode?, selectedNode: DOMNode?) {
        revision = 0
        snapshot = Self.makeSnapshot(revision: revision, rootNode: rootNode, selectedNode: selectedNode)
    }

    deinit {
        transactionRelay.finish()
    }

    func apply(
        changes: [DOMTreeTransaction.Change],
        rootNode: DOMNode?,
        selectedNode: DOMNode?
    ) {
        let oldSnapshot = snapshot
        revision &+= 1
        let newSnapshot = Self.makeSnapshot(revision: revision, rootNode: rootNode, selectedNode: selectedNode)
        snapshot = newSnapshot
        guard transactionRelay.hasContinuations else {
            return
        }
        transactionRelay.yield(
            DOMTreeTransaction(
                revision: revision,
                oldSnapshot: oldSnapshot,
                newSnapshot: newSnapshot,
                changes: changes
            ))
    }

    private static func makeSnapshot(
        revision: UInt64,
        rootNode: DOMNode?,
        selectedNode: DOMNode?
    ) -> DOMTreeSnapshot {
        DOMTreeSnapshot.make(revision: revision, rootNode: rootNode, selectedNode: selectedNode)
    }
}

extension DOMTreeSnapshot {
    static func make(
        revision: UInt64,
        rootNode: DOMNode?,
        selectedNode: DOMNode?
    ) -> DOMTreeSnapshot {
        guard let rootNode else {
            return DOMTreeSnapshot(
                revision: revision,
                rootNodeID: nil,
                selectedNodeID: nil,
                nodesByID: [:],
                parentByNodeID: [:]
            )
        }

        var nodesByID: [DOMNode.ID: DOMTreeSnapshot.Node] = [:]
        var parentByNodeID: [DOMNode.ID: DOMNode.ID] = [:]
        collectSnapshotNodes(rootNode, parentID: nil, nodesByID: &nodesByID, parentByNodeID: &parentByNodeID)
        let selectedNodeID = selectedNode.flatMap { nodesByID[$0.id] == nil ? nil : $0.id }
        return DOMTreeSnapshot(
            revision: revision,
            rootNodeID: rootNode.id,
            selectedNodeID: selectedNodeID,
            nodesByID: nodesByID,
            parentByNodeID: parentByNodeID
        )
    }

    private static func collectSnapshotNodes(
        _ node: DOMNode,
        parentID: DOMNode.ID?,
        nodesByID: inout [DOMNode.ID: DOMTreeSnapshot.Node],
        parentByNodeID: inout [DOMNode.ID: DOMNode.ID]
    ) {
        if let parentID {
            parentByNodeID[node.id] = parentID
        }

        let children: DOMTreeSnapshot.Node.Children
        switch node.children {
        case let .unrequested(count):
            children = .unrequested(count: count)
        case let .loaded(childNodes):
            children = .loaded(childNodes.map(\.id))
        }

        nodesByID[node.id] = DOMTreeSnapshot.Node(
            id: node.id,
            nodeName: node.nodeName,
            localName: node.localName,
            nodeValue: node.nodeValue,
            nodeType: node.nodeType,
            kind: node.kind,
            frameID: node.frameID,
            documentURL: node.documentURL,
            baseURL: node.baseURL,
            attributes: node.attributes,
            attributeList: node.attributeList,
            childNodeCount: node.childNodeCount,
            children: children,
            contentDocumentID: node.contentDocument?.id,
            shadowRootIDs: node.shadowRoots.map(\.id),
            templateContentID: node.templateContent?.id,
            beforePseudoElementID: node.beforePseudoElement?.id,
            otherPseudoElementIDs: node.otherPseudoElements.map(\.id),
            afterPseudoElementID: node.afterPseudoElement?.id,
            pseudoType: node.pseudoType,
            shadowRootType: node.shadowRootType
        )

        for child in node.associatedSubtreeRoots() {
            collectSnapshotNodes(child, parentID: node.id, nodesByID: &nodesByID, parentByNodeID: &parentByNodeID)
        }
        guard case let .loaded(childNodes) = node.children else {
            return
        }
        for child in childNodes {
            collectSnapshotNodes(child, parentID: node.id, nodesByID: &nodesByID, parentByNodeID: &parentByNodeID)
        }
    }
}

extension DOMTreeSnapshot.Node {
    var hasUnloadedRegularChildren: Bool {
        if case let .unrequested(count) = children {
            return count > 0
        }
        return false
    }
}

final class WeakDOMTreeState {
    weak var tree: DOMTreeState?

    init(_ tree: DOMTreeState) {
        self.tree = tree
    }
}
