import Testing
@testable import WebInspectorEngine

@MainActor
struct DOMDocumentStoreTests {
    @Test
    func selectionIsPreservedWhenSelectedNodeIsRebuiltWithSameID() {
        let store = DOMDocumentStore()
        store.applySnapshot(
            .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 2)])
            )
        )
        store.select(localID: 2)
        let originalSelection = store.selectedEntry

        store.applyMutationBundle(
            .init(
                events: [
                    .setChildNodes(
                        parentLocalID: 1,
                        nodes: [makeNode(localID: 2, attributes: [DOMAttribute(nodeId: 2, name: "class", value: "updated")])]
                    ),
                ]
            )
        )

        #expect(store.selectedEntry?.id.localID == 2)
        #expect(store.selectedEntry !== originalSelection)
        #expect(store.selectedEntry?.attributes.first?.value == "updated")
    }

    @Test
    func selectionClearsWhenSelectedNodeIsRemoved() {
        let store = DOMDocumentStore()
        store.applySnapshot(
            .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 2)])
            )
        )
        store.select(localID: 2)

        store.applyMutationBundle(
            .init(
                events: [
                    .childNodeRemoved(parentLocalID: 1, nodeLocalID: 2),
                ]
            )
        )

        #expect(store.selectedEntry == nil)
    }

    @Test
    func resetContentsForFreshReloadClearsEntriesAndSelection() {
        let store = DOMDocumentStore()
        store.applySnapshot(.init(root: makeNode(localID: 1)))
        store.select(localID: 1)

        store.resetContentsForFreshReload()

        #expect(store.entriesByID.isEmpty)
        #expect(store.rootID == nil)
        #expect(store.selectedEntry == nil)
    }

    @Test
    func clearingSelectionAlsoClearsMatchedStylesOnPreviouslySelectedEntry() {
        let store = DOMDocumentStore()
        store.applySelectionSnapshot(
            .init(
                localID: 42,
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

        #expect(store.selectedEntry == nil)
        #expect(store.entry(forLocalID: 42)?.matchedStyles.isEmpty == true)
        #expect(store.entry(forLocalID: 42)?.matchedStylesTruncated == false)
        #expect(store.entry(forLocalID: 42)?.blockedStylesheetCount == 0)
        #expect(store.entry(forLocalID: 42)?.isLoadingMatchedStyles == false)
    }

    @Test
    func replaceSubtreeForUnknownNodeDoesNotRewriteRoot() {
        let store = DOMDocumentStore()
        store.applySnapshot(
            .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 2)])
            )
        )

        store.applyMutationBundle(
            .init(
                events: [
                    .replaceSubtree(root: makeNode(localID: 999, children: [makeNode(localID: 1000)])),
                ]
            )
        )

        #expect(store.rootID?.localID == 1)
        #expect(store.entry(forLocalID: 2) != nil)
        #expect(store.entry(forLocalID: 999) == nil)
    }

    @Test
    func replaceSubtreeForRootKeepsRootIDAndReplacesChildren() {
        let store = DOMDocumentStore()
        store.applySnapshot(
            .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 2)])
            )
        )

        store.applyMutationBundle(
            .init(
                events: [
                    .replaceSubtree(root: makeNode(localID: 1, children: [makeNode(localID: 3)])),
                ]
            )
        )

        #expect(store.rootID?.localID == 1)
        #expect(store.entry(forLocalID: 2) == nil)
        #expect(store.entry(forLocalID: 3) != nil)
        #expect(store.entry(forLocalID: 1)?.children.map(\.id.localID) == [3])
    }

    @Test
    func childNodeInsertedWithUnknownPreviousSiblingAppendsToEnd() {
        let store = DOMDocumentStore()
        store.applySnapshot(
            .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 2), makeNode(localID: 3)])
            )
        )

        store.applyMutationBundle(
            .init(
                events: [
                    .childNodeInserted(
                        parentLocalID: 1,
                        previousLocalID: 999,
                        node: makeNode(localID: 4)
                    ),
                ]
            )
        )

        let childOrder = store.entry(forLocalID: 1)?.children.map(\.id.localID) ?? []
        #expect(childOrder == [2, 3, 4])
    }

    @Test
    func childNodeInsertedIncrementsChildCountForPartiallyLoadedParent() {
        let store = DOMDocumentStore()
        store.applySnapshot(
            .init(
                root: makeNode(
                    localID: 1,
                    childCount: 10,
                    children: [makeNode(localID: 2)]
                )
            )
        )

        store.applyMutationBundle(
            .init(
                events: [
                    .childNodeInserted(
                        parentLocalID: 1,
                        previousLocalID: 2,
                        node: makeNode(localID: 3)
                    ),
                ]
            )
        )

        #expect(store.entry(forLocalID: 1)?.childCount == 11)
        #expect(store.entry(forLocalID: 1)?.children.map(\.id.localID) == [2, 3])
    }

    @Test
    func childNodeInsertedWithZeroPreviousSiblingPrependsToStart() {
        let store = DOMDocumentStore()
        store.applySnapshot(
            .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 2), makeNode(localID: 3)])
            )
        )

        store.applyMutationBundle(
            .init(
                events: [
                    .childNodeInserted(
                        parentLocalID: 1,
                        previousLocalID: 0,
                        node: makeNode(localID: 4)
                    ),
                ]
            )
        )

        let childOrder = store.entry(forLocalID: 1)?.children.map(\.id.localID) ?? []
        #expect(childOrder == [4, 2, 3])
    }

    @Test
    func replaceSubtreeForDetachedPlaceholderDoesNotPromotePlaceholderToRoot() {
        let store = DOMDocumentStore()
        store.applySnapshot(
            .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 2)])
            )
        )
        store.applySelectionSnapshot(
            .init(
                localID: 99,
                preview: "<div id='detached'>",
                attributes: [],
                path: [],
                selectorPath: "#detached",
                styleRevision: 0
            )
        )

        store.applyMutationBundle(
            .init(
                events: [
                    .replaceSubtree(root: makeNode(localID: 99, children: [makeNode(localID: 100)])),
                ]
            )
        )

        #expect(store.rootID?.localID == 1)
        #expect(store.entry(forLocalID: 2) != nil)
        #expect(store.entry(forLocalID: 99) != nil)
        #expect(store.entry(forLocalID: 99)?.parent == nil)
    }

    @Test
    func replaceSubtreeUnderPartiallyLoadedParentKeepsChildCount() {
        let store = DOMDocumentStore()
        store.applySnapshot(
            .init(
                root: makeNode(
                    localID: 1,
                    childCount: 10,
                    children: [makeNode(localID: 2)]
                )
            )
        )

        store.applyMutationBundle(
            .init(
                events: [
                    .replaceSubtree(
                        root: makeNode(localID: 2, attributes: [DOMAttribute(nodeId: 2, name: "class", value: "replaced")])
                    ),
                ]
            )
        )

        #expect(store.entry(forLocalID: 1)?.childCount == 10)
        #expect(store.entry(forLocalID: 1)?.children.map(\.id.localID) == [2])
        #expect(store.entry(forLocalID: 2)?.attributes.first?.value == "replaced")
    }

    private func makeNode(
        localID: UInt64,
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
            localID: localID,
            backendNodeID: localID <= UInt64(Int.max) ? Int(localID) : nil,
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
