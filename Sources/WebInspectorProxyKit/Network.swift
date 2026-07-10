import Foundation

/// Types and commands for the Web Inspector Network domain.
public enum Network {
    /// A target-scoped client for Network commands and events.
    public struct Client: Sendable {
        package let context: DomainClientContext

        package init(context: DomainClientContext) {
            self.context = context
        }

        /// Enables Network domain events and commands for the target.
        public func enable() async throws {
            try await context.dispatchVoid(
                domain: .network,
                method: "enable",
                payload: EnablePayload()
            )
        }

        /// Disables Network domain events for the target.
        public func disable() async throws {
            try await context.dispatchVoid(
                domain: .network,
                method: "disable",
                payload: DisablePayload()
            )
        }

        /// Runs an operation with an atomically registered Network event scope.
        ///
        /// The first scope registers before `Network.enable` is sent. Scope
        /// completion waits for the final matching `Network.disable`.
        public func withEvents<Output>(
            buffering: WebInspectorEventBufferingPolicy = .bounded(256),
            isolation: isolated (any Actor)? = #isolation,
            _ operation: (
                AsyncThrowingStream<WebInspectorPageEvent<Network.Event>, any Error>
            ) async throws -> Output
        ) async throws -> Output {
            try await context.withEvents(
                domain: .network,
                buffering: buffering,
                isolation: isolation,
                extract: { event in
                    guard case let .network(value) = event else {
                        return nil
                    }
                    return value
                },
                operation
            )
        }

        /// Returns the response body for a completed network request.
        public func responseBody(
            for id: Request.ID,
            backendResourceIdentifier: BackendResourceID? = nil
        ) async throws -> Body {
            try await context.dispatch(
                domain: .network,
                method: "getResponseBody",
                payload: GetResponseBodyPayload(id: id, backendResourceIdentifier: backendResourceIdentifier),
                returning: Body.self
            )
        }

        /// Network domain events emitted by this target.
        public var events: EventStream {
            EventStream {
                context.networkEvents()
            }
        }
    }

    package struct EnablePayload: Sendable {
        package init() {}
    }

    package struct DisablePayload: Sendable {
        package init() {}
    }

    package struct GetResponseBodyPayload: Sendable {
        package let id: Request.ID
        package let backendResourceIdentifier: BackendResourceID?

        package init(id: Request.ID, backendResourceIdentifier: BackendResourceID? = nil) {
            self.id = id
            self.backendResourceIdentifier = backendResourceIdentifier
        }
    }

    /// A network request payload reported by WebKit.
    public struct Request: Identifiable, Sendable {
        /// Stable identity for a network request.
        public struct ID: Hashable, Sendable {
            package let rawValue: String

            package init(_ rawValue: String) {
                self.rawValue = rawValue
            }
        }

        /// The backend identity for the request.
        public let id: ID

        /// The request URL.
        public let url: String

        /// The HTTP method.
        public let method: String

        /// Request headers keyed by header name.
        public let headers: [String: String]

        /// The request body text, if WebKit included it.
        public let postData: String?

        /// The referrer policy, if WebKit reported one.
        public let referrerPolicy: ReferrerPolicy?

        /// The request integrity metadata, if any.
        public let integrity: String?

        /// The backend resource identity used for some body lookups.
        public let backendResourceIdentifier: BackendResourceID?

        /// Creates a network request payload.
        public init(
            id: ID,
            url: String,
            method: String,
            headers: [String: String] = [:],
            postData: String? = nil,
            referrerPolicy: ReferrerPolicy? = nil,
            integrity: String? = nil,
            backendResourceIdentifier: BackendResourceID? = nil
        ) {
            self.id = id
            self.url = url
            self.method = method
            self.headers = headers
            self.postData = postData
            self.referrerPolicy = referrerPolicy
            self.integrity = integrity
            self.backendResourceIdentifier = backendResourceIdentifier
        }
    }

    /// WebKit's backend-process resource identity for a request. Some
    /// resources (network-process or cached loads) key their bodies by this
    /// identifier, so body commands must forward it when present.
    public struct BackendResourceID: Hashable, Sendable {
        /// The backend process identifier.
        public let sourceProcessID: String

        /// The backend resource identifier.
        public let resourceID: String

        /// Creates a backend resource identity.
        public init(sourceProcessID: String, resourceID: String) {
            self.sourceProcessID = sourceProcessID
            self.resourceID = resourceID
        }
    }

    /// A network response payload reported by WebKit.
    public struct Response: Sendable {
        /// The response URL.
        public let url: String?

        /// The HTTP status code.
        public let status: Int?

        /// The HTTP status text.
        public let statusText: String?

        /// The response MIME type.
        public let mimeType: String?

        /// Response headers keyed by header name.
        public let headers: [String: String]

        /// WebKit's response source value.
        public let source: Source?

        /// Request headers associated with the response, if reported.
        public let requestHeaders: [String: String]?

        /// The response body size, if reported.
        public let bodySize: Int?

        /// Creates a network response payload.
        public init(
            url: String? = nil,
            status: Int? = nil,
            statusText: String? = nil,
            mimeType: String? = nil,
            headers: [String: String] = [:],
            source: Source? = nil,
            requestHeaders: [String: String]? = nil,
            bodySize: Int? = nil
        ) {
            self.url = url
            self.status = status
            self.statusText = statusText
            self.mimeType = mimeType
            self.headers = headers
            self.source = source
            self.requestHeaders = requestHeaders
            self.bodySize = bodySize
        }
    }

    /// WebKit's referrer policy value.
    public struct ReferrerPolicy: RawRepresentable, Hashable, Sendable {
        /// The raw protocol referrer policy.
        public let rawValue: String

        /// Creates a referrer policy from its raw protocol value.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    /// WebKit's response source value.
    public struct Source: RawRepresentable, Hashable, Sendable {
        /// The raw protocol source.
        public let rawValue: String

        /// Creates a source from its raw protocol value.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    /// Transfer metrics reported when loading finishes.
    public struct Metrics: Sendable {
        /// The protocol timestamp associated with the metrics.
        public let timestamp: Double?

        /// The negotiated network protocol.
        public let networkProtocol: String?

        /// The remote address, if WebKit reported one.
        public let remoteAddress: String?

        /// Encoded bytes transferred over the network.
        public let encodedDataLength: Int?

        /// Decoded body bytes.
        public let decodedBodyLength: Int?

        /// Creates network transfer metrics.
        public init(
            timestamp: Double? = nil,
            networkProtocol: String? = nil,
            remoteAddress: String? = nil,
            encodedDataLength: Int? = nil,
            decodedBodyLength: Int? = nil
        ) {
            self.timestamp = timestamp
            self.networkProtocol = networkProtocol
            self.remoteAddress = remoteAddress
            self.encodedDataLength = encodedDataLength
            self.decodedBodyLength = decodedBodyLength
        }
    }

    /// Request initiator information.
    public struct Initiator: Sendable {
        /// The initiator kind reported by WebKit.
        public let kind: String

        /// The initiating script URL, if any.
        public let url: String?

        /// The initiating source line, if any.
        public let line: Int?

        /// The initiating source column, if any.
        public let column: Int?

        /// Creates request initiator information.
        public init(kind: String, url: String? = nil, line: Int? = nil, column: Int? = nil) {
            self.kind = kind
            self.url = url
            self.line = line
            self.column = column
        }
    }

    /// A request or response body payload.
    public struct Body: Sendable {
        /// The body data as text or base64.
        public let data: String

        /// A Boolean value indicating whether ``data`` is base64 encoded.
        public let base64Encoded: Bool

        /// Creates a body payload.
        public init(data: String, base64Encoded: Bool = false) {
            self.data = data
            self.base64Encoded = base64Encoded
        }
    }

    /// WebKit's resource type value.
    public struct ResourceType: RawRepresentable, Hashable, Sendable {
        /// The raw protocol resource type.
        public let rawValue: String

        /// Creates a resource type from its raw protocol value.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// A document resource.
        public static let document = ResourceType(rawValue: "Document")

        /// A stylesheet resource.
        public static let stylesheet = ResourceType(rawValue: "Stylesheet")

        /// An image resource.
        public static let image = ResourceType(rawValue: "Image")

        /// A font resource.
        public static let font = ResourceType(rawValue: "Font")

        /// A script resource.
        public static let script = ResourceType(rawValue: "Script")

        /// An XMLHttpRequest resource.
        public static let xhr = ResourceType(rawValue: "XHR")

        /// A Fetch API resource.
        public static let fetch = ResourceType(rawValue: "Fetch")

        /// A ping resource.
        public static let ping = ResourceType(rawValue: "Ping")

        /// A beacon resource.
        public static let beacon = ResourceType(rawValue: "Beacon")

        /// A WebSocket resource.
        public static let webSocket = ResourceType(rawValue: "WebSocket")

        /// An EventSource resource.
        public static let eventSource = ResourceType(rawValue: "EventSource")

        /// A media resource.
        public static let media = ResourceType(rawValue: "Media")

        /// A resource type not covered by another constant.
        public static let other = ResourceType(rawValue: "Other")
    }

    /// Events emitted by the Network domain.
    public enum Event: Sendable {
        /// A request is about to be sent.
        case requestWillBeSent(
            id: Request.ID,
            request: Request,
            resourceType: ResourceType?,
            redirectResponse: Response?,
            timestamp: Double
        )
        /// A response was received for a request.
        case responseReceived(id: Request.ID, response: Response, resourceType: ResourceType?, timestamp: Double)

        /// Additional response data was received.
        case dataReceived(id: Request.ID, dataLength: Int, encodedDataLength: Int, timestamp: Double)

        /// Request loading finished successfully.
        case loadingFinished(id: Request.ID, timestamp: Double, sourceMapURL: String?, metrics: Metrics?)

        /// Request loading failed or was cancelled.
        case loadingFailed(id: Request.ID, errorText: String, canceled: Bool, timestamp: Double)

        /// A request was served from the memory cache.
        case requestServedFromMemoryCache(id: Request.ID, response: Response, resourceType: ResourceType?, timestamp: Double)

        /// A WebSocket-specific event was emitted.
        case webSocket(WebSocketEvent)

        /// An event that is not modeled by this package.
        case unknown(RawEvent)
    }

    /// WebSocket lifecycle and frame events.
    public enum WebSocketEvent: Sendable {
        /// A WebSocket was created.
        case created(id: Request.ID, url: String)

        /// The WebSocket handshake request was sent.
        case handshakeRequest(id: Request.ID, request: Request, timestamp: Double?)

        /// The WebSocket handshake response was received.
        case handshakeResponse(id: Request.ID, response: Response, timestamp: Double?)

        /// The WebSocket was closed.
        case closed(id: Request.ID, timestamp: Double)

        /// A WebSocket frame was sent.
        case frameSent(id: Request.ID, frame: WebSocketFrame, timestamp: Double)

        /// A WebSocket frame was received.
        case frameReceived(id: Request.ID, frame: WebSocketFrame, timestamp: Double)

        /// A WebSocket error was reported.
        case error(id: Request.ID, message: String, timestamp: Double)

        /// A WebSocket event that is not modeled by this package.
        case other(RawEvent)
    }

    /// WebSocket frame payload metadata.
    public struct WebSocketFrame: Sendable {
        /// The WebSocket opcode.
        public let opcode: Int

        /// A Boolean value indicating whether the frame was masked.
        public let mask: Bool

        /// The frame payload as text or base64.
        public let payloadData: String

        /// The payload length in bytes.
        public let payloadLength: Int

        /// Creates WebSocket frame metadata.
        public init(opcode: Int, mask: Bool, payloadData: String, payloadLength: Int) {
            self.opcode = opcode
            self.mask = mask
            self.payloadData = payloadData
            self.payloadLength = payloadLength
        }
    }

    /// An asynchronous stream of Network domain events.
    public struct EventStream: AsyncSequence, Sendable {
        /// The event yielded by the stream.
        public typealias Element = Event

        /// The iterator type used by the stream.
        public typealias AsyncIterator = AsyncStream<Event>.Iterator

        private let makeStream: @Sendable () -> AsyncStream<Event>

        package init(
            _ makeStream: @escaping @Sendable () -> AsyncStream<Event> = {
                finishedStream(of: Event.self)
            }
        ) {
            self.makeStream = makeStream
        }

        /// Creates an iterator over Network events.
        public func makeAsyncIterator() -> AsyncIterator {
            makeStream().makeAsyncIterator()
        }
    }
}

package extension Network.Request.ID {
    private static var targetScopeSeparator: Character { "\u{1E}" }

    init(_ rawValue: String, scopedToTargetRawValue targetRawValue: String) {
        self.init("\(targetRawValue)\(Self.targetScopeSeparator)\(rawValue)")
    }

    var targetScopeRawValue: String? {
        let parts = rawValue.split(separator: Self.targetScopeSeparator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }
        return String(parts[0])
    }

    var unscopedRawValue: String {
        let parts = rawValue.split(separator: Self.targetScopeSeparator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return rawValue
        }
        return String(parts[1])
    }
}
