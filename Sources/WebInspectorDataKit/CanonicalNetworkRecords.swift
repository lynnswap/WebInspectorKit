import Foundation
import WebInspectorProxyKit

package struct CanonicalNetworkBackendResourceIdentifier: Equatable, Sendable {
    package let sourceProcessID: String
    package let resourceID: String

    package init(_ identifier: Network.BackendResourceID) {
        sourceProcessID = identifier.sourceProcessID
        resourceID = identifier.resourceID
    }
}

/// Immutable normalized storage for every field in `Network.Request`.
package struct CanonicalNetworkRequestPayload: Equatable, Sendable {
    package let rawID: Network.Request.ID
    package var url: String
    package let method: String
    package var headers: [String: String]
    package let postData: String?
    package let referrerPolicy: String?
    package let integrity: String?
    package let backendResourceIdentifier: CanonicalNetworkBackendResourceIdentifier?

    package init(_ request: Network.Request) {
        rawID = request.id
        url = request.url
        method = request.method
        headers = request.headers
        postData = request.postData
        referrerPolicy = request.referrerPolicy?.rawValue
        integrity = request.integrity
        backendResourceIdentifier = request.backendResourceIdentifier.map(
            CanonicalNetworkBackendResourceIdentifier.init
        )
    }

    package init(
        rawID: Network.Request.ID,
        url: String,
        method: String,
        headers: [String: String] = [:]
    ) {
        self.rawID = rawID
        self.url = url
        self.method = method
        self.headers = headers
        postData = nil
        referrerPolicy = nil
        integrity = nil
        backendResourceIdentifier = nil
    }
}

/// Immutable normalized storage for every field in `Network.Response`.
package struct CanonicalNetworkResponsePayload: Equatable, Sendable {
    package let url: String?
    package let status: Int?
    package let statusText: String?
    package let mimeType: String?
    package let headers: [String: String]
    package let source: String?
    package let requestHeaders: [String: String]?
    package let bodySize: Int?

    package init(_ response: Network.Response) {
        url = response.url
        status = response.status
        statusText = response.statusText
        mimeType = response.mimeType
        headers = response.headers
        source = response.source?.rawValue
        requestHeaders = response.requestHeaders
        bodySize = response.bodySize
    }

    /// WebKit compares the parsed MIME type exactly with
    /// `multipart/x-mixed-replace`; only ASCII case is semantically
    /// insignificant at this protocol boundary.
    package var isMultipartMixedReplace: Bool {
        guard let mimeType else {
            return false
        }
        return mimeType.utf8.elementsEqual(
            "multipart/x-mixed-replace".utf8,
            by: { lhs, rhs in
                let folded = lhs >= 65 && lhs <= 90 ? lhs + 32 : lhs
                return folded == rhs
            }
        )
    }
}

package struct CanonicalNetworkMetrics: Equatable, Sendable {
    package let timestamp: Double?
    package let networkProtocol: String?
    package let remoteAddress: String?
    package let encodedDataLength: Int?
    package let decodedBodyLength: Int?

    package init(_ metrics: Network.Metrics) {
        timestamp = metrics.timestamp
        networkProtocol = metrics.networkProtocol
        remoteAddress = metrics.remoteAddress
        encodedDataLength = metrics.encodedDataLength
        decodedBodyLength = metrics.decodedBodyLength
    }
}

package struct CanonicalNetworkInitiator: Equatable, Sendable {
    package let kind: String
    package let url: String?
    package let line: Int?
    package let column: Int?
    package let rawNodeID: DOM.Node.ID?

    package init(_ initiator: Network.Initiator) {
        kind = initiator.kind
        url = initiator.url
        line = initiator.line
        column = initiator.column
        rawNodeID = initiator.nodeID
    }
}

package struct CanonicalNetworkTransfer: Equatable, Sendable {
    package var decodedDataLength: Int
    package var encodedDataLength: Int
    package var lastDataReceivedTimestamp: Double?

    package init(
        decodedDataLength: Int = 0,
        encodedDataLength: Int = 0,
        lastDataReceivedTimestamp: Double? = nil
    ) {
        self.decodedDataLength = decodedDataLength
        self.encodedDataLength = encodedDataLength
        self.lastDataReceivedTimestamp = lastDataReceivedTimestamp
    }
}

package struct CanonicalNetworkCurrentHop: Equatable, Sendable {
    package var request: CanonicalNetworkRequestPayload
    package var resourceType: String?
    package var requestSentTimestamp: Double?
    package var response: CanonicalNetworkResponsePayload?
    package var responseReceivedTimestamp: Double?
    package var transfer: CanonicalNetworkTransfer
    package var sourceMapURL: String?
    package var metrics: CanonicalNetworkMetrics?
    package var terminalTimestamp: Double?
    package var servedFromMemoryCache: Bool

    package init(
        request: CanonicalNetworkRequestPayload,
        resourceType: String?,
        requestSentTimestamp: Double?,
        response: CanonicalNetworkResponsePayload? = nil,
        responseReceivedTimestamp: Double? = nil,
        transfer: CanonicalNetworkTransfer = .init(),
        sourceMapURL: String? = nil,
        metrics: CanonicalNetworkMetrics? = nil,
        terminalTimestamp: Double? = nil,
        servedFromMemoryCache: Bool = false
    ) {
        self.request = request
        self.resourceType = resourceType
        self.requestSentTimestamp = requestSentTimestamp
        self.response = response
        self.responseReceivedTimestamp = responseReceivedTimestamp
        self.transfer = transfer
        self.sourceMapURL = sourceMapURL
        self.metrics = metrics
        self.terminalTimestamp = terminalTimestamp
        self.servedFromMemoryCache = servedFromMemoryCache
    }
}

package struct CanonicalNetworkRedirectHop: Equatable, Sendable {
    package let request: CanonicalNetworkRequestPayload
    package let response: CanonicalNetworkResponsePayload
    package let resourceType: String?
    package let requestSentTimestamp: Double?
    package let responseReceivedTimestamp: Double?
    package let lastDataReceivedTimestamp: Double?
    package let decodedDataLength: Int
    package let encodedDataLength: Int
    package let redirectTimestamp: Double

    package init(
        currentHop: CanonicalNetworkCurrentHop,
        response: CanonicalNetworkResponsePayload,
        redirectTimestamp: Double
    ) {
        request = currentHop.request
        self.response = response
        resourceType = currentHop.resourceType
        requestSentTimestamp = currentHop.requestSentTimestamp
        responseReceivedTimestamp = currentHop.responseReceivedTimestamp
        lastDataReceivedTimestamp = currentHop.transfer.lastDataReceivedTimestamp
        decodedDataLength = currentHop.transfer.decodedDataLength
        encodedDataLength = currentHop.transfer.encodedDataLength
        self.redirectTimestamp = redirectTimestamp
    }
}

package enum CanonicalNetworkLifecycle: Equatable, Sendable {
    case pending
    case responded
    case finished
    case failed(errorText: String, canceled: Bool)

    package var isTerminal: Bool {
        switch self {
        case .pending, .responded:
            false
        case .finished, .failed:
            true
        }
    }
}

package enum CanonicalNetworkWebSocketReadyState: Equatable, Sendable {
    case connecting
    case open
    case closed
}

package struct CanonicalNetworkWebSocketHandshakeRequest: Equatable, Sendable {
    package let request: CanonicalNetworkRequestPayload
    package let timestamp: Double?
}

package struct CanonicalNetworkWebSocketHandshakeResponse: Equatable, Sendable {
    package let response: CanonicalNetworkResponsePayload
    package let timestamp: Double?
}

package enum CanonicalNetworkWebSocketContent: Equatable, Sendable {
    case frame(
        direction: Direction,
        opcode: Int,
        mask: Bool,
        payloadData: String,
        payloadLength: Int,
        timestamp: Double
    )
    case error(message: String, timestamp: Double)

    package enum Direction: Equatable, Sendable {
        case sent
        case received
    }
}

package struct CanonicalNetworkWebSocketRecord: Equatable, Sendable {
    package var creationURL: String
    package var readyState: CanonicalNetworkWebSocketReadyState
    package var handshakeRequest: CanonicalNetworkWebSocketHandshakeRequest?
    package var handshakeResponse: CanonicalNetworkWebSocketHandshakeResponse?
    package var contents: [CanonicalNetworkWebSocketContent]
    package var closedTimestamp: Double?

    package init(creationURL: String) {
        self.creationURL = creationURL
        readyState = .connecting
        handshakeRequest = nil
        handshakeResponse = nil
        contents = []
        closedTimestamp = nil
    }
}

/// Complete pure-value semantic state for one Network request.
package struct CanonicalNetworkRequestRecord: Equatable, Sendable {
    package let id: CanonicalNetworkRequestIDStorage
    package let insertionOrdinal: UInt64
    package let initialInitiator: CanonicalNetworkInitiator?
    package var logicalStartTimestamp: Double?
    package var currentHop: CanonicalNetworkCurrentHop
    package var redirects: [CanonicalNetworkRedirectHop]
    package var lifecycle: CanonicalNetworkLifecycle
    package var allowsMultipartContinuation: Bool
    package var webSocket: CanonicalNetworkWebSocketRecord?
    package var responseBodyRevision: UInt64

    package init(
        id: CanonicalNetworkRequestIDStorage,
        insertionOrdinal: UInt64,
        initialInitiator: CanonicalNetworkInitiator?,
        logicalStartTimestamp: Double?,
        currentHop: CanonicalNetworkCurrentHop,
        redirects: [CanonicalNetworkRedirectHop] = [],
        lifecycle: CanonicalNetworkLifecycle = .pending,
        allowsMultipartContinuation: Bool = false,
        webSocket: CanonicalNetworkWebSocketRecord? = nil,
        responseBodyRevision: UInt64 = 0
    ) {
        self.id = id
        self.insertionOrdinal = insertionOrdinal
        self.initialInitiator = initialInitiator
        self.logicalStartTimestamp = logicalStartTimestamp
        self.currentHop = currentHop
        self.redirects = redirects
        self.lifecycle = lifecycle
        self.allowsMultipartContinuation = allowsMultipartContinuation
        self.webSocket = webSocket
        self.responseBodyRevision = responseBodyRevision
    }
}

package enum CanonicalNetworkResourceCategory: String, Hashable, Sendable {
    case document
    case stylesheet
    case script
    case image
    case font
    case xhrFetch
    case media
    case webSocket
    case other
}

package struct CanonicalNetworkChronologyKey: Equatable, Comparable, Sendable {
    package let timestamp: Double?
    package let insertionOrdinal: UInt64

    package static func < (
        lhs: CanonicalNetworkChronologyKey,
        rhs: CanonicalNetworkChronologyKey
    ) -> Bool {
        switch (lhs.timestamp, rhs.timestamp) {
        case let (lhsTimestamp?, rhsTimestamp?) where lhsTimestamp != rhsTimestamp:
            return lhsTimestamp < rhsTimestamp
        case (nil, _?):
            return true
        case (_?, nil):
            return false
        default:
            return lhs.insertionOrdinal < rhs.insertionOrdinal
        }
    }
}

package struct CanonicalNetworkRequestQueryProjection: Equatable, Sendable {
    package let id: CanonicalNetworkRequestIDStorage
    package let insertionOrdinal: UInt64
    package let chronology: CanonicalNetworkChronologyKey
    package let url: String
    package let method: String
    package let resourceType: String?
    package let mimeType: String?
    package let resourceCategory: CanonicalNetworkResourceCategory
    package let searchableText: String
    package let statusCode: Int?
    package let groupKey: CanonicalNetworkGroupKey
}

package enum CanonicalNetworkEntryLifecycleSummary: Equatable, Sendable {
    case loading
    case finished
    case failed
}

package struct CanonicalNetworkEntrySummary: Equatable, Sendable {
    package let primaryRequestID: CanonicalNetworkRequestIDStorage
    package let requestCount: Int
    package let url: String
    package let method: String
    package let statusCode: Int?
    package let decodedDataLength: Int
    package let encodedDataLength: Int
    package let lifecycle: CanonicalNetworkEntryLifecycleSummary
}

package struct CanonicalNetworkEntryQueryProjection: Equatable, Sendable {
    package let id: CanonicalNetworkEntryIDStorage
    package let chronology: CanonicalNetworkChronologyKey
    package let resourceCategories: Set<CanonicalNetworkResourceCategory>
    package let searchTexts: [String]
}

package struct CanonicalNetworkEntryRecord: Equatable, Sendable {
    package let id: CanonicalNetworkEntryIDStorage
    package let groupKey: CanonicalNetworkGroupKey
    package var requestIDs: [CanonicalNetworkRequestIDStorage]
    package var summary: CanonicalNetworkEntrySummary
}

/// Authority captured before issuing a response-body command.
package struct CanonicalNetworkResponseBodyLease: Hashable, Sendable {
    package let requestID: CanonicalNetworkRequestIDStorage
    package let responseRevision: UInt64

    package init(
        requestID: CanonicalNetworkRequestIDStorage,
        responseRevision: UInt64
    ) {
        self.requestID = requestID
        self.responseRevision = responseRevision
    }
}

/// An authoritative update that a context projection can apply without
/// repeating protocol semantics.
package enum CanonicalNetworkRequestPatch: Equatable, Sendable {
    case redirect(
        appendedHop: CanonicalNetworkRedirectHop,
        currentHop: CanonicalNetworkCurrentHop,
        lifecycle: CanonicalNetworkLifecycle,
        allowsMultipartContinuation: Bool,
        responseBodyRevision: UInt64
    )
    case response(
        currentHop: CanonicalNetworkCurrentHop,
        lifecycle: CanonicalNetworkLifecycle,
        allowsMultipartContinuation: Bool,
        responseBodyRevision: UInt64
    )
    case transfer(
        transfer: CanonicalNetworkTransfer,
        lifecycle: CanonicalNetworkLifecycle
    )
    case terminal(
        currentHop: CanonicalNetworkCurrentHop,
        lifecycle: CanonicalNetworkLifecycle
    )
    case webSocketHandshakeResponse(
        handshake: CanonicalNetworkWebSocketHandshakeResponse,
        response: CanonicalNetworkResponsePayload,
        responseReceivedTimestamp: Double?,
        readyState: CanonicalNetworkWebSocketReadyState,
        lifecycle: CanonicalNetworkLifecycle,
        responseBodyRevision: UInt64
    )
    case webSocketContentAppended(
        content: CanonicalNetworkWebSocketContent,
        transfer: CanonicalNetworkTransfer
    )
    case webSocketClosed(
        timestamp: Double,
        lifecycle: CanonicalNetworkLifecycle
    )
}

package extension CanonicalNetworkRequestRecord {
    mutating func apply(_ patch: CanonicalNetworkRequestPatch) {
        switch patch {
        case let .redirect(
            appendedHop,
            currentHop,
            lifecycle,
            allowsMultipartContinuation,
            responseBodyRevision
        ):
            redirects.append(appendedHop)
            self.currentHop = currentHop
            self.lifecycle = lifecycle
            self.allowsMultipartContinuation = allowsMultipartContinuation
            self.responseBodyRevision = responseBodyRevision
        case let .response(
            currentHop,
            lifecycle,
            allowsMultipartContinuation,
            responseBodyRevision
        ):
            self.currentHop = currentHop
            self.lifecycle = lifecycle
            self.allowsMultipartContinuation = allowsMultipartContinuation
            self.responseBodyRevision = responseBodyRevision
        case let .transfer(transfer, lifecycle):
            currentHop.transfer = transfer
            self.lifecycle = lifecycle
        case let .terminal(currentHop, lifecycle):
            self.currentHop = currentHop
            self.lifecycle = lifecycle
        case let .webSocketHandshakeResponse(
            handshake,
            response,
            responseReceivedTimestamp,
            readyState,
            lifecycle,
            responseBodyRevision
        ):
            precondition(webSocket != nil)
            webSocket?.handshakeResponse = handshake
            webSocket?.readyState = readyState
            currentHop.resourceType = Network.ResourceType.webSocket.rawValue
            currentHop.response = response
            currentHop.responseReceivedTimestamp = responseReceivedTimestamp
            self.lifecycle = lifecycle
            self.responseBodyRevision = responseBodyRevision
        case let .webSocketContentAppended(content, transfer):
            precondition(webSocket != nil)
            webSocket?.contents.append(content)
            currentHop.transfer = transfer
        case let .webSocketClosed(timestamp, lifecycle):
            precondition(webSocket != nil)
            webSocket?.readyState = .closed
            webSocket?.closedTimestamp = timestamp
            currentHop.terminalTimestamp = timestamp
            self.lifecycle = lifecycle
        }
    }
}

package enum CanonicalNetworkRequestChange: Equatable, Sendable {
    case insert(
        record: CanonicalNetworkRequestRecord,
        query: CanonicalNetworkRequestQueryProjection
    )
    case update(
        id: CanonicalNetworkRequestIDStorage,
        patch: CanonicalNetworkRequestPatch,
        query: CanonicalNetworkRequestQueryProjection?
    )
    case delete(CanonicalNetworkRequestIDStorage)
}

package struct CanonicalNetworkEntryPatch: Equatable, Sendable {
    package let requestIDs: [CanonicalNetworkRequestIDStorage]
    package let summary: CanonicalNetworkEntrySummary
}

package enum CanonicalNetworkEntryChange: Equatable, Sendable {
    case insert(
        record: CanonicalNetworkEntryRecord,
        query: CanonicalNetworkEntryQueryProjection
    )
    case update(
        id: CanonicalNetworkEntryIDStorage,
        patch: CanonicalNetworkEntryPatch,
        query: CanonicalNetworkEntryQueryProjection?
    )
    case delete(CanonicalNetworkEntryIDStorage)
}

package struct CanonicalNetworkTransaction: Equatable, Sendable {
    package let requestChanges: [CanonicalNetworkRequestChange]
    package let entryChanges: [CanonicalNetworkEntryChange]

    package init(
        requestChanges: [CanonicalNetworkRequestChange],
        entryChanges: [CanonicalNetworkEntryChange]
    ) {
        self.requestChanges = requestChanges
        self.entryChanges = entryChanges
    }
}

package struct CanonicalNetworkRequestSnapshotEntry: Equatable, Sendable {
    package let record: CanonicalNetworkRequestRecord
    package let query: CanonicalNetworkRequestQueryProjection
}

package struct CanonicalNetworkEntrySnapshotEntry: Equatable, Sendable {
    package let record: CanonicalNetworkEntryRecord
    package let query: CanonicalNetworkEntryQueryProjection
}

/// Complete owner-atomic Network state used only for initial/reset
/// publication. Incremental transactions never carry this full projection.
package struct CanonicalNetworkSnapshot: Equatable, Sendable {
    package let requests: [CanonicalNetworkRequestSnapshotEntry]
    package let entries: [CanonicalNetworkEntrySnapshotEntry]
}
