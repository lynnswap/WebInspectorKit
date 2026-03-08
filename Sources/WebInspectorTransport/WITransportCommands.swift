import Foundation

public enum WITransportCommands {
    public enum Target {}
    public enum Network {}
    public enum DOM {}
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
