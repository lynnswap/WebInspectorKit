import Foundation

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
        public let attributes: [String: String]
        public let childNodeCount: Int
        public let children: Children
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
            attributes: node.attributes,
            childNodeCount: node.childNodeCount,
            children: children
        )

        guard case let .loaded(childNodes) = node.children else {
            return
        }
        for child in childNodes {
            collectSnapshotNodes(child, parentID: node.id, nodesByID: &nodesByID, parentByNodeID: &parentByNodeID)
        }
    }
}

final class WeakDOMTreeState {
    weak var tree: DOMTreeState?

    init(_ tree: DOMTreeState) {
        self.tree = tree
    }
}
