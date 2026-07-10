import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@MainActor
@Test
func domStateStorePreservesNodeIdentityAcrossPayloadUpdates() throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = DOMStateStore()
    let documentID = DOM.Node.ID("document")
    let elementID = DOM.Node.ID("element")

    let applied = store.applyDocument(
        DOM.Node(
            id: documentID,
            nodeType: 9,
            nodeName: "#document",
            children: [
                DOM.Node(
                    id: elementID,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    attributes: ["class": "before"]
                )
            ]
        ),
        expectedEpoch: store.documentEpoch,
        reason: .initialDocument,
        modelContext: context,
        isolation: MainActor.shared
    )
    #expect(applied != nil)
    let original = try #require(store.node(for: DOMNode.ID(elementID)))

    _ = store.apply(
        .attributeModified(elementID, name: "class", value: "after"),
        modelContext: context,
        isolation: MainActor.shared
    )

    #expect(store.node(for: DOMNode.ID(elementID)) === original)
    #expect(original.attributes["class"] == "after")
}

@MainActor
@Test
func domStateStoreDocumentResetAdvancesEpochAndClearsSemanticState() throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = DOMStateStore()
    let childID = DOM.Node.ID("selected")
    _ = store.applyDocument(
        DOM.Node(
            id: DOM.Node.ID("document"),
            nodeType: 9,
            nodeName: "#document",
            children: [DOM.Node(id: childID, nodeType: 1, nodeName: "DIV", localName: "div")]
        ),
        expectedEpoch: store.documentEpoch,
        reason: .initialDocument,
        modelContext: context,
        isolation: MainActor.shared
    )
    let child = try #require(store.node(for: DOMNode.ID(childID)))
    _ = store.select(child, reveal: .none, isolation: MainActor.shared)
    _ = store.setElementPickerEnabled(true, isolation: MainActor.shared)
    let previousEpoch = store.documentEpoch

    let effects = store.apply(
        .documentUpdated,
        modelContext: context,
        isolation: MainActor.shared
    )

    #expect(store.documentEpoch == previousEpoch + 1)
    #expect(store.rootNode == nil)
    #expect(store.selectedNode == nil)
    #expect(store.node(for: child.id) == nil)
    #expect(store.isElementPickerEnabled == false)
    #expect(effects.documentReset)
    #expect(effects.shouldReloadDocument)
}

@MainActor
@Test
func domStateStoreProjectsFrameDocumentUnderItsFrameOwner() throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = DOMStateStore()
    let frameTargetID = WebInspectorTarget.ID("frame-target")
    let frameID = FrameID("child-frame")
    let iframeID = DOM.Node.ID("iframe")
    let frameDocumentID = DOM.Node.ID("frame-document")

    _ = store.applyDocument(
        DOM.Node(
            id: DOM.Node.ID("document"),
            nodeType: 9,
            nodeName: "#document",
            children: [
                DOM.Node(
                    id: iframeID,
                    nodeType: 1,
                    nodeName: "IFRAME",
                    localName: "iframe",
                    frameID: frameID
                )
            ]
        ),
        expectedEpoch: store.documentEpoch,
        reason: .initialDocument,
        modelContext: context,
        isolation: MainActor.shared
    )

    let applied = store.applyFrameDocument(
        DOM.Node(
            id: frameDocumentID,
            nodeType: 9,
            nodeName: "#document",
            frameID: frameID
        ),
        frameTargetID: frameTargetID,
        expectedEpoch: store.documentEpoch,
        modelContext: context,
        isolation: MainActor.shared
    )
    #expect(applied != nil)

    let scopedDocumentID = DOMNode.ID(DOM.Node.ID(
        frameDocumentID.rawValue,
        scopedToTargetRawValue: frameTargetID.rawValue
    ))
    let snapshot = store.currentTreeSnapshot(isolation: MainActor.shared)
    #expect(snapshot.parent(of: scopedDocumentID) == DOMNode.ID(iframeID))
    #expect(snapshot.visibleChildren(of: DOMNode.ID(iframeID)).nodeIDs == [scopedDocumentID])
}

@MainActor
@Test
func domStateStorePublishesSelectionDeltaAndRevealFromOneMutation() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = DOMStateStore()
    let parentID = DOM.Node.ID("parent")
    let childID = DOM.Node.ID("child")
    _ = store.applyDocument(
        DOM.Node(
            id: DOM.Node.ID("document"),
            nodeType: 9,
            nodeName: "#document",
            children: [
                DOM.Node(
                    id: parentID,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    children: [DOM.Node(id: childID, nodeType: 1, nodeName: "SPAN", localName: "span")]
                )
            ]
        ),
        expectedEpoch: store.documentEpoch,
        reason: .initialDocument,
        modelContext: context,
        isolation: MainActor.shared
    )
    let controller = store.rootTreeController(isolation: MainActor.shared)
    var updateIterator = controller.updates.makeAsyncIterator()
    var revealIterator = controller.revealRequests.makeAsyncIterator()
    guard case .snapshot? = await updateIterator.next() else {
        Issue.record("Expected the atomic initial DOM snapshot.")
        return
    }
    let child = try #require(store.node(for: DOMNode.ID(childID)))

    _ = store.select(child, reveal: .selectOnly, isolation: MainActor.shared)

    #expect(await updateIterator.next() == .delta(.selectionChanged(nodeID: child.id)))
    #expect(await revealIterator.next() == DOMTreeRevealRequest(
        nodeID: child.id,
        ancestorNodeIDs: [DOMNode.ID(parentID), DOMNode.ID(DOM.Node.ID("document"))],
        shouldSelect: true,
        shouldScroll: false
    ))
}

@MainActor
@Test
func domStateStoreTreeSubscriptionBridgesInitialSnapshotAndNextDeltaAtomically() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = DOMStateStore()
    let elementID = DOM.Node.ID("element")
    _ = store.applyDocument(
        DOM.Node(
            id: DOM.Node.ID("document"),
            nodeType: 9,
            nodeName: "#document",
            children: [DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")]
        ),
        expectedEpoch: store.documentEpoch,
        reason: .initialDocument,
        modelContext: context,
        isolation: MainActor.shared
    )
    let controller = store.rootTreeController(isolation: MainActor.shared)
    let initialRevision = controller.revision
    var iterator = controller.updates.makeAsyncIterator()

    _ = store.apply(
        .attributeModified(elementID, name: "class", value: "updated"),
        modelContext: context,
        isolation: MainActor.shared
    )

    guard case let .snapshot(snapshot, reason)? = await iterator.next() else {
        Issue.record("Expected initial snapshot before the next delta.")
        return
    }
    #expect(snapshot.revision == initialRevision)
    #expect(snapshot.node(for: DOMNode.ID(elementID))?.attributes["class"] == nil)
    #expect(reason == .initialDocument)
    #expect(await iterator.next() == .delta(.nodeChanged(nodeID: DOMNode.ID(elementID))))
}

@MainActor
@Test
func domStateStoreRejectsDocumentFromStaleEpoch() {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = DOMStateStore()
    let staleEpoch = store.documentEpoch
    store.advanceDocumentEpoch(isolation: MainActor.shared)
    _ = store.resetDocument(isolation: MainActor.shared)

    let applied = store.applyDocument(
        DOM.Node(id: DOM.Node.ID("stale-document"), nodeType: 9, nodeName: "#document"),
        expectedEpoch: staleEpoch,
        reason: .documentUpdated,
        modelContext: context,
        isolation: MainActor.shared
    )

    #expect(applied == nil)
    #expect(store.rootNode == nil)
}

@MainActor
@Test
func domStateStoreKeepsOnlyWeakTreeRegistrations() {
    let store = DOMStateStore()
    weak var releasedController: DOMTreeController?

    do {
        let controller = store.rootTreeController(isolation: MainActor.shared)
        releasedController = controller
        #expect(releasedController != nil)
    }

    #expect(releasedController == nil)
    _ = store.resetDocument(isolation: MainActor.shared)
}
