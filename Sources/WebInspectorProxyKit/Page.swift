import Foundation

/// A target-scoped handle for Web Inspector Page commands and events.
public struct Page: Sendable, WebInspectorEventDomainHandle {
    package static let eventDecoder = PageWireCoding.eventDecoder
    package static let eventCapability = PageWireCoding.capability

    package let endpoint: DomainEndpoint

    package init(endpoint: DomainEndpoint) {
        self.endpoint = endpoint
    }

    /// Runs an operation with an atomically registered Page event scope.
    public func withEvents<Output>(
        buffering: WebInspectorEventBufferingPolicy = .unbounded,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: (
            AsyncThrowingStream<WebInspectorPageEvent<Page.Event>, any Error>
        ) async throws -> Output
    ) async throws -> Output {
        try await _withEvents(buffering: buffering, isolation: isolation, operation)
    }

    /// Reloads the inspected page.
    public func reload(ignoringCache: Bool = false) async throws {
        try await endpoint.dispatch(PageWireCoding.reload(ignoringCache: ignoringCache))
    }

    /// Returns the current frame hierarchy and cached resources.
    public func resourceTree() async throws -> ResourceTree {
        try await endpoint.dispatch(PageWireCoding.resourceTree())
    }

    /// Returns the cached content for a resource in a frame.
    public func resourceContent(frameID: FrameID, url: String) async throws -> ResourceContent {
        try await endpoint.dispatch(PageWireCoding.resourceContent(frameID: frameID, url: url))
    }

    /// A page lifecycle event reported by WebKit.
    public enum Event: Sendable {
        case frameNavigated(Frame)
        case frameDetached(FrameID)
        case unknown(RawEvent)
    }

    /// A frame description carried by `Page.frameNavigated`.
    public struct Frame: Sendable {
        public let id: FrameID
        public let parentID: FrameID?
        public let loaderID: String
        public let name: String?
        public let url: String
        public let securityOrigin: String?
        public let mimeType: String?

        public init(
            id: FrameID,
            parentID: FrameID?,
            loaderID: String,
            name: String?,
            url: String,
            securityOrigin: String?,
            mimeType: String?
        ) {
            self.id = id
            self.parentID = parentID
            self.loaderID = loaderID
            self.name = name
            self.url = url
            self.securityOrigin = securityOrigin
            self.mimeType = mimeType
        }
    }

    public struct ResourceTree: Sendable {
        public let frame: Frame
        public let childFrames: [ResourceTree]
        public let resources: [Resource]

        public init(frame: Frame, childFrames: [ResourceTree], resources: [Resource]) {
            self.frame = frame
            self.childFrames = childFrames
            self.resources = resources
        }
    }

    public struct Resource: Sendable {
        public let url: String
        public let type: Network.ResourceType
        public let mimeType: String
        public let failed: Bool
        public let canceled: Bool
        public let sourceMapURL: String?
        public let targetID: String?

        public init(
            url: String,
            type: Network.ResourceType,
            mimeType: String,
            failed: Bool,
            canceled: Bool,
            sourceMapURL: String?,
            targetID: String?
        ) {
            self.url = url
            self.type = type
            self.mimeType = mimeType
            self.failed = failed
            self.canceled = canceled
            self.sourceMapURL = sourceMapURL
            self.targetID = targetID
        }
    }

    public struct ResourceContent: Sendable {
        public let content: String
        public let base64Encoded: Bool

        public init(content: String, base64Encoded: Bool) {
            self.content = content
            self.base64Encoded = base64Encoded
        }
    }
}
