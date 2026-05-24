import Testing
@testable import WebInspectorCore

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

    #expect(snapshot.currentPageTargetID == pageTargetID)
    #expect(snapshot.mainFrameID == mainFrameID)
    #expect(snapshot.targetsByID[pageTargetID]?.kind == .page)
    #expect(snapshot.framesByID[mainFrameID]?.targetID == pageTargetID)
}

@Test
func pageTargetCreationWithoutMainPageFlagOnlyRegistersTarget() async throws {
    let pageTargetID = ProtocolTarget.ID("page-candidate")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page))
    let snapshot = await session.snapshot()

    #expect(snapshot.currentPageTargetID == nil)
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

    #expect(after.currentPageTargetID == committedTargetID)
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
    #expect(after.framesByID[frameID]?.currentDocumentID == nil)
    #expect(after.nodesByID[frameRootID] == nil)
    #expect(after.frameDocumentProjections[committedFrameTargetID]?.state == .pending)
    #expect(after.frameDocumentProjections[committedFrameTargetID]?.ownerNodeID == nil)
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
func beginInspectSelectionRequestUsesExplicitProtocolTarget() async throws {
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID))
    _ = await session.replaceDocumentRoot(document(nodeID: 1), targetID: frameTargetID)

    let result = await session.beginInspectSelectionRequest(
        targetID: frameTargetID,
        objectID: "remote-node"
    )

    guard case let .success(.requestNode(_, targetID, objectID)) = result else {
        Issue.record("Expected DOM.requestNode")
        return
    }
    #expect(targetID == frameTargetID)
    #expect(objectID == "remote-node")
}

@Test
func beginInspectSelectionRequestUsesExplicitPickerTarget() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(document(nodeID: 1), targetID: pageTargetID)

    let result = await session.beginInspectSelectionRequest(
        targetID: pageTargetID,
        objectID: "opaque-remote-node"
    )

    guard case let .success(.requestNode(_, targetID, objectID)) = result else {
        Issue.record("Expected fallback DOM.requestNode")
        return
    }
    #expect(targetID == pageTargetID)
    #expect(objectID == "opaque-remote-node")
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
    let firstPageDocumentID = try #require(first.targetsByID[pageTargetID]?.currentDocumentID)

    _ = await session.replaceDocumentRoot(pageDocumentWithoutIframe(), targetID: pageTargetID)
    let second = await session.snapshot()
    let secondPageDocumentID = try #require(second.targetsByID[pageTargetID]?.currentDocumentID)
    let projection = await session.treeProjection(rootTargetID: pageTargetID)

    #expect(firstPageDocumentID.localDocumentLifetimeID == .init(1))
    #expect(secondPageDocumentID.localDocumentLifetimeID == .init(2))
    #expect(second.nodesByID[frameRootID] != nil)
    #expect(projection.rows.map(\.nodeID).contains(frameRootID) == false)
}

@Test
func resetDoesNotReuseDocumentLifetimeForSameTargetID() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let mainFrameID = DOMFrame.ID("main-frame")
    let session = await DOMSession()

    await session.applyTargetCreated(
        .init(id: pageTargetID, kind: .page, frameID: mainFrameID),
        makeCurrentMainPage: true
    )
    _ = await session.replaceDocumentRoot(pageDocumentWithoutIframe(), targetID: pageTargetID)
    let firstDocumentID = try #require(await session.snapshot().targetsByID[pageTargetID]?.currentDocumentID)
    let revisionBeforeReset = await session.treeRevision
    let selectionRevisionBeforeReset = await session.selectionRevision

    await session.reset()
    #expect(await session.treeRevision > revisionBeforeReset)
    #expect(await session.selectionRevision > selectionRevisionBeforeReset)
    await session.applyTargetCreated(
        .init(id: pageTargetID, kind: .page, frameID: mainFrameID),
        makeCurrentMainPage: true
    )
    _ = await session.replaceDocumentRoot(pageDocumentWithoutIframe(), targetID: pageTargetID)
    let secondDocumentID = try #require(await session.snapshot().targetsByID[pageTargetID]?.currentDocumentID)

    #expect(firstDocumentID.targetID == pageTargetID)
    #expect(secondDocumentID.targetID == pageTargetID)
    #expect(firstDocumentID.localDocumentLifetimeID == .init(1))
    #expect(secondDocumentID.localDocumentLifetimeID == .init(2))
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
    let projectionState = try #require(snapshot.frameDocumentProjections[frameTargetID])

    #expect(iframe.ownerFrameID == DOMFrameIdentifier("main-frame"))
    #expect(iframe.regularChildIDs.isEmpty)
    #expect(snapshot.nodesByID[frameRootID]?.parentID == nil)
    #expect(projectionState.ownerNodeID == iframeID)
    #expect(projectionState.state == .attached)
    #expect(projection.parent(of: frameRootID) == iframeID)
    #expect(projection.children(of: iframeID) == [frameRootID])
    #expect(projection.rows.contains { $0.nodeID == frameRootID && $0.depth > iframeDepth(in: projection, iframeID: iframeID) })
}

@Test
func pendingFrameOwnerHydrationWalksLoadedDescendants() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let mainFrameID = DOMFrame.ID("main-frame")
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page, frameID: mainFrameID), makeCurrentMainPage: true)
    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID, parentFrameID: mainFrameID))
    _ = await session.replaceDocumentRoot(pageDocumentWithNestedUnloadedOwner(), targetID: pageTargetID)
    _ = await session.replaceDocumentRoot(frameDocument(rootNodeID: 101), targetID: frameTargetID)

    let wrapperID = try #require(
        await session.snapshot().currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(30))]
    )
    #expect(await session.pendingFrameOwnerHydrationIntent() == .requestChildNodes(targetID: pageTargetID, nodeID: .init(30), depth: 1))
    #expect(await session.pendingFrameOwnerHydrationIntent() == nil)
    await session.clearOwnerHydrationTransactions(targetID: pageTargetID)
    #expect(await session.pendingFrameOwnerHydrationIntent() == .requestChildNodes(targetID: pageTargetID, nodeID: .init(30), depth: 1))

    await session.applySetChildNodes(
        parent: wrapperID,
        children: [
            .element(
                nodeID: 31,
                name: "iframe",
                ownerFrameID: mainFrameID,
                attributes: [.init(name: "src", value: "https://frame.example/ad")]
            ),
        ]
    )
    let snapshot = await session.snapshot()
    let iframeID = try #require(snapshot.currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(31))])
    #expect(snapshot.frameDocumentProjections[frameTargetID]?.ownerNodeID == iframeID)
    #expect(snapshot.frameDocumentProjections[frameTargetID]?.state == .attached)
}

@Test
func frameOwnerCandidatesAreScopedToParentFrameDocument() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let mainFrameID = DOMFrame.ID("main-frame")
    let childFrameTargetID = ProtocolTarget.ID("frame-child-target")
    let childFrameID = DOMFrame.ID("frame-child")
    let nestedFrameTargetID = ProtocolTarget.ID("frame-nested-target")
    let nestedFrameID = DOMFrame.ID("frame-nested")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page, frameID: mainFrameID), makeCurrentMainPage: true)
    await session.applyTargetCreated(.init(id: childFrameTargetID, kind: .frame, frameID: childFrameID, parentFrameID: mainFrameID))
    await session.applyTargetCreated(.init(id: nestedFrameTargetID, kind: .frame, frameID: nestedFrameID, parentFrameID: childFrameID))
    _ = await session.replaceDocumentRoot(pageDocument(iframeFrameID: childFrameID, ownerFrameID: mainFrameID), targetID: pageTargetID)
    _ = await session.replaceDocumentRoot(pageDocument(iframeFrameID: nestedFrameID, ownerFrameID: childFrameID), targetID: childFrameTargetID)
    _ = await session.replaceDocumentRoot(frameDocument(rootNodeID: 201), targetID: nestedFrameTargetID)

    let snapshot = await session.snapshot()
    let childDocumentIframeID = try #require(
        snapshot.currentNodeIDByKey[.init(targetID: childFrameTargetID, nodeID: .init(20))]
    )

    #expect(snapshot.frameDocumentProjections[nestedFrameTargetID]?.ownerNodeID == childDocumentIframeID)
    #expect(snapshot.frameDocumentProjections[nestedFrameTargetID]?.state == .attached)
}

@Test
func nestedFrameProjectionWaitsForParentFrameDocumentBeforeOwnerMatching() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let mainFrameID = DOMFrame.ID("main-frame")
    let childFrameTargetID = ProtocolTarget.ID("frame-child-target")
    let childFrameID = DOMFrame.ID("frame-child")
    let nestedFrameTargetID = ProtocolTarget.ID("frame-nested-target")
    let nestedFrameID = DOMFrame.ID("frame-nested")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page, frameID: mainFrameID), makeCurrentMainPage: true)
    await session.applyTargetCreated(.init(id: childFrameTargetID, kind: .frame, frameID: childFrameID, parentFrameID: mainFrameID))
    await session.applyTargetCreated(.init(id: nestedFrameTargetID, kind: .frame, frameID: nestedFrameID, parentFrameID: childFrameID))
    _ = await session.replaceDocumentRoot(
        pageDocument(
            iframeFrameID: childFrameID,
            ownerFrameID: mainFrameID,
            iframeAttributes: [.init(name: "src", value: "https://frame.example/child")]
        ),
        targetID: pageTargetID
    )
    let nestedRootID = await session.replaceDocumentRoot(
        frameDocument(rootNodeID: 201, documentURL: "https://frame.example/nested"),
        targetID: nestedFrameTargetID
    )

    var snapshot = await session.snapshot()
    #expect(snapshot.frameDocumentProjections[nestedFrameTargetID]?.ownerNodeID == nil)
    #expect(snapshot.frameDocumentProjections[nestedFrameTargetID]?.state == .pending)

    _ = await session.replaceDocumentRoot(
        nestedOwnerFrameDocument(
            documentURL: "https://frame.example/child",
            nestedFrameURL: "https://frame.example/nested",
            ownerFrameID: childFrameID
        ),
        targetID: childFrameTargetID
    )
    snapshot = await session.snapshot()
    let childDocumentIframeID = try #require(
        snapshot.currentNodeIDByKey[.init(targetID: childFrameTargetID, nodeID: .init(20))]
    )
    let projection = await session.treeProjection(rootTargetID: pageTargetID)

    #expect(snapshot.frameDocumentProjections[nestedFrameTargetID]?.ownerNodeID == childDocumentIframeID)
    #expect(snapshot.frameDocumentProjections[nestedFrameTargetID]?.state == .attached)
    #expect(projection.rows.map(\.nodeID).contains(nestedRootID))
}

@Test
func frameDocumentProjectionRemainsPendingWhenURLDoesNotMatch() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let mainFrameID = DOMFrame.ID("main-frame")
    let frameID = DOMFrame.ID("frame-ad")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page, frameID: mainFrameID), makeCurrentMainPage: true)
    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID, parentFrameID: mainFrameID))
    _ = await session.replaceDocumentRoot(
        pageDocument(
            iframeFrameID: frameID,
            iframeAttributes: [.init(name: "src", value: "https://ads.example/bootstrap")]
        ),
        targetID: pageTargetID
    )
    let frameRootID = await session.replaceDocumentRoot(
        frameDocument(rootNodeID: 101, documentURL: "https://redirect.example/final-ad"),
        targetID: frameTargetID
    )

    let snapshot = await session.snapshot()
    let projection = await session.treeProjection(rootTargetID: pageTargetID)
    let projectionState = try #require(snapshot.frameDocumentProjections[frameTargetID])

    #expect(projectionState.ownerNodeID == nil)
    #expect(projectionState.state == .pending)
    #expect(projection.rows.map(\.nodeID).contains(frameRootID) == false)
}

@Test
func srcLessIframeOwnerProjectsAboutBlankFrameDocument() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID))
    _ = await session.replaceDocumentRoot(
        pageDocument(iframeFrameID: frameID, iframeAttributes: []),
        targetID: pageTargetID
    )
    let frameRootID = await session.replaceDocumentRoot(
        frameDocument(rootNodeID: 101, documentURL: "about:blank"),
        targetID: frameTargetID
    )

    let snapshot = await session.snapshot()
    let projection = await session.treeProjection(rootTargetID: pageTargetID)
    let iframeID = try #require(snapshot.currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(20))])

    #expect(snapshot.frameDocumentProjections[frameTargetID]?.ownerNodeID == iframeID)
    #expect(snapshot.frameDocumentProjections[frameTargetID]?.state == .attached)
    #expect(projection.rows.contains { $0.nodeID == frameRootID && $0.depth > iframeDepth(in: projection, iframeID: iframeID) })
}

@Test
func iframeOwnerSetChildNodesDoesNotRemoveAttachedFrameDocumentProjection() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID))
    _ = await session.replaceDocumentRoot(pageDocument(iframeFrameID: frameID), targetID: pageTargetID)
    let frameRootID = await session.replaceDocumentRoot(frameDocument(rootNodeID: 101), targetID: frameTargetID)
    let before = await session.snapshot()
    let iframeID = try #require(before.currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(20))])

    await session.applySetChildNodes(
        parent: iframeID,
        children: [
            .element(nodeID: 30, name: "span"),
        ]
    )

    let after = await session.snapshot()
    let projection = await session.treeProjection(rootTargetID: pageTargetID)
    let iframe = try #require(after.nodesByID[iframeID])

    #expect(iframe.regularChildIDs.isEmpty)
    #expect(after.currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(30))] == nil)
    #expect(after.frameDocumentProjections[frameTargetID]?.ownerNodeID == iframeID)
    #expect(after.frameDocumentProjections[frameTargetID]?.state == .attached)
    #expect(projection.rows.contains { $0.nodeID == frameRootID && $0.depth > iframeDepth(in: projection, iframeID: iframeID) })
}

@Test
func ambiguousURLFallbackLeavesFrameDocumentPending() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID))
    _ = await session.replaceDocumentRoot(pageDocumentWithDuplicateIframeURLs(), targetID: pageTargetID)
    let frameRootID = await session.replaceDocumentRoot(frameDocument(rootNodeID: 101), targetID: frameTargetID)

    let snapshot = await session.snapshot()
    let projection = await session.treeProjection(rootTargetID: pageTargetID)
    let projectionState = try #require(snapshot.frameDocumentProjections[frameTargetID])

    #expect(projectionState.ownerNodeID == nil)
    #expect(projectionState.state == .ambiguous)
    #expect(projection.rows.map(\.nodeID).contains(frameRootID) == false)
}

@Test
func frameIDMatchDisambiguatesDuplicateURLFrameOwners() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-b-target")
    let frameID = DOMFrame.ID("frame-b")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID))
    _ = await session.replaceDocumentRoot(pageDocumentWithDuplicateIframeURLsAndFrameIDs(), targetID: pageTargetID)
    let frameRootID = await session.replaceDocumentRoot(frameDocument(rootNodeID: 101), targetID: frameTargetID)

    let snapshot = await session.snapshot()
    let projection = await session.treeProjection(rootTargetID: pageTargetID)
    let expectedIframeID = try #require(snapshot.currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(21))])
    let projectionState = try #require(snapshot.frameDocumentProjections[frameTargetID])

    #expect(projectionState.ownerNodeID == expectedIframeID)
    #expect(projectionState.state == .attached)
    #expect(projection.rows.contains { $0.nodeID == frameRootID && $0.depth > iframeDepth(in: projection, iframeID: expectedIframeID) })
}

@Test
func iframeOwnerSrcMutationReevaluatesFrameDocumentProjection() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID))
    _ = await session.replaceDocumentRoot(
        pageDocument(
            iframeFrameID: frameID,
            iframeAttributes: [.init(name: "src", value: "about:blank")]
        ),
        targetID: pageTargetID
    )
    let frameRootID = await session.replaceDocumentRoot(frameDocument(rootNodeID: 101), targetID: frameTargetID)
    let before = await session.snapshot()
    let iframeID = try #require(before.currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(20))])

    #expect(before.frameDocumentProjections[frameTargetID]?.ownerNodeID == nil)
    #expect(before.frameDocumentProjections[frameTargetID]?.state == .pending)

    await session.applyAttributeModified(iframeID, name: "src", value: "https://frame.example/ad")
    let after = await session.snapshot()
    let projection = await session.treeProjection(rootTargetID: pageTargetID)

    #expect(after.nodesByID[iframeID]?.attributes.first { $0.name == "src" }?.value == "https://frame.example/ad")
    #expect(after.frameDocumentProjections[frameTargetID]?.ownerNodeID == iframeID)
    #expect(after.frameDocumentProjections[frameTargetID]?.state == .attached)
    #expect(after.nodesByID[frameRootID]?.parentID == nil)
    #expect(projection.parent(of: frameRootID) == iframeID)
    #expect(projection.rows.contains { $0.nodeID == frameRootID && $0.depth > iframeDepth(in: projection, iframeID: iframeID) })

    await session.applyAttributeModified(iframeID, name: "src", value: "https://other.example/ad")
    let afterMismatch = await session.snapshot()
    let mismatchedProjection = await session.treeProjection(rootTargetID: pageTargetID)
    #expect(afterMismatch.frameDocumentProjections[frameTargetID]?.ownerNodeID == nil)
    #expect(afterMismatch.frameDocumentProjections[frameTargetID]?.state == .pending)
    #expect(afterMismatch.nodesByID[frameRootID]?.parentID == nil)
    #expect(mismatchedProjection.rows.map(\.nodeID).contains(frameRootID) == false)

    await session.applyAttributeModified(iframeID, name: "src", value: "https://frame.example/ad")
    let reattached = await session.snapshot()
    let reattachedProjection = await session.treeProjection(rootTargetID: pageTargetID)
    #expect(reattached.frameDocumentProjections[frameTargetID]?.ownerNodeID == iframeID)
    #expect(reattached.nodesByID[frameRootID]?.parentID == nil)
    #expect(reattachedProjection.parent(of: frameRootID) == iframeID)

    await session.applyAttributeRemoved(iframeID, name: "src")
    let afterRemoval = await session.snapshot()
    let removedProjection = await session.treeProjection(rootTargetID: pageTargetID)
    #expect(afterRemoval.frameDocumentProjections[frameTargetID]?.ownerNodeID == nil)
    #expect(afterRemoval.frameDocumentProjections[frameTargetID]?.state == .pending)
    #expect(afterRemoval.nodesByID[frameRootID]?.parentID == nil)
    #expect(removedProjection.rows.map(\.nodeID).contains(frameRootID) == false)
}

@Test
func getDocumentIntentRequiresDOMCapability() async throws {
    let session = await DOMSession()
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")

    await session.applyTargetCreated(
        .init(id: pageTargetID, kind: .page, capabilities: [.dom]),
        makeCurrentMainPage: true
    )
    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame))

    #expect(await session.getDocumentIntent(targetID: pageTargetID) == .getDocument(targetID: pageTargetID))
    #expect(await session.getDocumentIntent(targetID: frameTargetID) == nil)
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
    #expect(snapshot.frameDocumentProjections[frameTargetID]?.state == .attached)
    #expect(snapshot.frameDocumentProjections[frameTargetID]?.ownerNodeID != nil)
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

    #expect(after.frameDocumentProjections[frameTargetID]?.ownerNodeID == nil)
    #expect(after.frameDocumentProjections[frameTargetID]?.state == .pending)
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
func setChildNodesPreservesProtocolChildOrderAndSiblingLinks() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(
        document(nodeID: 1, children: [.element(nodeID: 2, name: "body")]),
        targetID: pageTargetID
    )
    let bodyID = try #require(await session.snapshot().currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(2))])

    await session.applySetChildNodes(
        parent: bodyID,
        children: [
            .element(nodeID: 3, name: "style"),
            .element(nodeID: 4, name: "script"),
            .element(nodeID: 5, name: "div"),
        ],
        eventSequence: 1
    )

    let snapshot = await session.snapshot()
    let childIDs = try [3, 4, 5].map { nodeID in
        try #require(snapshot.currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(nodeID))])
    }

    #expect(snapshot.nodesByID[bodyID]?.regularChildren.loadedChildren == childIDs)
    #expect(snapshot.nodesByID[childIDs[0]]?.previousSiblingID == nil)
    #expect(snapshot.nodesByID[childIDs[0]]?.nextSiblingID == childIDs[1])
    #expect(snapshot.nodesByID[childIDs[1]]?.previousSiblingID == childIDs[0])
    #expect(snapshot.nodesByID[childIDs[1]]?.nextSiblingID == childIDs[2])
    #expect(snapshot.nodesByID[childIDs[2]]?.previousSiblingID == childIDs[1])
    #expect(snapshot.nodesByID[childIDs[2]]?.nextSiblingID == nil)
}

@Test("Regression: detached root cannot overwrite connected page document nodes")
func detachedRootCannotOverwriteConnectedPageDocumentNodes() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(pageDocumentWithoutIframe(), targetID: pageTargetID)
    let before = await session.snapshot()

    let htmlKey = DOMNodeCurrentKey(targetID: pageTargetID, nodeID: .init(2))
    let headKey = DOMNodeCurrentKey(targetID: pageTargetID, nodeID: .init(3))
    let bodyKey = DOMNodeCurrentKey(targetID: pageTargetID, nodeID: .init(4))
    let htmlID = try #require(before.currentNodeIDByKey[htmlKey])
    let headID = try #require(before.currentNodeIDByKey[headKey])
    let bodyID = try #require(before.currentNodeIDByKey[bodyKey])

    await session.applyDetachedRoot(
        targetID: pageTargetID,
        payload: .element(
            nodeID: 2,
            name: "img",
            children: [
                .element(nodeID: 3, name: "source"),
            ]
        ),
        eventSequence: 1
    )

    let after = await session.snapshot()
    let projection = await session.treeProjection(rootTargetID: pageTargetID)

    #expect(after.treeRevision == before.treeRevision)
    #expect(after.currentNodeIDByKey[htmlKey] == htmlID)
    #expect(after.currentNodeIDByKey[headKey] == headID)
    #expect(after.currentNodeIDByKey[bodyKey] == bodyID)
    #expect(after.nodesByID[htmlID]?.nodeName == "html")
    #expect(after.nodesByID[headID]?.parentID == htmlID)
    #expect(after.nodesByID[bodyID]?.parentID == htmlID)
    #expect(projection.rows.map(\.nodeName) == ["#document", "html", "head", "body"])
}

@Test
func childNodeInsertedUsesWebKitPreviousSiblingSemantics() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(
        document(
            nodeID: 1,
            children: [
                .element(
                    nodeID: 2,
                    name: "body",
                    children: [
                        .element(nodeID: 3, name: "a"),
                        .element(nodeID: 5, name: "c"),
                    ]
                ),
            ]
        ),
        targetID: pageTargetID
    )
    var snapshot = await session.snapshot()
    let bodyID = try #require(snapshot.currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(2))])
    let aID = try #require(snapshot.currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(3))])
    let cID = try #require(snapshot.currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(5))])

    let bID = try #require(await session.applyChildInserted(parent: bodyID, previousSibling: aID, child: .element(nodeID: 4, name: "b")))
    let dID = try #require(await session.applyChildInserted(parent: bodyID, previousSibling: nil, child: .element(nodeID: 6, name: "d")))
    snapshot = await session.snapshot()

    #expect(snapshot.nodesByID[bodyID]?.regularChildren.loadedChildren == [dID, aID, bID, cID])
    #expect(snapshot.nodesByID[dID]?.previousSiblingID == nil)
    #expect(snapshot.nodesByID[dID]?.nextSiblingID == aID)
    #expect(snapshot.nodesByID[aID]?.previousSiblingID == dID)
    #expect(snapshot.nodesByID[aID]?.nextSiblingID == bID)
    #expect(snapshot.nodesByID[bID]?.previousSiblingID == aID)
    #expect(snapshot.nodesByID[bID]?.nextSiblingID == cID)
    #expect(snapshot.nodesByID[cID]?.previousSiblingID == bID)
    #expect(snapshot.nodesByID[cID]?.nextSiblingID == nil)
}

@Test
func directNodeSelectionUpdatesProjectionWithoutSnapshotModel() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(pageDocumentWithoutIframe(), targetID: pageTargetID)
    let snapshot = await session.snapshot()
    let htmlID = try #require(snapshot.currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(2))])

    await session.selectNode(htmlID)
    let projection = await session.treeProjection(rootTargetID: pageTargetID)

    #expect(await session.selectedNodeID == htmlID)
    #expect(projection.rows.contains { $0.nodeID == htmlID && $0.isSelected })
}

@Test
func clearingNodeSelectionCancelsPendingInspectSelection() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(pageDocumentWithoutIframe(), targetID: pageTargetID)

    let command = await session.beginInspectSelectionRequest(
        targetID: pageTargetID,
        objectID: "page-object"
    )
    let requestID: SelectionRequestIdentifier
    guard case let .success(.requestNode(id, _, _)) = command else {
        Issue.record("Expected pending requestNode selection")
        return
    }
    requestID = id

    await session.selectNode(nil)
    #expect((await session.snapshot()).selection.pendingRequest == nil)

    let result = await session.applyRequestNodeResult(
        selectionRequestID: requestID,
        targetID: pageTargetID,
        nodeID: .init(2)
    )
    guard case let .failed(.staleSelectionRequest(expected, received)) = result else {
        Issue.record("Expected cancelled request to be rejected as stale")
        return
    }
    #expect(expected == nil)
    #expect(received == requestID)
    #expect(await session.selectedNodeID == nil)
}

@Test
func protocolNodeSelectionResolvesCurrentNodeKey() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(pageDocumentWithoutIframe(), targetID: pageTargetID)

    let result = await session.selectProtocolNode(targetID: pageTargetID, nodeID: .init(2))

    let selectedID = try result.get()
    #expect(selectedID.nodeID == .init(2))
    #expect(await session.selectedNodeID == selectedID)
}

@Test
func unknownProtocolNodeSelectionRecordsFailure() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(pageDocumentWithoutIframe(), targetID: pageTargetID)
    let htmlID = try #require(
        await session.snapshot().currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(2))]
    )
    await session.selectNode(htmlID)

    let result = await session.selectProtocolNode(targetID: pageTargetID, nodeID: .init(999))

    guard case let .failure(.unresolvedNode(key)) = result else {
        Issue.record("Expected unresolved protocol node failure")
        return
    }
    #expect(key == DOMNodeCurrentKey(targetID: pageTargetID, nodeID: .init(999)))
    #expect((await session.snapshot()).selection.selectedNodeID == htmlID)
}

@Test
func selectedNodeCopyHelpersGenerateSelectorPathAndXPath() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(
        document(
            nodeID: 1,
            children: [
                .element(
                    nodeID: 2,
                    name: "html",
                    children: [
                        .element(
                            nodeID: 3,
                            name: "body",
                            children: [
                                .element(nodeID: 4, name: "div", attributes: [.init(name: "class", value: "card")]),
                                .element(
                                    nodeID: 5,
                                    name: "div",
                                    attributes: [.init(name: "class", value: "2xl selected")]
                                ),
                                .element(
                                    nodeID: 6,
                                    name: "section",
                                    attributes: [.init(name: "id", value: "123")]
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        ),
        targetID: pageTargetID
    )

    let nodeID = try #require((await session.snapshot()).currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(5))])
    await session.selectNode(nodeID)

    #expect(await session.selectedNodeCopyText(.selectorPath) == "body > div.\\32 xl.selected")
    #expect(await session.selectedNodeCopyText(.xPath) == "/html/body/div[2]")

    let idNodeID = try #require((await session.snapshot()).currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(6))])
    await session.selectNode(idNodeID)
    #expect(await session.selectedNodeCopyText(.selectorPath) == "#\\31 23")
}

@Test
func selectedNodeActionIntentsUseCommandIdentity() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(pageDocumentWithoutIframe(), targetID: pageTargetID)
    let htmlID = try #require((await session.snapshot()).currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(2))])

    let identity = DOMActionIdentity(
        documentTargetID: pageTargetID,
        rawNodeID: .init(2),
        commandTargetID: pageTargetID,
        commandNodeID: .protocolNode(.init(2))
    )
    #expect(await session.actionIdentity(for: htmlID) == identity)
    #expect(await session.outerHTMLIntent(for: htmlID) == .getOuterHTML(identity: identity))
    #expect(await session.removeNodeIntent(for: htmlID) == .removeNode(identity: identity))
}

@Test
func frameDocumentActionIdentityUsesMainTargetScopedCommandNode() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page, frameID: .init("main-frame")), makeCurrentMainPage: true)
    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID, parentFrameID: .init("main-frame")))
    _ = await session.replaceDocumentRoot(pageDocument(iframeFrameID: frameID), targetID: pageTargetID)
    _ = await session.replaceDocumentRoot(frameDocument(rootNodeID: 101), targetID: frameTargetID)
    let frameHTMLID = try #require((await session.snapshot()).currentNodeIDByKey[.init(targetID: frameTargetID, nodeID: .init(2))])

    let identity = try #require(await session.actionIdentity(for: frameHTMLID, commandTargetID: pageTargetID))

    #expect(identity.documentTargetID == frameTargetID)
    #expect(identity.rawNodeID == .init(2))
    #expect(identity.commandTargetID == pageTargetID)
    #expect(identity.commandNodeID == .scoped(targetID: frameTargetID, nodeID: .init(2)))
    #expect(await session.outerHTMLIntent(for: frameHTMLID, commandTargetID: pageTargetID) == .getOuterHTML(identity: identity))
    #expect(await session.removeNodeIntent(for: frameHTMLID, commandTargetID: pageTargetID) == .removeNode(identity: identity))

    let highlightIdentity = DOMActionIdentity(
        documentTargetID: frameTargetID,
        rawNodeID: .init(2),
        commandTargetID: frameTargetID,
        commandNodeID: .protocolNode(.init(2))
    )
    #expect(await session.highlightNodeIntent(for: frameHTMLID) == .highlightNode(identity: highlightIdentity))
}

@Test
func requestChildNodesIntentUsesNodeOwningTargetAndDepth() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(
        DOMNodePayload(
            nodeID: .init(1),
            nodeType: .element,
            nodeName: "article",
            localName: "article",
            regularChildren: .unrequested(count: 2)
        ),
        targetID: pageTargetID
    )
    let rootID = try #require(await session.currentPageRootNode?.id)

    let intent = await session.requestChildNodesIntent(for: rootID, depth: 4)

    #expect(intent == .requestChildNodes(targetID: pageTargetID, nodeID: .init(1), depth: 4))
}

@Test
func setChildNodesAppliesToCurrentDocumentWithoutTransaction() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(
        document(
            nodeID: 1,
            children: [
                DOMNodePayload(
                    nodeID: .init(4),
                    nodeType: .element,
                    nodeName: "BODY",
                    localName: "body",
                    regularChildren: .unrequested(count: 1)
                ),
            ]
        ),
        targetID: pageTargetID
    )
    let bodyID = try #require(await session.snapshot().currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(4))])

    await session.applySetChildNodes(
        parent: bodyID,
        children: [.element(nodeID: 8, name: "style")],
        eventSequence: 9
    )
    var snapshot = await session.snapshot()
    let styleID = try #require(snapshot.currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(8))])
    #expect(snapshot.nodesByID[styleID]?.nodeName == "style")

    await session.invalidateDocument(targetID: pageTargetID)
    await session.applySetChildNodes(
        parent: bodyID,
        children: [.element(nodeID: 9, name: "script")],
        eventSequence: 11
    )
    snapshot = await session.snapshot()
    #expect(snapshot.currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(9))] == nil)
}

@Test
func mainDocumentSelectionRequestsPageTarget() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(pageDocumentWithoutIframe(), targetID: pageTargetID)

    let result = await session.beginInspectSelectionRequest(
        targetID: pageTargetID,
        objectID: "page-object"
    )

    guard case let .success(.requestNode(_, targetID, objectID)) = result else {
        Issue.record("Expected page target requestNode")
        return
    }
    #expect(targetID == pageTargetID)
    #expect(objectID == "page-object")
}

@Test
func beginInspectSelectionRequestRejectsMissingObjectID() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(pageDocumentWithoutIframe(), targetID: pageTargetID)

    let result = await session.beginInspectSelectionRequest(targetID: pageTargetID, objectID: "")

    #expect(result == .failure(.missingObjectID))
}

@Test
func crossOriginIframeSelectionRequestsFrameTarget() async throws {
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID))
    _ = await session.replaceDocumentRoot(frameDocument(rootNodeID: 101), targetID: frameTargetID)

    let result = await session.beginInspectSelectionRequest(
        targetID: frameTargetID,
        objectID: "frame-object"
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
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID))
    _ = await session.replaceDocumentRoot(pageDocument(iframeFrameID: frameID), targetID: pageTargetID)
    _ = await session.replaceDocumentRoot(frameDocument(rootNodeID: 101, selectedNodeName: "img"), targetID: frameTargetID)
    let refreshedFrameRootID = await session.replaceDocumentRoot(
        frameDocument(rootNodeID: 201, selectedNodeName: "div"),
        targetID: frameTargetID
    )

    let command = await session.beginInspectSelectionRequest(
        targetID: frameTargetID,
        objectID: "frame-object"
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
    let iframeID = try #require(snapshot.currentNodeIDByKey[.init(targetID: pageTargetID, nodeID: .init(20))])

    #expect(snapshot.framesByID[frameID]?.currentDocumentID == refreshedFrameRootID.documentID)
    #expect(selectedNodeID.documentID == refreshedFrameRootID.documentID)
    #expect(snapshot.nodesByID[refreshedFrameRootID]?.parentID == nil)
    #expect(projection.parent(of: refreshedFrameRootID) == iframeID)
    #expect(projection.ancestorNodeIDs(of: selectedNodeID).contains(iframeID))
    #expect(projection.ancestorNodeIDs(of: selectedNodeID).contains(refreshedFrameRootID))
    #expect(projection.rows.contains { $0.nodeID == selectedNodeID && $0.isSelected })
    #expect(await session.selectedNodeCopyText(.selectorPath) == "#ad-node")
    #expect(await session.selectedNodeCopyText(.xPath) == "/html/body/div")
}

@Test
func staleSelectionRequestIsRejectedAfterFrameDocumentRefresh() async throws {
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: frameTargetID, kind: .frame, frameID: frameID))
    _ = await session.replaceDocumentRoot(frameDocument(rootNodeID: 101), targetID: frameTargetID)

    let command = await session.beginInspectSelectionRequest(
        targetID: frameTargetID,
        objectID: "frame-object"
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

    guard case let .failed(.staleDocument(expected, actual)) = result else {
        Issue.record("Expected stale document failure")
        return
    }
    #expect(expected.generation == .init(1))
    #expect(actual?.generation == .init(2))
    #expect(snapshot.selection.selectedNodeID == nil)
}

@Test
func requestNodeReplyAfterDocumentInvalidationIsRejected() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(pageDocumentWithoutIframe(), targetID: pageTargetID)

    let command = await session.beginInspectSelectionRequest(
        targetID: pageTargetID,
        objectID: "page-object"
    )
    let requestID: SelectionRequestIdentifier
    guard case let .success(.requestNode(id, _, _)) = command else {
        Issue.record("Expected pending requestNode selection")
        return
    }
    requestID = id

    await session.invalidateDocument(targetID: pageTargetID)
    let result = await session.applyRequestNodeResult(
        selectionRequestID: requestID,
        targetID: pageTargetID,
        nodeID: .init(2)
    )
    let snapshot = await session.snapshot()

    guard case let .failed(.missingCurrentDocument(targetID)) = result else {
        Issue.record("Expected missing current document failure")
        return
    }
    #expect(targetID == pageTargetID)
    #expect(snapshot.selection.selectedNodeID == nil)
    #expect(snapshot.selection.pendingRequest == nil)
}

@Test
func protocolNodeSelectionAfterDocumentInvalidationIsRejected() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(pageDocumentWithoutIframe(), targetID: pageTargetID)
    await session.invalidateDocument(targetID: pageTargetID)

    let result = await session.selectProtocolNode(targetID: pageTargetID, nodeID: .init(2))
    let snapshot = await session.snapshot()

    guard case let .failure(.missingCurrentDocument(targetID)) = result else {
        Issue.record("Expected missing current document failure")
        return
    }
    #expect(targetID == pageTargetID)
    #expect(snapshot.selection.selectedNodeID == nil)
}

@Test
func selectionFailureDoesNotMutateTreeFrameOrDocumentModel() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let session = await DOMSession()

    await session.applyTargetCreated(.init(id: pageTargetID, kind: .page), makeCurrentMainPage: true)
    _ = await session.replaceDocumentRoot(pageDocumentWithoutIframe(), targetID: pageTargetID)
    let before = await session.snapshot()

    let result = await session.beginInspectSelectionRequest(targetID: pageTargetID, objectID: "")
    let after = await session.snapshot()

    guard case let .failure(failure) = result else {
        Issue.record("Expected selection failure")
        return
    }
    #expect(failure == .missingObjectID)
    #expect(after.selection.failure == .missingObjectID)
    #expect(after.targetsByID == before.targetsByID)
    #expect(after.framesByID == before.framesByID)
    #expect(after.documentsByID == before.documentsByID)
    #expect(after.nodesByID == before.nodesByID)
    #expect(after.currentNodeIDByKey == before.currentNodeIDByKey)
}

private func iframeDepth(in projection: DOMTreeProjection, iframeID: DOMNode.ID) -> Int {
    projection.rows.first(where: { $0.nodeID == iframeID })?.depth ?? -1
}

private func document(
    nodeID: Int,
    documentURL: String? = nil,
    baseURL: String? = nil,
    children: [DOMNodePayload] = []
) -> DOMNodePayload {
    DOMNodePayload(
        nodeID: .init(nodeID),
        nodeType: .document,
        nodeName: "#document",
        documentURL: documentURL,
        baseURL: baseURL,
        regularChildren: .loaded(children)
    )
}

private func pageDocument(
    iframeFrameID _: DOMFrame.ID,
    ownerFrameID: DOMFrame.ID = .init("main-frame"),
    iframeAttributes: [DOMAttribute] = [.init(name: "src", value: "https://frame.example/ad")]
) -> DOMNodePayload {
    document(
        nodeID: 1,
        documentURL: "https://page.example/",
        baseURL: "https://page.example/",
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
                            .element(
                                nodeID: 20,
                                name: "iframe",
                                ownerFrameID: ownerFrameID,
                                attributes: iframeAttributes
                            ),
                        ]
                    ),
                ]
            ),
        ]
    )
}

private func pageDocumentWithDuplicateIframeURLs() -> DOMNodePayload {
    document(
        nodeID: 1,
        documentURL: "https://page.example/",
        baseURL: "https://page.example/",
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
                                nodeID: 20,
                                name: "iframe",
                                ownerFrameID: .init("main-frame"),
                                attributes: [.init(name: "src", value: "https://frame.example/ad")]
                            ),
                            .element(
                                nodeID: 21,
                                name: "iframe",
                                ownerFrameID: .init("main-frame"),
                                attributes: [.init(name: "src", value: "https://frame.example/ad")]
                            ),
                        ]
                    ),
                ]
            ),
        ]
    )
}

private func pageDocumentWithDuplicateIframeURLsAndFrameIDs() -> DOMNodePayload {
    document(
        nodeID: 1,
        documentURL: "https://page.example/",
        baseURL: "https://page.example/",
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
                                nodeID: 20,
                                name: "iframe",
                                ownerFrameID: .init("frame-a"),
                                attributes: [.init(name: "src", value: "https://frame.example/ad")]
                            ),
                            .element(
                                nodeID: 21,
                                name: "iframe",
                                ownerFrameID: .init("frame-b"),
                                attributes: [.init(name: "src", value: "https://frame.example/ad")]
                            ),
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

private func nestedOwnerFrameDocument(
    documentURL: String,
    nestedFrameURL: String,
    ownerFrameID: DOMFrame.ID
) -> DOMNodePayload {
    document(
        nodeID: 1,
        documentURL: documentURL,
        baseURL: documentURL,
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
                            .element(
                                nodeID: 20,
                                name: "iframe",
                                ownerFrameID: ownerFrameID,
                                attributes: [.init(name: "src", value: nestedFrameURL)]
                            ),
                        ]
                    ),
                ]
            ),
        ]
    )
}

private func pageDocumentWithNestedUnloadedOwner() -> DOMNodePayload {
    document(
        nodeID: 1,
        documentURL: "https://page.example/",
        baseURL: "https://page.example/",
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
                            DOMNodePayload(
                                nodeID: .init(30),
                                nodeType: .element,
                                nodeName: "div",
                                localName: "div",
                                regularChildren: .unrequested(count: 1)
                            ),
                        ]
                    ),
                ]
            ),
        ]
    )
}

private func frameDocument(
    rootNodeID: Int,
    documentURL: String = "https://frame.example/ad",
    selectedNodeName: String = "img"
) -> DOMNodePayload {
    document(
        nodeID: rootNodeID,
        documentURL: documentURL,
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
        ownerFrameID: DOMFrame.ID? = nil,
        documentURL: String? = nil,
        baseURL: String? = nil,
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
            ownerFrameID: ownerFrameID,
            documentURL: documentURL,
            baseURL: baseURL,
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
