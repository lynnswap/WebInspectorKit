import Testing
@testable import WebInspectorEngine

@MainActor
struct DOMDocumentModelTests {
    @Test
    func sameNodeIDReprojectionPreservesNodeIdentity() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 7)]),
                selectedNodeID: 7
            )
        )

        let initialID = try! #require(model.selectedNode?.id)

        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [makeNode(nodeID: 7, attributes: [.init(nodeId: 7, name: "class", value: "updated")])]
                ),
                selectedNodeID: 7
            ),
            isFreshDocument: false
        )

        let reprojected = try! #require(model.selectedNode)
        #expect(reprojected.id == initialID)
        #expect(reprojected.attributes.first(where: { $0.name == "class" })?.value == "updated")
    }

    @Test
    func nonFreshRefreshReprojectsSelectionWhenNodeIDChangesAtSameTreePath() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [
                        makeNode(
                            nodeID: 7,
                            attributes: [.init(name: "id", value: "target")]
                        )
                    ]
                ),
                selectedNodeID: 7
            )
        )
        model.applySelectionSnapshot(
            .init(
                nodeID: 7,
                attributes: [.init(name: "id", value: "target")],
                path: ["div"],
                selectorPath: "#target",
                styleRevision: 3
            )
        )

        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [
                        makeNode(
                            nodeID: 8,
                            attributes: [.init(name: "id", value: "target")]
                        )
                    ]
                )
            ),
            isFreshDocument: false
        )

        let selectedNode = try! #require(model.selectedNode)
        #expect(selectedNode.nodeID == 8)
        #expect(selectedNode.selectorPath == "#target")
        #expect(selectedNode.path == ["div"])
        #expect(selectedNode.styleRevision == 3)
    }

    @Test
    func nonFreshRefreshDoesNotReuseStalePreviousNodeIDBeforeAnchor() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [
                        makeNode(
                            nodeID: 7,
                            attributes: [.init(name: "id", value: "target")]
                        )
                    ]
                ),
                selectedNodeID: 7
            )
        )
        model.applySelectionSnapshot(
            .init(
                nodeID: 7,
                attributes: [.init(name: "id", value: "target")],
                path: ["div"],
                selectorPath: "#target",
                styleRevision: 3
            )
        )

        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [
                        makeNode(
                            nodeID: 7,
                            attributes: [.init(name: "id", value: "inserted")]
                        ),
                        makeNode(
                            nodeID: 8,
                            attributes: [.init(name: "id", value: "target")]
                        ),
                    ]
                )
            ),
            isFreshDocument: false
        )

        let selectedNode = try! #require(model.selectedNode)
        #expect(selectedNode.nodeID == 8)
        #expect(selectedNode.attributes.first(where: { $0.name == "id" })?.value == "target")
        #expect(selectedNode.selectorPath == "#target")
    }

    @Test
    func freshDocumentChangesNodeIdentity() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 7)]),
                selectedNodeID: 7
            )
        )

        let initialID = try! #require(model.selectedNode?.id)

        model.replaceDocument(
            with: .init(
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 7)]),
                selectedNodeID: 7
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
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 2)]),
                selectedNodeID: 2
            )
        )

        model.applyMutationBundle(.init(events: [.childNodeRemoved(parentNodeID: 1, nodeNodeID: 2)]))

        #expect(model.selectedNode == nil)
    }

    @Test
    func selectionTracksReplacementOfSameNodeID() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [makeNode(nodeID: 2, attributes: [.init(nodeId: 2, name: "class", value: "before")])]
                ),
                selectedNodeID: 2
            )
        )

        let originalSelection = try! #require(model.selectedNode)
        model.applyMutationBundle(
            .init(
                events: [
                    .setChildNodes(
                        parentNodeID: 1,
                        nodes: [makeNode(nodeID: 2, attributes: [.init(nodeId: 2, name: "class", value: "after")])]
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
    func nestedDocumentRemainsChildOfFrameOwner() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [
                        makeNode(
                            nodeID: 20,
                            frameID: "frame-child",
                            contentDocument:
                                makeNode(
                                    nodeID: 24,
                                    frameID: "frame-child",
                                    children: [
                                        makeNode(
                                            nodeID: 26,
                                            attributes: [.init(nodeId: 26, name: "id", value: "frame-target")],
                                            nodeName: "BUTTON",
                                            localName: "button"
                                        )
                                    ],
                                    nodeType: 9,
                                    nodeName: "#document",
                                    localName: ""
                                ),
                            nodeName: "IFRAME",
                            localName: "iframe"
                        )
                    ],
                    nodeType: 9,
                    nodeName: "#document",
                    localName: ""
                )
            )
        )

        let iframeNode = try! #require(model.node(nodeID: 20))
        let nestedDocument = try! #require(iframeNode.children.first)
        let nestedButton = try! #require(nestedDocument.children.first)

        #expect(iframeNode.frameID == "frame-child")
        #expect(nestedDocument.nodeType == .document)
        #expect(nestedDocument.parent === iframeNode)
        #expect(nestedDocument.frameID == "frame-child")
        #expect(nestedButton.localName == "button")
    }

    @Test
    func setChildNodesOnFrameOwnerDoesNotReplaceExistingContentDocument() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [
                        makeNode(
                            nodeID: 20,
                            frameID: "frame-child",
                            contentDocument:
                                makeNode(
                                    nodeID: 24,
                                    frameID: "frame-child",
                                    children: [
                                        makeNode(
                                            nodeID: 26,
                                            attributes: [.init(nodeId: 26, name: "id", value: "frame-target")],
                                            nodeName: "BUTTON",
                                            localName: "button"
                                        )
                                    ],
                                    nodeType: 9,
                                    nodeName: "#document",
                                    localName: ""
                                ),
                            nodeName: "IFRAME",
                            localName: "iframe"
                        )
                    ],
                    nodeType: 9,
                    nodeName: "#document",
                    localName: ""
                )
            )
        )

        model.applyMutationBundle(
            .init(
                events: [
                    .setChildNodes(parentNodeID: 20, nodes: [])
                ]
            )
        )

        let iframeNode = try! #require(model.node(nodeID: 20))
        let nestedDocument = try! #require(iframeNode.children.first)
        let nestedButton = try! #require(nestedDocument.children.first)

        #expect(iframeNode.childCount == 1)
        #expect(iframeNode.children.count == 1)
        #expect(nestedDocument.nodeID == 24)
        #expect(nestedDocument.parent === iframeNode)
        #expect(nestedButton.nodeID == 26)
    }

    @Test
    func setChildNodesOnFrameOwnerWithoutExplicitNodeTypesStillPreservesContentDocument() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [
                        makeNode(
                            nodeID: 20,
                            frameID: "frame-child",
                            attributes: [],
                            contentDocument:
                                makeNode(
                                    nodeID: 24,
                                    frameID: "frame-child",
                                    attributes: [],
                                    children: [
                                        makeNode(
                                            nodeID: 26,
                                            attributes: [.init(nodeId: 26, name: "id", value: "frame-target")],
                                            nodeType: 0,
                                            nodeName: "IMG",
                                            localName: "img"
                                        )
                                    ],
                                    nodeType: 0,
                                    nodeName: "#document",
                                    localName: ""
                                ),
                            nodeType: 0,
                            nodeName: "IFRAME",
                            localName: "iframe"
                        )
                    ],
                    nodeType: 9,
                    nodeName: "#document",
                    localName: ""
                )
            )
        )

        model.applyMutationBundle(
            .init(
                events: [
                    .setChildNodes(parentNodeID: 20, nodes: [])
                ]
            )
        )

        let iframeNode = try! #require(model.node(nodeID: 20))
        let nestedDocument = try! #require(model.node(nodeID: 24))
        let nestedImage = try! #require(model.node(nodeID: 26))

        #expect(iframeNode.children.count == 1)
        #expect(nestedDocument.parent === iframeNode)
        #expect(nestedImage.parent === nestedDocument)
    }

    @Test
    func setChildNodesOnlyReplacesRegularChildrenAndPreservesSpecialChildren() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [
                        makeNode(
                            nodeID: 10,
                            children: [makeNode(nodeID: 14, nodeName: "P", localName: "p")],
                            shadowRoots: [
                                makeNode(
                                    nodeID: 13,
                                    shadowRootType: "open",
                                    nodeType: 11,
                                    nodeName: "#document-fragment",
                                    localName: ""
                                )
                            ],
                            templateContent: makeNode(
                                nodeID: 11,
                                nodeType: 11,
                                nodeName: "#document-fragment",
                                localName: ""
                            ),
                            beforePseudoElement: makeNode(
                                nodeID: 12,
                                pseudoType: "before",
                                nodeName: "::before",
                                localName: ""
                            ),
                            afterPseudoElement: makeNode(
                                nodeID: 15,
                                pseudoType: "after",
                                nodeName: "::after",
                                localName: ""
                            )
                        )
                    ],
                    nodeType: 9,
                    nodeName: "#document",
                    localName: ""
                )
            )
        )

        model.applyMutationBundle(
            .init(events: [
                .setChildNodes(parentNodeID: 10, nodes: [makeNode(nodeID: 16, nodeName: "SPAN", localName: "span")])
            ])
        )

        let host = try! #require(model.node(nodeID: 10))
        #expect(host.regularChildren.map(\.nodeID) == [16])
        #expect(host.children.map(\.nodeID) == [13, 16])
        #expect(host.visibleDOMTreeChildren.map(\.nodeID) == [11, 12, 13, 16, 15])
        #expect(model.node(nodeID: 14) == nil)
        #expect(model.node(nodeID: 11) != nil)
        #expect(model.node(nodeID: 12) != nil)
        #expect(model.node(nodeID: 13) != nil)
        #expect(model.node(nodeID: 15) != nil)
    }

    @Test
    func emptySetChildNodesMarksRegularChildrenAsLoadedEmpty() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [
                        makeNode(
                            nodeID: 10,
                            children: [],
                            nodeName: "DIV",
                            localName: "div",
                            childCount: 1
                        )
                    ],
                    nodeType: 9,
                    nodeName: "#document",
                    localName: ""
                )
            )
        )

        let hostBeforeLoad = try! #require(model.node(nodeID: 10))
        #expect(hostBeforeLoad.hasUnloadedRegularChildren)

        model.applyMutationBundle(
            .init(events: [
                .setChildNodes(parentNodeID: 10, nodes: [])
            ])
        )

        let host = try! #require(model.node(nodeID: 10))
        #expect(host.childCount == 0)
        #expect(host.regularChildren.isEmpty)
        #expect(!host.hasUnloadedRegularChildren)
        #expect(host.visibleDOMTreeChildren.isEmpty)
    }

    @Test
    func childNodeInsertedUsesRegularChildOrderWithinVisibleWebKitOrder() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [
                        makeNode(
                            nodeID: 10,
                            children: [
                                makeNode(nodeID: 14, nodeName: "A", localName: "a"),
                                makeNode(nodeID: 16, nodeName: "C", localName: "c"),
                            ],
                            shadowRoots: [
                                makeNode(
                                    nodeID: 13,
                                    shadowRootType: "open",
                                    nodeType: 11,
                                    nodeName: "#document-fragment",
                                    localName: ""
                                )
                            ],
                            templateContent: makeNode(nodeID: 11, nodeType: 11, nodeName: "#document-fragment", localName: ""),
                            beforePseudoElement: makeNode(nodeID: 12, pseudoType: "before", nodeName: "::before", localName: ""),
                            afterPseudoElement: makeNode(nodeID: 17, pseudoType: "after", nodeName: "::after", localName: "")
                        )
                    ],
                    nodeType: 9,
                    nodeName: "#document",
                    localName: ""
                )
            )
        )

        model.applyMutationBundle(
            .init(events: [
                .childNodeInserted(
                    parentNodeID: 10,
                    previousNodeID: 14,
                    node: makeNode(nodeID: 15, nodeName: "B", localName: "b")
                )
            ])
        )

        let host = try! #require(model.node(nodeID: 10))
        #expect(host.regularChildren.map(\.nodeID) == [14, 15, 16])
        #expect(host.children.map(\.nodeID) == [13, 14, 15, 16])
        #expect(host.visibleDOMTreeChildren.map(\.nodeID) == [11, 12, 13, 14, 15, 16, 17])
    }

    @Test
    func childNodeInsertedWithoutPreviousSiblingAppendsToLoadedChildren() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [
                        makeNode(
                            nodeID: 10,
                            children: [
                                makeNode(nodeID: 14, nodeName: "A", localName: "a"),
                                makeNode(nodeID: 16, nodeName: "C", localName: "c"),
                            ],
                            nodeName: "DIV",
                            localName: "div"
                        )
                    ],
                    nodeType: 9,
                    nodeName: "#document",
                    localName: ""
                )
            )
        )

        model.applyMutationBundle(
            .init(events: [
                .childNodeInserted(
                    parentKey: domDocumentStoreTestKey(10),
                    previousSibling: .missing,
                    node: makeNode(nodeID: 15, nodeName: "B", localName: "b")
                )
            ])
        )

        let host = try! #require(model.node(nodeID: 10))
        #expect(host.regularChildren.map(\.nodeID) == [14, 16, 15])
    }

    @Test
    func childNodeInsertedWithZeroPreviousSiblingPrependsToLoadedChildren() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [
                        makeNode(
                            nodeID: 10,
                            children: [
                                makeNode(nodeID: 14, nodeName: "A", localName: "a"),
                                makeNode(nodeID: 16, nodeName: "C", localName: "c"),
                            ],
                            nodeName: "DIV",
                            localName: "div"
                        )
                    ],
                    nodeType: 9,
                    nodeName: "#document",
                    localName: ""
                )
            )
        )

        model.applyMutationBundle(
            .init(events: [
                .childNodeInserted(
                    parentKey: domDocumentStoreTestKey(10),
                    previousSibling: .firstChild,
                    node: makeNode(nodeID: 15, nodeName: "B", localName: "b")
                )
            ])
        )

        let host = try! #require(model.node(nodeID: 10))
        #expect(host.regularChildren.map(\.nodeID) == [15, 14, 16])
    }

    @Test
    func childNodeInsertedKeepsUnrequestedRegularChildrenUnrequested() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [
                        makeNode(
                            nodeID: 10,
                            children: [],
                            nodeName: "DIV",
                            localName: "div",
                            childCount: 2
                        )
                    ],
                    nodeType: 9,
                    nodeName: "#document",
                    localName: ""
                )
            )
        )

        let hostBeforeInsert = try! #require(model.node(nodeID: 10))
        #expect(hostBeforeInsert.hasUnloadedRegularChildren)
        #expect(hostBeforeInsert.regularChildCount == 2)

        model.applyMutationBundle(
            .init(events: [
                .childNodeInserted(
                    parentNodeID: 10,
                    previousNodeID: nil,
                    node: makeNode(nodeID: 14, nodeName: "SPAN", localName: "span")
                )
            ])
        )

        let host = try! #require(model.node(nodeID: 10))
        #expect(host.hasUnloadedRegularChildren)
        #expect(host.regularChildCount == 3)
        #expect(host.regularChildren.isEmpty)
        #expect(model.node(nodeID: 14) == nil)
    }

    @Test
    func childNodeRemovedDecrementsUnrequestedRegularChildCount() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [
                        makeNode(
                            nodeID: 10,
                            children: [],
                            nodeName: "DIV",
                            localName: "div",
                            childCount: 2
                        )
                    ],
                    nodeType: 9,
                    nodeName: "#document",
                    localName: ""
                )
            )
        )

        model.applyMutationBundle(
            .init(events: [
                .childNodeRemoved(
                    parentKey: domDocumentStoreTestKey(10),
                    nodeKey: domDocumentStoreTestKey(14)
                )
            ])
        )

        let host = try! #require(model.node(nodeID: 10))
        #expect(host.hasUnloadedRegularChildren)
        #expect(host.regularChildCount == 1)
        #expect(host.regularChildren.isEmpty)
        #expect(model.node(nodeID: 14) == nil)
    }

    @Test
    func childNodeCountUpdatedKeepsLoadedEmptyRegularChildrenLoaded() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [
                        makeNode(
                            nodeID: 10,
                            children: [],
                            nodeName: "DIV",
                            localName: "div",
                            childCount: 1
                        )
                    ],
                    nodeType: 9,
                    nodeName: "#document",
                    localName: ""
                )
            )
        )

        model.applyMutationBundle(
            .init(events: [
                .setChildNodes(parentNodeID: 10, nodes: []),
                .childNodeCountUpdated(
                    nodeKey: domDocumentStoreTestKey(10),
                    childCount: 1,
                    layoutFlags: nil,
                    isRendered: nil
                ),
                .childNodeInserted(
                    parentNodeID: 10,
                    previousNodeID: nil,
                    node: makeNode(nodeID: 14, nodeName: "SPAN", localName: "span")
                ),
            ])
        )

        let host = try! #require(model.node(nodeID: 10))
        #expect(!host.hasUnloadedRegularChildren)
        #expect(host.regularChildren.map(\.nodeID) == [14])
        #expect(host.childCount == 1)
        #expect(model.node(nodeID: 14) != nil)
    }

    @Test
    func childNodeRemovedCanRemoveSpecialChildren() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [
                        makeNode(
                            nodeID: 10,
                            children: [makeNode(nodeID: 14)],
                            beforePseudoElement: makeNode(
                                nodeID: 12,
                                pseudoType: "before",
                                nodeName: "::before",
                                localName: ""
                            )
                        )
                    ],
                    nodeType: 9,
                    nodeName: "#document",
                    localName: ""
                )
            )
        )

        model.applyMutationBundle(
            .init(events: [.childNodeRemoved(parentNodeID: 10, nodeNodeID: 12)])
        )

        let host = try! #require(model.node(nodeID: 10))
        #expect(host.beforePseudoElement == nil)
        #expect(host.visibleDOMTreeChildren.map(\.nodeID) == [14])
        #expect(model.node(nodeID: 12) == nil)
    }

    @Test
    func shadowRootPushedAddsSpecialChildWithoutChangingRegularChildCount() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [
                        makeNode(
                            nodeID: 10,
                            children: [makeNode(nodeID: 14)]
                        )
                    ],
                    nodeType: 9,
                    nodeName: "#document",
                    localName: ""
                )
            )
        )

        model.applyMutationBundle(
            .init(events: [
                .shadowRootPushed(
                    hostNodeID: 10,
                    root: makeNode(
                        nodeID: 13,
                        shadowRootType: "open",
                        nodeType: 11,
                        nodeName: "#shadow-root",
                        localName: ""
                    )
                )
            ])
        )

        let host = try! #require(model.node(nodeID: 10))
        #expect(host.regularChildren.map(\.nodeID) == [14])
        #expect(host.shadowRoots.map(\.nodeID) == [13])
        #expect(host.children.map(\.nodeID) == [13, 14])
        #expect(host.visibleDOMTreeChildren.map(\.nodeID) == [13, 14])
        #expect(host.childCount == 1)
        #expect(model.node(nodeID: 13) != nil)
    }

    @Test
    func pseudoElementAddedAndRemovedUpdatesSpecialBucket() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [makeNode(nodeID: 10)],
                    nodeType: 9,
                    nodeName: "#document",
                    localName: ""
                )
            )
        )

        model.applyMutationBundle(
            .init(events: [
                .pseudoElementAdded(
                    parentNodeID: 10,
                    node: makeNode(
                        nodeID: 12,
                        pseudoType: "before",
                        nodeName: "::before",
                        localName: ""
                    )
                )
            ])
        )

        var host = try! #require(model.node(nodeID: 10))
        #expect(host.beforePseudoElement?.nodeID == 12)
        #expect(host.visibleDOMTreeChildren.map(\.nodeID) == [12])
        #expect(model.node(nodeID: 12) != nil)

        model.applyMutationBundle(
            .init(events: [
                .pseudoElementRemoved(parentNodeID: 10, nodeNodeID: 12)
            ])
        )

        host = try! #require(model.node(nodeID: 10))
        #expect(host.beforePseudoElement == nil)
        #expect(host.visibleDOMTreeChildren.isEmpty)
        #expect(model.node(nodeID: 12) == nil)
    }

    @Test
    func nonBeforeAfterPseudoElementAddedAndRemovedIsRetained() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [makeNode(nodeID: 10)],
                    nodeType: 9,
                    nodeName: "#document",
                    localName: ""
                )
            )
        )

        model.applyMutationBundle(
            .init(events: [
                .pseudoElementAdded(
                    parentNodeID: 10,
                    node: makeNode(
                        nodeID: 12,
                        pseudoType: "marker",
                        nodeName: "::marker",
                        localName: ""
                    )
                )
            ])
        )

        var host = try! #require(model.node(nodeID: 10))
        #expect(host.otherPseudoElements.map(\.nodeID) == [12])
        #expect(host.otherPseudoElements.first?.pseudoType == "marker")
        #expect(host.visibleDOMTreeChildren.isEmpty)
        #expect(model.node(nodeID: 12) != nil)
        #expect(model.consumeRejectedStructuralMutationParentKeys().isEmpty)

        model.applyMutationBundle(
            .init(events: [
                .pseudoElementAdded(
                    parentNodeID: 10,
                    node: makeNode(
                        nodeID: 13,
                        pseudoType: "marker",
                        nodeName: "::marker",
                        localName: ""
                    )
                )
            ])
        )

        host = try! #require(model.node(nodeID: 10))
        #expect(host.otherPseudoElements.map(\.nodeID) == [13])
        #expect(model.node(nodeID: 12) == nil)
        #expect(model.node(nodeID: 13) != nil)

        model.applyMutationBundle(
            .init(events: [
                .pseudoElementRemoved(parentNodeID: 10, nodeNodeID: 13)
            ])
        )

        host = try! #require(model.node(nodeID: 10))
        #expect(host.otherPseudoElements.isEmpty)
        #expect(model.node(nodeID: 13) == nil)
    }

    @Test
    func childNodeRemovedCanRemoveContentDocumentFromFrameOwner() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    nodeID: 1,
                    children: [
                        makeNode(
                            nodeID: 10,
                            contentDocument: makeNode(
                                nodeID: 11,
                                nodeType: 9,
                                nodeName: "#document",
                                localName: ""
                            ),
                            nodeName: "IFRAME",
                            localName: "iframe"
                        )
                    ],
                    nodeType: 9,
                    nodeName: "#document",
                    localName: ""
                )
            )
        )

        model.applyMutationBundle(
            .init(events: [.childNodeRemoved(parentNodeID: 10, nodeNodeID: 11)])
        )

        let frameOwner = try! #require(model.node(nodeID: 10))
        #expect(frameOwner.contentDocument == nil)
        #expect(frameOwner.children.isEmpty)
        #expect(frameOwner.childCount == 0)
        #expect(model.node(nodeID: 11) == nil)
    }

    @Test
    func detachedRootsRemainQueryableWithoutReplacingMainRoot() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 2)])
            )
        )

        model.applyMutationBundle(
            .init(
                events: [
                    .setDetachedRoots(
                        nodes: [
                            makeNode(
                                nodeID: 900,
                                children: [
                                    makeNode(
                                        nodeID: 901,
                                        attributes: [.init(nodeId: 1093, name: "id", value: "detached-target")],
                                        nodeName: "IMG",
                                        localName: "img"
                                    )
                                ],
                                nodeType: 9,
                                nodeName: "#document",
                                localName: ""
                            )
                        ]
                    )
                ]
            )
        )

        let mainRoot = try! #require(model.rootNode)
        let detachedTarget = try! #require(model.node(nodeID: 901))

        #expect(mainRoot.nodeID == 1)
        #expect(mainRoot.children.first?.nodeID == 2)
        #expect(model.topLevelRoots().map(\.nodeID) == [1])
        #expect(model.detachedRootsForDiagnostics().map(\.nodeID) == [900])
        #expect(detachedTarget.nodeID == 901)
        #expect(detachedTarget.localName == "img")
        #expect(detachedTarget.parent?.nodeType == .document)
    }

    @Test
    func detachedRootUpdatesReplaceMatchingRootsAndKeepUnrelatedRoots() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 2)])
            )
        )

        model.applyMutationBundle(
            .init(
                events: [
                    .setDetachedRoots(
                        nodes: [
                            makeNode(
                                nodeID: 900,
                                children: [
                                    makeNode(
                                        nodeID: 901,
                                        attributes: [.init(nodeId: 1093, name: "id", value: "first-detached-target")],
                                        nodeName: "IMG",
                                        localName: "img"
                                    )
                                ],
                                nodeType: 9,
                                nodeName: "#document",
                                localName: ""
                            )
                        ]
                    )
                ]
            )
        )

        model.applyMutationBundle(
            .init(
                events: [
                    .setDetachedRoots(
                        nodes: [
                            makeNode(
                                nodeID: 900,
                                children: [
                                    makeNode(
                                        nodeID: 902,
                                        attributes: [.init(nodeId: 2093, name: "id", value: "replacement-detached-target")],
                                        nodeName: "DIV",
                                        localName: "div"
                                    )
                                ],
                                nodeType: 9,
                                nodeName: "#document",
                                localName: ""
                            ),
                            makeNode(
                                nodeID: 910,
                                children: [
                                    makeNode(
                                        nodeID: 911,
                                        attributes: [.init(nodeId: 3093, name: "id", value: "second-detached-target")],
                                        nodeName: "SPAN",
                                        localName: "span"
                                    )
                                ],
                                nodeType: 9,
                                nodeName: "#document",
                                localName: ""
                            )
                        ]
                    )
                ]
            )
        )

        let mainRoot = try! #require(model.rootNode)
        let replacementDetachedTarget = try! #require(model.node(nodeID: 902))
        let secondDetachedTarget = try! #require(model.node(nodeID: 911))

        #expect(mainRoot.nodeID == 1)
        #expect(model.topLevelRoots().map(\.nodeID) == [1])
        #expect(model.detachedRootsForDiagnostics().map(\.nodeID).sorted() == [900, 910])
        #expect(model.node(nodeID: 901) == nil)
        #expect(replacementDetachedTarget.nodeID == 902)
        #expect(replacementDetachedTarget.parent?.nodeID == 900)
        #expect(secondDetachedTarget.nodeID == 911)
        #expect(secondDetachedTarget.parent?.nodeID == 910)
    }

    @Test
    func unknownParentSetChildNodesMarksRejectedStructuralMutationWithoutCreatingPlaceholderRoot() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 2)])
            )
        )

        model.applyMutationBundle(
            .init(
                events: [
                    .setChildNodes(
                        parentNodeID: 900,
                        nodes: [
                            makeNode(
                                nodeID: 901,
                                attributes: [.init(nodeId: 1901, name: "id", value: "detached-child")]
                            )
                        ]
                    )
                ]
            )
        )

        let mainRoot = try! #require(model.rootNode)

        #expect(mainRoot.nodeID == 1)
        #expect(mainRoot.children.first?.nodeID == 2)
        #expect(model.topLevelRoots().map(\.nodeID) == [1])
        #expect(model.detachedRootsForDiagnostics().isEmpty)
        #expect(model.node(nodeID: 900) == nil)
        #expect(model.node(nodeID: 901) == nil)
        #expect(model.consumeMirrorInvariantViolationReason() == nil)
        #expect(model.consumeRejectedStructuralMutationParentNodeIDs() == Set<UInt64>([900]))
    }

    @Test
    func unknownParentSetChildNodesChainMarksRejectedStructuralMutationWithoutCreatingLeaf() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 2)])
            )
        )

        model.applyMutationBundle(
            .init(
                events: [
                    .setChildNodes(parentNodeID: 900, nodes: [makeNode(nodeID: 901)]),
                    .setChildNodes(parentNodeID: 901, nodes: [makeNode(nodeID: 902)]),
                    .setChildNodes(
                        parentNodeID: 902,
                        nodes: [
                            makeNode(
                                nodeID: 903,
                                nodeName: "IMG",
                                localName: "img"
                            )
                        ]
                    ),
                ]
            )
        )

        #expect(model.topLevelRoots().map(\.nodeID) == [1])
        #expect(model.detachedRootsForDiagnostics().isEmpty)
        #expect(model.node(nodeID: 903) == nil)
        #expect(model.consumeMirrorInvariantViolationReason() == nil)
        #expect(model.consumeRejectedStructuralMutationParentNodeIDs() == Set<UInt64>([900, 901, 902]))
    }

    @Test
    func laterMainTreeSubtreeStillAppliesAfterUnknownParentRejectedMutation() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 2)])
            )
        )

        model.applyMutationBundle(
            .init(
                events: [
                    .setChildNodes(parentNodeID: 900, nodes: [makeNode(nodeID: 901)]),
                ]
            )
        )
        #expect(model.consumeMirrorInvariantViolationReason() == nil)
        #expect(model.consumeRejectedStructuralMutationParentNodeIDs() == Set<UInt64>([900]))

        model.applyMutationBundle(
            .init(
                events: [
                    .setChildNodes(
                        parentNodeID: 2,
                        nodes: [
                            makeNode(
                                nodeID: 900,
                                children: [makeNode(nodeID: 902)]
                            )
                        ]
                    )
                ]
            )
        )

        let attachedNode = try! #require(model.node(nodeID: 900))
        #expect(model.topLevelRoots().map(\.nodeID) == [1])
        #expect(model.node(nodeID: 901) == nil)
        #expect(attachedNode.parent?.nodeID == 2)
        #expect(attachedNode.children.map(\.nodeID) == [902])
        #expect(model.consumeMirrorInvariantViolationReason() == nil)
        #expect(model.consumeRejectedStructuralMutationParentNodeIDs().isEmpty)
    }

    @Test
    func unknownParentChildNodeInsertedMarksRejectedStructuralMutationWithoutCreatingPlaceholderRoot() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 2)])
            )
        )

        model.applyMutationBundle(
            .init(
                events: [
                    .childNodeInserted(
                        parentNodeID: 900,
                        previousNodeID: nil,
                        node: makeNode(nodeID: 901)
                    )
                ]
            )
        )

        #expect(model.topLevelRoots().map(\.nodeID) == [1])
        #expect(model.detachedRootsForDiagnostics().isEmpty)
        #expect(model.node(nodeID: 900) == nil)
        #expect(model.node(nodeID: 901) == nil)
        #expect(model.consumeMirrorInvariantViolationReason() == nil)
        #expect(model.consumeRejectedStructuralMutationParentNodeIDs() == Set<UInt64>([900]))
    }

    @Test
    func selectionSnapshotIgnoresUnknownNodeWithoutCreatingPlaceholder() {
        let model = DOMDocumentModel()
        model.replaceDocument(with: .init(root: makeNode(nodeID: 1)))

        model.applySelectionSnapshot(
            .init(
                nodeID: 42,
                attributes: [],
                path: ["html", "body", "div"],
                selectorPath: "#placeholder",
                styleRevision: 0
            )
        )

        #expect(model.selectedNode == nil)
        #expect(model.node(nodeID: 42) == nil)
        #expect(model.node(nodeID: 77) == nil)
    }

    @Test
    func selectionSnapshotUpdatesDisplayedMetadata() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 42)]),
                selectedNodeID: 42
            )
        )

        model.applySelectionSnapshot(
            .init(
                nodeID: 42,
                attributes: [.init(nodeId: 42, name: "id", value: "target")],
                path: ["html", "body", "div"],
                selectorPath: "#target",
                styleRevision: 2
            )
        )

        let selectedNode = try! #require(model.selectedNode)
        #expect(selectedNode.selectorPath == "#target")
        #expect(selectedNode.styleRevision == 2)
        #expect(selectedNode.attributes.first(where: { $0.name == "id" })?.value == "target")
    }

    @Test
    func selectionSnapshotWithUnknownNodeIDIgnoresUnknownNode() {
        let model = DOMDocumentModel()
        model.applySelectionSnapshot(
            .init(
                nodeID: 42,
                attributes: [],
                path: ["html", "body", "div"],
                selectorPath: "#target",
                styleRevision: 0
            )
        )

        #expect(model.selectedNode == nil)
        #expect(model.node(nodeID: 42) == nil)
    }

    @Test
    func selectionSnapshotWithKnownNodeIDPreservesExistingNodeIdentity() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 42, attributes: [.init(nodeId: 77, name: "id", value: "target")])]),
                selectedNodeID: 42
            )
        )

        model.applySelectionSnapshot(
            .init(
                nodeID: 42,
                attributes: [],
                path: ["html", "body", "div"],
                selectorPath: "#target",
                styleRevision: 1
            )
        )

        let updatedSelection = try! #require(model.selectedNode)
        #expect(updatedSelection.nodeID == 42)
        #expect(updatedSelection.styleRevision == 1)
    }

    @Test
    func clearingSelectionDropsSelectionProjectionStateFromPreviouslySelectedNode() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 42)]),
                selectedNodeID: 42
            )
        )
        model.applySelectionSnapshot(
            .init(
                nodeID: 42,
                attributes: [.init(nodeId: 42, name: "id", value: "target")],
                path: ["html", "body", "div"],
                selectorPath: "#target",
                styleRevision: 3
            )
        )

        let selectedNode = try! #require(model.selectedNode)
        selectedNode.preview = "<div id=\"target\">"
        model.applySelectionSnapshot(nil)

        #expect(model.selectedNode == nil)
        #expect(selectedNode.preview == "<div id=\"target\">")
        #expect(selectedNode.path.isEmpty)
        #expect(selectedNode.selectorPath.isEmpty)
        #expect(selectedNode.styleRevision == 0)
    }

    @Test
    func clearDocumentDropsRootAndSelection() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(nodeID: 1, children: [makeNode(nodeID: 2)]),
                selectedNodeID: 2
            )
        )

        model.clearDocument()

        #expect(model.rootNode == nil)
        #expect(model.selectedNode == nil)
        #expect(model.errorMessage == nil)
    }

    private func makeNode(
        nodeID: UInt64,
        frameID: String? = nil,
        attributes: [DOMAttribute] = [],
        children: [DOMGraphNodeDescriptor] = [],
        contentDocument: DOMGraphNodeDescriptor? = nil,
        shadowRoots: [DOMGraphNodeDescriptor] = [],
        templateContent: DOMGraphNodeDescriptor? = nil,
        beforePseudoElement: DOMGraphNodeDescriptor? = nil,
        afterPseudoElement: DOMGraphNodeDescriptor? = nil,
        pseudoType: String? = nil,
        shadowRootType: String? = nil,
        nodeType: Int = 1,
        nodeName: String = "DIV",
        localName: String = "div",
        nodeValue: String = "",
        childCount: Int? = nil
    ) -> DOMGraphNodeDescriptor {
        DOMGraphNodeDescriptor(
            nodeID: nodeID,
            frameID: frameID,
            nodeType: nodeType,
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            pseudoType: pseudoType,
            shadowRootType: shadowRootType,
            attributes: attributes,
            childCount: childCount ?? max(children.count, contentDocument == nil ? 0 : 1),
            layoutFlags: [],
            isRendered: true,
            children: children,
            contentDocument: contentDocument,
            shadowRoots: shadowRoots,
            templateContent: templateContent,
            beforePseudoElement: beforePseudoElement,
            afterPseudoElement: afterPseudoElement
        )
    }
}

private let domDocumentStoreTestTargetIdentifier = "page-A"

private func domDocumentStoreTestKey(_ nodeID: UInt64) -> DOMNodeKey {
    DOMNodeKey(targetIdentifier: domDocumentStoreTestTargetIdentifier, nodeID: Int(nodeID))
}

private func == (lhs: DOMNodeKey, rhs: UInt64) -> Bool {
    lhs.nodeID == Int(rhs)
}

private func == (lhs: UInt64, rhs: DOMNodeKey) -> Bool {
    rhs == lhs
}

private func == (lhs: DOMNodeKey, rhs: Int) -> Bool {
    lhs.nodeID == rhs
}

private func == (lhs: Int, rhs: DOMNodeKey) -> Bool {
    rhs == lhs
}

private extension DOMGraphSnapshot {
    init(root: DOMGraphNodeDescriptor, selectedNodeID: UInt64?) {
        self.init(
            root: root,
            selectedKey: selectedNodeID.map(domDocumentStoreTestKey)
        )
    }
}

private extension DOMGraphNodeDescriptor {
    init(
        nodeID: UInt64,
        frameID: String? = nil,
        nodeType: Int,
        nodeName: String,
        localName: String,
        nodeValue: String,
        pseudoType: String? = nil,
        shadowRootType: String? = nil,
        attributes: [DOMAttribute],
        childCount: Int,
        layoutFlags: [String],
        isRendered: Bool,
        children: [DOMGraphNodeDescriptor] = [],
        contentDocument: DOMGraphNodeDescriptor? = nil,
        shadowRoots: [DOMGraphNodeDescriptor] = [],
        templateContent: DOMGraphNodeDescriptor? = nil,
        beforePseudoElement: DOMGraphNodeDescriptor? = nil,
        afterPseudoElement: DOMGraphNodeDescriptor? = nil
    ) {
        let regularChildCount = contentDocument == nil ? childCount : children.count
        self.init(
            targetIdentifier: domDocumentStoreTestTargetIdentifier,
            nodeID: Int(nodeID),
            frameID: frameID,
            nodeType: nodeType,
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            pseudoType: pseudoType,
            shadowRootType: shadowRootType,
            attributes: attributes,
            regularChildCount: regularChildCount,
            regularChildrenAreLoaded: !children.isEmpty || regularChildCount == 0,
            layoutFlags: layoutFlags,
            isRendered: isRendered,
            regularChildren: (!children.isEmpty || regularChildCount == 0) ? children : nil,
            contentDocument: contentDocument,
            shadowRoots: shadowRoots,
            templateContent: templateContent,
            beforePseudoElement: beforePseudoElement,
            afterPseudoElement: afterPseudoElement
        )
    }

    var childCount: Int {
        contentDocument == nil ? regularChildCount : 1
    }
}

private extension DOMGraphMutationEvent {
    static func childNodeInserted(
        parentNodeID: UInt64,
        previousNodeID: UInt64?,
        node: DOMGraphNodeDescriptor
    ) -> DOMGraphMutationEvent {
        .childNodeInserted(
            parentKey: domDocumentStoreTestKey(parentNodeID),
            previousSibling: previousNodeID.map {
                $0 == 0 ? .firstChild : .node(domDocumentStoreTestKey($0))
            } ?? .missing,
            node: node
        )
    }

    static func childNodeRemoved(
        parentNodeID: UInt64,
        nodeNodeID: UInt64
    ) -> DOMGraphMutationEvent {
        .childNodeRemoved(
            parentKey: domDocumentStoreTestKey(parentNodeID),
            nodeKey: domDocumentStoreTestKey(nodeNodeID)
        )
    }

    static func setChildNodes(
        parentNodeID: UInt64,
        nodes: [DOMGraphNodeDescriptor]
    ) -> DOMGraphMutationEvent {
        .setChildNodes(
            parentKey: domDocumentStoreTestKey(parentNodeID),
            nodes: nodes
        )
    }

    static func shadowRootPushed(
        hostNodeID: UInt64,
        root: DOMGraphNodeDescriptor
    ) -> DOMGraphMutationEvent {
        .shadowRootPushed(
            hostKey: domDocumentStoreTestKey(hostNodeID),
            root: root
        )
    }

    static func pseudoElementAdded(
        parentNodeID: UInt64,
        node: DOMGraphNodeDescriptor
    ) -> DOMGraphMutationEvent {
        .pseudoElementAdded(
            parentKey: domDocumentStoreTestKey(parentNodeID),
            node: node
        )
    }

    static func pseudoElementRemoved(
        parentNodeID: UInt64,
        nodeNodeID: UInt64
    ) -> DOMGraphMutationEvent {
        .pseudoElementRemoved(
            parentKey: domDocumentStoreTestKey(parentNodeID),
            nodeKey: domDocumentStoreTestKey(nodeNodeID)
        )
    }

}

private extension DOMSelectionSnapshotPayload {
    init(
        nodeID: Int?,
        attributes: [DOMAttribute],
        path: [String],
        selectorPath: String?,
        styleRevision: Int
    ) {
        self.init(
            key: nodeID.map { domDocumentStoreTestKey(UInt64($0)) },
            attributes: attributes,
            path: path,
            selectorPath: selectorPath,
            styleRevision: styleRevision
        )
    }
}

private extension DOMSelectorPathPayload {
    init(
        nodeID: Int?,
        attributes _: [DOMAttribute] = [],
        path _: [String] = [],
        selectorPath: String,
        styleRevision _: Int = 0
    ) {
        self.init(key: nodeID.map { domDocumentStoreTestKey(UInt64($0)) }, selectorPath: selectorPath)
    }
}

private extension DOMDocumentModel {
    func node(nodeID: UInt64) -> DOMNodeModel? {
        node(key: domDocumentStoreTestKey(nodeID))
    }

    func consumeRejectedStructuralMutationParentNodeIDs() -> Set<UInt64> {
        Set(consumeRejectedStructuralMutationParentKeys().map { UInt64($0.nodeID) })
    }
}

private extension DOMNodeModel {
    var effectiveChildren: [DOMNodeModel] {
        children
    }

    var childCount: Int {
        contentDocument == nil ? regularChildCount : 1
    }

}
