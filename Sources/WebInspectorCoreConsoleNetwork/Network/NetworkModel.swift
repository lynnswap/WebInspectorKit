import WebInspectorCoreDOMCSS
import WebInspectorCoreRuntime
import WebInspectorCoreSupport
import Observation
import WebInspectorTransport

extension NetworkRequest {
    package struct RedirectHop: Equatable, Sendable, Identifiable {
        package var id: NetworkRequest.RedirectHop.ID
        package var request: NetworkRequest.Payload
        package var response: NetworkRequest.Response.Payload
        package var timestamp: Double

        package init(
            id: NetworkRequest.RedirectHop.ID,
            request: NetworkRequest.Payload,
            response: NetworkRequest.Response.Payload,
            timestamp: Double
        ) {
            self.id = id
            self.request = request
            self.response = response
            self.timestamp = timestamp
        }
    }
}

extension NetworkRequest.WebSocket {
    package enum ReadyState: Equatable, Sendable {
        case connecting
        case open
        case closed
    }
}

extension NetworkRequest.WebSocket {
    package struct FrameEntry: Equatable, Sendable {
        package enum Direction: Equatable, Sendable {
            case incoming
            case outgoing
            case error(String)
        }

        package var payload: NetworkRequest.WebSocket.FramePayload?
        package var direction: Direction
        package var timestamp: Double

        package init(payload: NetworkRequest.WebSocket.FramePayload?, direction: Direction, timestamp: Double) {
            self.payload = payload
            self.direction = direction
            self.timestamp = timestamp
        }
    }
}

@MainActor
@Observable
package final class NetworkRequest: Identifiable {
    package let id: ID
    package var frameID: ProtocolFrame.ID?
    package var loaderID: String?
    package var documentURL: String?
    package var resourceType: NetworkRequest.ResourceType?
    package var originatingTargetID: ProtocolTarget.ID?
    package var backendResourceIdentifier: NetworkRequest.BackendResourceID?
    package var initiator: NetworkRequest.Initiator.Payload?
    package var request: NetworkRequest.Payload
    package var requestBody: NetworkBody?
    package var response: NetworkRequest.Response.Payload?
    package var responseBody: NetworkBody?
    package var sourceMapURL: String?
    package var metrics: NetworkRequest.Metrics.Payload?
    package var cachedResourceBodySize: Int?
    package var webSocketHandshakeRequest: NetworkRequest.WebSocket.RequestPayload?
    package var webSocketHandshakeResponse: NetworkRequest.WebSocket.ResponsePayload?
    package var webSocketReadyState: NetworkRequest.WebSocket.ReadyState?
    package var webSocketFrames: [NetworkRequest.WebSocket.FrameEntry]
    package var redirects: [NetworkRequest.RedirectHop]
    package var requestSentTimestamp: Double
    package var requestSentWalltime: Double?
    package var responseReceivedTimestamp: Double?
    package var lastDataReceivedTimestamp: Double?
    package var finishedOrFailedTimestamp: Double?
    package var encodedDataLength: Int
    package var decodedDataLength: Int
    package var state: NetworkRequest.State

    package init(
        id: ID,
        frameID: ProtocolFrame.ID?,
        loaderID: String?,
        documentURL: String?,
        request: NetworkRequest.Payload,
        resourceType: NetworkRequest.ResourceType?,
        originatingTargetID: ProtocolTarget.ID?,
        backendResourceIdentifier: NetworkRequest.BackendResourceID?,
        initiator: NetworkRequest.Initiator.Payload?,
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

    package func applyRedirect(to nextRequest: NetworkRequest.Payload, redirectResponse: NetworkRequest.Response.Payload, timestamp: Double, walltime: Double?) {
        let hopID = NetworkRequest.RedirectHop.ID(requestKey: id, redirectIndex: redirects.count)
        redirects.append(
            NetworkRequest.RedirectHop(
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

    package func applyRequestStart(
        frameID: ProtocolFrame.ID?,
        loaderID: String?,
        documentURL: String?,
        request: NetworkRequest.Payload,
        resourceType: NetworkRequest.ResourceType?,
        originatingTargetID: ProtocolTarget.ID?,
        backendResourceIdentifier: NetworkRequest.BackendResourceID?,
        initiator: NetworkRequest.Initiator.Payload?,
        timestamp: Double,
        walltime: Double?
    ) {
        self.frameID = frameID
        self.loaderID = loaderID
        self.documentURL = documentURL
        self.resourceType = resourceType
        self.originatingTargetID = originatingTargetID
        self.backendResourceIdentifier = backendResourceIdentifier
        self.initiator = initiator
        self.request = request
        requestBody = NetworkBody.makeRequestBody(for: request)
        response = nil
        responseBody = nil
        sourceMapURL = nil
        metrics = nil
        cachedResourceBodySize = nil
        webSocketHandshakeRequest = nil
        webSocketHandshakeResponse = nil
        webSocketReadyState = nil
        webSocketFrames = []
        redirects = []
        requestSentTimestamp = timestamp
        requestSentWalltime = walltime
        responseReceivedTimestamp = nil
        lastDataReceivedTimestamp = nil
        finishedOrFailedTimestamp = nil
        encodedDataLength = 0
        decodedDataLength = 0
        state = .pending
    }

    package func applyMetrics(_ metrics: NetworkRequest.Metrics.Payload) {
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
            var responseSecurity = response?.security ?? NetworkRequest.Security.Payload()
            responseSecurity.connection = securityConnection
            response?.security = responseSecurity
        }
    }

    package func applyResponseBody(_ payload: NetworkBody.Payload) {
        ensureResponseBody()
        responseBody?.apply(payload)
    }

    package var canFetchResponseBody: Bool {
        guard state == .finished else {
            return false
        }
        return responseBody?.needsFetch == true
    }

    package func markResponseBodyFetching() {
        ensureResponseBody()
        responseBody?.markFetching()
    }

    package func markResponseBodyFailed(_ error: NetworkBody.FetchError) {
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

extension NetworkRequest.RedirectHop {
    package struct Snapshot: Equatable, Sendable {
        package var id: NetworkRequest.RedirectHop.ID
        package var request: NetworkRequest.Payload
        package var response: NetworkRequest.Response.Payload
        package var timestamp: Double
    }
}

extension NetworkRequest {
    package struct Snapshot: Equatable, Sendable {
        package var id: NetworkRequest.ID
        package var frameID: ProtocolFrame.ID?
        package var loaderID: String?
        package var documentURL: String?
        package var resourceType: NetworkRequest.ResourceType?
        package var originatingTargetID: ProtocolTarget.ID?
        package var backendResourceIdentifier: NetworkRequest.BackendResourceID?
        package var initiator: NetworkRequest.Initiator.Payload?
        package var request: NetworkRequest.Payload
        package var response: NetworkRequest.Response.Payload?
        package var sourceMapURL: String?
        package var metrics: NetworkRequest.Metrics.Payload?
        package var cachedResourceBodySize: Int?
        package var webSocketHandshakeRequest: NetworkRequest.WebSocket.RequestPayload?
        package var webSocketHandshakeResponse: NetworkRequest.WebSocket.ResponsePayload?
        package var webSocketReadyState: NetworkRequest.WebSocket.ReadyState?
        package var webSocketFrames: [NetworkRequest.WebSocket.FrameEntry]
        package var redirects: [NetworkRequest.RedirectHop.Snapshot]
        package var requestSentTimestamp: Double
        package var requestSentWalltime: Double?
        package var responseReceivedTimestamp: Double?
        package var lastDataReceivedTimestamp: Double?
        package var finishedOrFailedTimestamp: Double?
        package var encodedDataLength: Int
        package var decodedDataLength: Int
        package var state: NetworkRequest.State
    }
}

extension NetworkSession {
    package struct Snapshot: Equatable, Sendable {
        package var orderedRequestIDs: [NetworkRequest.ID]
        package var requestsByID: [NetworkRequest.ID: NetworkRequest.Snapshot]
    }
}

@MainActor
private extension NetworkRequest.RedirectHop {
    var snapshot: NetworkRequest.RedirectHop.Snapshot {
        NetworkRequest.RedirectHop.Snapshot(
            id: id,
            request: request,
            response: response,
            timestamp: timestamp
        )
    }
}

@MainActor
private extension NetworkRequest {
    var snapshot: NetworkRequest.Snapshot {
        NetworkRequest.Snapshot(
            id: id,
            frameID: frameID,
            loaderID: loaderID,
            documentURL: documentURL,
            resourceType: resourceType,
            originatingTargetID: originatingTargetID,
            backendResourceIdentifier: backendResourceIdentifier,
            initiator: initiator,
            request: request,
            response: response,
            sourceMapURL: sourceMapURL,
            metrics: metrics,
            cachedResourceBodySize: cachedResourceBodySize,
            webSocketHandshakeRequest: webSocketHandshakeRequest,
            webSocketHandshakeResponse: webSocketHandshakeResponse,
            webSocketReadyState: webSocketReadyState,
            webSocketFrames: webSocketFrames,
            redirects: redirects.map(\.snapshot),
            requestSentTimestamp: requestSentTimestamp,
            requestSentWalltime: requestSentWalltime,
            responseReceivedTimestamp: responseReceivedTimestamp,
            lastDataReceivedTimestamp: lastDataReceivedTimestamp,
            finishedOrFailedTimestamp: finishedOrFailedTimestamp,
            encodedDataLength: encodedDataLength,
            decodedDataLength: decodedDataLength,
            state: state
        )
    }
}

@MainActor
private struct NetworkRequestStore {
    private var orderedIDs: [NetworkRequest.ID]
    private var requestsByIdentifier: [NetworkRequest.ID: NetworkRequest]
    private var activeRequestIDs: Set<NetworkRequest.ID>

    init() {
        orderedIDs = []
        requestsByIdentifier = [:]
        activeRequestIDs = []
    }

    var orderedRequestIDs: [NetworkRequest.ID] {
        orderedIDs
    }

    var requests: [NetworkRequest] {
        orderedIDs.compactMap { requestsByIdentifier[$0] }
    }

    func request(for id: NetworkRequest.ID) -> NetworkRequest? {
        requestsByIdentifier[id]
    }

    mutating func removeAll() {
        orderedIDs.removeAll()
        requestsByIdentifier.removeAll()
        activeRequestIDs.removeAll()
    }

    @discardableResult
    mutating func insert(_ request: NetworkRequest) -> NetworkRequest {
        if let existing = requestsByIdentifier[request.id] {
            return existing
        }
        requestsByIdentifier[request.id] = request
        orderedIDs.append(request.id)
        return request
    }

    mutating func markActive(_ id: NetworkRequest.ID) {
        activeRequestIDs.insert(id)
    }

    mutating func closeActive(_ id: NetworkRequest.ID) {
        activeRequestIDs.remove(id)
    }

    mutating func closeActiveRequests(targetID: ProtocolTarget.ID) {
        activeRequestIDs = activeRequestIDs.filter { $0.targetID != targetID }
    }

    func isActive(_ id: NetworkRequest.ID) -> Bool {
        activeRequestIDs.contains(id)
    }

    mutating func requestOrInsert(
        id: NetworkRequest.ID,
        makeRequest: () -> NetworkRequest
    ) -> NetworkRequest {
        if let existing = requestsByIdentifier[id] {
            return existing
        }
        let request = makeRequest()
        precondition(request.id == id, "NetworkRequestStore inserted a request with a mismatched id.")
        requestsByIdentifier[id] = request
        orderedIDs.append(id)
        return request
    }

    func snapshot() -> NetworkSession.Snapshot {
        NetworkSession.Snapshot(
            orderedRequestIDs: orderedIDs,
            requestsByID: Dictionary(
                uniqueKeysWithValues: orderedIDs.compactMap { id in
                    requestsByIdentifier[id].map { (id, $0.snapshot) }
                }
            )
        )
    }
}

@MainActor
@Observable
package final class NetworkSession {
    private var requestStore: NetworkRequestStore
    package private(set) var requestTopologyRevision: Int
    package private(set) var requestContentRevision: Int
    package private(set) var requestDisplayRevision: Int
    @ObservationIgnored private var commandChannel: ProtocolCommandChannel?
    @ObservationIgnored private let protocolCommands: NetworkProtocolCommands
    @ObservationIgnored private var recordError: ((InspectorError?) -> Void)?

    package init() {
        requestStore = NetworkRequestStore()
        requestTopologyRevision = 0
        requestContentRevision = 0
        requestDisplayRevision = 0
        commandChannel = nil
        protocolCommands = NetworkProtocolCommands()
        recordError = nil
    }

    package var orderedRequestIDs: [NetworkRequest.ID] {
        requestStore.orderedRequestIDs
    }

    package var requests: [NetworkRequest] {
        requestStore.requests
    }

    package func request(for id: NetworkRequest.ID) -> NetworkRequest? {
        requestStore.request(for: id)
    }

    package func reset() {
        requestStore.removeAll()
        recordRequestTopologyChange()
    }

    package func bindProtocolChannel(
        _ commandChannel: ProtocolCommandChannel,
        recordError: @escaping (InspectorError?) -> Void
    ) {
        self.commandChannel = commandChannel
        self.recordError = recordError
    }

    package func unbindProtocolChannel() {
        commandChannel = nil
        recordError = nil
    }

    @discardableResult
    package func perform(_ intent: NetworkCommand.Intent) async throws -> ProtocolCommand.Result {
        let commandChannel = try requireCommandChannel()
        return try await commandChannel.send(protocolCommands.command(for: intent))
    }

    package func fetchResponseBody(for id: NetworkRequest.ID) async {
        guard let request = request(for: id) else {
            return
        }
        guard request.canFetchResponseBody else {
            return
        }
        guard let intent = responseBodyCommandIntent(for: id) else {
            request.markResponseBodyFailed(.unavailable)
            return
        }
        guard let expectedBody = request.responseBody else {
            request.markResponseBodyFailed(.unavailable)
            return
        }

        request.markResponseBodyFetching()
        do {
            let result = try await perform(intent)
            let payload = try await protocolCommands.responseBodyPayload(from: result)
            guard let currentRequest = self.request(for: id),
                  currentRequest.responseBody === expectedBody else {
                return
            }
            protocolCommands.applyResponseBodyPayload(payload, to: currentRequest)
        } catch {
            guard let currentRequest = self.request(for: id),
                  currentRequest.responseBody === expectedBody else {
                return
            }
            currentRequest.markResponseBodyFailed(.unknown(String(describing: error)))
            recordError?(InspectorError(String(describing: error)))
        }
    }

    @discardableResult
    package func applyRequestWillBeSent(
        targetID: ProtocolTarget.ID,
        requestID: NetworkRequest.ProtocolID,
        frameID: ProtocolFrame.ID?,
        loaderID: String?,
        documentURL: String?,
        request: NetworkRequest.Payload,
        resourceType: NetworkRequest.ResourceType? = nil,
        originatingTargetID: ProtocolTarget.ID? = nil,
        backendResourceIdentifier: NetworkRequest.BackendResourceID? = nil,
        initiator: NetworkRequest.Initiator.Payload? = nil,
        redirectResponse: NetworkRequest.Response.Payload? = nil,
        timestamp: Double,
        walltime: Double? = nil
    ) -> NetworkRequest.ID {
        let key = NetworkRequest.ID(targetID: targetID, requestID: requestID)

        if let existing = requestStore.request(for: key) {
            let isActive = requestStore.isActive(key)
            if let redirectResponse,
               isActive {
                existing.frameID = frameID ?? existing.frameID
                existing.loaderID = loaderID ?? existing.loaderID
                existing.documentURL = documentURL ?? existing.documentURL
                existing.resourceType = resourceType ?? existing.resourceType
                existing.originatingTargetID = originatingTargetID ?? existing.originatingTargetID
                existing.backendResourceIdentifier = backendResourceIdentifier ?? existing.backendResourceIdentifier
                existing.initiator = initiator ?? existing.initiator
                existing.applyRedirect(to: request, redirectResponse: redirectResponse, timestamp: timestamp, walltime: walltime)
            } else if !isActive {
                existing.applyRequestStart(
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
            } else {
                existing.backendResourceIdentifier = backendResourceIdentifier ?? existing.backendResourceIdentifier
            }
            requestStore.markActive(key)
            recordRequestDisplayChange()
            return key
        }

        requestStore.insert(
            NetworkRequest(
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
        )
        requestStore.markActive(key)
        recordRequestTopologyChange()
        return key
    }

    package func applyResponseReceived(
        targetID: ProtocolTarget.ID,
        requestID: NetworkRequest.ProtocolID,
        frameID: ProtocolFrame.ID? = nil,
        loaderID: String? = nil,
        resourceType: NetworkRequest.ResourceType? = nil,
        response: NetworkRequest.Response.Payload,
        timestamp: Double
    ) {
        guard let request = requestStore.request(for: .init(targetID: targetID, requestID: requestID)) else {
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
        recordRequestDisplayChange()
    }

    package func applyDataReceived(
        targetID: ProtocolTarget.ID,
        requestID: NetworkRequest.ProtocolID,
        dataLength: Int,
        encodedDataLength: Int,
        timestamp: Double
    ) {
        guard let request = requestStore.request(for: .init(targetID: targetID, requestID: requestID)) else {
            return
        }
        request.decodedDataLength += max(0, dataLength)
        request.encodedDataLength += max(0, encodedDataLength)
        request.lastDataReceivedTimestamp = timestamp
        recordRequestContentChange()
    }

    package func applyLoadingFinished(
        targetID: ProtocolTarget.ID,
        requestID: NetworkRequest.ProtocolID,
        timestamp: Double,
        sourceMapURL: String? = nil,
        metrics: NetworkRequest.Metrics.Payload? = nil
    ) {
        guard let request = requestStore.request(for: .init(targetID: targetID, requestID: requestID)) else {
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
        requestStore.closeActive(.init(targetID: targetID, requestID: requestID))
        recordRequestContentChange()
    }

    package func applyLoadingFailed(
        targetID: ProtocolTarget.ID,
        requestID: NetworkRequest.ProtocolID,
        timestamp: Double,
        errorText: String,
        canceled: Bool = false
    ) {
        guard let request = requestStore.request(for: .init(targetID: targetID, requestID: requestID)) else {
            return
        }
        request.finishedOrFailedTimestamp = timestamp
        request.state = .failed(errorText: errorText, canceled: canceled)
        requestStore.closeActive(.init(targetID: targetID, requestID: requestID))
        recordRequestContentChange()
    }

    @discardableResult
    package func applyRequestServedFromMemoryCache(
        targetID: ProtocolTarget.ID,
        requestID: NetworkRequest.ProtocolID,
        frameID: ProtocolFrame.ID,
        loaderID: String,
        documentURL: String,
        timestamp: Double,
        initiator: NetworkRequest.Initiator.Payload?,
        resource: NetworkRequest.CachedResource.Payload
    ) -> NetworkRequest.ID {
        let key = NetworkRequest.ID(targetID: targetID, requestID: requestID)
        let didExist = requestStore.request(for: key) != nil
        let networkRequest = requestStore.requestOrInsert(id: key) {
            NetworkRequest(
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
        }

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
        if didExist {
            recordRequestDisplayChange()
        } else {
            recordRequestTopologyChange()
        }
        return key
    }

    @discardableResult
    package func applyWebSocketCreated(
        targetID: ProtocolTarget.ID,
        requestID: NetworkRequest.ProtocolID,
        url: String
    ) -> NetworkRequest.ID {
        let key = NetworkRequest.ID(targetID: targetID, requestID: requestID)
        if let existing = requestStore.request(for: key) {
            existing.request.url = url
            existing.resourceType = .webSocket
            existing.webSocketReadyState = .connecting
            recordRequestDisplayChange()
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
        requestStore.insert(networkRequest)
        requestStore.markActive(key)
        recordRequestTopologyChange()
        return key
    }

    package func applyWebSocketWillSendHandshakeRequest(
        targetID: ProtocolTarget.ID,
        requestID: NetworkRequest.ProtocolID,
        timestamp: Double,
        walltime: Double,
        request: NetworkRequest.WebSocket.RequestPayload
    ) {
        let key = NetworkRequest.ID(targetID: targetID, requestID: requestID)
        guard let networkRequest = requestStore.request(for: key) else {
            return
        }
        networkRequest.webSocketHandshakeRequest = request
        networkRequest.request.headers = request.headers
        networkRequest.requestSentTimestamp = timestamp
        networkRequest.requestSentWalltime = walltime
        networkRequest.webSocketReadyState = .connecting
        networkRequest.state = .pending
        recordRequestContentChange()
    }

    package func applyWebSocketHandshakeResponseReceived(
        targetID: ProtocolTarget.ID,
        requestID: NetworkRequest.ProtocolID,
        timestamp: Double,
        response: NetworkRequest.WebSocket.ResponsePayload
    ) {
        let key = NetworkRequest.ID(targetID: targetID, requestID: requestID)
        guard let networkRequest = requestStore.request(for: key) else {
            return
        }
        networkRequest.webSocketHandshakeResponse = response
        networkRequest.response = NetworkRequest.Response.Payload(
            url: networkRequest.request.url,
            status: response.status,
            statusText: response.statusText,
            headers: response.headers
        )
        networkRequest.ensureResponseBody()
        networkRequest.responseReceivedTimestamp = timestamp
        networkRequest.webSocketReadyState = .open
        networkRequest.state = .responded
        recordRequestDisplayChange()
    }

    package func applyWebSocketFrameReceived(
        targetID: ProtocolTarget.ID,
        requestID: NetworkRequest.ProtocolID,
        timestamp: Double,
        response: NetworkRequest.WebSocket.FramePayload
    ) {
        applyWebSocketFrame(targetID: targetID, requestID: requestID, timestamp: timestamp, response: response, direction: .incoming)
    }

    package func applyWebSocketFrameSent(
        targetID: ProtocolTarget.ID,
        requestID: NetworkRequest.ProtocolID,
        timestamp: Double,
        response: NetworkRequest.WebSocket.FramePayload
    ) {
        applyWebSocketFrame(targetID: targetID, requestID: requestID, timestamp: timestamp, response: response, direction: .outgoing)
    }

    package func applyWebSocketFrameError(
        targetID: ProtocolTarget.ID,
        requestID: NetworkRequest.ProtocolID,
        timestamp: Double,
        errorMessage: String
    ) {
        guard let request = requestStore.request(for: .init(targetID: targetID, requestID: requestID)) else {
            return
        }
        request.webSocketFrames.append(.init(payload: nil, direction: .error(errorMessage), timestamp: timestamp))
        request.lastDataReceivedTimestamp = timestamp
        recordRequestContentChange()
    }

    package func applyWebSocketClosed(
        targetID: ProtocolTarget.ID,
        requestID: NetworkRequest.ProtocolID,
        timestamp: Double
    ) {
        guard let request = requestStore.request(for: .init(targetID: targetID, requestID: requestID)) else {
            return
        }
        request.webSocketReadyState = .closed
        request.finishedOrFailedTimestamp = timestamp
        request.state = .finished
        requestStore.closeActive(.init(targetID: targetID, requestID: requestID))
        recordRequestContentChange()
    }

    package func applyTargetDestroyed(_ targetID: ProtocolTarget.ID) {
        requestStore.closeActiveRequests(targetID: targetID)
    }

    package func requestSnapshot(for id: NetworkRequest.ID) -> NetworkRequest.Snapshot? {
        requestStore.request(for: id)?.snapshot
    }

    package func responseBodyCommandIntent(for id: NetworkRequest.ID) -> NetworkCommand.Intent? {
        guard let request = requestStore.request(for: id),
              request.canFetchResponseBody else {
            return nil
        }
        return .getResponseBody(
            requestKey: id,
            backendResourceIdentifier: request.backendResourceIdentifier
        )
    }

    package func serializedCertificateCommandIntent(for id: NetworkRequest.ID) -> NetworkCommand.Intent? {
        requestStore.request(for: id).map {
            .getSerializedCertificate(requestKey: id, backendResourceIdentifier: $0.backendResourceIdentifier)
        }
    }

    package func snapshot() -> NetworkSession.Snapshot {
        requestStore.snapshot()
    }

    private func applyWebSocketFrame(
        targetID: ProtocolTarget.ID,
        requestID: NetworkRequest.ProtocolID,
        timestamp: Double,
        response: NetworkRequest.WebSocket.FramePayload,
        direction: NetworkRequest.WebSocket.FrameEntry.Direction
    ) {
        guard let request = requestStore.request(for: .init(targetID: targetID, requestID: requestID)) else {
            return
        }
        request.webSocketFrames.append(.init(payload: response, direction: direction, timestamp: timestamp))
        request.decodedDataLength += max(0, response.payloadLength)
        request.lastDataReceivedTimestamp = timestamp
        recordRequestContentChange()
    }

    private func requireCommandChannel() throws -> ProtocolCommandChannel {
        guard let commandChannel else {
            throw InspectorError("Inspector session is not attached.")
        }
        try commandChannel.requireAttached()
        return commandChannel
    }

    private func recordRequestTopologyChange() {
        requestTopologyRevision &+= 1
        recordRequestDisplayChange()
    }

    private func recordRequestDisplayChange() {
        requestDisplayRevision &+= 1
        recordRequestContentChange()
    }

    private func recordRequestContentChange() {
        requestContentRevision &+= 1
    }
}
