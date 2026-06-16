#if canImport(UIKit)
import Testing
import WebInspectorTransport
import UIKit
@testable import WebInspectorCore
@testable import WebInspectorUI

@MainActor
@Suite(.serialized)
struct DOMTreeTextViewTests {
    @Test
    func rendersDOMMarkupFromDOMSession() throws {
        let view = makeTreeView()
        let text = view.renderedTextForTesting

        #expect(!text.contains("#document"))
        #expect(text.contains("<!DOCTYPE html>"))
        #expect(text.contains("<html lang=\"en\">"))
        #expect(text.contains("<head>…</head>"))
        #expect(text.contains("<body class=\"logged-in env-production\">"))
        #expect(text.contains("<div id=\"start-of-content\" data-testid=\"cellInnerDiv\"></div>"))
        #expect(text.contains("<input disabled>"))
        #expect(text.contains("<article>…</article>"))
        #expect(text.contains("\"Introducing luma for iOS 26\""))
        #expect(text.contains("<!-- comment text -->"))
    }

    @Test
    func selectingNodeUpdatesCoreSelectionAndRowDecoration() throws {
        let session = makeDOMSession()
        let view = makeTreeView(session: session)

        view.selectRowForTesting(containing: "<input disabled>")
        view.layoutIfNeeded()

        #expect(session.selectedNode?.localName == "input")
        #expect(view.selectedRowRectsForTesting().count == 1)
    }

    @Test
    func primaryClickingRowUpdatesCoreSelection() throws {
        let session = makeDOMSession()
        let view = makeTreeView(session: session)

        view.primaryClickRowForTesting(containing: "<input disabled>")
        view.layoutIfNeeded()

        #expect(session.selectedNode?.localName == "input")
        #expect(view.selectedRowRectsForTesting().count == 1)
    }

    @Test
    func primaryClickingRowHighlightsSelectedPageNode() async throws {
        let session = makeDOMSession()
        let recorder = NodeActionRecorder()
        let view = DOMTreeTextView(
            dom: session,
            highlightNodeAction: { nodeID in
                recorder.record(nodeID)
            }
        )
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()

        view.primaryClickRowForTesting(containing: "<input disabled>")
        let highlightedNodeID = await recorder.nextNodeID()

        #expect(session.selectedNode?.id == highlightedNodeID)
        #expect(session.node(for: highlightedNodeID)?.localName == "input")
    }

    @Test
    func hoverEndRestoresSelectedPageHighlight() async throws {
        let session = makeDOMSession()
        let restoreRecorder = VoidActionRecorder()
        let view = DOMTreeTextView(
            dom: session,
            highlightNodeAction: { _ in },
            restoreHighlightAction: {
                restoreRecorder.record()
            }
        )
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()

        view.primaryClickRowForTesting(containing: "<input disabled>")
        view.hoverRowForTesting(containing: "<article")
        view.endHoverForTesting()
        await restoreRecorder.next()

        #expect(session.selectedNode?.localName == "input")
    }

    @Test
    func expandedElementRendersChildrenAndClosingTag() throws {
        let view = makeTreeView()

        view.toggleRowForTesting(containing: "<article")

        let text = view.renderedTextForTesting
        #expect(text.contains("<article>"))
        #expect(text.contains("<span id=\"nested-child\"></span>"))
        #expect(text.contains("</article>"))
        #expect(!text.contains("<article>…</article>"))
    }

    @Test
    func expandedDescendantMutationRerendersAfterExpansionDependencyRefresh() async throws {
        let session = makeDOMSession()
        let view = makeTreeView(session: session)
        let renderedText = await view.documentObservationDeliveryForTesting.values {
            view.renderedTextForTesting
        }

        view.toggleRowForTesting(containing: "<article")
        let didRenderExpandedChild = await renderedText.waitUntil { text in
            text.contains("<span id=\"nested-child\"></span>")
        } != nil
        #expect(didRenderExpandedChild)

        let nestedChildID = try #require(
            session.snapshot().nodesByID.first { entry in
                entry.value.attributes.contains { attribute in
                    attribute.name == "id" && attribute.value == "nested-child"
                }
            }?.key
        )

        session.applyAttributeModified(nestedChildID, name: "data-state", value: "ready")
        let didRenderMutation = await renderedText.waitUntil { text in
            text.contains("<span id=\"nested-child\" data-state=\"ready\"></span>")
        } != nil
        #expect(didRenderMutation)
    }

    @Test
    func selectionChangeUpdatesDecorationsWithoutRebuildingRenderedRows() async throws {
        let session = makeDOMSession()
        let view = makeTreeView(session: session)
        let selectedRowCounts = await view.selectionObservationDeliveryForTesting.values {
            view.selectedRowRectsForTesting().count
        }
        view.resetPerformanceCountersForTesting()

        let htmlID = try #require(
            session.snapshot().nodesByID.first { entry in
                entry.value.localName == "html"
            }?.key
        )
        session.selectNode(htmlID)

        let didRenderSelection = await selectedRowCounts.waitUntil { $0 == 1 } != nil
        #expect(didRenderSelection)
        #expect(view.buildRenderedRowsCallCountForTesting == 0)
    }

    @Test
    func documentResetClearsLocalExpansionStateEvenWhenNodeIDsRepeat() async throws {
        let session = makeDOMSession()
        let view = makeTreeView(session: session)
        let renderedText = await view.documentObservationDeliveryForTesting.values {
            view.renderedTextForTesting
        }

        view.toggleRowForTesting(containing: "<article")
        #expect(view.renderedTextForTesting.contains("<span id=\"nested-child\"></span>"))

        let targetID = ProtocolTarget.ID("page-main")
        session.reset()
        session.applyTargetCreated(
            ProtocolTarget.Record(
                id: targetID,
                kind: .page,
                frameID: DOMFrame.ID("main-frame")
            ),
            makeCurrentMainPage: true
        )
        _ = session.replaceDocumentRoot(documentNode(), targetID: targetID)

        let didRenderReset = await renderedText.waitUntil { text in
            text.contains("<article>…</article>")
                && !text.contains("<span id=\"nested-child\"></span>")
        } != nil
        #expect(didRenderReset)
    }

    @Test
    func openingUnloadedRowRequestsChildrenThroughInjectedAction() async throws {
        let session = makeDOMSession(root: documentWithDeferredArticle())
        let recorder = NodeRequestRecorder()
        let view = DOMTreeTextView(
            dom: session,
            requestChildrenAction: { nodeID in
                recorder.record(nodeID)
                return true
            }
        )
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()

        view.toggleRowForTesting(containing: "<article")
        let requestedNodeID = await recorder.next()

        #expect(session.node(for: requestedNodeID)?.localName == "article")
    }

    @Test
    func initialSelectionOpensProjectedFrameAncestors() throws {
        let fixture = try makeProjectedFrameSession()
        fixture.session.selectNode(fixture.selectedNodeID)

        let view = makeTreeView(session: fixture.session)

        let projection = fixture.session.treeProjection(rootTargetID: fixture.pageTargetID)
        #expect(fixture.session.snapshot().nodesByID[fixture.frameRootID]?.parentID == nil)
        #expect(projection.ancestorNodeIDs(of: fixture.selectedNodeID).contains(fixture.frameRootID))
        #expect(view.renderedTextForTesting.contains("#document"))
        #expect(view.renderedTextForTesting.contains("<img id=\"ad-node\">"))
        #expect(view.selectedRowRectsForTesting().count == 1)
    }

    @Test
    func selectingProjectedFrameNodeOpensComposedAncestors() async throws {
        let fixture = try makeProjectedFrameSession()
        let view = makeTreeView(session: fixture.session)

        let sampleRenderedState: @MainActor @Sendable () -> RenderedDOMTreeState = {
            view.layoutIfNeeded()
            return RenderedDOMTreeState(
                text: view.renderedTextForTesting,
                selectedRowCount: view.selectedRowRectsForTesting().count
            )
        }
        let renderedState = await view.selectionObservationDeliveryForTesting.values(sampleRenderedState)
        defer { renderedState.cancel() }

        fixture.session.selectNode(fixture.selectedNodeID)
        var didRenderSelection = renderedState.latestValue?.hasProjectedFrameSelection == true
            || sampleRenderedState().hasProjectedFrameSelection
        if !didRenderSelection {
            didRenderSelection = await renderedState.waitUntil { $0.hasProjectedFrameSelection } != nil
                || sampleRenderedState().hasProjectedFrameSelection
        }

        let projection = fixture.session.treeProjection(rootTargetID: fixture.pageTargetID)
        #expect(fixture.session.snapshot().nodesByID[fixture.frameRootID]?.parentID == nil)
        #expect(projection.ancestorNodeIDs(of: fixture.selectedNodeID).contains(fixture.frameRootID))
        #expect(didRenderSelection)
    }
}

private struct RenderedDOMTreeState: Equatable, Sendable {
    var text: String
    var selectedRowCount: Int

    var hasProjectedFrameSelection: Bool {
        text.contains("#document")
            && text.contains("<img id=\"ad-node\">")
            && selectedRowCount == 1
    }
}

@MainActor
private final class NodeRequestRecorder {
    private var nodeID: DOMNode.ID?
    private var continuation: CheckedContinuation<DOMNode.ID, Never>?

    func record(_ nodeID: DOMNode.ID) {
        self.nodeID = nodeID
        continuation?.resume(returning: nodeID)
        continuation = nil
    }

    func next() async -> DOMNode.ID {
        if let nodeID {
            return nodeID
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

@MainActor
private final class NodeActionRecorder {
    private var nodeID: DOMNode.ID?
    private var continuation: CheckedContinuation<DOMNode.ID, Never>?

    func record(_ nodeID: DOMNode.ID) {
        self.nodeID = nodeID
        continuation?.resume(returning: nodeID)
        continuation = nil
    }

    func nextNodeID() async -> DOMNode.ID {
        if let nodeID {
            return nodeID
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

@MainActor
private final class VoidActionRecorder {
    private var didRecord = false
    private var continuation: CheckedContinuation<Void, Never>?

    func record() {
        didRecord = true
        continuation?.resume()
        continuation = nil
    }

    func next() async {
        if didRecord {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

@MainActor
private func makeTreeView(root: DOMNode.Payload = documentNode()) -> DOMTreeTextView {
    makeTreeView(session: makeDOMSession(root: root))
}

@MainActor
private func makeTreeView(session: DOMSession) -> DOMTreeTextView {
    let view = DOMTreeTextView(dom: session)
    view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
    view.layoutIfNeeded()
    return view
}

@MainActor
private func makeDOMSession(root: DOMNode.Payload = documentNode()) -> DOMSession {
    let targetID = ProtocolTarget.ID("page-main")
    let session = DOMSession()
    session.applyTargetCreated(
        ProtocolTarget.Record(
            id: targetID,
            kind: .page,
            frameID: DOMFrame.ID("main-frame")
        ),
        makeCurrentMainPage: true
    )
    _ = session.replaceDocumentRoot(root, targetID: targetID)
    return session
}

@MainActor
private func makeProjectedFrameSession() throws -> (
    session: DOMSession,
    pageTargetID: ProtocolTarget.ID,
    frameRootID: DOMNode.ID,
    selectedNodeID: DOMNode.ID
) {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let session = DOMSession()

    session.applyTargetCreated(
        ProtocolTarget.Record(id: pageTargetID, kind: .page, frameID: DOMFrame.ID("main-frame")),
        makeCurrentMainPage: true
    )
    session.applyTargetCreated(
        ProtocolTarget.Record(id: frameTargetID, kind: .frame, frameID: frameID)
    )
    _ = session.replaceDocumentRoot(projectedPageDocument(frameID: frameID), targetID: pageTargetID)
    let frameRootID = session.replaceDocumentRoot(projectedFrameDocument(), targetID: frameTargetID)
    let selectedNodeID = try #require(
        session.snapshot().currentNodeIDByKey[DOMNode.CurrentKey(targetID: frameTargetID, nodeID: .init(8))]
    )

    return (session, pageTargetID, frameRootID, selectedNodeID)
}

private func documentNode() -> DOMNode.Payload {
    DOMNode.Payload(
        nodeID: .init(1),
        nodeType: .document,
        nodeName: "#document",
        regularChildren: .loaded([
            DOMNode.Payload(
                nodeID: .init(2),
                nodeType: .documentType,
                nodeName: "html"
            ),
            DOMNode.Payload(
                nodeID: .init(3),
                nodeType: .element,
                nodeName: "HTML",
                localName: "html",
                attributes: [DOMNode.Attribute(name: "lang", value: "en")],
                regularChildren: .loaded([
                    DOMNode.Payload(
                        nodeID: .init(4),
                        nodeType: .element,
                        nodeName: "HEAD",
                        localName: "head",
                        regularChildren: .loaded([
                            DOMNode.Payload(
                                nodeID: .init(5),
                                nodeType: .element,
                                nodeName: "TITLE",
                                localName: "title"
                            ),
                        ])
                    ),
                    bodyNode(article: articleNode()),
                ])
            ),
        ])
    )
}

private func documentWithDeferredArticle() -> DOMNode.Payload {
    DOMNode.Payload(
        nodeID: .init(1),
        nodeType: .document,
        nodeName: "#document",
        regularChildren: .loaded([
            DOMNode.Payload(
                nodeID: .init(3),
                nodeType: .element,
                nodeName: "HTML",
                localName: "html",
                regularChildren: .loaded([
                    bodyNode(
                        article: DOMNode.Payload(
                            nodeID: .init(8),
                            nodeType: .element,
                            nodeName: "ARTICLE",
                            localName: "article",
                            regularChildren: .unrequested(count: 1)
                        )
                    ),
                ])
            ),
        ])
    )
}

private func projectedPageDocument(frameID: DOMFrame.ID) -> DOMNode.Payload {
    DOMNode.Payload(
        nodeID: .init(1),
        nodeType: .document,
        nodeName: "#document",
        regularChildren: .loaded([
            DOMNode.Payload(
                nodeID: .init(2),
                nodeType: .element,
                nodeName: "HTML",
                localName: "html",
                regularChildren: .loaded([
                    DOMNode.Payload(
                        nodeID: .init(3),
                        nodeType: .element,
                        nodeName: "BODY",
                        localName: "body",
                        regularChildren: .loaded([
                            DOMNode.Payload(
                                nodeID: .init(20),
                                nodeType: .element,
                                nodeName: "IFRAME",
                                localName: "iframe",
                                ownerFrameID: frameID,
                                attributes: [DOMNode.Attribute(name: "src", value: "https://frame.example/ad")]
                            ),
                        ])
                    ),
                ])
            ),
        ])
    )
}

private func projectedFrameDocument() -> DOMNode.Payload {
    DOMNode.Payload(
        nodeID: .init(101),
        nodeType: .document,
        nodeName: "#document",
        documentURL: "https://frame.example/ad",
        regularChildren: .loaded([
            DOMNode.Payload(
                nodeID: .init(2),
                nodeType: .element,
                nodeName: "HTML",
                localName: "html",
                regularChildren: .loaded([
                    DOMNode.Payload(
                        nodeID: .init(3),
                        nodeType: .element,
                        nodeName: "BODY",
                        localName: "body",
                        regularChildren: .loaded([
                            DOMNode.Payload(
                                nodeID: .init(8),
                                nodeType: .element,
                                nodeName: "IMG",
                                localName: "img",
                                attributes: [DOMNode.Attribute(name: "id", value: "ad-node")]
                            ),
                        ])
                    ),
                ])
            ),
        ])
    )
}

private func bodyNode(article: DOMNode.Payload) -> DOMNode.Payload {
    DOMNode.Payload(
        nodeID: .init(6),
        nodeType: .element,
        nodeName: "BODY",
        localName: "body",
        attributes: [DOMNode.Attribute(name: "class", value: "logged-in env-production")],
        regularChildren: .loaded([
            DOMNode.Payload(
                nodeID: .init(7),
                nodeType: .element,
                nodeName: "DIV",
                localName: "div",
                attributes: [
                    DOMNode.Attribute(name: "id", value: "start-of-content"),
                    DOMNode.Attribute(name: "data-testid", value: "cellInnerDiv"),
                ]
            ),
            DOMNode.Payload(
                nodeID: .init(12),
                nodeType: .element,
                nodeName: "INPUT",
                localName: "input",
                attributes: [DOMNode.Attribute(name: "disabled", value: "")]
            ),
            article,
            DOMNode.Payload(
                nodeID: .init(10),
                nodeType: .text,
                nodeName: "#text",
                nodeValue: "Introducing luma for iOS 26"
            ),
            DOMNode.Payload(
                nodeID: .init(11),
                nodeType: .comment,
                nodeName: "#comment",
                nodeValue: "comment text"
            ),
        ])
    )
}

private func articleNode() -> DOMNode.Payload {
    DOMNode.Payload(
        nodeID: .init(8),
        nodeType: .element,
        nodeName: "ARTICLE",
        localName: "article",
        regularChildren: .loaded([
            DOMNode.Payload(
                nodeID: .init(9),
                nodeType: .element,
                nodeName: "SPAN",
                localName: "span",
                attributes: [DOMNode.Attribute(name: "id", value: "nested-child")]
            ),
        ])
    )
}
#endif
