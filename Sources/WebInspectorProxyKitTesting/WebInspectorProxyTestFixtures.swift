import Foundation
import WebInspectorProxyKit

public enum WebInspectorProxyTestFixtures {
    public static func domNodeID(_ rawValue: String) -> DOM.Node.ID {
        DOM.Node.ID(rawValue)
    }

    public static func domNode(
        id: String,
        nodeType: Int,
        nodeName: String,
        localName: String = "",
        nodeValue: String = "",
        documentURL: String? = nil,
        baseURL: String? = nil,
        attributes: [String: String] = [:],
        attributeList: [DOM.Attribute]? = nil,
        childNodeCount: Int = 0,
        children: [DOM.Node]? = nil
    ) -> DOM.Node {
        DOM.Node(
            id: domNodeID(id),
            nodeType: nodeType,
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            documentURL: documentURL,
            baseURL: baseURL,
            attributes: attributes,
            attributeList: attributeList,
            childNodeCount: childNodeCount,
            children: children
        )
    }

    public static func domDocument(
        id: String = "document",
        documentURL: String? = nil,
        childNodeCount: Int = 0,
        children: [DOM.Node]? = nil
    ) -> DOM.Node {
        domNode(
            id: id,
            nodeType: 9,
            nodeName: "#document",
            documentURL: documentURL,
            childNodeCount: childNodeCount,
            children: children
        )
    }

    public static func networkRequestID(_ rawValue: String) -> Network.Request.ID {
        Network.Request.ID(rawValue)
    }

    public static func networkRequest(
        id: String,
        url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        postData: String? = nil,
        referrerPolicy: Network.ReferrerPolicy? = nil,
        integrity: String? = nil
    ) -> Network.Request {
        Network.Request(
            id: networkRequestID(id),
            url: url,
            method: method,
            headers: headers,
            postData: postData,
            referrerPolicy: referrerPolicy,
            integrity: integrity
        )
    }

    public static func runtimeRemoteObjectID(_ rawValue: String) -> Runtime.RemoteObject.ID {
        Runtime.RemoteObject.ID(rawValue)
    }

    public static func runtimeRemoteObject(
        id: String? = nil,
        kind: Runtime.Kind,
        subtype: Runtime.Subtype? = nil,
        className: String? = nil,
        description: String? = nil,
        value: Runtime.JSONValue? = nil,
        size: Int? = nil,
        preview: Runtime.ObjectPreview? = nil
    ) -> Runtime.RemoteObject {
        Runtime.RemoteObject(
            id: id.map(runtimeRemoteObjectID),
            kind: kind,
            subtype: subtype,
            className: className,
            description: description,
            value: value,
            size: size,
            preview: preview
        )
    }
}
