import Foundation
import WebInspectorProxyKit

/// Immutable snapshot of a DOM tree projection.
public struct DOMTreeSnapshot: Hashable, Sendable {
    /// A snapshot node detached from observable ``DOMNode`` instances.
    public struct Node: Hashable, Identifiable, Sendable {
        /// Loading state for a snapshot node's regular children.
        public enum Children: Hashable, Sendable {
            /// Children have not been requested yet, but WebKit reported a count.
            case unrequested(count: Int)

            /// Child node identities loaded in the snapshot.
            case loaded([DOMNode.ID])
        }

        /// The stable node identity.
        public let id: DOMNode.ID

        /// The protocol node name.
        public let nodeName: String

        /// The local element name, if available.
        public let localName: String

        /// The node value for text-like nodes.
        public let nodeValue: String

        /// The raw numeric DOM node type.
        public let nodeType: Int

        /// The DOM node kind.
        public let kind: DOMNode.Kind

        /// The frame that owns the node, if WebKit reported one.
        public let frameID: FrameID?

        /// The document URL associated with the node.
        public let documentURL: String?

        /// The base URL associated with the node.
        public let baseURL: String?

        /// Attributes keyed by name.
        public let attributes: [String: String]

        /// Attributes in protocol order.
        public let attributeList: [DOMNode.Attribute]

        /// The number of regular children reported by WebKit.
        public let childNodeCount: Int

        /// Loading state for regular child nodes.
        public let children: Children

        /// The content document identity for frame-like elements.
        public let contentDocumentID: DOMNode.ID?

        /// Shadow root identities attached to the node.
        public let shadowRootIDs: [DOMNode.ID]

        /// Template content identity associated with the node.
        public let templateContentID: DOMNode.ID?

        /// The `::before` pseudo-element identity.
        public let beforePseudoElementID: DOMNode.ID?

        /// Additional pseudo-element identities reported by WebKit.
        public let otherPseudoElementIDs: [DOMNode.ID]

        /// The `::after` pseudo-element identity.
        public let afterPseudoElementID: DOMNode.ID?

        /// The node's pseudo-element kind.
        public let pseudoType: DOM.PseudoType?

        /// The node's shadow-root kind.
        public let shadowRootType: DOM.ShadowRootType?

        /// A display name suitable for tree rows.
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

    /// Visible child identities for tree rendering.
    public struct VisibleChildren: Hashable, Sendable {
        /// Child identities in render order.
        public let nodeIDs: [DOMNode.ID]

        /// A Boolean value indicating whether regular children are still unloaded.
        public let hasUnloadedChildren: Bool

        /// A Boolean value indicating whether the node can render any child disclosure.
        public let hasRenderableChildren: Bool
    }

    /// Monotonic revision that changes when the snapshot topology changes.
    public let revision: UInt64

    /// The root node identity for the snapshot.
    public let rootNodeID: DOMNode.ID?

    /// The selected node identity at the time of the snapshot.
    public let selectedNodeID: DOMNode.ID?

    /// Snapshot nodes keyed by identity.
    public let nodesByID: [DOMNode.ID: Node]

    /// Parent identities keyed by child identity.
    public let parentByNodeID: [DOMNode.ID: DOMNode.ID]

    /// Returns the snapshot node for an identity.
    public func node(for id: DOMNode.ID) -> Node? {
        nodesByID[id]
    }

    /// Returns regular child identities for a node.
    public func children(of id: DOMNode.ID) -> [DOMNode.ID] {
        guard case let .loaded(children) = nodesByID[id]?.children else {
            return []
        }
        return children
    }

    /// Returns child identities in the order tree views should render them.
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

    /// Returns the visible root identities for tree rendering.
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

    /// Returns whether the identity is a template content node.
    public func isTemplateContent(_ id: DOMNode.ID) -> Bool {
        guard let parentID = parentByNodeID[id],
              let parent = nodesByID[parentID] else {
            return false
        }
        return parent.templateContentID == id
    }

    /// Returns the parent identity for a node.
    public func parent(of id: DOMNode.ID) -> DOMNode.ID? {
        parentByNodeID[id]
    }

    /// Returns ancestor identities from parent to root.
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

/// Updates emitted by a ``DOMTreeController``.
public enum DOMTreeUpdate: Hashable, Sendable {
    /// A full snapshot replacement.
    case snapshot(DOMTreeSnapshot, reason: DOMTreeSnapshotReason)

    /// An incremental tree update.
    case delta(DOMTreeDelta)
}

/// Reason a DOM tree snapshot was emitted.
public enum DOMTreeSnapshotReason: Hashable, Sendable {
    /// The initial snapshot emitted to a subscriber.
    case initialDocument

    /// The inspected page target changed.
    case pageChanged

    /// WebKit reported that the document changed.
    case documentUpdated

    /// The tree state was reset.
    case reset
}

/// Incremental DOM tree change.
public enum DOMTreeDelta: Hashable, Sendable {
    /// A node's display data changed.
    case nodeChanged(nodeID: DOMNode.ID)

    /// A child was inserted under a parent.
    case childInserted(parentID: DOMNode.ID, nodeID: DOMNode.ID, previousSiblingID: DOMNode.ID?)

    /// A child was removed from a parent.
    case childRemoved(parentID: DOMNode.ID, nodeID: DOMNode.ID)

    /// A parent's children were replaced.
    case childrenReplaced(parentID: DOMNode.ID, childIDs: [DOMNode.ID])

    /// A node's child count changed.
    case childCountChanged(nodeID: DOMNode.ID)

    /// The selected node changed.
    case selectionChanged(nodeID: DOMNode.ID?)
}

/// Request emitted when a tree view should reveal a node.
public struct DOMTreeRevealRequest: Hashable, Sendable {
    /// The node to reveal.
    public var nodeID: DOMNode.ID

    /// Ancestors that should be expanded before revealing the node.
    public var ancestorNodeIDs: [DOMNode.ID]

    /// A Boolean value indicating whether the node should become selected.
    public var shouldSelect: Bool

    /// A Boolean value indicating whether the node should be scrolled into view.
    public var shouldScroll: Bool

    /// Creates a reveal request.
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

/// Live controller for a DOM tree snapshot and its updates.
public final class DOMTreeController {
    /// The current snapshot.
    public var snapshot: DOMTreeSnapshot {
        tree.snapshot
    }

    /// The current snapshot revision.
    public var revision: UInt64 {
        tree.revision
    }

    /// The currently selected node identity.
    public var selectedNodeID: DOMNode.ID? {
        tree.selectedNodeID
    }

    /// Stream of snapshot and delta updates.
    public var updates: AsyncStream<DOMTreeUpdate> {
        tree.updates
    }

    /// Stream of reveal requests.
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
        for previousChildID in previousChildIDs {
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

    func applySelectionChanged(nodeID: DOMNode.ID?, reveal: DOMRevealPolicy) {
        let nextSelectedNodeID = nodeID.flatMap { nodesByID[$0] == nil ? nil : $0 }
        guard selectedNodeID != nextSelectedNodeID else {
            return
        }
        replaceSnapshot(selectedNodeID: .some(nextSelectedNodeID))
        publish(.selectionChanged(nodeID: nextSelectedNodeID))
        if let nextSelectedNodeID,
           reveal != .none {
            revealRequestRelay.yield(DOMTreeRevealRequest(
                nodeID: nextSelectedNodeID,
                ancestorNodeIDs: ancestorNodeIDs(of: nextSelectedNodeID),
                shouldSelect: true,
                shouldScroll: reveal == .selectAndScroll
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
