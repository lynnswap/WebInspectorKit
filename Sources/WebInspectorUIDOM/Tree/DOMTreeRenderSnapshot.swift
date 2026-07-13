#if canImport(UIKit)
import WebInspectorDataKit
import WebInspectorProxyKit

struct DOMTreeRenderSnapshot: Sendable {
    struct Node: Sendable {
        enum Children: Equatable, Sendable {
            case unrequested(count: Int)
            case loaded([DOMNode.ID])
        }

        let id: DOMNode.ID
        let parentID: DOMNode.ID?
        let nodeName: String
        let localName: String
        let nodeValue: String
        let nodeType: Int
        let frameID: FrameID?
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
        let pseudoType: DOM.PseudoType?
        let shadowRootType: DOM.ShadowRootType?

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
            if !localName.isEmpty {
                return localName
            }
            if !nodeName.isEmpty {
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

    init(_ snapshot: DOMTreeSnapshot) {
        revision = snapshot.revision
        rootNodeID = snapshot.rootNodeID
        selectedNodeID = snapshot.selectedNodeID
        nodesByID = snapshot.nodesByID.mapValues { node in
            Node(
                id: node.id,
                parentID: snapshot.parentByNodeID[node.id],
                nodeName: node.nodeName,
                localName: node.localName,
                nodeValue: node.nodeValue,
                nodeType: node.nodeType,
                frameID: node.frameID,
                documentURL: node.documentURL,
                baseURL: node.baseURL,
                attributes: node.attributes,
                attributeList: node.attributeList,
                children: Self.makeChildren(node.children),
                contentDocumentID: node.contentDocumentID,
                shadowRootIDs: node.shadowRootIDs,
                templateContentID: node.templateContentID,
                beforePseudoElementID: node.beforePseudoElementID,
                otherPseudoElementIDs: node.otherPseudoElementIDs,
                afterPseudoElementID: node.afterPseudoElementID,
                pseudoType: node.pseudoType,
                shadowRootType: node.shadowRootType
            )
        }
        parentByNodeID = snapshot.parentByNodeID
    }

    fileprivate init(
        revision: UInt64,
        rootNodeID: DOMNode.ID?,
        selectedNodeID: DOMNode.ID?,
        nodesByID: [DOMNode.ID: Node]
    ) {
        precondition(
            rootNodeID.map { nodesByID[$0] != nil } ?? nodesByID.isEmpty,
            "A DOM render tree must contain its root and cannot contain nodes without one."
        )
        self.revision = revision
        self.rootNodeID = rootNodeID
        self.selectedNodeID = selectedNodeID.flatMap { nodesByID[$0] == nil ? nil : $0 }
        self.nodesByID = nodesByID
        parentByNodeID = nodesByID.reduce(into: [:]) { result, element in
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
            hasRenderableChildren: !nodeIDs.isEmpty || node.childNodeCount > 0
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

    private static func makeChildren(
        _ children: DOMTreeSnapshot.Node.Children
    ) -> Node.Children {
        switch children {
        case let .unrequested(count):
            .unrequested(count: count)
        case let .loaded(ids):
            .loaded(ids)
        }
    }
}

@MainActor
final class DOMTreeRenderState {
    private(set) var snapshot: DOMTreeRenderSnapshot

    init(_ snapshot: DOMTreeSnapshot) {
        self.snapshot = DOMTreeRenderSnapshot(snapshot)
    }

    init(selectedNodeID: DOMNode.ID? = nil) {
        snapshot = DOMTreeRenderSnapshot(
            revision: 0,
            rootNodeID: nil,
            selectedNodeID: selectedNodeID,
            nodesByID: [:]
        )
    }

    init(
        revision: UInt64,
        snapshot: WebInspectorDOMTreeSnapshot,
        selectedNodeID: DOMNode.ID?
    ) {
        self.snapshot = Self.makeSnapshot(
            revision: revision,
            snapshot: snapshot,
            selectedNodeID: selectedNodeID
        )
    }

    func replace(_ legacySnapshot: DOMTreeSnapshot) {
        snapshot = DOMTreeRenderSnapshot(legacySnapshot)
    }

    func replace(
        revision: UInt64,
        snapshot: WebInspectorDOMTreeSnapshot,
        selectedNodeID: DOMNode.ID?,
        startRevision: UInt64? = nil,
        resetsLocalDocumentState: Bool
    ) -> DOMTreeRenderInvalidation {
        self.snapshot = Self.makeSnapshot(
            revision: revision,
            snapshot: snapshot,
            selectedNodeID: selectedNodeID
        )
        return DOMTreeRenderInvalidation(
            kind: .root,
            revision: revision,
            startRevision: startRevision ?? revision,
            affectedNodeIDs: Set(snapshot.primaryRootID.map { [$0] } ?? []),
            parentNodeIDs: [],
            resetsLocalDocumentState: resetsLocalDocumentState
        )
    }

    func apply(
        _ delta: WebInspectorDOMTreeDelta,
        fromRevision: UInt64,
        toRevision: UInt64,
        selectedNodeID: DOMNode.ID?
    ) -> DOMTreeRenderInvalidation {
        precondition(snapshot.revision == fromRevision)
        precondition(toRevision == fromRevision + 1)

        var nodes = snapshot.nodesByID
        var affectedNodeIDs = delta.deletedRowIDs
        var parentNodeIDs: Set<DOMNode.ID> = []
        var kind: DOMTreeRenderInvalidation.Kind = .content

        for id in delta.deletedRowIDs {
            if let node = nodes.removeValue(forKey: id) {
                kind = .structure
                if let parentID = node.parentID {
                    parentNodeIDs.insert(parentID)
                }
            }
        }
        for row in delta.upsertedRows {
            let next = Self.makeNode(row)
            affectedNodeIDs.insert(row.id)
            if let previous = nodes.updateValue(next, forKey: row.id) {
                if previous.topology != next.topology {
                    kind = .structure
                    if let parentID = previous.parentID {
                        parentNodeIDs.insert(parentID)
                    }
                    if let parentID = next.parentID {
                        parentNodeIDs.insert(parentID)
                    }
                }
            } else {
                kind = .structure
                if let parentID = next.parentID {
                    parentNodeIDs.insert(parentID)
                }
            }
        }

        let rootID = delta.primaryRootChange?.rootID ?? snapshot.rootNodeID
        let rootChanged = delta.primaryRootChange != nil
        if rootChanged {
            kind = .root
        }
        snapshot = DOMTreeRenderSnapshot(
            revision: toRevision,
            rootNodeID: rootID,
            selectedNodeID: selectedNodeID,
            nodesByID: nodes
        )
        return DOMTreeRenderInvalidation(
            kind: kind,
            revision: toRevision,
            startRevision: fromRevision,
            affectedNodeIDs: affectedNodeIDs,
            parentNodeIDs: parentNodeIDs,
            resetsLocalDocumentState: rootChanged
        )
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

    private static func makeSnapshot(
        revision: UInt64,
        snapshot: WebInspectorDOMTreeSnapshot,
        selectedNodeID: DOMNode.ID?
    ) -> DOMTreeRenderSnapshot {
        DOMTreeRenderSnapshot(
            revision: revision,
            rootNodeID: snapshot.primaryRootID,
            selectedNodeID: selectedNodeID,
            nodesByID: snapshot.rowsByID.mapValues(makeNode)
        )
    }

    private static func makeNode(
        _ row: WebInspectorDOMTreeRow
    ) -> DOMTreeRenderSnapshot.Node {
        DOMTreeRenderSnapshot.Node(
            id: row.id,
            parentID: row.parentID,
            nodeName: row.nodeName,
            localName: row.localName,
            nodeValue: row.nodeValue,
            nodeType: row.nodeType,
            frameID: row.frameID,
            documentURL: row.documentURL,
            baseURL: row.baseURL,
            attributes: row.attributes,
            attributeList: row.attributeList,
            children: makeChildren(row.children),
            contentDocumentID: row.contentDocumentID,
            shadowRootIDs: row.shadowRootIDs,
            templateContentID: row.templateContentID,
            beforePseudoElementID: row.beforePseudoElementID,
            otherPseudoElementIDs: row.otherPseudoElementIDs,
            afterPseudoElementID: row.afterPseudoElementID,
            pseudoType: row.pseudoType,
            shadowRootType: row.shadowRootType
        )
    }

    private static func makeChildren(
        _ children: WebInspectorDOMTreeChildren
    ) -> DOMTreeRenderSnapshot.Node.Children {
        switch children {
        case let .unrequested(count):
            .unrequested(count: count)
        case let .loaded(ids):
            .loaded(ids)
        }
    }
}
#endif
