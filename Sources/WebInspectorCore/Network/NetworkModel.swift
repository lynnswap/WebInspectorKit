import Observation

package struct NetworkRedirectHop: Equatable, Sendable {
    package var id: NetworkRedirectHopIdentifier
    package var request: NetworkRequestPayload
    package var response: NetworkResponsePayload
    package var timestamp: Double

    package init(
        id: NetworkRedirectHopIdentifier,
        request: NetworkRequestPayload,
        response: NetworkResponsePayload,
        timestamp: Double
    ) {
        self.id = id
        self.request = request
        self.response = response
        self.timestamp = timestamp
    }
}

package enum NetworkWebSocketReadyState: Equatable, Sendable {
    case connecting
    case open
    case closed
}

package struct NetworkWebSocketFrameEntry: Equatable, Sendable {
    package enum Direction: Equatable, Sendable {
        case incoming
        case outgoing
        case error(String)
    }

    package var payload: NetworkWebSocketFramePayload?
    package var direction: Direction
    package var timestamp: Double

    package init(payload: NetworkWebSocketFramePayload?, direction: Direction, timestamp: Double) {
        self.payload = payload
        self.direction = direction
        self.timestamp = timestamp
    }
}

@MainActor
@Observable
package final class NetworkRequest {
    package typealias ID = NetworkRequestIdentifierKey

    package let id: ID
    package var frameID: DOMFrameIdentifier?
    package var loaderID: String?
    package var documentURL: String?
    package var resourceType: NetworkResourceType?
    package var originatingTargetID: ProtocolTargetIdentifier?
    package var backendResourceIdentifier: NetworkBackendResourceIdentifier?
    package var initiator: NetworkInitiatorPayload?
    package var request: NetworkRequestPayload
    package var requestBody: NetworkBody?
    package var response: NetworkResponsePayload?
    package var responseBody: NetworkBody?
    package var sourceMapURL: String?
    package var metrics: NetworkLoadMetricsPayload?
    package var cachedResourceBodySize: Int?
    package var webSocketHandshakeRequest: NetworkWebSocketRequestPayload?
    package var webSocketHandshakeResponse: NetworkWebSocketResponsePayload?
    package var webSocketReadyState: NetworkWebSocketReadyState?
    package var webSocketFrames: [NetworkWebSocketFrameEntry]
    package var redirects: [NetworkRedirectHop]
    package var requestSentTimestamp: Double
    package var requestSentWalltime: Double?
    package var responseReceivedTimestamp: Double?
    package var lastDataReceivedTimestamp: Double?
    package var finishedOrFailedTimestamp: Double?
    package var encodedDataLength: Int
    package var decodedDataLength: Int
    package var state: NetworkRequestState

    package init(
        id: ID,
        frameID: DOMFrameIdentifier?,
        loaderID: String?,
        documentURL: String?,
        request: NetworkRequestPayload,
        resourceType: NetworkResourceType?,
        originatingTargetID: ProtocolTargetIdentifier?,
        backendResourceIdentifier: NetworkBackendResourceIdentifier?,
        initiator: NetworkInitiatorPayload?,
        timestamp: Double,
        walltime: Double?
    ) {
        self.id = id
        self.frameID = frameID
        self.loaderID = loaderID
        self.documentURL = documentURL
        self.resourceType = resourceType
        self.originatingTargetID = originatingTargetID
        self.backendResourceIdentifier = backendResourceIdentifier
        self.initiator = initiator
        self.request = request
        self.requestBody = NetworkBody.makeRequestBody(for: request)
        self.response = nil
        self.responseBody = nil
        self.sourceMapURL = nil
        self.metrics = nil
        self.cachedResourceBodySize = nil
        self.webSocketHandshakeRequest = nil
        self.webSocketHandshakeResponse = nil
        self.webSocketReadyState = nil
        self.webSocketFrames = []
        self.redirects = []
        self.requestSentTimestamp = timestamp
        self.requestSentWalltime = walltime
        self.responseReceivedTimestamp = nil
        self.lastDataReceivedTimestamp = nil
        self.finishedOrFailedTimestamp = nil
        self.encodedDataLength = 0
        self.decodedDataLength = 0
        self.state = .pending
    }

    package func applyRedirect(to nextRequest: NetworkRequestPayload, redirectResponse: NetworkResponsePayload, timestamp: Double, walltime: Double?) {
        let hopID = NetworkRedirectHopIdentifier(requestKey: id, redirectIndex: redirects.count)
        redirects.append(
            NetworkRedirectHop(
                id: hopID,
                request: request,
                response: redirectResponse,
                timestamp: timestamp
            )
        )
        request = nextRequest
        requestBody = NetworkBody.makeRequestBody(for: nextRequest)
        requestSentTimestamp = timestamp
        requestSentWalltime = walltime
        response = nil
        responseBody = nil
        sourceMapURL = nil
        metrics = nil
        cachedResourceBodySize = nil
        webSocketHandshakeRequest = nil
        webSocketHandshakeResponse = nil
        webSocketReadyState = nil
        webSocketFrames = []
        responseReceivedTimestamp = nil
        lastDataReceivedTimestamp = nil
        finishedOrFailedTimestamp = nil
        encodedDataLength = 0
        decodedDataLength = 0
        state = .pending
    }

    package func applyMetrics(_ metrics: NetworkLoadMetricsPayload) {
        self.metrics = metrics
        if let requestHeaders = metrics.requestHeaders {
            request.headers = requestHeaders
            refreshRequestBodyHints()
        }
        if let responseBodyBytesReceived = metrics.responseBodyBytesReceived {
            encodedDataLength = max(0, responseBodyBytesReceived)
        }
        if let responseBodyDecodedSize = metrics.responseBodyDecodedSize {
            decodedDataLength = max(0, responseBodyDecodedSize)
        }
        if let securityConnection = metrics.securityConnection {
            var responseSecurity = response?.security ?? NetworkSecurityPayload()
            responseSecurity.connection = securityConnection
            response?.security = responseSecurity
        }
    }

    package func applyResponseBody(_ payload: NetworkBodyPayload) {
        ensureResponseBody()
        responseBody?.apply(payload)
    }

    package func markResponseBodyFetching() {
        ensureResponseBody()
        responseBody?.markFetching()
    }

    package func markResponseBodyFailed(_ error: NetworkBodyFetchError) {
        ensureResponseBody()
        responseBody?.markFailed(error)
    }

    package func ensureResponseBody() {
        guard let response else {
            return
        }
        guard resourceType != .webSocket else {
            responseBody = nil
            return
        }
        if let responseBody {
            let hints = NetworkBody.bodyHints(
                mimeType: response.mimeType,
                headers: response.headers,
                url: response.url,
                role: .response
            )
            responseBody.updateHints(kind: hints.kind, sourceSyntaxKind: hints.syntaxKind)
        } else {
            responseBody = NetworkBody.makeResponseBody(for: response)
        }
    }

    private func refreshRequestBodyHints() {
        guard let requestBody else {
            self.requestBody = NetworkBody.makeRequestBody(for: request)
            return
        }
        let hints = NetworkBody.bodyHints(
            mimeType: nil,
            headers: request.headers,
            url: request.url,
            role: .request
        )
        requestBody.updateHints(kind: hints.kind, sourceSyntaxKind: hints.syntaxKind)
    }
}

package struct NetworkRedirectHopSnapshot: Equatable, Sendable {
    package var id: NetworkRedirectHopIdentifier
    package var request: NetworkRequestPayload
    package var response: NetworkResponsePayload
    package var timestamp: Double
}

package struct NetworkRequestSnapshot: Equatable, Sendable {
    package var id: NetworkRequestIdentifierKey
    package var frameID: DOMFrameIdentifier?
    package var loaderID: String?
    package var documentURL: String?
    package var resourceType: NetworkResourceType?
    package var originatingTargetID: ProtocolTargetIdentifier?
    package var backendResourceIdentifier: NetworkBackendResourceIdentifier?
    package var initiator: NetworkInitiatorPayload?
    package var request: NetworkRequestPayload
    package var response: NetworkResponsePayload?
    package var sourceMapURL: String?
    package var metrics: NetworkLoadMetricsPayload?
    package var cachedResourceBodySize: Int?
    package var webSocketHandshakeRequest: NetworkWebSocketRequestPayload?
    package var webSocketHandshakeResponse: NetworkWebSocketResponsePayload?
    package var webSocketReadyState: NetworkWebSocketReadyState?
    package var webSocketFrames: [NetworkWebSocketFrameEntry]
    package var redirects: [NetworkRedirectHopSnapshot]
    package var requestSentTimestamp: Double
    package var requestSentWalltime: Double?
    package var responseReceivedTimestamp: Double?
    package var lastDataReceivedTimestamp: Double?
    package var finishedOrFailedTimestamp: Double?
    package var encodedDataLength: Int
    package var decodedDataLength: Int
    package var state: NetworkRequestState
}

package struct NetworkSessionSnapshot: Equatable, Sendable {
    package var orderedRequestIDs: [NetworkRequestIdentifierKey]
    package var requestsByID: [NetworkRequestIdentifierKey: NetworkRequestSnapshot]
}

@MainActor
@Observable
package final class NetworkSession {
    private var orderedRequestIDs: [NetworkRequest.ID]
    private var requestsByID: [NetworkRequest.ID: NetworkRequest]

    package init() {
        orderedRequestIDs = []
        requestsByID = [:]
    }

    package var requests: [NetworkRequest] {
        orderedRequestIDs.compactMap { requestsByID[$0] }
    }

    package func request(for id: NetworkRequest.ID) -> NetworkRequest? {
        requestsByID[id]
    }

    package func reset() {
        orderedRequestIDs.removeAll()
        requestsByID.removeAll()
    }

    @discardableResult
    package func applyRequestWillBeSent(
        targetID: ProtocolTargetIdentifier,
        requestID: NetworkRequestIdentifier,
        frameID: DOMFrameIdentifier?,
        loaderID: String?,
        documentURL: String?,
        request: NetworkRequestPayload,
        resourceType: NetworkResourceType? = nil,
        originatingTargetID: ProtocolTargetIdentifier? = nil,
        backendResourceIdentifier: NetworkBackendResourceIdentifier? = nil,
        initiator: NetworkInitiatorPayload? = nil,
        redirectResponse: NetworkResponsePayload? = nil,
        timestamp: Double,
        walltime: Double? = nil
    ) -> NetworkRequest.ID {
        let key = NetworkRequest.ID(targetID: targetID, requestID: requestID)

        if let existing = requestsByID[key] {
            if let redirectResponse {
                existing.frameID = frameID ?? existing.frameID
                existing.loaderID = loaderID ?? existing.loaderID
                existing.documentURL = documentURL ?? existing.documentURL
                existing.resourceType = resourceType ?? existing.resourceType
                existing.originatingTargetID = originatingTargetID ?? existing.originatingTargetID
                existing.backendResourceIdentifier = backendResourceIdentifier ?? existing.backendResourceIdentifier
                existing.initiator = initiator ?? existing.initiator
                existing.applyRedirect(to: request, redirectResponse: redirectResponse, timestamp: timestamp, walltime: walltime)
            } else {
                existing.backendResourceIdentifier = backendResourceIdentifier ?? existing.backendResourceIdentifier
            }
            return key
        }

        let networkRequest = NetworkRequest(
            id: key,
            frameID: frameID,
            loaderID: loaderID,
            documentURL: documentURL,
            request: request,
            resourceType: resourceType,
            originatingTargetID: originatingTargetID,
            backendResourceIdentifier: backendResourceIdentifier,
            initiator: initiator,
            timestamp: timestamp,
            walltime: walltime
        )
        requestsByID[key] = networkRequest
        if !orderedRequestIDs.contains(key) {
            orderedRequestIDs.append(key)
        }
        return key
    }

    package func applyResponseReceived(
        targetID: ProtocolTargetIdentifier,
        requestID: NetworkRequestIdentifier,
        frameID: DOMFrameIdentifier? = nil,
        loaderID: String? = nil,
        resourceType: NetworkResourceType? = nil,
        response: NetworkResponsePayload,
        timestamp: Double
    ) {
        guard let request = requestsByID[.init(targetID: targetID, requestID: requestID)] else {
            return
        }
        request.frameID = frameID ?? request.frameID
        request.loaderID = loaderID ?? request.loaderID
        request.resourceType = resourceType ?? request.resourceType
        if let requestHeaders = response.requestHeaders {
            request.request.headers = requestHeaders
            request.requestBody = NetworkBody.makeRequestBody(for: request.request)
        }
        request.response = response
        request.ensureResponseBody()
        request.responseReceivedTimestamp = timestamp
        request.state = .responded
    }

    package func applyDataReceived(
        targetID: ProtocolTargetIdentifier,
        requestID: NetworkRequestIdentifier,
        dataLength: Int,
        encodedDataLength: Int,
        timestamp: Double
    ) {
        guard let request = requestsByID[.init(targetID: targetID, requestID: requestID)] else {
            return
        }
        request.decodedDataLength += max(0, dataLength)
        request.encodedDataLength += max(0, encodedDataLength)
        request.lastDataReceivedTimestamp = timestamp
    }

    package func applyLoadingFinished(
        targetID: ProtocolTargetIdentifier,
        requestID: NetworkRequestIdentifier,
        timestamp: Double,
        sourceMapURL: String? = nil,
        metrics: NetworkLoadMetricsPayload? = nil
    ) {
        guard let request = requestsByID[.init(targetID: targetID, requestID: requestID)] else {
            return
        }
        if let sourceMapURL {
            request.sourceMapURL = sourceMapURL
        }
        if let metrics {
            request.applyMetrics(metrics)
        }
        request.finishedOrFailedTimestamp = timestamp
        request.state = .finished
    }

    package func applyLoadingFailed(
        targetID: ProtocolTargetIdentifier,
        requestID: NetworkRequestIdentifier,
        timestamp: Double,
        errorText: String,
        canceled: Bool = false
    ) {
        guard let request = requestsByID[.init(targetID: targetID, requestID: requestID)] else {
            return
        }
        request.finishedOrFailedTimestamp = timestamp
        request.state = .failed(errorText: errorText, canceled: canceled)
    }

    @discardableResult
    package func applyRequestServedFromMemoryCache(
        targetID: ProtocolTargetIdentifier,
        requestID: NetworkRequestIdentifier,
        frameID: DOMFrameIdentifier,
        loaderID: String,
        documentURL: String,
        timestamp: Double,
        initiator: NetworkInitiatorPayload?,
        resource: NetworkCachedResourcePayload
    ) -> NetworkRequest.ID {
        let key = NetworkRequest.ID(targetID: targetID, requestID: requestID)
        let networkRequest = requestsByID[key] ?? NetworkRequest(
            id: key,
            frameID: frameID,
            loaderID: loaderID,
            documentURL: documentURL,
            request: .init(url: resource.url),
            resourceType: resource.type,
            originatingTargetID: nil,
            backendResourceIdentifier: nil,
            initiator: initiator,
            timestamp: timestamp,
            walltime: nil
        )

        networkRequest.frameID = frameID
        networkRequest.loaderID = loaderID
        networkRequest.documentURL = documentURL
        networkRequest.resourceType = resource.type
        networkRequest.initiator = initiator
        networkRequest.requestSentTimestamp = timestamp
        if var response = resource.response {
            response.source = response.source ?? .memoryCache
            networkRequest.response = response
            networkRequest.ensureResponseBody()
            networkRequest.responseReceivedTimestamp = timestamp
        }
        networkRequest.sourceMapURL = resource.sourceMapURL
        networkRequest.cachedResourceBodySize = max(0, resource.bodySize)
        networkRequest.decodedDataLength = max(0, resource.bodySize)
        networkRequest.encodedDataLength = max(0, resource.bodySize)
        networkRequest.finishedOrFailedTimestamp = timestamp
        networkRequest.state = .finished

        if requestsByID[key] == nil {
            requestsByID[key] = networkRequest
            orderedRequestIDs.append(key)
        }
        return key
    }

    @discardableResult
    package func applyWebSocketCreated(
        targetID: ProtocolTargetIdentifier,
        requestID: NetworkRequestIdentifier,
        url: String
    ) -> NetworkRequest.ID {
        let key = NetworkRequest.ID(targetID: targetID, requestID: requestID)
        if let existing = requestsByID[key] {
            existing.request.url = url
            existing.resourceType = .webSocket
            existing.webSocketReadyState = .connecting
            return key
        }

        let networkRequest = NetworkRequest(
            id: key,
            frameID: nil,
            loaderID: nil,
            documentURL: nil,
            request: .init(url: url),
            resourceType: .webSocket,
            originatingTargetID: nil,
            backendResourceIdentifier: nil,
            initiator: nil,
            timestamp: 0,
            walltime: nil
        )
        networkRequest.webSocketReadyState = .connecting
        requestsByID[key] = networkRequest
        orderedRequestIDs.append(key)
        return key
    }

    package func applyWebSocketWillSendHandshakeRequest(
        targetID: ProtocolTargetIdentifier,
        requestID: NetworkRequestIdentifier,
        timestamp: Double,
        walltime: Double,
        request: NetworkWebSocketRequestPayload
    ) {
        let key = NetworkRequest.ID(targetID: targetID, requestID: requestID)
        guard let networkRequest = requestsByID[key] else {
            return
        }
        networkRequest.webSocketHandshakeRequest = request
        networkRequest.request.headers = request.headers
        networkRequest.requestSentTimestamp = timestamp
        networkRequest.requestSentWalltime = walltime
        networkRequest.webSocketReadyState = .connecting
        networkRequest.state = .pending
    }

    package func applyWebSocketHandshakeResponseReceived(
        targetID: ProtocolTargetIdentifier,
        requestID: NetworkRequestIdentifier,
        timestamp: Double,
        response: NetworkWebSocketResponsePayload
    ) {
        let key = NetworkRequest.ID(targetID: targetID, requestID: requestID)
        guard let networkRequest = requestsByID[key] else {
            return
        }
        networkRequest.webSocketHandshakeResponse = response
        networkRequest.response = NetworkResponsePayload(
            url: networkRequest.request.url,
            status: response.status,
            statusText: response.statusText,
            headers: response.headers
        )
        networkRequest.ensureResponseBody()
        networkRequest.responseReceivedTimestamp = timestamp
        networkRequest.webSocketReadyState = .open
        networkRequest.state = .responded
    }

    package func applyWebSocketFrameReceived(
        targetID: ProtocolTargetIdentifier,
        requestID: NetworkRequestIdentifier,
        timestamp: Double,
        response: NetworkWebSocketFramePayload
    ) {
        applyWebSocketFrame(targetID: targetID, requestID: requestID, timestamp: timestamp, response: response, direction: .incoming)
    }

    package func applyWebSocketFrameSent(
        targetID: ProtocolTargetIdentifier,
        requestID: NetworkRequestIdentifier,
        timestamp: Double,
        response: NetworkWebSocketFramePayload
    ) {
        applyWebSocketFrame(targetID: targetID, requestID: requestID, timestamp: timestamp, response: response, direction: .outgoing)
    }

    package func applyWebSocketFrameError(
        targetID: ProtocolTargetIdentifier,
        requestID: NetworkRequestIdentifier,
        timestamp: Double,
        errorMessage: String
    ) {
        guard let request = requestsByID[.init(targetID: targetID, requestID: requestID)] else {
            return
        }
        request.webSocketFrames.append(.init(payload: nil, direction: .error(errorMessage), timestamp: timestamp))
        request.lastDataReceivedTimestamp = timestamp
    }

    package func applyWebSocketClosed(
        targetID: ProtocolTargetIdentifier,
        requestID: NetworkRequestIdentifier,
        timestamp: Double
    ) {
        guard let request = requestsByID[.init(targetID: targetID, requestID: requestID)] else {
            return
        }
        request.webSocketReadyState = .closed
        request.finishedOrFailedTimestamp = timestamp
        request.state = .finished
    }

    package func requestSnapshot(for id: NetworkRequest.ID) -> NetworkRequestSnapshot? {
        requestsByID[id].map(snapshot(for:))
    }

    package func responseBodyCommandIntent(for id: NetworkRequest.ID) -> NetworkCommandIntent? {
        guard let request = requestsByID[id],
              request.responseBody != nil else {
            return nil
        }
        return .getResponseBody(
            requestKey: id,
            backendResourceIdentifier: request.backendResourceIdentifier
        )
    }

    package func serializedCertificateCommandIntent(for id: NetworkRequest.ID) -> NetworkCommandIntent? {
        requestsByID[id].map {
            .getSerializedCertificate(requestKey: id, backendResourceIdentifier: $0.backendResourceIdentifier)
        }
    }

    package func snapshot() -> NetworkSessionSnapshot {
        NetworkSessionSnapshot(
            orderedRequestIDs: orderedRequestIDs,
            requestsByID: Dictionary(uniqueKeysWithValues: requestsByID.map { key, value in
                (key, snapshot(for: value))
            })
        )
    }

    private func snapshot(for request: NetworkRequest) -> NetworkRequestSnapshot {
        NetworkRequestSnapshot(
            id: request.id,
            frameID: request.frameID,
            loaderID: request.loaderID,
            documentURL: request.documentURL,
            resourceType: request.resourceType,
            originatingTargetID: request.originatingTargetID,
            backendResourceIdentifier: request.backendResourceIdentifier,
            initiator: request.initiator,
            request: request.request,
            response: request.response,
            sourceMapURL: request.sourceMapURL,
            metrics: request.metrics,
            cachedResourceBodySize: request.cachedResourceBodySize,
            webSocketHandshakeRequest: request.webSocketHandshakeRequest,
            webSocketHandshakeResponse: request.webSocketHandshakeResponse,
            webSocketReadyState: request.webSocketReadyState,
            webSocketFrames: request.webSocketFrames,
            redirects: request.redirects.map { redirect in
                NetworkRedirectHopSnapshot(
                    id: redirect.id,
                    request: redirect.request,
                    response: redirect.response,
                    timestamp: redirect.timestamp
                )
            },
            requestSentTimestamp: request.requestSentTimestamp,
            requestSentWalltime: request.requestSentWalltime,
            responseReceivedTimestamp: request.responseReceivedTimestamp,
            lastDataReceivedTimestamp: request.lastDataReceivedTimestamp,
            finishedOrFailedTimestamp: request.finishedOrFailedTimestamp,
            encodedDataLength: request.encodedDataLength,
            decodedDataLength: request.decodedDataLength,
            state: request.state
        )
    }

    private func applyWebSocketFrame(
        targetID: ProtocolTargetIdentifier,
        requestID: NetworkRequestIdentifier,
        timestamp: Double,
        response: NetworkWebSocketFramePayload,
        direction: NetworkWebSocketFrameEntry.Direction
    ) {
        guard let request = requestsByID[.init(targetID: targetID, requestID: requestID)] else {
            return
        }
        request.webSocketFrames.append(.init(payload: response, direction: direction, timestamp: timestamp))
        request.decodedDataLength += max(0, response.payloadLength)
        request.lastDataReceivedTimestamp = timestamp
    }
}
