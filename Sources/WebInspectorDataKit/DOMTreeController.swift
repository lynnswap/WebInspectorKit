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

public enum DOMTreeUpdate: Hashable, Sendable {
    case snapshot(DOMTreeSnapshot, reason: DOMTreeSnapshotReason)
    case delta(DOMTreeDelta)
}

public enum DOMTreeSnapshotReason: Hashable, Sendable {
    case initialDocument
    case pageChanged
    case documentUpdated
    case reset
}

public enum DOMTreeDelta: Hashable, Sendable {
    case nodeChanged(nodeID: DOMNode.ID)
    case childInserted(parentID: DOMNode.ID, nodeID: DOMNode.ID, previousSiblingID: DOMNode.ID?)
    case childRemoved(parentID: DOMNode.ID, nodeID: DOMNode.ID)
    case childrenReplaced(parentID: DOMNode.ID, childIDs: [DOMNode.ID])
    case childCountChanged(nodeID: DOMNode.ID)
    case selectionChanged(nodeID: DOMNode.ID?)
}

public struct DOMTreeRevealRequest: Hashable, Sendable {
    public var nodeID: DOMNode.ID
    public var ancestorNodeIDs: [DOMNode.ID]
    public var shouldSelect: Bool
    public var shouldScroll: Bool

    public init(
        nodeID: DOMNode.ID,
        ancestorNodeIDs: [DOMNode.ID],
        shouldSelect: Bool,
        shouldScroll: Bool
    ) {
        self.nodeID = nodeID
        self.ancestorNodeIDs = ancestorNodeIDs
        self.shouldSelect = shouldSelect
        self.shouldScroll = shouldScroll
    }
}

public final class DOMTreeController {
    public var snapshot: DOMTreeSnapshot {
        tree.snapshot
    }

    public var revision: UInt64 {
        tree.revision
    }

    public var selectedNodeID: DOMNode.ID? {
        tree.selectedNodeID
    }

    public var updates: AsyncStream<DOMTreeUpdate> {
        tree.updates
    }

    public var revealRequests: AsyncStream<DOMTreeRevealRequest> {
        tree.revealRequests
    }

    private let tree: DOMTreeState

    init(tree: DOMTreeState) {
        self.tree = tree
    }
}

final class DOMTreeState {
    var snapshot: DOMTreeSnapshot {
        makeSnapshotFromIndex()
    }

    private(set) var revision: UInt64
    private var rootNodeID: DOMNode.ID?
    private(set) var selectedNodeID: DOMNode.ID?
    private var nodesByID: [DOMNode.ID: DOMTreeSnapshot.Node]
    private var parentByNodeID: [DOMNode.ID: DOMNode.ID]
    private let updateRelay = WebInspectorAsyncStreamRelay<DOMTreeUpdate>()
    private let revealRequestRelay = WebInspectorAsyncStreamRelay<DOMTreeRevealRequest>()

    var updates: AsyncStream<DOMTreeUpdate> {
        updateRelay.makeStream(initialElement: .snapshot(snapshot, reason: .initialDocument))
    }

    var revealRequests: AsyncStream<DOMTreeRevealRequest> {
        revealRequestRelay.makeStream()
    }

    init(rootNode: DOMNode?, selectedNode: DOMNode?) {
        revision = 0
        let snapshot = DOMTreeSnapshot.make(revision: revision, rootNode: rootNode, selectedNode: selectedNode)
        rootNodeID = snapshot.rootNodeID
        selectedNodeID = snapshot.selectedNodeID
        nodesByID = snapshot.nodesByID
        parentByNodeID = snapshot.parentByNodeID
    }

    deinit {
        updateRelay.finish()
        revealRequestRelay.finish()
    }

    func applySnapshot(
        rootNode: DOMNode?,
        selectedNode: DOMNode?,
        reason: DOMTreeSnapshotReason
    ) {
        revision &+= 1
        let nextSnapshot = DOMTreeSnapshot.make(revision: revision, rootNode: rootNode, selectedNode: selectedNode)
        rootNodeID = nextSnapshot.rootNodeID
        selectedNodeID = nextSnapshot.selectedNodeID
        nodesByID = nextSnapshot.nodesByID
        parentByNodeID = nextSnapshot.parentByNodeID
        updateRelay.yield(.snapshot(makeSnapshotFromIndex(), reason: reason))
    }

    func applyChildrenReplaced(parent: DOMNode) {
        let visibleChildIDs = visibleChildIDs(of: parent)

        let previousChildIDs = nodesByID[parent.id]
            .map(indexedSubtreeChildIDs(of:)) ?? []
        let nextChildIDs = Set(indexedSubtreeChildIDs(of: parent))
        for previousChildID in previousChildIDs where nextChildIDs.contains(previousChildID) == false {
            removeSubtree(previousChildID, nodesByID: &nodesByID, parentByNodeID: &parentByNodeID)
        }
        upsertNode(parent, parentID: parentByNodeID[parent.id], nodesByID: &nodesByID, parentByNodeID: &parentByNodeID)
        for associatedRoot in parent.associatedSubtreeRoots() {
            upsertSubtree(associatedRoot, parentID: parent.id, nodesByID: &nodesByID, parentByNodeID: &parentByNodeID)
        }
        if case let .loaded(children) = parent.children {
            for child in children {
                upsertSubtree(child, parentID: parent.id, nodesByID: &nodesByID, parentByNodeID: &parentByNodeID)
            }
        }
        replaceSnapshot()
        publish(.childrenReplaced(parentID: parent.id, childIDs: visibleChildIDs))
    }

    func applyChildInserted(parent: DOMNode, node: DOMNode, previousSiblingID: DOMNode.ID?) {
        upsertNode(parent, parentID: parentByNodeID[parent.id], nodesByID: &nodesByID, parentByNodeID: &parentByNodeID)
        upsertSubtree(node, parentID: parent.id, nodesByID: &nodesByID, parentByNodeID: &parentByNodeID)
        replaceSnapshot()
        publish(.childInserted(parentID: parent.id, nodeID: node.id, previousSiblingID: previousSiblingID))
    }

    func applyChildRemoved(parent: DOMNode, nodeID: DOMNode.ID) {
        let selectedNodeWasRemoved = selectedNodeID.map { selectedNodeID in
            selectedNodeID == nodeID || ancestorNodeIDs(of: selectedNodeID).contains(nodeID)
        } ?? false
        removeSubtree(nodeID, nodesByID: &nodesByID, parentByNodeID: &parentByNodeID)
        upsertNode(parent, parentID: parentByNodeID[parent.id], nodesByID: &nodesByID, parentByNodeID: &parentByNodeID)
        replaceSnapshot(
            selectedNodeID: selectedNodeWasRemoved ? .some(nil) : nil
        )
        publish(.childRemoved(parentID: parent.id, nodeID: nodeID))
        if selectedNodeWasRemoved {
            publish(.selectionChanged(nodeID: nil))
        }
    }

    func applyChildCountChanged(node: DOMNode) {
        upsertNode(node, parentID: parentByNodeID[node.id], nodesByID: &nodesByID, parentByNodeID: &parentByNodeID)
        replaceSnapshot()
        publish(.childCountChanged(nodeID: node.id))
    }

    func applyNodeChanged(_ node: DOMNode) {
        upsertNode(node, parentID: parentByNodeID[node.id], nodesByID: &nodesByID, parentByNodeID: &parentByNodeID)
        replaceSnapshot()
        publish(.nodeChanged(nodeID: node.id))
    }

    func applySelectionChanged(nodeID: DOMNode.ID?) {
        let nextSelectedNodeID = nodeID.flatMap { nodesByID[$0] == nil ? nil : $0 }
        guard selectedNodeID != nextSelectedNodeID else {
            return
        }
        replaceSnapshot(selectedNodeID: .some(nextSelectedNodeID))
        publish(.selectionChanged(nodeID: nextSelectedNodeID))
        if let nextSelectedNodeID {
            revealRequestRelay.yield(DOMTreeRevealRequest(
                nodeID: nextSelectedNodeID,
                ancestorNodeIDs: ancestorNodeIDs(of: nextSelectedNodeID),
                shouldSelect: true,
                shouldScroll: true
            ))
        }
    }

    private func makeSnapshotFromIndex() -> DOMTreeSnapshot {
        DOMTreeSnapshot(
            revision: revision,
            rootNodeID: rootNodeID,
            selectedNodeID: selectedNodeID,
            nodesByID: Dictionary(uniqueKeysWithValues: nodesByID.map { ($0.key, $0.value) }),
            parentByNodeID: Dictionary(uniqueKeysWithValues: parentByNodeID.map { ($0.key, $0.value) })
        )
    }

    private func replaceSnapshot(
        selectedNodeID: DOMNode.ID?? = nil
    ) {
        revision &+= 1
        if let selectedNodeID {
            self.selectedNodeID = selectedNodeID
        } else if let currentSelectedNodeID = self.selectedNodeID,
                  nodesByID[currentSelectedNodeID] == nil {
            self.selectedNodeID = nil
        }
    }

    private func publish(_ delta: DOMTreeDelta) {
        updateRelay.yield(.delta(delta))
    }

    private func ancestorNodeIDs(of id: DOMNode.ID) -> [DOMNode.ID] {
        var ancestors: [DOMNode.ID] = []
        var visited = Set<DOMNode.ID>()
        var current = parentByNodeID[id]
        while let ancestorID = current,
              visited.insert(ancestorID).inserted {
            ancestors.append(ancestorID)
            current = parentByNodeID[ancestorID]
        }
        return ancestors
    }

    private func upsertSubtree(
        _ node: DOMNode,
        parentID: DOMNode.ID?,
        nodesByID: inout [DOMNode.ID: DOMTreeSnapshot.Node],
        parentByNodeID: inout [DOMNode.ID: DOMNode.ID]
    ) {
        upsertNode(node, parentID: parentID, nodesByID: &nodesByID, parentByNodeID: &parentByNodeID)
        for associatedRoot in node.associatedSubtreeRoots() {
            upsertSubtree(
                associatedRoot,
                parentID: node.id,
                nodesByID: &nodesByID,
                parentByNodeID: &parentByNodeID
            )
        }
        guard case let .loaded(children) = node.children else {
            return
        }
        for child in children {
            upsertSubtree(child, parentID: node.id, nodesByID: &nodesByID, parentByNodeID: &parentByNodeID)
        }
    }

    private func upsertNode(
        _ node: DOMNode,
        parentID: DOMNode.ID?,
        nodesByID: inout [DOMNode.ID: DOMTreeSnapshot.Node],
        parentByNodeID: inout [DOMNode.ID: DOMNode.ID]
    ) {
        nodesByID[node.id] = DOMTreeSnapshot.Node(snapshotting: node)
        if let parentID {
            parentByNodeID[node.id] = parentID
        } else {
            parentByNodeID.removeValue(forKey: node.id)
        }
    }

    private func removeSubtree(
        _ rootID: DOMNode.ID,
        nodesByID: inout [DOMNode.ID: DOMTreeSnapshot.Node],
        parentByNodeID: inout [DOMNode.ID: DOMNode.ID]
    ) {
        guard let node = nodesByID[rootID] else {
            parentByNodeID.removeValue(forKey: rootID)
            return
        }
        for childID in indexedSubtreeChildIDs(of: node) {
            removeSubtree(childID, nodesByID: &nodesByID, parentByNodeID: &parentByNodeID)
        }
        nodesByID.removeValue(forKey: rootID)
        parentByNodeID.removeValue(forKey: rootID)
    }

    private func indexedSubtreeChildIDs(of node: DOMTreeSnapshot.Node) -> [DOMNode.ID] {
        var childIDs: [DOMNode.ID] = []
        if let templateContentID = node.templateContentID {
            childIDs.append(templateContentID)
        }
        if let beforePseudoElementID = node.beforePseudoElementID {
            childIDs.append(beforePseudoElementID)
        }
        childIDs.append(contentsOf: node.otherPseudoElementIDs)
        if let contentDocumentID = node.contentDocumentID {
            childIDs.append(contentDocumentID)
        }
        childIDs.append(contentsOf: node.shadowRootIDs)
        if case let .loaded(children) = node.children {
            childIDs.append(contentsOf: children)
        }
        if let afterPseudoElementID = node.afterPseudoElementID {
            childIDs.append(afterPseudoElementID)
        }
        return childIDs
    }

    private func indexedSubtreeChildIDs(of node: DOMNode) -> [DOMNode.ID] {
        var childIDs = node.associatedSubtreeRoots().map(\.id)
        if case let .loaded(children) = node.children {
            childIDs.append(contentsOf: children.map(\.id))
        }
        return childIDs
    }

    private func visibleChildIDs(of node: DOMNode) -> [DOMNode.ID] {
        var childIDs: [DOMNode.ID] = []
        if let templateContent = node.templateContent {
            childIDs.append(templateContent.id)
        }
        if let beforePseudoElement = node.beforePseudoElement {
            childIDs.append(beforePseudoElement.id)
        }
        childIDs.append(contentsOf: node.otherPseudoElements.map(\.id))
        if let contentDocument = node.contentDocument {
            childIDs.append(contentDocument.id)
        } else {
            childIDs.append(contentsOf: node.shadowRoots.map(\.id))
            if case let .loaded(children) = node.children {
                childIDs.append(contentsOf: children.map(\.id))
            }
        }
        if let afterPseudoElement = node.afterPseudoElement {
            childIDs.append(afterPseudoElement.id)
        }
        return childIDs
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
    init(snapshotting node: DOMNode) {
        let children: Children
        switch node.children {
        case let .unrequested(count):
            children = .unrequested(count: count)
        case let .loaded(childNodes):
            children = .loaded(childNodes.map(\.id))
        }

        self.init(
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
    }

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
