package struct NetworkRequestIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
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

package struct NetworkRequestIdentifierKey: Hashable, Sendable {
    package var targetID: ProtocolTargetIdentifier
    package var requestID: NetworkRequestIdentifier

    package init(targetID: ProtocolTargetIdentifier, requestID: NetworkRequestIdentifier) {
        self.targetID = targetID
        self.requestID = requestID
    }
}

package struct NetworkRedirectHopIdentifier: Hashable, Sendable {
    package var requestKey: NetworkRequestIdentifierKey
    package var redirectIndex: Int

    package init(requestKey: NetworkRequestIdentifierKey, redirectIndex: Int) {
        self.requestKey = requestKey
        self.redirectIndex = redirectIndex
    }
}

package struct ConsoleCallFramePayload: Equatable, Sendable {
    package var functionName: String
    package var url: String
    package var scriptID: String
    package var lineNumber: Int
    package var columnNumber: Int

    package init(functionName: String, url: String, scriptID: String, lineNumber: Int, columnNumber: Int) {
        self.functionName = functionName
        self.url = url
        self.scriptID = scriptID
        self.lineNumber = lineNumber
        self.columnNumber = columnNumber
    }
}

package struct ConsoleStackTracePayload: Equatable, Sendable {
    package var callFrames: [ConsoleCallFramePayload]
    package var topCallFrameIsBoundary: Bool?
    package var truncated: Bool?
    package var parentStackTraces: [ConsoleStackTracePayload]

    package init(
        callFrames: [ConsoleCallFramePayload],
        topCallFrameIsBoundary: Bool? = nil,
        truncated: Bool? = nil,
        parentStackTraces: [ConsoleStackTracePayload] = []
    ) {
        self.callFrames = callFrames
        self.topCallFrameIsBoundary = topCallFrameIsBoundary
        self.truncated = truncated
        self.parentStackTraces = parentStackTraces
    }
}

package struct NetworkReferrerPolicy: RawRepresentable, Hashable, Sendable {
    package let rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    package init(rawValue: String) {
        self.rawValue = rawValue
    }
}

package struct NetworkRequestPayload: Equatable, Sendable {
    package var url: String
    package var method: String
    package var headers: [String: String]
    package var postData: String?
    package var referrerPolicy: NetworkReferrerPolicy?
    package var integrity: String?

    package init(
        url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        postData: String? = nil,
        referrerPolicy: NetworkReferrerPolicy? = nil,
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

package struct NetworkResourceTimingPayload: Equatable, Sendable {
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

package struct NetworkSecurityConnectionPayload: Equatable, Sendable {
    package var protocolName: String?
    package var cipher: String?

    package init(protocolName: String? = nil, cipher: String? = nil) {
        self.protocolName = protocolName
        self.cipher = cipher
    }
}

package struct NetworkCertificatePayload: Equatable, Sendable {
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

package struct NetworkSecurityPayload: Equatable, Sendable {
    package var connection: NetworkSecurityConnectionPayload?
    package var certificate: NetworkCertificatePayload?

    package init(connection: NetworkSecurityConnectionPayload? = nil, certificate: NetworkCertificatePayload? = nil) {
        self.connection = connection
        self.certificate = certificate
    }
}

package struct NetworkResponseSource: RawRepresentable, Hashable, Sendable {
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

package struct NetworkResponsePayload: Equatable, Sendable {
    package var url: String
    package var status: Int
    package var statusText: String
    package var headers: [String: String]
    package var mimeType: String?
    package var source: NetworkResponseSource?
    package var requestHeaders: [String: String]?
    package var timing: NetworkResourceTimingPayload?
    package var security: NetworkSecurityPayload?

    package init(
        url: String,
        status: Int,
        statusText: String = "",
        headers: [String: String] = [:],
        mimeType: String? = nil,
        source: NetworkResponseSource? = nil,
        requestHeaders: [String: String]? = nil,
        timing: NetworkResourceTimingPayload? = nil,
        security: NetworkSecurityPayload? = nil
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

package struct NetworkResourceType: RawRepresentable, Hashable, Sendable {
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

package struct NetworkPriority: RawRepresentable, Hashable, Sendable {
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

package struct NetworkLoadMetricsPayload: Equatable, Sendable {
    package var networkProtocol: String?
    package var priority: NetworkPriority?
    package var connectionIdentifier: String?
    package var remoteAddress: String?
    package var requestHeaders: [String: String]?
    package var requestHeaderBytesSent: Int?
    package var requestBodyBytesSent: Int?
    package var responseHeaderBytesReceived: Int?
    package var responseBodyBytesReceived: Int?
    package var responseBodyDecodedSize: Int?
    package var securityConnection: NetworkSecurityConnectionPayload?
    package var isProxyConnection: Bool?

    package init(
        networkProtocol: String? = nil,
        priority: NetworkPriority? = nil,
        connectionIdentifier: String? = nil,
        remoteAddress: String? = nil,
        requestHeaders: [String: String]? = nil,
        requestHeaderBytesSent: Int? = nil,
        requestBodyBytesSent: Int? = nil,
        responseHeaderBytesReceived: Int? = nil,
        responseBodyBytesReceived: Int? = nil,
        responseBodyDecodedSize: Int? = nil,
        securityConnection: NetworkSecurityConnectionPayload? = nil,
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

package struct NetworkInitiatorType: RawRepresentable, Hashable, Sendable {
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

package struct NetworkInitiatorPayload: Equatable, Sendable {
    package var type: NetworkInitiatorType
    package var stackTrace: ConsoleStackTracePayload?
    package var url: String?
    package var lineNumber: Double?
    package var nodeID: DOMProtocolNodeID?

    package init(
        type: NetworkInitiatorType,
        stackTrace: ConsoleStackTracePayload? = nil,
        url: String? = nil,
        lineNumber: Double? = nil,
        nodeID: DOMProtocolNodeID? = nil
    ) {
        self.type = type
        self.stackTrace = stackTrace
        self.url = url
        self.lineNumber = lineNumber
        self.nodeID = nodeID
    }
}

package struct NetworkCachedResourcePayload: Equatable, Sendable {
    package var url: String
    package var type: NetworkResourceType
    package var response: NetworkResponsePayload?
    package var bodySize: Int
    package var sourceMapURL: String?

    package init(
        url: String,
        type: NetworkResourceType,
        response: NetworkResponsePayload? = nil,
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

package struct NetworkWebSocketRequestPayload: Equatable, Sendable {
    package var headers: [String: String]

    package init(headers: [String: String] = [:]) {
        self.headers = headers
    }
}

package struct NetworkWebSocketResponsePayload: Equatable, Sendable {
    package var status: Int
    package var statusText: String
    package var headers: [String: String]

    package init(status: Int, statusText: String = "", headers: [String: String] = [:]) {
        self.status = status
        self.statusText = statusText
        self.headers = headers
    }
}

package struct NetworkWebSocketFramePayload: Equatable, Sendable {
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

package enum NetworkRequestState: Equatable, Sendable {
    case pending
    case responded
    case finished
    case failed(errorText: String, canceled: Bool)
}
