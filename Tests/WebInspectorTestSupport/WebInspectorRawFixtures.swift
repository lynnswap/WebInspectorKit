import WebInspectorProxyKit
import WebInspectorProxyKitTesting

/// Encodes a test fixture as one validated top-level protocol object.
public func webInspectorTestJSONObject<Value: Encodable>(
    _ value: Value
) throws -> WebInspectorTestJSONObject {
    try WebInspectorTestJSONObject(encoding: value)
}

/// Validates a literal top-level protocol object.
public func webInspectorTestJSONObject(
    _ json: String
) throws -> WebInspectorTestJSONObject {
    try WebInspectorTestJSONObject(json: json)
}

/// Creates a raw `DOM.getDocument` result from a typed ProxyKit node tree.
public func webInspectorDOMDocumentResult(
    _ document: DOM.Node
) throws -> WebInspectorTestJSONObject {
    try webInspectorTestJSONObject(
        WebInspectorDOMDocumentWireResult(root: WebInspectorDOMNodeWire(document))
    )
}

/// Raw WebKit encoding for a typed DOM node test fixture.
public final class WebInspectorDOMNodeWire: Encodable {
    let nodeId: String
    let nodeType: Int
    let nodeName: String
    let localName: String
    let nodeValue: String
    let frameId: String?
    let childNodeCount: Int
    let children: [WebInspectorDOMNodeWire]?
    let attributes: [String]
    let documentURL: String?
    let baseURL: String?
    let pseudoType: String?
    let shadowRootType: String?
    let contentDocument: WebInspectorDOMNodeWire?
    let shadowRoots: [WebInspectorDOMNodeWire]
    let templateContent: WebInspectorDOMNodeWire?
    let pseudoElements: [WebInspectorDOMNodeWire]

    public init(_ node: DOM.Node) {
        nodeId = node.id.rawValue
        nodeType = node.nodeType
        nodeName = node.nodeName
        localName = node.localName
        nodeValue = node.nodeValue
        frameId = node.frameID?.rawValue
        childNodeCount = node.childNodeCount
        children = node.children?.map(Self.init)
        attributes = node.attributeList.flatMap { [$0.name, $0.value] }
        documentURL = node.documentURL
        baseURL = node.baseURL
        pseudoType = node.pseudoType.map(Self.pseudoType)
        shadowRootType = node.shadowRootType.map(Self.shadowRootType)
        contentDocument = node.contentDocument.map(Self.init)
        shadowRoots = node.shadowRoots.map(Self.init)
        templateContent = node.templateContent.map(Self.init)
        pseudoElements = (
            [node.beforePseudoElement].compactMap { $0 }
                + node.otherPseudoElements
                + [node.afterPseudoElement].compactMap { $0 }
        ).map(Self.init)
    }

    private static func pseudoType(_ value: DOM.PseudoType) -> String {
        switch value {
        case .before:
            "before"
        case .after:
            "after"
        case let .other(rawValue):
            rawValue
        }
    }

    private static func shadowRootType(_ value: DOM.ShadowRootType) -> String {
        switch value {
        case .open:
            "open"
        case .closed:
            "closed"
        case .userAgent:
            "user-agent"
        case let .other(rawValue):
            rawValue
        }
    }
}

private struct WebInspectorDOMDocumentWireResult: Encodable {
    let root: WebInspectorDOMNodeWire
}
