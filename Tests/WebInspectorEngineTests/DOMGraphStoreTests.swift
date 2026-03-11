import Testing
@testable import WebInspectorEngine

@MainActor
struct DOMGraphStoreTests {
    @Test
    func selectionIsPreservedWhenSelectedNodeIsRebuiltWithSameID() {
        let store = DOMGraphStore()
        store.applySnapshot(
            .init(
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 2)])
            )
        )
        store.select(nodeID: 2)

        store.applyMutationBundle(
            .init(
                events: [
                    .setChildNodes(
                        parentNodeID: 1,
                        nodes: [makeNode(nodeID: 2, attributes: [DOMAttribute(nodeId: 2, name: "class", value: "updated")])]
                    ),
                ]
            )
        )

        #expect(store.selectedID?.nodeID == 2)
        #expect(store.selectedEntry?.id.nodeID == 2)
        #expect(store.selectedEntry?.attributes.first?.value == "updated")
    }

    @Test
    func selectionClearsWhenSelectedNodeIsRemoved() {
        let store = DOMGraphStore()
        store.applySnapshot(
            .init(
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 2)])
            )
        )
        store.select(nodeID: 2)

        store.applyMutationBundle(
            .init(
                events: [
                    .childNodeRemoved(parentNodeID: 1, nodeID: 2),
                ]
            )
        )

        #expect(store.selectedID == nil)
        #expect(store.selectedEntry == nil)
    }

    @Test
    func documentUpdatedInMutationBundleResetsGenerationAndSelection() {
        let store = DOMGraphStore()
        let initialGeneration = store.documentGeneration
        store.applySnapshot(.init(root: makeNode(nodeID: 1)))
        store.select(nodeID: 1)

        store.applyMutationBundle(
            .init(
                events: [
                    .documentUpdated,
                ]
            )
        )

        #expect(store.documentGeneration == initialGeneration + 1)
        #expect(store.entriesByID.isEmpty)
        #expect(store.rootID == nil)
        #expect(store.selectedID == nil)
    }

    @Test
    func clearingSelectionRetainsStyleStateOnPreviouslySelectedEntry() {
        let store = DOMGraphStore()
        store.applySnapshot(.init(root: makeNode(nodeID: 42)))
        store.applySelectionSnapshot(
            .init(
                nodeID: 42,
                preview: "<div>",
                attributes: [],
                path: ["html", "body", "div"],
                selectorPath: "div",
                styleRevision: 1
            )
        )
        store.applyMatchedStyles(
            .init(
                nodeId: 42,
                rules: [
                    .init(
                        origin: .author,
                        selectorText: ".target",
                        declarations: [.init(name: "color", value: "red", important: false)],
                        sourceLabel: "<style>"
                    ),
                ],
                truncated: true,
                blockedStylesheetCount: 2
            ),
            for: 42
        )

        store.applySelectionSnapshot(nil)

        #expect(store.selectedID == nil)
        #expect(store.entry(forNodeID: 42)?.matchedStyles.isEmpty == false)
        #expect(store.entry(forNodeID: 42)?.matchedStylesTruncated == true)
        #expect(store.entry(forNodeID: 42)?.blockedStylesheetCount == 2)
        #expect(store.entry(forNodeID: 42)?.isLoadingMatchedStyles == false)
    }

    @Test
    func unknownSelectionDoesNotCreatePlaceholderEntry() {
        let store = DOMGraphStore()
        store.applySnapshot(.init(root: makeNode(nodeID: 1)))

        let applied = store.applySelectionSnapshot(
            .init(
                nodeID: 99,
                preview: "<div id='detached'>",
                attributes: [],
                path: [],
                selectorPath: "#detached",
                styleRevision: 0
            )
        )

        #expect(applied == false)
        #expect(store.selectedID == nil)
        #expect(store.entry(forNodeID: 99) == nil)
    }

    @Test
    func replaceSubtreeForUnknownNodeDoesNotRewriteRoot() {
        let store = DOMGraphStore()
        store.applySnapshot(
            .init(
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 2)])
            )
        )

        store.applyMutationBundle(
            .init(
                events: [
                    .replaceSubtree(root: makeNode(nodeID: 999, children: [makeNode(nodeID: 1000)])),
                ]
            )
        )

        #expect(store.rootID?.nodeID == 1)
        #expect(store.entry(forNodeID: 2) != nil)
        #expect(store.entry(forNodeID: 999) == nil)
    }

    @Test
    func replaceSubtreeForRootKeepsRootIDAndReplacesChildren() {
        let store = DOMGraphStore()
        store.applySnapshot(
            .init(
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 2)])
            )
        )

        store.applyMutationBundle(
            .init(
                events: [
                    .replaceSubtree(root: makeNode(nodeID: 1, children: [makeNode(nodeID: 3)])),
                ]
            )
        )

        #expect(store.rootID?.nodeID == 1)
        #expect(store.entry(forNodeID: 2) == nil)
        #expect(store.entry(forNodeID: 3) != nil)
        #expect(store.entry(forNodeID: 1)?.children.map(\.id.nodeID) == [3])
    }

    @Test
    func childNodeInsertedWithUnknownPreviousSiblingAppendsToEnd() {
        let store = DOMGraphStore()
        store.applySnapshot(
            .init(
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 2), makeNode(nodeID: 3)])
            )
        )

        store.applyMutationBundle(
            .init(
                events: [
                    .childNodeInserted(
                        parentNodeID: 1,
                        previousNodeID: 999,
                        node: makeNode(nodeID: 4)
                    ),
                ]
            )
        )

        let childOrder = store.entry(forNodeID: 1)?.children.map(\.id.nodeID) ?? []
        #expect(childOrder == [2, 3, 4])
    }

    @Test
    func childNodeInsertedIncrementsChildCountForPartiallyLoadedParent() {
        let store = DOMGraphStore()
        store.applySnapshot(
            .init(
                root: makeNode(
                    nodeID: 1,
                    childCount: 10,
                    children: [makeNode(nodeID: 2)]
                )
            )
        )

        store.applyMutationBundle(
            .init(
                events: [
                    .childNodeInserted(
                        parentNodeID: 1,
                        previousNodeID: 2,
                        node: makeNode(nodeID: 3)
                    ),
                ]
            )
        )

        #expect(store.entry(forNodeID: 1)?.childCount == 11)
        #expect(store.entry(forNodeID: 1)?.children.map(\.id.nodeID) == [2, 3])
    }

    @Test
    func childNodeInsertedWithZeroPreviousSiblingPrependsToStart() {
        let store = DOMGraphStore()
        store.applySnapshot(
            .init(
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 2), makeNode(nodeID: 3)])
            )
        )

        store.applyMutationBundle(
            .init(
                events: [
                    .childNodeInserted(
                        parentNodeID: 1,
                        previousNodeID: 0,
                        node: makeNode(nodeID: 4)
                    ),
                ]
            )
        )

        let childOrder = store.entry(forNodeID: 1)?.children.map(\.id.nodeID) ?? []
        #expect(childOrder == [4, 2, 3])
    }

    @Test
    func replaceSubtreeUnderPartiallyLoadedParentKeepsChildCount() {
        let store = DOMGraphStore()
        store.applySnapshot(
            .init(
                root: makeNode(
                    nodeID: 1,
                    childCount: 10,
                    children: [makeNode(nodeID: 2)]
                )
            )
        )

        store.applyMutationBundle(
            .init(
                events: [
                    .replaceSubtree(
                        root: makeNode(nodeID: 2, attributes: [DOMAttribute(nodeId: 2, name: "class", value: "replaced")])
                    ),
                ]
            )
        )

        #expect(store.entry(forNodeID: 1)?.childCount == 10)
        #expect(store.entry(forNodeID: 1)?.children.map(\.id.nodeID) == [2])
        #expect(store.entry(forNodeID: 2)?.attributes.first?.value == "replaced")
    }

    private func makeNode(
        nodeID: Int,
        nodeType: Int = 1,
        nodeName: String = "DIV",
        localName: String = "div",
        nodeValue: String = "",
        attributes: [DOMAttribute] = [],
        childCount: Int? = nil,
        layoutFlags: [String] = [],
        isRendered: Bool = true,
        children: [DOMGraphNodeDescriptor] = []
    ) -> DOMGraphNodeDescriptor {
        DOMGraphNodeDescriptor(
            nodeID: nodeID,
            nodeType: nodeType,
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            attributes: attributes,
            childCount: childCount ?? children.count,
            layoutFlags: layoutFlags,
            isRendered: isRendered,
            children: children
        )
    }
}
