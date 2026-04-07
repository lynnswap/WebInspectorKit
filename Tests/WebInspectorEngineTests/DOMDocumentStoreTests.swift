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
    func stableBackendLookupIgnoresUnstableBackendIDCollisions() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [
                        makeNode(
                            localID: 7,
                            backendNodeID: 7,
                            backendNodeIDIsStable: false,
                            attributes: [.init(nodeId: 7, name: "id", value: "collision")]
                        ),
                        makeNode(
                            localID: 70,
                            backendNodeID: 7,
                            backendNodeIDIsStable: true,
                            attributes: [.init(nodeId: 7, name: "id", value: "stable")]
                        ),
                    ]
                )
            )
        )

        let resolvedNode = try! #require(model.node(stableBackendNodeID: 7))
        #expect(resolvedNode.localID == 70)
        #expect(resolvedNode.attributes.first(where: { $0.name == "id" })?.value == "stable")
    }

    @Test
    func replaceSubtreeUsesStableBackendFallbackWhenLocalIDsDrift() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [
                        makeNode(
                            localID: 7,
                            backendNodeID: 7,
                            backendNodeIDIsStable: false,
                            attributes: [.init(nodeId: 7, name: "id", value: "collision")]
                        ),
                        makeNode(
                            localID: 70,
                            backendNodeID: 7,
                            backendNodeIDIsStable: true,
                            attributes: [.init(nodeId: 7, name: "id", value: "stable")]
                        ),
                    ]
                )
            )
        )

        model.applyMutationBundle(
            .init(
                events: [
                    .replaceSubtree(
                        root: makeNode(
                            localID: 700,
                            backendNodeID: 7,
                            backendNodeIDIsStable: true,
                            attributes: [.init(nodeId: 7, name: "id", value: "replacement")]
                        )
                    )
                ]
            )
        )

        let root = try! #require(model.rootNode)
        #expect(root.children.count == 2)
        #expect(root.children.contains { $0.localID == 7 })
        #expect(root.children.contains { $0.localID == 700 })
        #expect(root.children.contains { $0.localID == 70 } == false)
        #expect(root.children.first(where: { $0.localID == 7 })?.attributes.first(where: { $0.name == "id" })?.value == "collision")
        #expect(root.children.first(where: { $0.localID == 700 })?.attributes.first(where: { $0.name == "id" })?.value == "replacement")
    }

    @Test
    func replaceSubtreeReplacesMatchingPlaceholderWhenStableBackendNodeArrives() {
        let model = DOMDocumentModel()
        model.replaceDocument(with: .init(root: makeNode(localID: 1)))
        model.applySelectionSnapshot(
            .init(
                localID: 42,
                backendNodeID: 77,
                backendNodeIDIsStable: false,
                preview: "<div id=\"placeholder\">",
                attributes: [],
                path: ["html", "body", "div"],
                selectorPath: "#placeholder",
                styleRevision: 0
            )
        )

        let placeholder = try! #require(model.node(localID: 42))
        #expect(placeholder.nodeName.isEmpty)

        model.applyMutationBundle(
            .init(
                events: [
                    .replaceSubtree(
                        root: makeNode(
                            localID: 700,
                            backendNodeID: 77,
                            backendNodeIDIsStable: true,
                            attributes: [.init(nodeId: 77, name: "id", value: "materialized")]
                        )
                    )
                ]
            )
        )

        #expect(model.node(localID: 42) == nil)
        let materialized = try! #require(model.node(localID: 700))
        #expect(materialized.backendNodeID == 77)
        #expect(materialized.backendNodeIDIsStable)
        #expect(model.node(stableBackendNodeID: 77)?.id == materialized.id)
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
    func selectionSnapshotWithoutBackendNodeIDKeepsPlaceholderBackendNodeIDUnset() {
        let model = DOMDocumentModel()
        model.applySelectionSnapshot(
            .init(
                localID: 42,
                preview: "<div id=\"target\">",
                attributes: [],
                path: ["html", "body", "div"],
                selectorPath: "#target",
                styleRevision: 0
            )
        )

        let initialSelection = try! #require(model.selectedNode)
        #expect(initialSelection.backendNodeID == nil)
    }

    @Test
    func selectionSnapshotPlaceholderPreservesProvidedBackendNodeID() {
        let model = DOMDocumentModel()
        model.applySelectionSnapshot(
            .init(
                localID: 42,
                backendNodeID: 77,
                preview: "<div id=\"target\">",
                attributes: [],
                path: ["html", "body", "div"],
                selectorPath: "#target",
                styleRevision: 0
            )
        )

        let selectedNode = try! #require(model.selectedNode)
        #expect(selectedNode.backendNodeID == 77)
    }

    @Test
    func selectionSnapshotWithoutBackendNodeIDPreservesExistingLiveBackendNodeID() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 42, attributes: [.init(nodeId: 77, name: "id", value: "target")])]),
                selectedLocalID: 42
            )
        )

        model.applySelectionSnapshot(
            .init(
                localID: 42,
                backendNodeID: nil,
                preview: "<div id=\"target\">",
                attributes: [],
                path: ["html", "body", "div"],
                selectorPath: "#target",
                styleRevision: 1
            )
        )

        let updatedSelection = try! #require(model.selectedNode)
        #expect(updatedSelection.backendNodeID == 42)
        #expect(updatedSelection.styleRevision == 1)
    }

    @Test
    func clearingSelectionDropsSelectionProjectionStateFromPreviouslySelectedNode() {
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
                styleRevision: 3
            )
        )

        let selectedNode = try! #require(model.selectedNode)
        model.applySelectionSnapshot(nil)

        #expect(model.selectedNode == nil)
        #expect(selectedNode.preview.isEmpty)
        #expect(selectedNode.path.isEmpty)
        #expect(selectedNode.selectorPath.isEmpty)
        #expect(selectedNode.styleRevision == 0)
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

    @Test
    @available(*, deprecated, message: "Legacy API compatibility coverage.")
    func deprecatedDocumentStoreAliasesForwardToCurrentProperties() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 2)]),
                selectedLocalID: 2
            )
        )

        #expect(legacyRootEntry(in: model)?.backendNodeID == model.rootNode?.backendNodeID)
        #expect(legacySelectedEntry(in: model)?.backendNodeID == model.selectedNode?.backendNodeID)
    }

    private func makeNode(
        localID: UInt64,
        backendNodeID: Int? = nil,
        backendNodeIDIsStable: Bool? = nil,
        attributes: [DOMAttribute] = [],
        children: [DOMGraphNodeDescriptor] = [],
        nodeType: Int = 1,
        nodeName: String = "DIV",
        localName: String = "div",
        nodeValue: String = ""
    ) -> DOMGraphNodeDescriptor {
        DOMGraphNodeDescriptor(
            localID: localID,
            backendNodeID: backendNodeID ?? Int(localID),
            backendNodeIDIsStable: backendNodeIDIsStable,
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

@available(*, deprecated, message: "Legacy API compatibility coverage.")
@MainActor
private func legacyRootEntry(in model: DOMDocumentStore) -> DOMNodeModel? {
    model.rootEntry
}

@available(*, deprecated, message: "Legacy API compatibility coverage.")
@MainActor
private func legacySelectedEntry(in model: DOMDocumentStore) -> DOMNodeModel? {
    model.selectedEntry
}
