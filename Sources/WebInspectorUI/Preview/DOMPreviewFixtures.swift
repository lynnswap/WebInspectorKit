import WebInspectorCore
import WebInspectorTransport

@MainActor
enum DOMPreviewFixtures {
    static func makeDOMSession() -> DOMSession {
        let session = DOMSession()
        let targetID = ProtocolTarget.ID("preview-page")
        session.applyTargetCreated(
            ProtocolTarget.Record(
                id: targetID,
                kind: .page,
                frameID: DOMFrame.ID("preview-frame")
            ),
            makeCurrentMainPage: true
        )
        _ = session.replaceDocumentRoot(previewDocument(), targetID: targetID)
        return session
    }

    private static func previewDocument() -> DOMNode.Payload {
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
                                ),
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
                        ),
                    ])
                ),
            ])
        )
    }
}
