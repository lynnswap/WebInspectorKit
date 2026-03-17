import Foundation

package enum NetworkSeedKind {
    case stable
    case historical
}

package struct NetworkEntrySeed {
    package let kind: NetworkSeedKind
    package let sessionID: String
    package let requestID: Int
    package let url: String
    package let method: String
    package let requestHeaders: NetworkHeaders
    package let responseHeaders: NetworkHeaders
    package let startTimestamp: TimeInterval
    package let wallTime: TimeInterval?
    package let statusCode: Int?
    package let statusText: String
    package let mimeType: String?
    package let encodedBodyLength: Int?
    package let decodedBodyLength: Int?
    package let errorDescription: String?
    package let requestType: String?
    package let requestBodyBytesSent: Int?
    package let phase: NetworkEntry.Phase
    package let requestBody: NetworkBody?
    package let responseBody: NetworkBody?

    package init(
        kind: NetworkSeedKind,
        sessionID: String,
        requestID: Int,
        url: String,
        method: String,
        requestHeaders: NetworkHeaders = NetworkHeaders(),
        responseHeaders: NetworkHeaders = NetworkHeaders(),
        startTimestamp: TimeInterval,
        wallTime: TimeInterval? = nil,
        statusCode: Int? = nil,
        statusText: String = "",
        mimeType: String? = nil,
        encodedBodyLength: Int? = nil,
        decodedBodyLength: Int? = nil,
        errorDescription: String? = nil,
        requestType: String? = nil,
        requestBodyBytesSent: Int? = nil,
        phase: NetworkEntry.Phase,
        requestBody: NetworkBody? = nil,
        responseBody: NetworkBody? = nil
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.requestID = requestID
        self.url = url
        self.method = method
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.startTimestamp = startTimestamp
        self.wallTime = wallTime
        self.statusCode = statusCode
        self.statusText = statusText
        self.mimeType = mimeType
        self.encodedBodyLength = encodedBodyLength
        self.decodedBodyLength = decodedBodyLength
        self.errorDescription = errorDescription
        self.requestType = requestType
        self.requestBodyBytesSent = requestBodyBytesSent
        self.phase = phase
        self.requestBody = requestBody
        self.responseBody = responseBody
    }
}
