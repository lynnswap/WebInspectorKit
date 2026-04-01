import Testing
@testable import WebInspectorEngine

@MainActor
struct DOMDocumentModelTests {
    @Test
    func sameLocalIDReprojectionPreservesNodeIdentity() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 7)]),
                selectedLocalID: 7
            )
        )

        let initialID = try! #require(model.selectedNode?.id)

        model.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [makeNode(localID: 7, attributes: [.init(nodeId: 7, name: "class", value: "updated")])]
                ),
                selectedLocalID: 7
            ),
            isFreshDocument: false
        )

        let reprojected = try! #require(model.selectedNode)
        #expect(reprojected.id == initialID)
        #expect(reprojected.attributes.first(where: { $0.name == "class" })?.value == "updated")
    }

    @Test
    func freshDocumentChangesNodeIdentity() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 7)]),
                selectedLocalID: 7
            )
        )

        let initialID = try! #require(model.selectedNode?.id)

        model.replaceDocument(
            with: .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 7)]),
                selectedLocalID: 7
            ),
            isFreshDocument: true
        )

        let refreshedID = try! #require(model.selectedNode?.id)
        #expect(refreshedID != initialID)
    }

    @Test
    func selectionClearsWhenSelectedNodeIsRemoved() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 2)]),
                selectedLocalID: 2
            )
        )

        model.applyMutationBundle(.init(events: [.childNodeRemoved(parentLocalID: 1, nodeLocalID: 2)]))

        #expect(model.selectedNode == nil)
    }

    @Test
    func selectionTracksReplacementOfSameLocalID() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [makeNode(localID: 2, attributes: [.init(nodeId: 2, name: "class", value: "before")])]
                ),
                selectedLocalID: 2
            )
        )

        let originalSelection = try! #require(model.selectedNode)
        model.applyMutationBundle(
            .init(
                events: [
                    .setChildNodes(
                        parentLocalID: 1,
                        nodes: [makeNode(localID: 2, attributes: [.init(nodeId: 2, name: "class", value: "after")])]
                    )
                ]
            )
        )

        let replacement = try! #require(model.selectedNode)
        #expect(replacement !== originalSelection)
        #expect(replacement.id == originalSelection.id)
        #expect(replacement.attributes.first(where: { $0.name == "class" })?.value == "after")
    }

    @Test
    func replaceSubtreeSeedsRootWhenDocumentIsEmpty() {
        let model = DOMDocumentModel()

        model.applyMutationBundle(
            .init(events: [.replaceSubtree(root: makeNode(localID: 1, children: [makeNode(localID: 2)]))])
        )

        #expect(model.rootNode?.backendNodeID == 1)
        #expect(model.rootNode?.children.first?.backendNodeID == 2)
    }

    @Test
    func selectionSnapshotUpdatesDisplayedMetadata() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 42)]),
                selectedLocalID: 42
            )
        )

        model.applySelectionSnapshot(
            .init(
                localID: 42,
                preview: "<div id=\"target\">",
                attributes: [.init(nodeId: 42, name: "id", value: "target")],
                path: ["html", "body", "div"],
                selectorPath: "#target",
                styleRevision: 2
            )
        )

        let selectedNode = try! #require(model.selectedNode)
        #expect(selectedNode.preview == "<div id=\"target\">")
        #expect(selectedNode.selectorPath == "#target")
        #expect(selectedNode.styleRevision == 2)
        #expect(selectedNode.attributes.first(where: { $0.name == "id" })?.value == "target")
    }

    @Test
    func clearDocumentDropsRootAndSelection() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 2)]),
                selectedLocalID: 2
            )
        )

        model.clearDocument()

        #expect(model.rootNode == nil)
        #expect(model.selectedNode == nil)
        #expect(model.errorMessage == nil)
    }

    private func makeNode(
        localID: UInt64,
        attributes: [DOMAttribute] = [],
        children: [DOMGraphNodeDescriptor] = [],
        nodeType: Int = 1,
        nodeName: String = "DIV",
        localName: String = "div",
        nodeValue: String = ""
    ) -> DOMGraphNodeDescriptor {
        DOMGraphNodeDescriptor(
            localID: localID,
            backendNodeID: Int(localID),
            nodeType: nodeType,
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            attributes: attributes,
            childCount: children.count,
            layoutFlags: [],
            isRendered: true,
            children: children
        )
    }
}
