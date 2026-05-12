import Testing
@testable import V2_WebInspectorCore

@Test
func pageTargetCreationCreatesCurrentPageAndMainFrame() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let mainFrameID = DOMFrame.ID("main-frame")
    let session = await DOMSession()

    await session.applyTargetCreated(
        .init(id: pageTargetID, kind: .page, frameID: mainFrameID),
        makeCurrentMainPage: true
    )
    let snapshot = await session.snapshot()

    #expect(snapshot.currentPage?.mainTargetID == pageTargetID)
    #expect(snapshot.currentPage?.mainFrameID == mainFrameID)
    #expect(snapshot.targetsByID[pageTargetID]?.kind == .page)
    #expect(snapshot.framesByID[mainFrameID]?.targetID == pageTargetID)
}

@Test
func pageTargetCreationWithoutMainPageFlagOnlyRegistersTarget() async throws {
    let pageTargetID = ProtocolTarget.ID("page-candidate")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page))
    let snapshot = await session.snapshot()

    #expect(snapshot.currentPage == nil)
    #expect(snapshot.targetsByID[pageTargetID]?.kind == .page)
}

@Test
func serviceWorkerTargetAndLifecycleFlagsArePreservedInSnapshot() async throws {
    let targetID = ProtocolTarget.ID("service-worker")
    let session = await DOMSession()

    await session.applyTargetCreated(
        .init(
            id: targetID,
            kind: .serviceWorker,
            isProvisional: true,
            isPaused: true
        )
    )
    let snapshot = await session.snapshot()

    #expect(snapshot.targetsByID[targetID]?.kind == .serviceWorker)
    #expect(snapshot.targetsByID[targetID]?.isProvisional == true)
    #expect(snapshot.targetsByID[targetID]?.isPaused == true)
}

@Test
func provisionalPageCommitUpdatesMainPageTargetWithoutKeepingOldDocument() async throws {
    let provisionalTargetID = ProtocolTarget.ID("page-provisional")
    let committedTargetID = ProtocolTarget.ID("page-committed")
    let mainFrameID = DOMFrame.ID("main-frame")
    let session = await DOMSession()

    await session.applyTargetCreated(
        .init(id: provisionalTargetID, kind: .page, frameID: mainFrameID, isProvisional: true),
        makeCurrentMainPage: true
    )
    _ = await session.replaceDocumentRoot(pageDocumentWithoutIframe(), targetID: provisionalTargetID)
    let before = await session.snapshot()
    let oldDocumentID = try #require(before.targetsByID[provisionalTargetID]?.currentDocumentID)

    await session.applyTargetCommitted(oldTargetID: provisionalTargetID, newTargetID: committedTargetID)
    let after = await session.snapshot()

    #expect(after.currentPage?.mainTargetID == committedTargetID)
    #expect(after.targetsByID[provisionalTargetID] == nil)
    #expect(after.targetsByID[committedTargetID]?.isProvisional == false)
    #expect(after.framesByID[mainFrameID]?.targetID == committedTargetID)
    #expect(after.documentsByID[oldDocumentID] == nil)
}

@Test
func provisionalFrameCommitDoesNotResetParentPageDocument() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let mainFrameID = DOMFrame.ID("main-frame")
    let provisionalFrameTargetID = ProtocolTarget.ID("frame-provisional")
    let committedFrameTargetID = ProtocolTarget.ID("frame-committed")
    let frameID = DOMFrame.ID("frame-ad")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page, frameID: mainFrameID), makeCurrentMainPage: true)
    await session.applyTargetCreated(
        .init(
            id: provisionalFrameTargetID,
            kind: .frame,
            frameID: frameID,
            parentFrameID: mainFrameID,
            isProvisional: true
        )
    )
    _ = await session.replaceDocumentRoot(pageDocument(iframeFrameID: frameID), targetID: pageTargetID)
    let frameRootID = await session.replaceDocumentRoot(frameDocument(rootNodeID: 101), targetID: provisionalFrameTargetID)
    let before = await session.snapshot()
    let pageDocumentID = try #require(before.targetsByID[pageTargetID]?.currentDocumentID)

    await session.applyTargetCommitted(oldTargetID: provisionalFrameTargetID, newTargetID: committedFrameTargetID)
    let after = await session.snapshot()

    #expect(after.targetsByID[pageTargetID]?.currentDocumentID == pageDocumentID)
    #expect(after.targetsByID[provisionalFrameTargetID] == nil)
    #expect(after.targetsByID[committedFrameTargetID]?.kind == .frame)
    #expect(after.framesByID[frameID]?.targetID == committedFrameTargetID)
    #expect(after.nodesByID[frameRootID] == nil)
}

@Test
func frameTargetCreationLinksProtocolTargetToFrame() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let mainFrameID = DOMFrame.ID("main-frame")
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page, frameID: mainFrameID), makeCurrentMainPage: true)
    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID, parentFrameID: mainFrameID))
    let snapshot = await session.snapshot()

    #expect(snapshot.targetsByID[frameTargetID]?.frameID == frameID)
    #expect(snapshot.framesByID[frameID]?.targetID == frameTargetID)
    #expect(snapshot.framesByID[frameID]?.parentFrameID == mainFrameID)
    #expect(snapshot.framesByID[mainFrameID]?.childFrameIDs.contains(frameID) == true)
}

@Test
func executionContextRoutesRequestNodeToProtocolTarget() async throws {
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let executionContextID = ExecutionContextID(41)
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID))
    _ = await session.replaceDocumentRoot(document(nodeID: 1), targetID: frameTargetID)
    await session.applyExecutionContextCreated(.init(id: executionContextID, targetID: frameTargetID, frameID: frameID))

    let result = await session.resolveInspectSelection(
        remoteObject: .init(objectID: "remote-node", injectedScriptID: executionContextID)
    )

    guard case let .success(.requestNode(_, targetID, objectID)) = result else {
        Issue.record("Expected DOM.requestNode")
        return
    }
    #expect(targetID == frameTargetID)
    #expect(objectID == "remote-node")
    #expect((await session.snapshot()).executionContextsByID[executionContextID]?.frameID == frameID)
}

@Test
func nodeIDIsScopedByTargetAndDocumentGeneration() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: .init("frame-ad")))

    let pageRootID = await session.replaceDocumentRoot(
        document(nodeID: 1, children: [.element(nodeID: 2, name: "html")]),
        targetID: pageTargetID
    )
    let frameRootID = await session.replaceDocumentRoot(
        document(nodeID: 1, children: [.element(nodeID: 2, name: "html")]),
        targetID: frameTargetID
    )

    #expect(pageRootID.nodeID == frameRootID.nodeID)
    #expect(pageRootID.documentID.targetID != frameRootID.documentID.targetID)
    #expect(pageRootID != frameRootID)
}

@Test
func frameDocumentReplacementOnlyUpdatesFrameGeneration() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID))
    _ = await session.replaceDocumentRoot(document(nodeID: 1), targetID: pageTargetID)
    _ = await session.replaceDocumentRoot(frameDocument(rootNodeID: 101), targetID: frameTargetID)
    let before = await session.snapshot()
    let pageDocumentID = try #require(before.targetsByID[pageTargetID]?.currentDocumentID)
    let frameDocumentID = try #require(before.targetsByID[frameTargetID]?.currentDocumentID)

    _ = await session.replaceDocumentRoot(frameDocument(rootNodeID: 201), targetID: frameTargetID)
    let after = await session.snapshot()

    #expect(after.targetsByID[pageTargetID]?.currentDocumentID == pageDocumentID)
    #expect(after.targetsByID[frameTargetID]?.currentDocumentID != frameDocumentID)
    #expect(after.framesByID[frameID]?.currentDocumentID == after.targetsByID[frameTargetID]?.currentDocumentID)
}

@Test
func mainPageNavigationDoesNotMixFrameDocumentsIntoParentDocument() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let mainFrameID = DOMFrame.ID("main-frame")
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page, frameID: mainFrameID), makeCurrentMainPage: true)
    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID, parentFrameID: mainFrameID))
    _ = await session.replaceDocumentRoot(pageDocument(iframeFrameID: frameID), targetID: pageTargetID)
    let frameRootID = await session.replaceDocumentRoot(frameDocument(rootNodeID: 101), targetID: frameTargetID)
    let first = await session.snapshot()

    _ = await session.replaceDocumentRoot(pageDocumentWithoutIframe(), targetID: pageTargetID)
    let second = await session.snapshot()
    let projection = await session.treeProjection(rootTargetID: pageTargetID)

    #expect(first.currentPage?.navigationGeneration == 1)
    #expect(second.currentPage?.navigationGeneration == 2)
    #expect(second.nodesByID[frameRootID] != nil)
    #expect(projection.rows.map(\.nodeID).contains(frameRootID) == false)
}

@Test
func iframeOwnerProjectsFrameDocumentWithoutStoringItAsRegularChild() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID))
    _ = await session.replaceDocumentRoot(pageDocument(iframeFrameID: frameID), targetID: pageTargetID)
    let frameRootID = await session.replaceDocumentRoot(frameDocument(rootNodeID: 101), targetID: frameTargetID)

    let snapshot = await session.snapshot()
    let projection = await session.treeProjection(rootTargetID: pageTargetID)
    let iframeID = try #require(snapshot.currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(20))])
    let iframe = try #require(snapshot.nodesByID[iframeID])

    #expect(iframe.regularChildIDs.isEmpty)
    #expect(snapshot.nodesByID[frameRootID]?.parentID == nil)
    #expect(snapshot.framesByID[frameID]?.ownerNodeID == iframeID)
    #expect(projection.rows.contains { $0.nodeID == frameRootID && $0.depth > iframeDepth(in: projection, iframeID: iframeID) })
}

@Test
func ownerMissingFrameDocumentProjectsWhenOwnerAppears() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID))
    let frameRootID = await session.replaceDocumentRoot(frameDocument(rootNodeID: 101), targetID: frameTargetID)
    var projection = await session.treeProjection(rootTargetID: pageTargetID)

    #expect(projection.rows.map(\.nodeID).contains(frameRootID) == false)

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(pageDocument(iframeFrameID: frameID), targetID: pageTargetID)
    projection = await session.treeProjection(rootTargetID: pageTargetID)
    let snapshot = await session.snapshot()

    #expect(snapshot.framesByID[frameID]?.currentDocumentID == frameRootID.documentID)
    #expect(snapshot.framesByID[frameID]?.ownerNodeID != nil)
    #expect(projection.rows.map(\.nodeID).contains(frameRootID))
}

@Test
func iframeOwnerRemovalDropsProjectionButKeepsFrameTargetMirror() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID))
    _ = await session.replaceDocumentRoot(pageDocument(iframeFrameID: frameID), targetID: pageTargetID)
    let frameRootID = await session.replaceDocumentRoot(frameDocument(rootNodeID: 101), targetID: frameTargetID)
    let snapshot = await session.snapshot()
    let iframeID = try #require(snapshot.currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(20))])

    await session.applyNodeRemoved(iframeID)
    let after = await session.snapshot()
    let projection = await session.treeProjection(rootTargetID: pageTargetID)

    #expect(after.framesByID[frameID]?.ownerNodeID == nil)
    #expect(after.nodesByID[frameRootID] != nil)
    #expect(projection.rows.map(\.nodeID).contains(frameRootID) == false)
}

@Test
func visibleOrderMatchesWebKitDOMTreeOrder() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(
        .element(
            nodeID: 1,
            name: "div",
            children: [.element(nodeID: 6, name: "span")],
            shadowRoots: [.element(nodeID: 5, name: "#shadow-root")],
            templateContent: .element(nodeID: 2, name: "#document-fragment"),
            beforePseudoElement: .element(nodeID: 3, name: "::before", pseudoType: "before"),
            otherPseudoElements: [.element(nodeID: 4, name: "::marker", pseudoType: "marker")],
            afterPseudoElement: .element(nodeID: 7, name: "::after", pseudoType: "after")
        ),
        targetID: pageTargetID
    )

    let projection = await session.treeProjection(rootTargetID: pageTargetID)

    #expect(projection.rows.map(\.nodeName) == [
        "div",
        "#document-fragment",
        "::before",
        "::marker",
        "#shadow-root",
        "span",
        "::after",
    ])
}

@Test
func mainDocumentSelectionRequestsPageTarget() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let executionContextID = ExecutionContextID(7)
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(pageDocumentWithoutIframe(), targetID: pageTargetID)
    await session.applyExecutionContextCreated(executionContextID, targetID: pageTargetID)

    let result = await session.resolveInspectSelection(
        remoteObject: .init(objectID: "page-object", injectedScriptID: executionContextID)
    )

    guard case let .success(.requestNode(_, targetID, objectID)) = result else {
        Issue.record("Expected page target requestNode")
        return
    }
    #expect(targetID == pageTargetID)
    #expect(objectID == "page-object")
}

@Test
func crossOriginIframeSelectionRequestsFrameTarget() async throws {
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let executionContextID = ExecutionContextID(77)
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID))
    _ = await session.replaceDocumentRoot(frameDocument(rootNodeID: 101), targetID: frameTargetID)
    await session.applyExecutionContextCreated(executionContextID, targetID: frameTargetID)

    let result = await session.resolveInspectSelection(
        remoteObject: .init(objectID: "frame-object", injectedScriptID: executionContextID)
    )

    guard case let .success(.requestNode(_, targetID, objectID)) = result else {
        Issue.record("Expected frame target requestNode")
        return
    }
    #expect(targetID == frameTargetID)
    #expect(objectID == "frame-object")
}

@Test
func iframeAdRefreshSelectionUsesNewFrameDocumentGenerationAndSelectedProjectionRow() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let executionContextID = ExecutionContextID(77)
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID))
    await session.applyExecutionContextCreated(executionContextID, targetID: frameTargetID)
    _ = await session.replaceDocumentRoot(pageDocument(iframeFrameID: frameID), targetID: pageTargetID)
    _ = await session.replaceDocumentRoot(frameDocument(rootNodeID: 101, selectedNodeName: "img"), targetID: frameTargetID)
    let refreshedFrameRootID = await session.replaceDocumentRoot(
        frameDocument(rootNodeID: 201, selectedNodeName: "div"),
        targetID: frameTargetID
    )

    let command = await session.resolveInspectSelection(
        remoteObject: .init(objectID: "frame-object", injectedScriptID: executionContextID)
    )
    let requestID: SelectionRequestIdentifier
    guard case let .success(.requestNode(id, targetID, objectID)) = command else {
        Issue.record("Expected frame-target requestNode")
        return
    }
    requestID = id
    #expect(targetID == frameTargetID)
    #expect(objectID == "frame-object")

    let selectedNodeID = try await session.applyRequestNodeResult(
        selectionRequestID: requestID,
        targetID: frameTargetID,
        nodeID: .init(8)
    ).get()
    let snapshot = await session.snapshot()
    let projection = await session.treeProjection(rootTargetID: pageTargetID)

    #expect(snapshot.framesByID[frameID]?.currentDocumentID == refreshedFrameRootID.documentID)
    #expect(selectedNodeID.documentID == refreshedFrameRootID.documentID)
    #expect(projection.rows.contains { $0.nodeID == selectedNodeID && $0.isSelected })
}

@Test
func staleSelectionRequestIsRejectedAfterFrameDocumentRefresh() async throws {
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let executionContextID = ExecutionContextID(77)
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID))
    await session.applyExecutionContextCreated(executionContextID, targetID: frameTargetID)
    _ = await session.replaceDocumentRoot(frameDocument(rootNodeID: 101), targetID: frameTargetID)

    let command = await session.resolveInspectSelection(
        remoteObject: .init(objectID: "frame-object", injectedScriptID: executionContextID)
    )
    let requestID: SelectionRequestIdentifier
    guard case let .success(.requestNode(id, _, _)) = command else {
        Issue.record("Expected frame-target requestNode")
        return
    }
    requestID = id

    _ = await session.replaceDocumentRoot(frameDocument(rootNodeID: 201), targetID: frameTargetID)
    let result = await session.applyRequestNodeResult(
        selectionRequestID: requestID,
        targetID: frameTargetID,
        nodeID: .init(8)
    )
    let snapshot = await session.snapshot()

    guard case let .failure(.staleDocument(expected, actual)) = result else {
        Issue.record("Expected stale document failure")
        return
    }
    #expect(expected.generation == .init(1))
    #expect(actual?.generation == .init(2))
    #expect(snapshot.selection.selectedNodeID == nil)
}

@Test
func selectionFailureDoesNotMutateTreeFrameOrDocumentModel() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(pageDocumentWithoutIframe(), targetID: pageTargetID)
    let before = await session.snapshot()

    let result = await session.resolveInspectSelection(
        remoteObject: .init(objectID: "node", injectedScriptID: .init(404))
    )
    let after = await session.snapshot()

    guard case let .failure(failure) = result else {
        Issue.record("Expected selection failure")
        return
    }
    #expect(failure == .unknownExecutionContext(.init(404)))
    #expect(after.selection.failure == .unknownExecutionContext(.init(404)))
    #expect(after.targetsByID == before.targetsByID)
    #expect(after.framesByID == before.framesByID)
    #expect(after.documentsByID == before.documentsByID)
    #expect(after.nodesByID == before.nodesByID)
    #expect(after.currentNodeIDByKey == before.currentNodeIDByKey)
}

private func iframeDepth(in projection: DOMTreeProjection, iframeID: DOMNode.ID) -> Int {
    projection.rows.first(where: { $0.nodeID == iframeID })?.depth ?? -1
}

private func document(nodeID: Int, children: [DOMNodePayload] = []) -> DOMNodePayload {
    DOMNodePayload(
        nodeID: .init(nodeID),
        nodeType: .document,
        nodeName: "#document",
        regularChildren: .loaded(children)
    )
}

private func pageDocument(iframeFrameID: DOMFrame.ID) -> DOMNodePayload {
    document(
        nodeID: 1,
        children: [
            .element(
                nodeID: 2,
                name: "html",
                children: [
                    .element(nodeID: 3, name: "head"),
                    .element(
                        nodeID: 4,
                        name: "body",
                        children: [
                            .element(nodeID: 20, name: "iframe", frameID: iframeFrameID),
                        ]
                    ),
                ]
            ),
        ]
    )
}

private func pageDocumentWithoutIframe() -> DOMNodePayload {
    document(
        nodeID: 1,
        children: [
            .element(
                nodeID: 2,
                name: "html",
                children: [
                    .element(nodeID: 3, name: "head"),
                    .element(nodeID: 4, name: "body"),
                ]
            ),
        ]
    )
}

private func frameDocument(rootNodeID: Int, selectedNodeName: String = "img") -> DOMNodePayload {
    document(
        nodeID: rootNodeID,
        children: [
            .element(
                nodeID: 2,
                name: "html",
                children: [
                    .element(
                        nodeID: 3,
                        name: "body",
                        children: [
                            .element(
                                nodeID: 8,
                                name: selectedNodeName,
                                attributes: [.init(name: "id", value: "ad-node")]
                            ),
                        ]
                    ),
                ]
            ),
        ]
    )
}

private extension DOMNodePayload {
    static func element(
        nodeID: Int,
        name: String,
        frameID: DOMFrame.ID? = nil,
        attributes: [DOMAttribute] = [],
        children: [DOMNodePayload] = [],
        shadowRoots: [DOMNodePayload] = [],
        templateContent: DOMNodePayload? = nil,
        beforePseudoElement: DOMNodePayload? = nil,
        otherPseudoElements: [DOMNodePayload] = [],
        afterPseudoElement: DOMNodePayload? = nil,
        pseudoType: String? = nil
    ) -> DOMNodePayload {
        DOMNodePayload(
            nodeID: .init(nodeID),
            nodeType: .element,
            nodeName: name,
            localName: name,
            frameID: frameID,
            attributes: attributes,
            regularChildren: .loaded(children),
            shadowRoots: shadowRoots,
            templateContent: templateContent,
            beforePseudoElement: beforePseudoElement,
            otherPseudoElements: otherPseudoElements,
            afterPseudoElement: afterPseudoElement,
            pseudoType: pseudoType
        )
    }
}
