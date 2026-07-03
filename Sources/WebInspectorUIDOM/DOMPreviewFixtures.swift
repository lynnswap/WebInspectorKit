import WebInspectorUIBase
import WebInspectorCore
import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorTransport

@MainActor
package enum DOMPreviewFixtures {
    package static func makeWebInspectorContext(
        document: WebInspectorProxyKit.DOM.Node = previewProxyDocument()
    ) -> WebInspectorContext {
        let context = WebInspectorContext.preview(isolation: MainActor.shared)
        context.seedDOMDocument(document)
        return context
    }

    package static func makeDOMSession() -> DOMSession {
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

    private static func previewDocument() -> WebInspectorCore.DOMNode.Payload {
        WebInspectorCore.DOMNode.Payload(
            nodeID: .init(1),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                WebInspectorCore.DOMNode.Payload(
                    nodeID: .init(2),
                    nodeType: .documentType,
                    nodeName: "html"
                ),
                WebInspectorCore.DOMNode.Payload(
                    nodeID: .init(3),
                    nodeType: .element,
                    nodeName: "HTML",
                    localName: "html",
                    attributes: [WebInspectorCore.DOMNode.Attribute(name: "lang", value: "en")],
                    regularChildren: .loaded([
                        WebInspectorCore.DOMNode.Payload(
                            nodeID: .init(4),
                            nodeType: .element,
                            nodeName: "HEAD",
                            localName: "head",
                            regularChildren: .loaded([
                                WebInspectorCore.DOMNode.Payload(
                                    nodeID: .init(5),
                                    nodeType: .element,
                                    nodeName: "TITLE",
                                    localName: "title"
                                ),
                            ])
                        ),
                        WebInspectorCore.DOMNode.Payload(
                            nodeID: .init(6),
                            nodeType: .element,
                            nodeName: "BODY",
                            localName: "body",
                            attributes: [WebInspectorCore.DOMNode.Attribute(name: "class", value: "logged-in env-production")],
                            regularChildren: .loaded([
                                WebInspectorCore.DOMNode.Payload(
                                    nodeID: .init(7),
                                    nodeType: .element,
                                    nodeName: "DIV",
                                    localName: "div",
                                    attributes: [
                                        WebInspectorCore.DOMNode.Attribute(name: "id", value: "start-of-content"),
                                        WebInspectorCore.DOMNode.Attribute(name: "data-testid", value: "cellInnerDiv"),
                                    ]
                                ),
                                WebInspectorCore.DOMNode.Payload(
                                    nodeID: .init(8),
                                    nodeType: .element,
                                    nodeName: "ARTICLE",
                                    localName: "article",
                                    regularChildren: .loaded([
                                        WebInspectorCore.DOMNode.Payload(
                                            nodeID: .init(9),
                                            nodeType: .element,
                                            nodeName: "SPAN",
                                            localName: "span",
                                            attributes: [WebInspectorCore.DOMNode.Attribute(name: "id", value: "nested-child")]
                                        ),
                                    ])
                                ),
                                WebInspectorCore.DOMNode.Payload(
                                    nodeID: .init(10),
                                    nodeType: .text,
                                    nodeName: "#text",
                                    nodeValue: "Introducing luma for iOS 26"
                                ),
                                WebInspectorCore.DOMNode.Payload(
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

    private static func previewProxyDocument() -> WebInspectorProxyKit.DOM.Node {
        WebInspectorProxyKit.DOM.Node(
            id: .init("document"),
            nodeType: 9,
            nodeName: "#document",
            childNodeCount: 2,
            children: [
                WebInspectorProxyKit.DOM.Node(
                    id: .init("doctype"),
                    nodeType: 10,
                    nodeName: "html"
                ),
                WebInspectorProxyKit.DOM.Node(
                    id: .init("html"),
                    nodeType: 1,
                    nodeName: "HTML",
                    localName: "html",
                    attributes: ["lang": "en"],
                    attributeList: [WebInspectorProxyKit.DOM.Attribute(name: "lang", value: "en")],
                    childNodeCount: 2,
                    children: [
                        WebInspectorProxyKit.DOM.Node(
                            id: .init("head"),
                            nodeType: 1,
                            nodeName: "HEAD",
                            localName: "head",
                            childNodeCount: 1,
                            children: [
                                WebInspectorProxyKit.DOM.Node(
                                    id: .init("title"),
                                    nodeType: 1,
                                    nodeName: "TITLE",
                                    localName: "title"
                                ),
                            ]
                        ),
                        WebInspectorProxyKit.DOM.Node(
                            id: .init("body"),
                            nodeType: 1,
                            nodeName: "BODY",
                            localName: "body",
                            attributes: ["class": "logged-in env-production"],
                            attributeList: [
                                WebInspectorProxyKit.DOM.Attribute(name: "class", value: "logged-in env-production"),
                            ],
                            childNodeCount: 4,
                            children: [
                                WebInspectorProxyKit.DOM.Node(
                                    id: .init("start-of-content"),
                                    nodeType: 1,
                                    nodeName: "DIV",
                                    localName: "div",
                                    attributes: [
                                        "id": "start-of-content",
                                        "data-testid": "cellInnerDiv",
                                    ],
                                    attributeList: [
                                        WebInspectorProxyKit.DOM.Attribute(name: "id", value: "start-of-content"),
                                        WebInspectorProxyKit.DOM.Attribute(name: "data-testid", value: "cellInnerDiv"),
                                    ]
                                ),
                                WebInspectorProxyKit.DOM.Node(
                                    id: .init("article"),
                                    nodeType: 1,
                                    nodeName: "ARTICLE",
                                    localName: "article",
                                    childNodeCount: 1,
                                    children: [
                                        WebInspectorProxyKit.DOM.Node(
                                            id: .init("nested-child"),
                                            nodeType: 1,
                                            nodeName: "SPAN",
                                            localName: "span",
                                            attributes: ["id": "nested-child"],
                                            attributeList: [
                                                WebInspectorProxyKit.DOM.Attribute(name: "id", value: "nested-child"),
                                            ]
                                        ),
                                    ]
                                ),
                                WebInspectorProxyKit.DOM.Node(
                                    id: .init("intro-text"),
                                    nodeType: 3,
                                    nodeName: "#text",
                                    nodeValue: "Introducing luma for iOS 26"
                                ),
                                WebInspectorProxyKit.DOM.Node(
                                    id: .init("comment"),
                                    nodeType: 8,
                                    nodeName: "#comment",
                                    nodeValue: "comment text"
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        )
    }
}
