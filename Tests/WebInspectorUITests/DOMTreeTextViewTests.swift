#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorCore
@testable import WebInspectorUI

@MainActor
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
    func documentResetClearsLocalExpansionStateEvenWhenNodeIDsRepeat() async throws {
        let session = makeDOMSession()
        let view = makeTreeView(session: session)

        view.toggleRowForTesting(containing: "<article")
        #expect(view.renderedTextForTesting.contains("<span id=\"nested-child\"></span>"))

        let targetID = ProtocolTargetIdentifier("page-main")
        session.reset()
        session.applyTargetCreated(
            ProtocolTargetRecord(
                id: targetID,
                kind: .page,
                frameID: DOMFrameIdentifier("main-frame")
            ),
            makeCurrentMainPage: true
        )
        _ = session.replaceDocumentRoot(documentNode(), targetID: targetID)
        await waitForObservationDelivery()
        view.layoutIfNeeded()

        let text = view.renderedTextForTesting
        #expect(text.contains("<article>…</article>"))
        #expect(!text.contains("<span id=\"nested-child\"></span>"))
    }

    @Test
    func openingUnloadedRowRequestsChildrenThroughInjectedAction() async throws {
        let session = makeDOMSession(root: documentWithDeferredArticle())
        var requestedNodeID: DOMNode.ID?
        let view = DOMTreeTextView(
            dom: session,
            requestChildrenAction: { nodeID in
                requestedNodeID = nodeID
                return true
            }
        )
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()

        view.toggleRowForTesting(containing: "<article")
        await waitForObservationDelivery()

        #expect(requestedNodeID.flatMap { session.node(for: $0) }?.localName == "article")
    }

    @Test
    func selectingProjectedFrameNodeOpensComposedAncestors() async throws {
        let pageTargetID = ProtocolTargetIdentifier("page-main")
        let frameTargetID = ProtocolTargetIdentifier("frame-ad-target")
        let frameID = DOMFrameIdentifier("frame-ad")
        let session = DOMSession()

        session.applyTargetCreated(
            ProtocolTargetRecord(id: pageTargetID, kind: .page, frameID: DOMFrameIdentifier("main-frame")),
            makeCurrentMainPage: true
        )
        session.applyTargetCreated(
            ProtocolTargetRecord(id: frameTargetID, kind: .frame, frameID: frameID)
        )
        _ = session.replaceDocumentRoot(projectedPageDocument(frameID: frameID), targetID: pageTargetID)
        let frameRootID = session.replaceDocumentRoot(projectedFrameDocument(), targetID: frameTargetID)
        let selectedNodeID = try #require(
            session.snapshot().currentNodeIDByKey[DOMNodeCurrentKey(targetID: frameTargetID, nodeID: .init(8))]
        )
        let view = makeTreeView(session: session)

        session.selectNode(selectedNodeID)
        await waitForObservationDelivery()
        view.layoutIfNeeded()

        let projection = session.treeProjection(rootTargetID: pageTargetID)
        #expect(session.snapshot().nodesByID[frameRootID]?.parentID == nil)
        #expect(projection.ancestorNodeIDs(of: selectedNodeID).contains(frameRootID))
        #expect(view.renderedTextForTesting.contains("#document"))
        #expect(view.renderedTextForTesting.contains("<img id=\"ad-node\">"))
        #expect(view.selectedRowRectsForTesting().count == 1)
    }

    private func makeTreeView(root: DOMNodePayload = documentNode()) -> DOMTreeTextView {
        makeTreeView(session: makeDOMSession(root: root))
    }

    private func makeTreeView(session: DOMSession) -> DOMTreeTextView {
        let view = DOMTreeTextView(dom: session)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        return view
    }

    private func waitForObservationDelivery() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }
}

@MainActor
private func makeDOMSession(root: DOMNodePayload = documentNode()) -> DOMSession {
    let targetID = ProtocolTargetIdentifier("page-main")
    let session = DOMSession()
    session.applyTargetCreated(
        ProtocolTargetRecord(
            id: targetID,
            kind: .page,
            frameID: DOMFrameIdentifier("main-frame")
        ),
        makeCurrentMainPage: true
    )
    _ = session.replaceDocumentRoot(root, targetID: targetID)
    return session
}

private func documentNode() -> DOMNodePayload {
    DOMNodePayload(
        nodeID: .init(1),
        nodeType: .document,
        nodeName: "#document",
        regularChildren: .loaded([
            DOMNodePayload(
                nodeID: .init(2),
                nodeType: .documentType,
                nodeName: "html"
            ),
            DOMNodePayload(
                nodeID: .init(3),
                nodeType: .element,
                nodeName: "HTML",
                localName: "html",
                attributes: [DOMAttribute(name: "lang", value: "en")],
                regularChildren: .loaded([
                    DOMNodePayload(
                        nodeID: .init(4),
                        nodeType: .element,
                        nodeName: "HEAD",
                        localName: "head",
                        regularChildren: .loaded([
                            DOMNodePayload(
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

private func documentWithDeferredArticle() -> DOMNodePayload {
    DOMNodePayload(
        nodeID: .init(1),
        nodeType: .document,
        nodeName: "#document",
        regularChildren: .loaded([
            DOMNodePayload(
                nodeID: .init(3),
                nodeType: .element,
                nodeName: "HTML",
                localName: "html",
                regularChildren: .loaded([
                    bodyNode(
                        article: DOMNodePayload(
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

private func projectedPageDocument(frameID: DOMFrame.ID) -> DOMNodePayload {
    DOMNodePayload(
        nodeID: .init(1),
        nodeType: .document,
        nodeName: "#document",
        regularChildren: .loaded([
            DOMNodePayload(
                nodeID: .init(2),
                nodeType: .element,
                nodeName: "HTML",
                localName: "html",
                regularChildren: .loaded([
                    DOMNodePayload(
                        nodeID: .init(3),
                        nodeType: .element,
                        nodeName: "BODY",
                        localName: "body",
                        regularChildren: .loaded([
                            DOMNodePayload(
                                nodeID: .init(20),
                                nodeType: .element,
                                nodeName: "IFRAME",
                                localName: "iframe",
                                ownerFrameID: frameID,
                                attributes: [DOMAttribute(name: "src", value: "https://frame.example/ad")]
                            ),
                        ])
                    ),
                ])
            ),
        ])
    )
}

private func projectedFrameDocument() -> DOMNodePayload {
    DOMNodePayload(
        nodeID: .init(101),
        nodeType: .document,
        nodeName: "#document",
        documentURL: "https://frame.example/ad",
        regularChildren: .loaded([
            DOMNodePayload(
                nodeID: .init(2),
                nodeType: .element,
                nodeName: "HTML",
                localName: "html",
                regularChildren: .loaded([
                    DOMNodePayload(
                        nodeID: .init(3),
                        nodeType: .element,
                        nodeName: "BODY",
                        localName: "body",
                        regularChildren: .loaded([
                            DOMNodePayload(
                                nodeID: .init(8),
                                nodeType: .element,
                                nodeName: "IMG",
                                localName: "img",
                                attributes: [DOMAttribute(name: "id", value: "ad-node")]
                            ),
                        ])
                    ),
                ])
            ),
        ])
    )
}

private func bodyNode(article: DOMNodePayload) -> DOMNodePayload {
    DOMNodePayload(
        nodeID: .init(6),
        nodeType: .element,
        nodeName: "BODY",
        localName: "body",
        attributes: [DOMAttribute(name: "class", value: "logged-in env-production")],
        regularChildren: .loaded([
            DOMNodePayload(
                nodeID: .init(7),
                nodeType: .element,
                nodeName: "DIV",
                localName: "div",
                attributes: [
                    DOMAttribute(name: "id", value: "start-of-content"),
                    DOMAttribute(name: "data-testid", value: "cellInnerDiv"),
                ]
            ),
            DOMNodePayload(
                nodeID: .init(12),
                nodeType: .element,
                nodeName: "INPUT",
                localName: "input",
                attributes: [DOMAttribute(name: "disabled", value: "")]
            ),
            article,
            DOMNodePayload(
                nodeID: .init(10),
                nodeType: .text,
                nodeName: "#text",
                nodeValue: "Introducing luma for iOS 26"
            ),
            DOMNodePayload(
                nodeID: .init(11),
                nodeType: .comment,
                nodeName: "#comment",
                nodeValue: "comment text"
            ),
        ])
    )
}

private func articleNode() -> DOMNodePayload {
    DOMNodePayload(
        nodeID: .init(8),
        nodeType: .element,
        nodeName: "ARTICLE",
        localName: "article",
        regularChildren: .loaded([
            DOMNodePayload(
                nodeID: .init(9),
                nodeType: .element,
                nodeName: "SPAN",
                localName: "span",
                attributes: [DOMAttribute(name: "id", value: "nested-child")]
            ),
        ])
    )
}
#endif
