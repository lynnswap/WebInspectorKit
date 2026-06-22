import WebInspectorCoreDOMCSS
import WebInspectorCoreRuntime
import WebInspectorCoreSupport
import WebInspectorTransport

package enum NetworkCommand {}

extension NetworkRequest {
    package enum Timing {}
    package enum Security {}
    package enum Response {}
    package enum Metrics {}
    package enum Initiator {}
    package enum CachedResource {}
    package enum WebSocket {}
}
extension NetworkRequest {
    package struct ProtocolID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
        package let rawValue: String

        package init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        package init(rawValue: String) {
            self.rawValue = rawValue
        }

        package var description: String {
            rawValue
        }
    }
}

extension NetworkRequest {
    package struct ID: Hashable, Sendable {
        package var targetID: ProtocolTarget.ID
        package var requestID: NetworkRequest.ProtocolID

        package init(targetID: ProtocolTarget.ID, requestID: NetworkRequest.ProtocolID) {
            self.targetID = targetID
            self.requestID = requestID
        }
    }
}

extension NetworkRequest.RedirectHop {
    package struct ID: Hashable, Sendable {
        package var requestKey: NetworkRequest.ID
        package var redirectIndex: Int

        package init(requestKey: NetworkRequest.ID, redirectIndex: Int) {
            self.requestKey = requestKey
            self.redirectIndex = redirectIndex
        }
    }
}

extension NetworkRequest {
    package struct BackendResourceID: Hashable, Codable, Sendable {
        package var sourceProcessID: String
        package var resourceID: String

        package init(sourceProcessID: String, resourceID: String) {
            self.sourceProcessID = sourceProcessID
            self.resourceID = resourceID
        }
    }
}

extension NetworkCommand {
    package enum Intent: Equatable, Sendable {
        case getResponseBody(
            requestKey: NetworkRequest.ID,
            backendResourceIdentifier: NetworkRequest.BackendResourceID?
        )
        case getSerializedCertificate(
            requestKey: NetworkRequest.ID,
            backendResourceIdentifier: NetworkRequest.BackendResourceID?
        )
    }
}

extension NetworkRequest {
    package struct ReferrerPolicy: RawRepresentable, Hashable, Sendable {
        package let rawValue: String

        package init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        package init(rawValue: String) {
            self.rawValue = rawValue
        }
    }
}

extension NetworkRequest {
    package struct Payload: Equatable, Sendable {
        package var url: String
        package var method: String
        package var headers: [String: String]
        package var postData: String?
        package var referrerPolicy: NetworkRequest.ReferrerPolicy?
        package var integrity: String?

        package init(
            url: String,
            method: String = "GET",
            headers: [String: String] = [:],
            postData: String? = nil,
            referrerPolicy: NetworkRequest.ReferrerPolicy? = nil,
            integrity: String? = nil
        ) {
            self.url = url
            self.method = method
            self.headers = headers
            self.postData = postData
            self.referrerPolicy = referrerPolicy
            self.integrity = integrity
        }
    }
}

extension NetworkRequest.Timing {
    package struct Payload: Equatable, Sendable {
        package var startTime: Double
        package var redirectStart: Double
        package var redirectEnd: Double
        package var fetchStart: Double
        package var domainLookupStart: Double
        package var domainLookupEnd: Double
        package var connectStart: Double
        package var connectEnd: Double
        package var secureConnectionStart: Double
        package var requestStart: Double
        package var responseStart: Double
        package var responseEnd: Double

        package init(
            startTime: Double,
            redirectStart: Double,
            redirectEnd: Double,
            fetchStart: Double,
            domainLookupStart: Double,
            domainLookupEnd: Double,
            connectStart: Double,
            connectEnd: Double,
            secureConnectionStart: Double,
            requestStart: Double,
            responseStart: Double,
            responseEnd: Double
        ) {
            self.startTime = startTime
            self.redirectStart = redirectStart
            self.redirectEnd = redirectEnd
            self.fetchStart = fetchStart
            self.domainLookupStart = domainLookupStart
            self.domainLookupEnd = domainLookupEnd
            self.connectStart = connectStart
            self.connectEnd = connectEnd
            self.secureConnectionStart = secureConnectionStart
            self.requestStart = requestStart
            self.responseStart = responseStart
            self.responseEnd = responseEnd
        }
    }
}

extension NetworkRequest.Security {
    package struct ConnectionPayload: Equatable, Sendable {
        package var protocolName: String?
        package var cipher: String?

        package init(protocolName: String? = nil, cipher: String? = nil) {
            self.protocolName = protocolName
            self.cipher = cipher
        }
    }
}

extension NetworkRequest.Security {
    package struct CertificatePayload: Equatable, Sendable {
        package var subject: String?
        package var validFrom: Double?
        package var validUntil: Double?
        package var dnsNames: [String]
        package var ipAddresses: [String]

        package init(
            subject: String? = nil,
            validFrom: Double? = nil,
            validUntil: Double? = nil,
            dnsNames: [String] = [],
            ipAddresses: [String] = []
        ) {
            self.subject = subject
            self.validFrom = validFrom
            self.validUntil = validUntil
            self.dnsNames = dnsNames
            self.ipAddresses = ipAddresses
        }
    }
}

extension NetworkRequest.Security {
    package struct Payload: Equatable, Sendable {
        package var connection: NetworkRequest.Security.ConnectionPayload?
        package var certificate: NetworkRequest.Security.CertificatePayload?

        package init(connection: NetworkRequest.Security.ConnectionPayload? = nil, certificate: NetworkRequest.Security.CertificatePayload? = nil) {
            self.connection = connection
            self.certificate = certificate
        }
    }
}

extension NetworkRequest.Response {
    package struct Source: RawRepresentable, Hashable, Sendable {
        package let rawValue: String

        package init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        package init(rawValue: String) {
            self.rawValue = rawValue
        }

        package static let unknown = Self("unknown")
        package static let network = Self("network")
        package static let memoryCache = Self("memory-cache")
        package static let diskCache = Self("disk-cache")
        package static let serviceWorker = Self("service-worker")
        package static let inspectorOverride = Self("inspector-override")
    }
}

extension NetworkRequest.Response {
    package struct Payload: Equatable, Sendable {
        package var url: String
        package var status: Int
        package var statusText: String
        package var headers: [String: String]
        package var mimeType: String?
        package var source: NetworkRequest.Response.Source?
        package var requestHeaders: [String: String]?
        package var timing: NetworkRequest.Timing.Payload?
        package var security: NetworkRequest.Security.Payload?

        package init(
            url: String,
            status: Int,
            statusText: String = "",
            headers: [String: String] = [:],
            mimeType: String? = nil,
            source: NetworkRequest.Response.Source? = nil,
            requestHeaders: [String: String]? = nil,
            timing: NetworkRequest.Timing.Payload? = nil,
            security: NetworkRequest.Security.Payload? = nil
        ) {
            self.url = url
            self.status = status
            self.statusText = statusText
            self.headers = headers
            self.mimeType = mimeType
            self.source = source
            self.requestHeaders = requestHeaders
            self.timing = timing
            self.security = security
        }
    }
}

extension NetworkRequest {
    package struct ResourceType: RawRepresentable, Hashable, Sendable {
        package let rawValue: String

        package init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        package init(rawValue: String) {
            self.rawValue = rawValue
        }

        package static let document = Self("Document")
        package static let styleSheet = Self("StyleSheet")
        package static let image = Self("Image")
        package static let media = Self("Media")
        package static let font = Self("Font")
        package static let script = Self("Script")
        package static let xhr = Self("XHR")
        package static let fetch = Self("Fetch")
        package static let ping = Self("Ping")
        package static let beacon = Self("Beacon")
        package static let webSocket = Self("WebSocket")
        package static let eventSource = Self("EventSource")
        package static let other = Self("Other")
    }
}

extension NetworkRequest {
    package struct Priority: RawRepresentable, Hashable, Sendable {
        package let rawValue: String

        package init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        package init(rawValue: String) {
            self.rawValue = rawValue
        }

        package static let low = Self("low")
        package static let medium = Self("medium")
        package static let high = Self("high")
    }
}

extension NetworkRequest.Metrics {
    package struct Payload: Equatable, Sendable {
        package var networkProtocol: String?
        package var priority: NetworkRequest.Priority?
        package var connectionIdentifier: String?
        package var remoteAddress: String?
        package var requestHeaders: [String: String]?
        package var requestHeaderBytesSent: Int?
        package var requestBodyBytesSent: Int?
        package var responseHeaderBytesReceived: Int?
        package var responseBodyBytesReceived: Int?
        package var responseBodyDecodedSize: Int?
        package var securityConnection: NetworkRequest.Security.ConnectionPayload?
        package var isProxyConnection: Bool?

        package init(
            networkProtocol: String? = nil,
            priority: NetworkRequest.Priority? = nil,
            connectionIdentifier: String? = nil,
            remoteAddress: String? = nil,
            requestHeaders: [String: String]? = nil,
            requestHeaderBytesSent: Int? = nil,
            requestBodyBytesSent: Int? = nil,
            responseHeaderBytesReceived: Int? = nil,
            responseBodyBytesReceived: Int? = nil,
            responseBodyDecodedSize: Int? = nil,
            securityConnection: NetworkRequest.Security.ConnectionPayload? = nil,
            isProxyConnection: Bool? = nil
        ) {
            self.networkProtocol = networkProtocol
            self.priority = priority
            self.connectionIdentifier = connectionIdentifier
            self.remoteAddress = remoteAddress
            self.requestHeaders = requestHeaders
            self.requestHeaderBytesSent = requestHeaderBytesSent
            self.requestBodyBytesSent = requestBodyBytesSent
            self.responseHeaderBytesReceived = responseHeaderBytesReceived
            self.responseBodyBytesReceived = responseBodyBytesReceived
            self.responseBodyDecodedSize = responseBodyDecodedSize
            self.securityConnection = securityConnection
            self.isProxyConnection = isProxyConnection
        }
    }
}

extension NetworkRequest.Initiator {
    package struct Kind: RawRepresentable, Hashable, Sendable {
        package let rawValue: String

        package init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        package init(rawValue: String) {
            self.rawValue = rawValue
        }

        package static let parser = Self("parser")
        package static let script = Self("script")
        package static let other = Self("other")
    }
}

extension NetworkRequest.Initiator {
    package struct Payload: Equatable, Sendable {
        package var type: NetworkRequest.Initiator.Kind
        package var stackTrace: ConsoleMessage.StackTracePayload?
        package var url: String?
        package var lineNumber: Double?
        package var nodeID: DOMNode.ProtocolID?

        package init(
            type: NetworkRequest.Initiator.Kind,
            stackTrace: ConsoleMessage.StackTracePayload? = nil,
            url: String? = nil,
            lineNumber: Double? = nil,
            nodeID: DOMNode.ProtocolID? = nil
        ) {
            self.type = type
            self.stackTrace = stackTrace
            self.url = url
            self.lineNumber = lineNumber
            self.nodeID = nodeID
        }
    }
}

extension NetworkRequest.CachedResource {
    package struct Payload: Equatable, Sendable {
        package var url: String
        package var type: NetworkRequest.ResourceType
        package var response: NetworkRequest.Response.Payload?
        package var bodySize: Int
        package var sourceMapURL: String?

        package init(
            url: String,
            type: NetworkRequest.ResourceType,
            response: NetworkRequest.Response.Payload? = nil,
            bodySize: Int,
            sourceMapURL: String? = nil
        ) {
            self.url = url
            self.type = type
            self.response = response
            self.bodySize = bodySize
            self.sourceMapURL = sourceMapURL
        }
    }
}

extension NetworkRequest.WebSocket {
    package struct RequestPayload: Equatable, Sendable {
        package var headers: [String: String]

        package init(headers: [String: String] = [:]) {
            self.headers = headers
        }
    }
}

extension NetworkRequest.WebSocket {
    package struct ResponsePayload: Equatable, Sendable {
        package var status: Int
        package var statusText: String
        package var headers: [String: String]

        package init(status: Int, statusText: String = "", headers: [String: String] = [:]) {
            self.status = status
            self.statusText = statusText
            self.headers = headers
        }
    }
}

extension NetworkRequest.WebSocket {
    package struct FramePayload: Equatable, Sendable {
        package var opcode: Int
        package var mask: Bool
        package var payloadData: String
        package var payloadLength: Int

        package init(opcode: Int, mask: Bool, payloadData: String, payloadLength: Int) {
            self.opcode = opcode
            self.mask = mask
            self.payloadData = payloadData
            self.payloadLength = payloadLength
        }
    }
}

extension NetworkRequest {
    package enum State: Equatable, Sendable {
        case pending
        case responded
        case finished
        case failed(errorText: String, canceled: Bool)
    }
}
