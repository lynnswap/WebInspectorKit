import Foundation
import WebInspectorEngine

package enum WITransportMethod {
    package enum Browser {
        package static let getVersion = "Browser.getVersion"
    }

    package enum Target {
        package static let setPauseOnStart = "Target.setPauseOnStart"
    }

    package enum Page {
        package static let getResourceTree = "Page.getResourceTree"
        package static let getResourceContent = "Page.getResourceContent"
    }

    package enum Network {
        package static let enable = "Network.enable"
        package static let getResponseBody = "Network.getResponseBody"
    }

    package enum DOM {
        package static let enable = "DOM.enable"
        package static let getDocument = "DOM.getDocument"
        package static let setInspectModeEnabled = "DOM.setInspectModeEnabled"
        package static let requestChildNodes = "DOM.requestChildNodes"
        package static let requestNode = "DOM.requestNode"
        package static let querySelector = "DOM.querySelector"
        package static let removeNode = "DOM.removeNode"
        package static let setAttributeValue = "DOM.setAttributeValue"
        package static let removeAttribute = "DOM.removeAttribute"
        package static let getOuterHTML = "DOM.getOuterHTML"
        package static let highlightNode = "DOM.highlightNode"
        package static let hideHighlight = "DOM.hideHighlight"
        package static let undo = "DOM.undo"
        package static let redo = "DOM.redo"
    }

    package enum Inspector {
        package static let enable = "Inspector.enable"
        package static let initialized = "Inspector.initialized"
    }

    package enum Runtime {
        package static let evaluate = "Runtime.evaluate"
    }
}

public enum WITransportPageResourceType: String, Decodable, Sendable {
    case document = "Document"
    case styleSheet = "StyleSheet"
    case image = "Image"
    case font = "Font"
    case script = "Script"
    case xhr = "XHR"
    case fetch = "Fetch"
    case ping = "Ping"
    case beacon = "Beacon"
    case webSocket = "WebSocket"
    case eventSource = "EventSource"
    case other = "Other"

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .other
    }
}

public struct WITransportFrame: Decodable, Sendable {
    public let id: String
    public let parentId: String?
    public let loaderId: String
    public let name: String?
    public let url: String
    public let securityOrigin: String
    public let mimeType: String

    public init(
        id: String,
        parentId: String? = nil,
        loaderId: String,
        name: String? = nil,
        url: String,
        securityOrigin: String,
        mimeType: String
    ) {
        self.id = id
        self.parentId = parentId
        self.loaderId = loaderId
        self.name = name
        self.url = url
        self.securityOrigin = securityOrigin
        self.mimeType = mimeType
    }
}

public struct WITransportFrameResource: Decodable, Sendable {
    public let url: String
    public let type: WITransportPageResourceType
    public let mimeType: String
    public let failed: Bool?
    public let canceled: Bool?
    public let sourceMapURL: String?
    public let targetId: String?

    public init(
        url: String,
        type: WITransportPageResourceType,
        mimeType: String,
        failed: Bool? = nil,
        canceled: Bool? = nil,
        sourceMapURL: String? = nil,
        targetId: String? = nil
    ) {
        self.url = url
        self.type = type
        self.mimeType = mimeType
        self.failed = failed
        self.canceled = canceled
        self.sourceMapURL = sourceMapURL
        self.targetId = targetId
    }
}

public struct WITransportFrameResourceTree: Decodable, Sendable {
    public let frame: WITransportFrame
    public let childFrames: [WITransportFrameResourceTree]?
    public let resources: [WITransportFrameResource]

    public init(
        frame: WITransportFrame,
        childFrames: [WITransportFrameResourceTree]? = nil,
        resources: [WITransportFrameResource]
    ) {
        self.frame = frame
        self.childFrames = childFrames
        self.resources = resources
    }
}

public final class WITransportDOMNode: Decodable, Sendable {
    public let nodeId: Int
    public let nodeType: DOMNodeType
    public let nodeName: String
    public let localName: String
    public let nodeValue: String
    public let childNodeCount: Int?
    public let children: [WITransportDOMNode]?
    public let attributes: [String]?
    public let documentURL: String?
    public let baseURL: String?
    public let frameId: String?
    public let contentDocument: WITransportDOMNode?
    public let layoutFlags: [String]?

    public init(
        nodeId: Int,
        nodeType: DOMNodeType,
        nodeName: String,
        localName: String,
        nodeValue: String,
        childNodeCount: Int?,
        children: [WITransportDOMNode]?,
        attributes: [String]?,
        documentURL: String?,
        baseURL: String?,
        frameId: String?,
        contentDocument: WITransportDOMNode? = nil,
        layoutFlags: [String]?
    ) {
        self.nodeId = nodeId
        self.nodeType = nodeType
        self.nodeName = nodeName
        self.localName = localName
        self.nodeValue = nodeValue
        self.childNodeCount = childNodeCount
        self.children = children
        self.attributes = attributes
        self.documentURL = documentURL
        self.baseURL = baseURL
        self.frameId = frameId
        self.contentDocument = contentDocument
        self.layoutFlags = layoutFlags
    }

    public convenience init(
        nodeId: Int,
        nodeType: Int,
        nodeName: String,
        localName: String,
        nodeValue: String,
        childNodeCount: Int?,
        children: [WITransportDOMNode]?,
        attributes: [String]?,
        documentURL: String?,
        baseURL: String?,
        frameId: String?,
        contentDocument: WITransportDOMNode? = nil,
        layoutFlags: [String]?
    ) {
        self.init(
            nodeId: nodeId,
            nodeType: DOMNodeType(protocolValue: nodeType),
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            childNodeCount: childNodeCount,
            children: children,
            attributes: attributes,
            documentURL: documentURL,
            baseURL: baseURL,
            frameId: frameId,
            contentDocument: contentDocument,
            layoutFlags: layoutFlags
        )
    }
}

public struct WITransportPageGetResourceTreeResponse: Decodable, Sendable {
    public let frameTree: WITransportFrameResourceTree
}
