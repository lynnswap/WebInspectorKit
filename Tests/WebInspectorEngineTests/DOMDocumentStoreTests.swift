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
    func nestedDocumentRemainsChildOfFrameOwner() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [
                        makeNode(
                            localID: 20,
                            frameID: "frame-child",
                            contentDocument:
                                makeNode(
                                    localID: 24,
                                    backendNodeID: 24,
                                    frameID: "frame-child",
                                    children: [
                                        makeNode(
                                            localID: 26,
                                            backendNodeID: 26,
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

        let iframeNode = try! #require(model.node(localID: 20))
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
                    localID: 1,
                    children: [
                        makeNode(
                            localID: 20,
                            frameID: "frame-child",
                            contentDocument:
                                makeNode(
                                    localID: 24,
                                    backendNodeID: 24,
                                    frameID: "frame-child",
                                    children: [
                                        makeNode(
                                            localID: 26,
                                            backendNodeID: 26,
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
                    .setChildNodes(parentLocalID: 20, nodes: [])
                ]
            )
        )

        let iframeNode = try! #require(model.node(localID: 20))
        let nestedDocument = try! #require(iframeNode.children.first)
        let nestedButton = try! #require(nestedDocument.children.first)

        #expect(iframeNode.childCount == 1)
        #expect(iframeNode.children.count == 1)
        #expect(nestedDocument.localID == 24)
        #expect(nestedDocument.parent === iframeNode)
        #expect(nestedButton.localID == 26)
    }

    @Test
    func setChildNodesOnFrameOwnerWithoutExplicitNodeTypesStillPreservesContentDocument() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [
                        makeNode(
                            localID: 20,
                            frameID: "frame-child",
                            attributes: [],
                            contentDocument:
                                makeNode(
                                    localID: 24,
                                    backendNodeID: 24,
                                    frameID: "frame-child",
                                    attributes: [],
                                    children: [
                                        makeNode(
                                            localID: 26,
                                            backendNodeID: 26,
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
                    .setChildNodes(parentLocalID: 20, nodes: [])
                ]
            )
        )

        let iframeNode = try! #require(model.node(localID: 20))
        let nestedDocument = try! #require(model.node(localID: 24))
        let nestedImage = try! #require(model.node(localID: 26))

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
                    localID: 1,
                    children: [
                        makeNode(
                            localID: 10,
                            children: [makeNode(localID: 14, nodeName: "P", localName: "p")],
                            shadowRoots: [
                                makeNode(
                                    localID: 13,
                                    shadowRootType: "open",
                                    nodeType: 11,
                                    nodeName: "#document-fragment",
                                    localName: ""
                                )
                            ],
                            templateContent: makeNode(
                                localID: 11,
                                nodeType: 11,
                                nodeName: "#document-fragment",
                                localName: ""
                            ),
                            beforePseudoElement: makeNode(
                                localID: 12,
                                pseudoType: "before",
                                nodeName: "::before",
                                localName: ""
                            ),
                            afterPseudoElement: makeNode(
                                localID: 15,
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
                .setChildNodes(parentLocalID: 10, nodes: [makeNode(localID: 16, nodeName: "SPAN", localName: "span")])
            ])
        )

        let host = try! #require(model.node(localID: 10))
        #expect(host.regularChildren.map(\.localID) == [16])
        #expect(host.children.map(\.localID) == [13, 16])
        #expect(host.visibleDOMTreeChildren.map(\.localID) == [11, 12, 13, 16, 15])
        #expect(model.node(localID: 14) == nil)
        #expect(model.node(localID: 11) != nil)
        #expect(model.node(localID: 12) != nil)
        #expect(model.node(localID: 13) != nil)
        #expect(model.node(localID: 15) != nil)
    }

    @Test
    func emptySetChildNodesMarksRegularChildrenAsLoadedEmpty() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [
                        makeNode(
                            localID: 10,
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

        let hostBeforeLoad = try! #require(model.node(localID: 10))
        #expect(hostBeforeLoad.hasUnloadedRegularChildren)

        model.applyMutationBundle(
            .init(events: [
                .setChildNodes(parentLocalID: 10, nodes: [])
            ])
        )

        let host = try! #require(model.node(localID: 10))
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
                    localID: 1,
                    children: [
                        makeNode(
                            localID: 10,
                            children: [
                                makeNode(localID: 14, nodeName: "A", localName: "a"),
                                makeNode(localID: 16, nodeName: "C", localName: "c"),
                            ],
                            shadowRoots: [
                                makeNode(
                                    localID: 13,
                                    shadowRootType: "open",
                                    nodeType: 11,
                                    nodeName: "#document-fragment",
                                    localName: ""
                                )
                            ],
                            templateContent: makeNode(localID: 11, nodeType: 11, nodeName: "#document-fragment", localName: ""),
                            beforePseudoElement: makeNode(localID: 12, pseudoType: "before", nodeName: "::before", localName: ""),
                            afterPseudoElement: makeNode(localID: 17, pseudoType: "after", nodeName: "::after", localName: "")
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
                    parentLocalID: 10,
                    previousLocalID: 14,
                    node: makeNode(localID: 15, nodeName: "B", localName: "b")
                )
            ])
        )

        let host = try! #require(model.node(localID: 10))
        #expect(host.regularChildren.map(\.localID) == [14, 15, 16])
        #expect(host.children.map(\.localID) == [13, 14, 15, 16])
        #expect(host.visibleDOMTreeChildren.map(\.localID) == [11, 12, 13, 14, 15, 16, 17])
    }

    @Test
    func childNodeRemovedCanRemoveSpecialChildren() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [
                        makeNode(
                            localID: 10,
                            children: [makeNode(localID: 14)],
                            beforePseudoElement: makeNode(
                                localID: 12,
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
            .init(events: [.childNodeRemoved(parentLocalID: 10, nodeLocalID: 12)])
        )

        let host = try! #require(model.node(localID: 10))
        #expect(host.beforePseudoElement == nil)
        #expect(host.visibleDOMTreeChildren.map(\.localID) == [14])
        #expect(model.node(localID: 12) == nil)
    }

    @Test
    func childNodeRemovedCanRemoveContentDocumentFromFrameOwner() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [
                        makeNode(
                            localID: 10,
                            contentDocument: makeNode(
                                localID: 11,
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
            .init(events: [.childNodeRemoved(parentLocalID: 10, nodeLocalID: 11)])
        )

        let frameOwner = try! #require(model.node(localID: 10))
        #expect(frameOwner.contentDocument == nil)
        #expect(frameOwner.children.isEmpty)
        #expect(frameOwner.childCount == 0)
        #expect(model.node(localID: 11) == nil)
    }

    @Test
    func selectionReprojectsInsideNestedDocumentByStableBackendNodeID() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [
                        makeNode(
                            localID: 20,
                            frameID: "frame-child",
                            contentDocument:
                                makeNode(
                                    localID: 24,
                                    backendNodeID: 24,
                                    frameID: "frame-child",
                                    children: [
                                        makeNode(
                                            localID: 26,
                                            backendNodeID: 77,
                                            backendNodeIDIsStable: true,
                                            attributes: [.init(nodeId: 77, name: "id", value: "before")],
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
                ),
                selectedLocalID: 26
            )
        )

        model.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [
                        makeNode(
                            localID: 200,
                            frameID: "frame-child",
                            contentDocument:
                                makeNode(
                                    localID: 240,
                                    backendNodeID: 24,
                                    frameID: "frame-child",
                                    children: [
                                        makeNode(
                                            localID: 260,
                                            backendNodeID: 77,
                                            backendNodeIDIsStable: true,
                                            attributes: [.init(nodeId: 77, name: "id", value: "after")],
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
            ),
            isFreshDocument: false
        )

        let reprojected = try! #require(model.selectedNode)
        #expect(reprojected.localID == 260)
        #expect(reprojected.backendNodeID == 77)
        #expect(reprojected.attributes.first(where: { $0.name == "id" })?.value == "after")
    }

    @Test
    func sameContextSnapshotReplaceRebindsSelectionByStableBackendNodeID() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [
                        makeNode(
                            localID: 7,
                            backendNodeID: 77,
                            backendNodeIDIsStable: true,
                            attributes: [.init(nodeId: 77, name: "class", value: "before")]
                        )
                    ]
                ),
                selectedLocalID: 7
            )
        )

        model.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [
                        makeNode(
                            localID: 70,
                            backendNodeID: 77,
                            backendNodeIDIsStable: true,
                            attributes: [.init(nodeId: 77, name: "class", value: "after")]
                        )
                    ]
                )
            ),
            isFreshDocument: false
        )

        let reprojected = try! #require(model.selectedNode)
        #expect(reprojected.localID == 70)
        #expect(reprojected.backendNodeID == 77)
        #expect(reprojected.attributes.first(where: { $0.name == "class" })?.value == "after")
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
    func detachedRootsRemainQueryableWithoutReplacingMainRoot() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 2)])
            )
        )

        model.applyMutationBundle(
            .init(
                events: [
                    .setDetachedRoots(
                        nodes: [
                            makeNode(
                                localID: 900,
                                backendNodeID: 900,
                                children: [
                                    makeNode(
                                        localID: 901,
                                        backendNodeID: 1093,
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
        let detachedTarget = try! #require(model.node(backendNodeID: 1093))

        #expect(mainRoot.localID == 1)
        #expect(mainRoot.children.first?.localID == 2)
        #expect(model.topLevelRoots().map(\.localID) == [1])
        #expect(model.detachedRootsForDiagnostics().map(\.localID) == [900])
        #expect(detachedTarget.localID == 901)
        #expect(detachedTarget.localName == "img")
        #expect(detachedTarget.parent?.nodeType == .document)
    }

    @Test
    func detachedRootUpdatesReplaceMatchingRootsAndKeepUnrelatedRoots() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 2)])
            )
        )

        model.applyMutationBundle(
            .init(
                events: [
                    .setDetachedRoots(
                        nodes: [
                            makeNode(
                                localID: 900,
                                backendNodeID: 900,
                                children: [
                                    makeNode(
                                        localID: 901,
                                        backendNodeID: 1093,
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
                                localID: 900,
                                backendNodeID: 900,
                                children: [
                                    makeNode(
                                        localID: 902,
                                        backendNodeID: 2093,
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
                                localID: 910,
                                backendNodeID: 910,
                                children: [
                                    makeNode(
                                        localID: 911,
                                        backendNodeID: 3093,
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
        let replacementDetachedTarget = try! #require(model.node(backendNodeID: 2093))
        let secondDetachedTarget = try! #require(model.node(backendNodeID: 3093))

        #expect(mainRoot.localID == 1)
        #expect(model.topLevelRoots().map(\.localID) == [1])
        #expect(model.detachedRootsForDiagnostics().map(\.localID).sorted() == [900, 910])
        #expect(model.node(backendNodeID: 1093) == nil)
        #expect(replacementDetachedTarget.localID == 902)
        #expect(replacementDetachedTarget.parent?.localID == 900)
        #expect(secondDetachedTarget.localID == 911)
        #expect(secondDetachedTarget.parent?.localID == 910)
    }

    @Test
    func unknownParentSetChildNodesMarksRejectedStructuralMutationWithoutCreatingPlaceholderRoot() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 2)])
            )
        )

        model.applyMutationBundle(
            .init(
                events: [
                    .setChildNodes(
                        parentLocalID: 900,
                        nodes: [
                            makeNode(
                                localID: 901,
                                backendNodeID: 1901,
                                attributes: [.init(nodeId: 1901, name: "id", value: "detached-child")]
                            )
                        ]
                    )
                ]
            )
        )

        let mainRoot = try! #require(model.rootNode)

        #expect(mainRoot.localID == 1)
        #expect(mainRoot.children.first?.localID == 2)
        #expect(model.topLevelRoots().map(\.localID) == [1])
        #expect(model.detachedRootsForDiagnostics().isEmpty)
        #expect(model.node(localID: 900) == nil)
        #expect(model.node(backendNodeID: 1901) == nil)
        #expect(model.consumeMirrorInvariantViolationReason() == nil)
        #expect(model.consumeRejectedStructuralMutationParentLocalIDs() == Set<UInt64>([900]))
    }

    @Test
    func unknownParentSetChildNodesChainMarksRejectedStructuralMutationWithoutMaterializingLeaf() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 2)])
            )
        )

        model.applyMutationBundle(
            .init(
                events: [
                    .setChildNodes(parentLocalID: 900, nodes: [makeNode(localID: 901)]),
                    .setChildNodes(parentLocalID: 901, nodes: [makeNode(localID: 902)]),
                    .setChildNodes(
                        parentLocalID: 902,
                        nodes: [
                            makeNode(
                                localID: 903,
                                backendNodeID: 2903,
                                nodeName: "IMG",
                                localName: "img"
                            )
                        ]
                    ),
                ]
            )
        )

        #expect(model.topLevelRoots().map(\.localID) == [1])
        #expect(model.detachedRootsForDiagnostics().isEmpty)
        #expect(model.node(backendNodeID: 2903) == nil)
        #expect(model.consumeMirrorInvariantViolationReason() == nil)
        #expect(model.consumeRejectedStructuralMutationParentLocalIDs() == Set<UInt64>([900, 901, 902]))
    }

    @Test
    func laterMainTreeSubtreeStillAppliesAfterUnknownParentRejectedMutation() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 2)])
            )
        )

        model.applyMutationBundle(
            .init(
                events: [
                    .setChildNodes(parentLocalID: 900, nodes: [makeNode(localID: 901, backendNodeID: 1901)]),
                ]
            )
        )
        #expect(model.consumeMirrorInvariantViolationReason() == nil)
        #expect(model.consumeRejectedStructuralMutationParentLocalIDs() == Set<UInt64>([900]))

        model.applyMutationBundle(
            .init(
                events: [
                    .setChildNodes(
                        parentLocalID: 2,
                        nodes: [
                            makeNode(
                                localID: 900,
                                backendNodeID: 900,
                                children: [makeNode(localID: 902, backendNodeID: 2902)]
                            )
                        ]
                    )
                ]
            )
        )

        let attachedNode = try! #require(model.node(localID: 900))
        #expect(model.topLevelRoots().map(\.localID) == [1])
        #expect(model.node(localID: 901) == nil)
        #expect(attachedNode.parent?.localID == 2)
        #expect(attachedNode.children.map(\.localID) == [902])
        #expect(model.consumeMirrorInvariantViolationReason() == nil)
        #expect(model.consumeRejectedStructuralMutationParentLocalIDs().isEmpty)
    }

    @Test
    func unknownParentChildNodeInsertedMarksRejectedStructuralMutationWithoutCreatingPlaceholderRoot() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 2)])
            )
        )

        model.applyMutationBundle(
            .init(
                events: [
                    .childNodeInserted(
                        parentLocalID: 900,
                        previousLocalID: nil,
                        node: makeNode(localID: 901, backendNodeID: 1901)
                    )
                ]
            )
        )

        #expect(model.topLevelRoots().map(\.localID) == [1])
        #expect(model.detachedRootsForDiagnostics().isEmpty)
        #expect(model.node(localID: 900) == nil)
        #expect(model.node(backendNodeID: 1901) == nil)
        #expect(model.consumeMirrorInvariantViolationReason() == nil)
        #expect(model.consumeRejectedStructuralMutationParentLocalIDs() == Set<UInt64>([900]))
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
    func selectionSnapshotIgnoresUnknownNodeWithoutCreatingPlaceholder() {
        let model = DOMDocumentModel()
        model.replaceDocument(with: .init(root: makeNode(localID: 1)))

        model.applySelectionSnapshot(
            .init(
                localID: 42,
                backendNodeID: 77,
                backendNodeIDIsStable: false,
                attributes: [],
                path: ["html", "body", "div"],
                selectorPath: "#placeholder",
                styleRevision: 0
            )
        )

        #expect(model.selectedNode == nil)
        #expect(model.node(localID: 42) == nil)
        #expect(model.node(backendNodeID: 77) == nil)
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
    func selectionSnapshotWithoutBackendNodeIDIgnoresUnknownNode() {
        let model = DOMDocumentModel()
        model.applySelectionSnapshot(
            .init(
                localID: 42,
                attributes: [],
                path: ["html", "body", "div"],
                selectorPath: "#target",
                styleRevision: 0
            )
        )

        #expect(model.selectedNode == nil)
        #expect(model.node(localID: 42) == nil)
    }

    @Test
    func selectionSnapshotWithStableBackendNodeIDRebindsToExistingAttachedNode() {
        let model = DOMDocumentModel()
        model.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [
                        makeNode(
                            localID: 70,
                            backendNodeID: 77,
                            backendNodeIDIsStable: true,
                            attributes: [.init(nodeId: 77, name: "id", value: "target")]
                        )
                    ]
                )
            )
        )

        model.applySelectionSnapshot(
            .init(
                localID: 42,
                backendNodeID: 77,
                backendNodeIDIsStable: true,
                attributes: [.init(nodeId: 77, name: "id", value: "target")],
                path: ["html", "body", "div"],
                selectorPath: "#target",
                styleRevision: 0
            )
        )

        let selectedNode = try! #require(model.selectedNode)
        #expect(selectedNode.localID == 70)
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
        backendNodeID: Int? = nil,
        backendNodeIDIsStable: Bool? = nil,
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
            localID: localID,
            backendNodeID: backendNodeID ?? Int(localID),
            backendNodeIDIsStable: backendNodeIDIsStable,
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
