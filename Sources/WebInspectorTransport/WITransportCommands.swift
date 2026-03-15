import Foundation

public enum WITransportCommands {
    public enum Target {}
    public enum Page {}
    public enum Network {}
    public enum DOM {}
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

package enum WITransportNetworkBootstrapPhase: String, Decodable, Sendable {
    case completed
    case failed
    case inFlight

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .completed
    }
}

package struct WITransportNetworkBootstrapBodyFetchDescriptor: Decodable, Sendable {
    package let targetIdentifier: String?
    package let frameId: String
    package let url: String
}

package struct WITransportNetworkBootstrapResource: Decodable, Sendable {
    package let bootstrapRowID: String
    package let rawRequestID: String?
    package let ownerSessionID: String
    package let frameID: String?
    package let targetIdentifier: String?
    package let url: String
    package let method: String
    package let requestType: String?
    package let mimeType: String?
    package let statusCode: Int?
    package let statusText: String?
    package let requestHeaders: [String: String]?
    package let responseHeaders: [String: String]?
    package let phase: WITransportNetworkBootstrapPhase
    package let canceled: Bool?
    package let errorDescription: String?
    package let bodyFetchDescriptor: WITransportNetworkBootstrapBodyFetchDescriptor?

    private enum CodingKeys: String, CodingKey {
        case bootstrapRowID
        case rawRequestID
        case ownerSessionID
        case frameID
        case targetIdentifier
        case url
        case method
        case requestType
        case mimeType
        case statusCode
        case statusText
        case requestHeaders
        case responseHeaders
        case phase
        case canceled
        case errorDescription
        case bodyFetchDescriptor
    }
}

public struct WITransportDOMNode: Decodable, Sendable {
    public let nodeId: Int
    public let nodeType: Int
    public let nodeName: String
    public let localName: String
    public let nodeValue: String
    public let childNodeCount: Int?
    public let children: [WITransportDOMNode]?
    public let attributes: [String]?
    public let documentURL: String?
    public let baseURL: String?
    public let frameId: String?
    public let layoutFlags: [String]?

    public init(
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
        self.layoutFlags = layoutFlags
    }
}

public extension WITransportCommands.Target {
    /// iOS inspector root target does not expose `Target.enable`, so this
    /// compatibility command maps the bootstrap step to `Target.setPauseOnStart(false)`.
    struct Enable: WITransportRootCommand, Sendable {
        public typealias Response = WIEmptyTransportResponse
        public let parameters = SetPauseOnStart.Parameters(pauseOnStart: false)

        public init() {}

        public static let method = SetPauseOnStart.method
    }

    struct SetPauseOnStart: WITransportRootCommand, Sendable {
        public struct Parameters: Encodable, Sendable {
            public let pauseOnStart: Bool

            public init(pauseOnStart: Bool) {
                self.pauseOnStart = pauseOnStart
            }
        }

        public typealias Response = WIEmptyTransportResponse
        public let parameters: Parameters

        public init(pauseOnStart: Bool) {
            parameters = Parameters(pauseOnStart: pauseOnStart)
        }

        public static let method = "Target.setPauseOnStart"
    }
}

public extension WITransportCommands.Page {
    struct GetResourceTree: WITransportPageCommand, Sendable {
        public struct Response: Decodable, Sendable {
            public let frameTree: WITransportFrameResourceTree

            public init(frameTree: WITransportFrameResourceTree) {
                self.frameTree = frameTree
            }
        }

        public let parameters = WIEmptyTransportParameters()

        public init() {}

        public static let method = "Page.getResourceTree"
    }

    struct GetResourceContent: WITransportPageCommand, Sendable {
        public struct Parameters: Encodable, Sendable {
            public let frameId: String
            public let url: String

            public init(frameId: String, url: String) {
                self.frameId = frameId
                self.url = url
            }
        }

        public struct Response: Decodable, Sendable {
            public let content: String
            public let base64Encoded: Bool

            public init(content: String, base64Encoded: Bool) {
                self.content = content
                self.base64Encoded = base64Encoded
            }
        }

        public let parameters: Parameters

        public init(frameId: String, url: String) {
            parameters = Parameters(frameId: frameId, url: url)
        }

        public static let method = "Page.getResourceContent"
    }
}

public extension WITransportCommands.Network {
    struct Enable: WITransportPageCommand, Sendable {
        public typealias Response = WIEmptyTransportResponse
        public let parameters = WIEmptyTransportParameters()

        public init() {}

        public static let method = "Network.enable"
    }

    struct GetResponseBody: WITransportPageCommand, Sendable {
        public struct Parameters: Encodable, Sendable {
            public let requestId: String

            public init(requestId: String) {
                self.requestId = requestId
            }
        }

        public struct Response: Decodable, Sendable {
            public let body: String
            public let base64Encoded: Bool

            public init(body: String, base64Encoded: Bool) {
                self.body = body
                self.base64Encoded = base64Encoded
            }
        }

        public let parameters: Parameters

        public init(requestId: String) {
            parameters = Parameters(requestId: requestId)
        }

        public static let method = "Network.getResponseBody"
    }

    struct GetRequestPostData: WITransportPageCommand, Sendable {
        public struct Parameters: Encodable, Sendable {
            public let requestId: String

            public init(requestId: String) {
                self.requestId = requestId
            }
        }

        public struct Response: Decodable, Sendable {
            public let postData: String

            public init(postData: String) {
                self.postData = postData
            }
        }

        public let parameters: Parameters

        public init(requestId: String) {
            parameters = Parameters(requestId: requestId)
        }

        public static let method = "Network.getRequestPostData"
    }
}

package extension WITransportCommands.Network {
    struct GetBootstrapSnapshot: WITransportPageCommand, Sendable {
        package struct Response: Decodable, Sendable {
            let resources: [WITransportNetworkBootstrapResource]
        }

        package let parameters = WIEmptyTransportParameters()

        package init() {}

        package static let method = "Network.getBootstrapSnapshot"
    }
}

public extension WITransportCommands.DOM {
    struct Enable: WITransportPageCommand, Sendable {
        public typealias Response = WIEmptyTransportResponse
        public let parameters = WIEmptyTransportParameters()

        public init() {}

        public static let method = "DOM.enable"
    }

    struct GetDocument: WITransportPageCommand, Sendable {
        public struct Parameters: Encodable, Sendable {
            public let depth: Int?
            public let pierce: Bool?

            public init(depth: Int? = nil, pierce: Bool? = nil) {
                self.depth = depth
                self.pierce = pierce
            }
        }

        public struct Response: Decodable, Sendable {
            public let root: WITransportDOMNode

            public init(root: WITransportDOMNode) {
                self.root = root
            }
        }

        public let parameters: Parameters

        public init(depth: Int? = nil, pierce: Bool? = nil) {
            parameters = Parameters(depth: depth, pierce: pierce)
        }

        public static let method = "DOM.getDocument"
    }

    struct QuerySelector: WITransportPageCommand, Sendable {
        public struct Parameters: Encodable, Sendable {
            public let nodeId: Int
            public let selector: String

            public init(nodeId: Int, selector: String) {
                self.nodeId = nodeId
                self.selector = selector
            }
        }

        public struct Response: Decodable, Sendable {
            public let nodeId: Int

            public init(nodeId: Int) {
                self.nodeId = nodeId
            }
        }

        public let parameters: Parameters

        public init(nodeId: Int, selector: String) {
            parameters = Parameters(nodeId: nodeId, selector: selector)
        }

        public static let method = "DOM.querySelector"
    }

    struct GetOuterHTML: WITransportPageCommand, Sendable {
        public struct Parameters: Encodable, Sendable {
            public let nodeId: Int?

            public init(nodeId: Int? = nil) {
                self.nodeId = nodeId
            }
        }

        public struct Response: Decodable, Sendable {
            public let outerHTML: String

            public init(outerHTML: String) {
                self.outerHTML = outerHTML
            }
        }

        public let parameters: Parameters

        public init(nodeId: Int? = nil) {
            parameters = Parameters(nodeId: nodeId)
        }

        public static let method = "DOM.getOuterHTML"
    }
}
