import Foundation

public enum Network {
    public struct Client: Sendable {
        package let context: DomainClientContext

        package init(context: DomainClientContext) {
            self.context = context
        }

        public func enable() async throws {
            try await context.dispatchVoid(
                domain: .network,
                method: "enable",
                payload: EnablePayload()
            )
        }

        public func disable() async throws {
            try await context.dispatchVoid(
                domain: .network,
                method: "disable",
                payload: DisablePayload()
            )
        }

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

    public struct Request: Identifiable, Sendable {
        public struct ID: Hashable, Sendable {
            package let rawValue: String

            package init(_ rawValue: String) {
                self.rawValue = rawValue
            }
        }

        public let id: ID
        public let url: String
        public let method: String
        public let headers: [String: String]
        public let postData: String?
        public let referrerPolicy: ReferrerPolicy?
        public let integrity: String?
        public let backendResourceIdentifier: BackendResourceID?

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
        public let sourceProcessID: String
        public let resourceID: String

        public init(sourceProcessID: String, resourceID: String) {
            self.sourceProcessID = sourceProcessID
            self.resourceID = resourceID
        }
    }

    public struct Response: Sendable {
        public let url: String?
        public let status: Int?
        public let statusText: String?
        public let mimeType: String?
        public let headers: [String: String]
        public let source: Source?
        public let requestHeaders: [String: String]?

        public init(
            url: String? = nil,
            status: Int? = nil,
            statusText: String? = nil,
            mimeType: String? = nil,
            headers: [String: String] = [:],
            source: Source? = nil,
            requestHeaders: [String: String]? = nil
        ) {
            self.url = url
            self.status = status
            self.statusText = statusText
            self.mimeType = mimeType
            self.headers = headers
            self.source = source
            self.requestHeaders = requestHeaders
        }
    }

    public struct ReferrerPolicy: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public struct Source: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public struct Metrics: Sendable {
        public let timestamp: Double?
        public let networkProtocol: String?
        public let remoteAddress: String?
        public let encodedDataLength: Int?
        public let decodedBodyLength: Int?

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

    public struct Initiator: Sendable {
        public let kind: String
        public let url: String?
        public let line: Int?
        public let column: Int?

        public init(kind: String, url: String? = nil, line: Int? = nil, column: Int? = nil) {
            self.kind = kind
            self.url = url
            self.line = line
            self.column = column
        }
    }

    public struct Body: Sendable {
        public let data: String
        public let base64Encoded: Bool

        public init(data: String, base64Encoded: Bool = false) {
            self.data = data
            self.base64Encoded = base64Encoded
        }
    }

    public struct ResourceType: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let document = ResourceType(rawValue: "Document")
        public static let stylesheet = ResourceType(rawValue: "Stylesheet")
        public static let image = ResourceType(rawValue: "Image")
        public static let font = ResourceType(rawValue: "Font")
        public static let script = ResourceType(rawValue: "Script")
        public static let xhr = ResourceType(rawValue: "XHR")
        public static let fetch = ResourceType(rawValue: "Fetch")
        public static let ping = ResourceType(rawValue: "Ping")
        public static let beacon = ResourceType(rawValue: "Beacon")
        public static let webSocket = ResourceType(rawValue: "WebSocket")
        public static let eventSource = ResourceType(rawValue: "EventSource")
        public static let media = ResourceType(rawValue: "Media")
        public static let other = ResourceType(rawValue: "Other")
    }

    public enum Event: Sendable {
        case requestWillBeSent(
            id: Request.ID,
            request: Request,
            resourceType: ResourceType?,
            redirectResponse: Response?,
            timestamp: Double
        )
        case responseReceived(id: Request.ID, response: Response, resourceType: ResourceType?, timestamp: Double)
        case dataReceived(id: Request.ID, dataLength: Int, encodedDataLength: Int, timestamp: Double)
        case loadingFinished(id: Request.ID, timestamp: Double, sourceMapURL: String?, metrics: Metrics?)
        case loadingFailed(id: Request.ID, errorText: String, canceled: Bool, timestamp: Double)
        case requestServedFromMemoryCache(id: Request.ID, response: Response, resourceType: ResourceType?, timestamp: Double)
        case webSocket(WebSocketEvent)
        case unknown(RawEvent)
    }

    public enum WebSocketEvent: Sendable {
        case created(id: Request.ID, url: String)
        case handshakeRequest(id: Request.ID, request: Request, timestamp: Double?)
        case handshakeResponse(id: Request.ID, response: Response, timestamp: Double?)
        case closed(id: Request.ID, timestamp: Double)
        case frameSent(id: Request.ID, frame: WebSocketFrame, timestamp: Double)
        case frameReceived(id: Request.ID, frame: WebSocketFrame, timestamp: Double)
        case error(id: Request.ID, message: String, timestamp: Double)
        case other(RawEvent)
    }

    public struct WebSocketFrame: Sendable {
        public let opcode: Int
        public let mask: Bool
        public let payloadData: String
        public let payloadLength: Int

        public init(opcode: Int, mask: Bool, payloadData: String, payloadLength: Int) {
            self.opcode = opcode
            self.mask = mask
            self.payloadData = payloadData
            self.payloadLength = payloadLength
        }
    }

    public struct EventStream: AsyncSequence, Sendable {
        public typealias Element = Event
        public typealias AsyncIterator = AsyncStream<Event>.Iterator

        private let makeStream: @Sendable () -> AsyncStream<Event>

        package init(
            _ makeStream: @escaping @Sendable () -> AsyncStream<Event> = {
                finishedStream(of: Event.self)
            }
        ) {
            self.makeStream = makeStream
        }

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
