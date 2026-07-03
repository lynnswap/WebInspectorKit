import WebInspectorUIBase
import WebInspectorDataKit
import WebInspectorProxyKit

@MainActor
package enum DOMPreviewFixtures {
    package static func makeWebInspectorContext(
        document: DOM.Node = previewProxyDocument()
    ) -> WebInspectorContext {
        let context = WebInspectorContext.preview(isolation: MainActor.shared)
        context.seedDOMDocument(document)
        return context
    }

    package static func firstElement(named localName: String, in context: WebInspectorContext) -> DOMNode? {
        guard let rootNode = context.rootNode else {
            return nil
        }
        var stack = [rootNode]
        while let node = stack.popLast() {
            if node.localName == localName {
                return node
            }
            if case let .loaded(children) = node.children {
                stack.append(contentsOf: children.reversed())
            }
        }
        return nil
    }

    private static func previewProxyDocument() -> DOM.Node {
        DOM.Node(
            id: .init("document"),
            nodeType: 9,
            nodeName: "#document",
            childNodeCount: 2,
            children: [
                DOM.Node(
                    id: .init("doctype"),
                    nodeType: 10,
                    nodeName: "html"
                ),
                DOM.Node(
                    id: .init("html"),
                    nodeType: 1,
                    nodeName: "HTML",
                    localName: "html",
                    attributes: ["lang": "en"],
                    attributeList: [DOM.Attribute(name: "lang", value: "en")],
                    childNodeCount: 2,
                    children: [
                        DOM.Node(
                            id: .init("head"),
                            nodeType: 1,
                            nodeName: "HEAD",
                            localName: "head",
                            childNodeCount: 1,
                            children: [
                                DOM.Node(
                                    id: .init("title"),
                                    nodeType: 1,
                                    nodeName: "TITLE",
                                    localName: "title"
                                ),
                            ]
                        ),
                        DOM.Node(
                            id: .init("body"),
                            nodeType: 1,
                            nodeName: "BODY",
                            localName: "body",
                            attributes: ["class": "logged-in env-production"],
                            attributeList: [
                                DOM.Attribute(name: "class", value: "logged-in env-production"),
                            ],
                            childNodeCount: 4,
                            children: [
                                DOM.Node(
                                    id: .init("start-of-content"),
                                    nodeType: 1,
                                    nodeName: "DIV",
                                    localName: "div",
                                    attributes: [
                                        "id": "start-of-content",
                                        "data-testid": "cellInnerDiv",
                                    ],
                                    attributeList: [
                                        DOM.Attribute(name: "id", value: "start-of-content"),
                                        DOM.Attribute(name: "data-testid", value: "cellInnerDiv"),
                                    ]
                                ),
                                DOM.Node(
                                    id: .init("article"),
                                    nodeType: 1,
                                    nodeName: "ARTICLE",
                                    localName: "article",
                                    childNodeCount: 1,
                                    children: [
                                        DOM.Node(
                                            id: .init("nested-child"),
                                            nodeType: 1,
                                            nodeName: "SPAN",
                                            localName: "span",
                                            attributes: ["id": "nested-child"],
                                            attributeList: [
                                                DOM.Attribute(name: "id", value: "nested-child"),
                                            ]
                                        ),
                                    ]
                                ),
                                DOM.Node(
                                    id: .init("intro-text"),
                                    nodeType: 3,
                                    nodeName: "#text",
                                    nodeValue: "Introducing luma for iOS 26"
                                ),
                                DOM.Node(
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
