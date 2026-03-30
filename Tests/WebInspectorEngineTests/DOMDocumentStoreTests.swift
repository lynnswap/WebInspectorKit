import Testing
@testable import WebInspectorEngine

@MainActor
struct DOMDocumentStoreTests {
    @Test
    func selectionIsPreservedWhenSelectedNodeIsRebuiltWithSameLocalID() {
        let store = DOMDocumentStore()
        replaceDocument(
            in: store,
            root: makeNode(localID: 1, children: [makeNode(localID: 2)]),
            selectedLocalID: 2
        )
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

        #expect(store.selectedEntry?.backendNodeID == 2)
        #expect(store.selectedEntry !== originalSelection)
        #expect(store.selectedEntry?.attributes.first?.value == "updated")
    }

    @Test
    func selectionClearsWhenSelectedNodeIsRemoved() {
        let store = DOMDocumentStore()
        replaceDocument(
            in: store,
            root: makeNode(localID: 1, children: [makeNode(localID: 2)]),
            selectedLocalID: 2
        )

        store.applyMutationBundle(
            .init(events: [.childNodeRemoved(parentLocalID: 1, nodeLocalID: 2)])
        )

        #expect(store.selectedEntry == nil)
    }

    @Test
    func clearDocumentClearsRootAndSelection() {
        let store = DOMDocumentStore()
        replaceDocument(
            in: store,
            root: makeNode(localID: 1),
            selectedLocalID: 1
        )

        store.clearDocument()

        #expect(store.rootEntry == nil)
        #expect(store.selectedEntry == nil)
        #expect(store.errorMessage == nil)
    }

    @Test
    func clearedDocumentCanSeedPlaceholderRootFromSetChildNodes() {
        let store = DOMDocumentStore()
        replaceDocument(
            in: store,
            root: makeNode(localID: 1, children: [makeNode(localID: 2)]),
            selectedLocalID: 2
        )

        store.clearDocument()
        store.applyMutationBundle(
            .init(
                events: [
                    .setChildNodes(
                        parentLocalID: 1,
                        nodes: [makeNode(localID: 3)]
                    ),
                ]
            )
        )

        #expect(store.rootEntry?.backendNodeID == 1)
        #expect(childNodeIDs(of: store.rootEntry) == [3])
        #expect(store.selectedEntry == nil)
    }

    @Test
    func setChildNodesSeedsRootEvenWhenDetachedSelectionPlaceholderExists() {
        let store = DOMDocumentStore()

        store.applySelectionSnapshot(
            .init(
                localID: 2,
                preview: "<span>",
                attributes: [],
                path: ["html", "body", "span"],
                selectorPath: "span",
                styleRevision: 1
            )
        )

        store.applyMutationBundle(
            .init(
                events: [
                    .setChildNodes(
                        parentLocalID: 1,
                        nodes: [makeNode(localID: 2)]
                    ),
                ]
            )
        )

        #expect(store.rootEntry?.backendNodeID == 1)
        #expect(childNodeIDs(of: store.rootEntry) == [2])
        #expect(store.selectedEntry?.backendNodeID == 2)
        #expect(store.selectedEntry?.parent === store.rootEntry)
    }

    @Test
    func clearedDocumentCanSeedNewRootFromReplaceSubtree() {
        let store = DOMDocumentStore()
        replaceDocument(
            in: store,
            root: makeNode(localID: 1, children: [makeNode(localID: 2)])
        )

        store.clearDocument()
        store.applyMutationBundle(
            .init(
                events: [
                    .replaceSubtree(
                        root: makeNode(
                            localID: 10,
                            nodeName: "HTML",
                            localName: "html",
                            children: [makeNode(localID: 11)]
                        )
                    ),
                ]
            )
        )

        #expect(store.rootEntry?.backendNodeID == 10)
        #expect(childNodeIDs(of: store.rootEntry) == [11])
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
        let selectedEntry = try! #require(store.selectedEntry)
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
            for: selectedEntry
        )

        store.applySelectionSnapshot(nil)

        #expect(store.selectedEntry == nil)
        #expect(selectedEntry.matchedStyles.isEmpty == true)
        #expect(selectedEntry.matchedStylesTruncated == false)
        #expect(selectedEntry.blockedStylesheetCount == 0)
        #expect(selectedEntry.isLoadingMatchedStyles == false)
    }

    @Test
    func replaceSubtreeForUnknownNodeDoesNotRewriteRoot() {
        let store = DOMDocumentStore()
        replaceDocument(
            in: store,
            root: makeNode(localID: 1, children: [makeNode(localID: 2)])
        )

        store.applyMutationBundle(
            .init(events: [.replaceSubtree(root: makeNode(localID: 999, children: [makeNode(localID: 1000)]))])
        )

        #expect(store.rootEntry?.backendNodeID == 1)
        #expect(findEntry(backendNodeID: 2, in: store.rootEntry) != nil)
        #expect(findEntry(backendNodeID: 999, in: store.rootEntry) == nil)
    }

    @Test
    func replaceSubtreeForRootReplacesChildren() {
        let store = DOMDocumentStore()
        replaceDocument(
            in: store,
            root: makeNode(localID: 1, children: [makeNode(localID: 2)])
        )

        store.applyMutationBundle(
            .init(events: [.replaceSubtree(root: makeNode(localID: 1, children: [makeNode(localID: 3)]))])
        )

        #expect(store.rootEntry?.backendNodeID == 1)
        #expect(findEntry(backendNodeID: 2, in: store.rootEntry) == nil)
        #expect(findEntry(backendNodeID: 3, in: store.rootEntry) != nil)
        #expect(childNodeIDs(of: store.rootEntry) == [3])
    }

    @Test
    func childNodeInsertedWithUnknownPreviousSiblingAppendsToEnd() {
        let store = DOMDocumentStore()
        replaceDocument(
            in: store,
            root: makeNode(localID: 1, children: [makeNode(localID: 2), makeNode(localID: 3)])
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

        #expect(childNodeIDs(of: store.rootEntry) == [2, 3, 4])
    }

    @Test
    func childNodeInsertedIncrementsChildCountForPartiallyLoadedParent() {
        let store = DOMDocumentStore()
        replaceDocument(
            in: store,
            root: makeNode(localID: 1, childCount: 10, children: [makeNode(localID: 2)])
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

        #expect(store.rootEntry?.childCount == 11)
        #expect(childNodeIDs(of: store.rootEntry) == [2, 3])
    }

    @Test
    func childNodeInsertedWithZeroPreviousSiblingPrependsToStart() {
        let store = DOMDocumentStore()
        replaceDocument(
            in: store,
            root: makeNode(localID: 1, children: [makeNode(localID: 2), makeNode(localID: 3)])
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

        #expect(childNodeIDs(of: store.rootEntry) == [4, 2, 3])
    }

    @Test
    func replaceSubtreeForDetachedPlaceholderDoesNotPromotePlaceholderToRoot() {
        let store = DOMDocumentStore()
        replaceDocument(
            in: store,
            root: makeNode(localID: 1, children: [makeNode(localID: 2)])
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
            .init(events: [.replaceSubtree(root: makeNode(localID: 99, children: [makeNode(localID: 100)]))])
        )

        #expect(store.rootEntry?.backendNodeID == 1)
        #expect(findEntry(backendNodeID: 2, in: store.rootEntry) != nil)
        let detachedEntry = try! #require(store.selectedEntry)
        #expect(detachedEntry.parent == nil)
    }

    @Test
    func replaceSubtreeSeedsRootWhenOnlyDetachedPlaceholderExists() {
        let store = DOMDocumentStore()
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
            .init(events: [.replaceSubtree(root: makeNode(localID: 1, children: [makeNode(localID: 2)]))])
        )

        #expect(store.rootEntry?.backendNodeID == 1)
        #expect(childNodeIDs(of: store.rootEntry) == [2])
    }

    @Test
    func replaceSubtreeUnderPartiallyLoadedParentKeepsChildCount() {
        let store = DOMDocumentStore()
        replaceDocument(
            in: store,
            root: makeNode(localID: 1, childCount: 10, children: [makeNode(localID: 2)])
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

        #expect(store.rootEntry?.childCount == 10)
        #expect(childNodeIDs(of: store.rootEntry) == [2])
        #expect(findEntry(backendNodeID: 2, in: store.rootEntry)?.attributes.first?.value == "replaced")
    }

    private func replaceDocument(
        in store: DOMDocumentStore,
        root: DOMGraphNodeDescriptor,
        selectedLocalID: UInt64? = nil
    ) {
        store.replaceDocument(
            with: .init(root: root, selectedLocalID: selectedLocalID)
        )
    }

    private func childNodeIDs(of entry: DOMEntry?) -> [Int] {
        entry?.children.compactMap(\.backendNodeID) ?? []
    }

    private func findEntry(backendNodeID: Int, in root: DOMEntry?) -> DOMEntry? {
        guard let root else {
            return nil
        }
        if root.backendNodeID == backendNodeID {
            return root
        }
        for child in root.children {
            if let match = findEntry(backendNodeID: backendNodeID, in: child) {
                return match
            }
        }
        return nil
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
