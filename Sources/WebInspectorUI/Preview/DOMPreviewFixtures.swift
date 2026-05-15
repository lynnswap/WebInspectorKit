#if DEBUG
import WebInspectorCore

@MainActor
enum DOMPreviewFixtures {
    static func makeDOMSession() -> DOMSession {
        let session = DOMSession()
        let targetID = ProtocolTargetIdentifier("preview-page")
        session.applyTargetCreated(
            ProtocolTargetRecord(
                id: targetID,
                kind: .page,
                frameID: DOMFrameIdentifier("preview-frame")
            ),
            makeCurrentMainPage: true
        )
        _ = session.replaceDocumentRoot(previewDocument(), targetID: targetID)
        return session
    }

    private static func previewDocument() -> DOMNodePayload {
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
                                ),
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
                        ),
                    ])
                ),
            ])
        )
    }
}
#endif
