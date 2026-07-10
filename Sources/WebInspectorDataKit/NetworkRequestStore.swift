import Foundation
import WebInspectorProxyKit

/// Owns Network request identity, order, query projection, and publication.
///
/// `WebInspectorModelContext` remains the attachment and transport coordinator. The
/// model context confines access to the store, which never retains an actor token
/// or starts transport work.
package final class NetworkRequestStore {
    package struct IndexWork: Sendable {
        fileprivate enum Action: Sendable {
            case replace(
                inputs: [NetworkRequestRecordInput],
                sequence: UInt64,
                sourceEpoch: UInt64
            )
            case upsert(input: NetworkRequestRecordInput, sequence: UInt64)
        }

        fileprivate let index: NetworkRequestIndex
        fileprivate let actions: [Action]

        package nonisolated(nonsending) func run() async -> IndexResult {
            var deliveries: [NetworkRequestIndex.QueryDelivery] = []
            for action in actions {
                switch action {
                case let .replace(inputs, sequence, sourceEpoch):
                    deliveries += await index.replace(
                        with: inputs,
                        sequence: sequence,
                        sourceEpoch: sourceEpoch
                    )
                case let .upsert(input, sequence):
                    deliveries += await index.upsert(input, sequence: sequence)
                }
            }
            return IndexResult(deliveries: deliveries)
        }
    }

    package struct IndexResult: Sendable {
        fileprivate let deliveries: [NetworkRequestIndex.QueryDelivery]
    }

    package struct IndexAcknowledgementWork: Sendable {
        fileprivate struct Entry: Sendable {
            let id: WebInspectorQueryRegistrationID
            let generation: UInt64
            let sourceEpoch: UInt64
            let sequence: UInt64
        }

        fileprivate let index: NetworkRequestIndex
        fileprivate let entries: [Entry]

        package nonisolated(nonsending) func run() async {
            for entry in entries {
                await index.acknowledge(
                    id: entry.id,
                    generation: entry.generation,
                    sourceEpoch: entry.sourceEpoch,
                    sequence: entry.sequence
                )
            }
        }
    }

    private enum ConcreteQueryBufferDestination {
        case candidate
        case committing
    }

    private struct PendingConcreteQuery {
        var generation: UInt64
        var query: NetworkQuery
        var projection: NetworkRequestIndex.QueryProjection?
    }

    private struct ConcreteQueryRegistration {
        var results: WeakWebInspectorFetchedResults<NetworkRequest>
        var activeGeneration: UInt64
        var activeQuery: NetworkQuery
        var candidate: PendingConcreteQuery?
        var committing: [UInt64: PendingConcreteQuery]
    }

    package struct QueryIndexReset: Sendable {
        fileprivate var sequence: UInt64
        fileprivate var sourceEpoch: UInt64
    }

    private struct ModelChange {
        let request: NetworkRequest
        let inserted: Bool
    }

#if DEBUG
    package struct PerformanceCounters: Equatable {
        package var fullModelProjectionCount = 0
        package var fullRecordProjectionCount = 0
        package var incrementalRecordProjectionCount = 0
        package var resultIdentityLookupCount = 0
    }
#endif

    package let collectionState: NetworkRequestCollectionState

    private var requestsByID: [NetworkRequest.ID: NetworkRequest]
    private var orderedRequestIDs: [NetworkRequest.ID]
    private var orderIndicesByID: [NetworkRequest.ID: Int]
    private var clearedRequestIDs: Set<NetworkRequest.ID>
    private let queryIndex: NetworkRequestIndex
    private var queryIndexSequence: UInt64
    private var queryIndexNeedsRebuild: Bool
    private var querySourceEpoch: UInt64
    private var nextConcreteQueryRegistrationID: UInt64
    private var initializingConcreteQueries: [
        WebInspectorQueryRegistrationID: PendingConcreteQuery
    ]
    private var concreteQueryRegistrations: [
        WebInspectorQueryRegistrationID: ConcreteQueryRegistration
    ]
#if DEBUG
    private var performanceCounters: PerformanceCounters
#endif

    package init() {
        collectionState = NetworkRequestCollectionState()
        requestsByID = [:]
        orderedRequestIDs = []
        orderIndicesByID = [:]
        clearedRequestIDs = []
        queryIndex = NetworkRequestIndex()
        queryIndexSequence = 0
        queryIndexNeedsRebuild = false
        querySourceEpoch = 0
        nextConcreteQueryRegistrationID = 0
        initializingConcreteQueries = [:]
        concreteQueryRegistrations = [:]
#if DEBUG
        performanceCounters = PerformanceCounters()
#endif
    }

#if DEBUG
    package var performanceCountersForTesting: PerformanceCounters {
        performanceCounters
    }

    package func resetPerformanceCountersForTesting() {
        performanceCounters = PerformanceCounters()
    }
#endif

    package func request(for id: NetworkRequest.ID) -> NetworkRequest? {
        requestsByID[id]
    }

    package func request(forProxyID id: Network.Request.ID) -> NetworkRequest? {
        request(for: NetworkRequest.ID(id))
    }

    package func finishResponseBodyFetch(
        _ result: Result<Network.Body, WebInspectorProxyError>,
        for request: NetworkRequest,
        expectedBody: NetworkBody
    ) {
        guard requestsByID[request.id] === request else {
            return
        }
        request.finishResponseBodyFetch(result: result, expectedBody: expectedBody)
    }

    package nonisolated(nonsending) func results(
        matching query: NetworkQuery,
        modelContext: WebInspectorModelContext
    ) async throws -> WebInspectorFetchedResults<NetworkRequest> {
        await syncQueryIndexIfNeeded()
        let id = allocateConcreteQueryRegistrationID()
        let lifetime = WebInspectorQueryRegistrationLifetime()
        let results = WebInspectorFetchedResults<NetworkRequest>(modelContext: modelContext)
        results.installQueryRegistration(id: id, lifetime: lifetime)
        let generation = results.nextConcreteQueryGeneration()
        initializingConcreteQueries[id] = PendingConcreteQuery(
            generation: generation,
            query: query,
            projection: nil
        )

        let initialProjection: NetworkRequestIndex.QueryProjection
        do {
            initialProjection = try await queryIndex.register(
                id: id,
                generation: generation,
                query: query,
                lifetime: lifetime,
                minimumSequence: queryIndexSequence
            )
        } catch {
            initializingConcreteQueries[id] = nil
            throw error
        }

        guard var initialization = initializingConcreteQueries.removeValue(forKey: id),
              initialization.generation == generation else {
            preconditionFailure("Network query initialization lost its owner state after index commit.")
        }
        initialization.projection = coalesce(
            initialization.projection,
            with: initialProjection
        )
        let installedProjection = initialization.projection ?? initialProjection
        guard installedProjection.sourceEpoch == querySourceEpoch else {
            throw CancellationError()
        }
        results.installInitialNetworkQuery(
            query,
            generation: generation,
            projection: installedProjection,
            lookup: { id in self.requestForResult(id) }
        )
        concreteQueryRegistrations[id] = ConcreteQueryRegistration(
            results: WeakWebInspectorFetchedResults(results),
            activeGeneration: generation,
            activeQuery: query,
            candidate: nil,
            committing: [:]
        )
        await queryIndex.acknowledge(
            id: id,
            generation: generation,
            sourceEpoch: installedProjection.sourceEpoch,
            sequence: installedProjection.sequence
        )
        return results
    }

    package nonisolated(nonsending) func update(
        _ query: NetworkQuery,
        for results: WebInspectorFetchedResults<NetworkRequest>
    ) async throws {
        guard let id = results.concreteQueryRegistrationID else {
            preconditionFailure("Network fetched results are not registered in this store.")
        }
        await syncQueryIndexIfNeeded()
        guard var registration = concreteQueryRegistrations[id],
              registration.results.value === results else {
            preconditionFailure("Network fetched results are not registered in this store.")
        }
        let generation = results.nextConcreteQueryGeneration()
        registration.candidate = PendingConcreteQuery(
            generation: generation,
            query: query,
            projection: nil
        )
        concreteQueryRegistrations[id] = registration

        do {
            let prepared = try await queryIndex.prepareReplacement(
                id: id,
                generation: generation,
                query: query,
                minimumSequence: queryIndexSequence
            )
            buffer(
                prepared,
                for: id,
                generation: generation,
                query: query,
                destination: .candidate
            )
            guard results.isCurrentConcreteQueryGeneration(generation) else {
                throw CancellationError()
            }
            try Task.checkCancellation()
        } catch {
            await queryIndex.discardCandidates(id: id, through: generation)
            clearCandidate(id: id, generation: generation)
            throw error
        }

        guard var beforeCommit = concreteQueryRegistrations[id],
              let candidate = beforeCommit.candidate,
              candidate.generation == generation,
              candidate.projection?.sourceEpoch == querySourceEpoch else {
            await queryIndex.discardCandidates(id: id, through: generation)
            clearCandidate(id: id, generation: generation)
            throw CancellationError()
        }
        beforeCommit.committing[generation] = candidate
        beforeCommit.candidate = nil
        concreteQueryRegistrations[id] = beforeCommit

        guard let committed = await queryIndex.commitReplacement(
            id: id,
            generation: generation
        ) else {
            clearCommitting(id: id, generation: generation)
            throw CancellationError()
        }

        guard var afterCommit = concreteQueryRegistrations[id],
              var pendingPublication = afterCommit.committing.removeValue(forKey: generation) else {
            preconditionFailure("Network query replacement lost committed publication state.")
        }
        pendingPublication.projection = coalesce(
            pendingPublication.projection,
            with: committed
        )
        let publication = pendingPublication.projection ?? committed
        let applied = results.applyNetworkQueryProjection(
            publication,
            query: query,
            generation: generation,
            isReplacement: true,
            lookup: { id in self.requestForResult(id) }
        )
        if generation > afterCommit.activeGeneration {
            afterCommit.activeGeneration = generation
            afterCommit.activeQuery = query
        }
        concreteQueryRegistrations[id] = afterCommit
        if applied {
            await queryIndex.acknowledge(
                id: id,
                generation: generation,
                sourceEpoch: publication.sourceEpoch,
                sequence: publication.sequence
            )
        }
    }

    /// Clears requests while remembering their protocol identities so late
    /// terminal events from the cleared loads remain ignorable.
    package nonisolated(nonsending) func clear() async {
        clearedRequestIDs.formUnion(requestsByID.keys)
        let reset = prepareRemoveAllRequests()
        await finishQueryIndexReset(reset)
    }

    /// Begins a new attachment epoch and immediately removes prior identities.
    package func prepareResetForNewAttachment() -> QueryIndexReset {
        clearedRequestIDs = []
        return prepareRemoveAllRequests()
    }

    package nonisolated(nonsending) func finishQueryIndexReset(_ reset: QueryIndexReset) async {
        let deliveries = await queryIndex.replace(
            with: [],
            sequence: reset.sequence,
            sourceEpoch: reset.sourceEpoch
        )
        await applyConcreteDeliveries(deliveries)
    }

    @discardableResult
    package func seedRequest(
        requestID rawRequestID: String,
        url: String,
        method: String = "GET",
        resourceTypeRawValue: String?,
        requestHeaders: [String: String] = [:],
        postData: String? = nil,
        responseMIMEType: String,
        responseStatus: Int,
        responseStatusText: String,
        responseHeaders: [String: String] = [:],
        responseBody: String? = nil,
        timestamp: Double,
        encodedBodyLength: Int = 0,
        modelContext: WebInspectorModelContext
    ) -> NetworkRequest.ID {
        let requestID = Network.Request.ID(rawRequestID)
        let resourceType = resourceTypeRawValue.map(Network.ResourceType.init(rawValue:))
        let payload = Network.Request(
            id: requestID,
            url: url,
            method: method,
            headers: requestHeaders,
            postData: postData
        )
        let id = NetworkRequest.ID(requestID)
        let request: NetworkRequest
        let inserted: Bool
        if let existing = requestsByID[id] {
            request = existing
            request.applyRequestWillBeSent(
                request: payload,
                resourceType: resourceType,
                timestamp: timestamp
            )
            inserted = false
        } else {
            request = NetworkRequest(
                request: payload,
                resourceType: resourceType,
                timestamp: timestamp,
                modelContext: modelContext
            )
            requestsByID[id] = request
            appendRequestID(id)
            inserted = true
        }
        request.applyResponse(
            Network.Response(
                url: url,
                status: responseStatus,
                statusText: responseStatusText,
                mimeType: responseMIMEType,
                headers: responseHeaders,
                source: Network.Source(rawValue: "network"),
                requestHeaders: requestHeaders
            ),
            resourceType: resourceType ?? .other,
            timestamp: timestamp + 0.1
        )
        request.applyDataReceived(
            dataLength: encodedBodyLength,
            encodedDataLength: encodedBodyLength,
            timestamp: timestamp + 0.11
        )
        request.finish(
            timestamp: timestamp + 0.2,
            sourceMapURL: nil,
            metrics: Network.Metrics(
                encodedDataLength: encodedBodyLength,
                decodedBodyLength: encodedBodyLength
            )
        )
        if let responseBody {
            request.responseBody.load(Network.Body(data: responseBody, base64Encoded: false))
        }
        queryIndexNeedsRebuild = true
        if inserted {
            collectionState.didInsertRequest()
        }
        return request.id
    }

    package func seedResponseBody(
        for requestID: NetworkRequest.ID,
        body: String,
        base64Encoded: Bool = false,
        size: Int? = nil,
        isTruncated: Bool = false
    ) {
        guard let request = requestsByID[requestID] else {
            preconditionFailure("Cannot seed a response body for an unregistered NetworkRequest.")
        }
        request.responseBody.load(NetworkBody.Payload(
            body: body,
            base64Encoded: base64Encoded,
            size: size,
            isTruncated: isTruncated
        ))
    }

    package func indexWork(for reset: QueryIndexReset) -> IndexWork {
        IndexWork(
            index: queryIndex,
            actions: [
                .replace(
                    inputs: [],
                    sequence: reset.sequence,
                    sourceEpoch: reset.sourceEpoch
                )
            ]
        )
    }

    /// Applies the semantic portion of one ordered feed event synchronously and
    /// returns index-only work that can run without retaining this store or its
    /// model context.
    package func prepareModelEvent(
        _ event: Network.Event,
        modelContext: WebInspectorModelContext
    ) -> IndexWork? {
        let change: ModelChange?
        switch event {
        case let .requestWillBeSent(id, payload, resourceType, redirectResponse, timestamp):
            change = prepareRequestWillBeSent(
                id: id,
                request: payload,
                resourceType: resourceType,
                redirectResponse: redirectResponse,
                timestamp: timestamp,
                modelContext: modelContext
            )
        case let .responseReceived(id, response, resourceType, timestamp):
            change = prepareResponseReceived(
                id: id,
                response: response,
                resourceType: resourceType,
                timestamp: timestamp,
                modelContext: modelContext
            )
        case let .dataReceived(id, dataLength, encodedDataLength, timestamp):
            guard let request = request(for: id, method: "dataReceived") else {
                return nil
            }
            request.applyDataReceived(
                dataLength: dataLength,
                encodedDataLength: encodedDataLength,
                timestamp: timestamp
            )
            change = ModelChange(request: request, inserted: false)
        case let .loadingFinished(id, timestamp, sourceMapURL, metrics):
            guard let request = request(for: id, method: "loadingFinished") else {
                return nil
            }
            request.finish(timestamp: timestamp, sourceMapURL: sourceMapURL, metrics: metrics)
            change = ModelChange(request: request, inserted: false)
        case let .loadingFailed(id, errorText, canceled, timestamp):
            guard let request = request(for: id, method: "loadingFailed") else {
                return nil
            }
            request.fail(errorText: errorText, canceled: canceled, timestamp: timestamp)
            change = ModelChange(request: request, inserted: false)
        case let .webSocket(event):
            change = prepareWebSocketEvent(event, modelContext: modelContext)
        case let .requestServedFromMemoryCache(id, response, resourceType, timestamp):
            change = prepareRequestServedFromMemoryCache(
                id: id,
                response: response,
                resourceType: resourceType,
                timestamp: timestamp,
                modelContext: modelContext
            )
        case .unknown:
            return nil
        }
        guard let change else {
            return nil
        }
        if change.inserted {
            collectionState.didInsertRequest()
        }
        var actions: [IndexWork.Action] = []
        if queryIndexNeedsRebuild {
            queryIndexNeedsRebuild = false
            actions.append(.replace(
                inputs: currentRecordInputs(),
                sequence: nextQueryIndexSequence(),
                sourceEpoch: querySourceEpoch
            ))
        }
        actions.append(.upsert(
            input: recordInput(for: change.request),
            sequence: nextQueryIndexSequence()
        ))
        return IndexWork(index: queryIndex, actions: actions)
    }

    package func commit(_ result: IndexResult) -> IndexAcknowledgementWork? {
        let entries = applyConcreteDeliveriesSynchronously(result.deliveries)
        guard !entries.isEmpty else {
            return nil
        }
        return IndexAcknowledgementWork(index: queryIndex, entries: entries)
    }

    private func prepareRequestWillBeSent(
        id proxyID: Network.Request.ID,
        request payload: Network.Request,
        resourceType: Network.ResourceType?,
        redirectResponse: Network.Response?,
        timestamp: Double,
        modelContext: WebInspectorModelContext
    ) -> ModelChange? {
        let id = NetworkRequest.ID(proxyID)
        guard !clearedRequestIDs.contains(id) || redirectResponse == nil else {
            return nil
        }
        clearedRequestIDs.remove(id)
        if let request = requestsByID[id] {
            if let redirectResponse, request.isActive {
                request.applyRedirect(
                    to: payload,
                    redirectResponse: redirectResponse,
                    timestamp: timestamp,
                    resourceType: resourceType
                )
                return ModelChange(request: request, inserted: false)
            }
            guard !request.isActive else {
                return nil
            }
            request.applyRequestWillBeSent(
                request: payload,
                resourceType: resourceType,
                timestamp: timestamp
            )
            return ModelChange(request: request, inserted: false)
        }
        let request = NetworkRequest(
            request: payload,
            resourceType: resourceType,
            timestamp: timestamp,
            modelContext: modelContext
        )
        requestsByID[id] = request
        appendRequestID(id)
        return ModelChange(request: request, inserted: true)
    }

    private func prepareResponseReceived(
        id proxyID: Network.Request.ID,
        response: Network.Response,
        resourceType: Network.ResourceType?,
        timestamp: Double,
        modelContext: WebInspectorModelContext
    ) -> ModelChange? {
        let id = NetworkRequest.ID(proxyID)
        guard !clearedRequestIDs.contains(id) else {
            return nil
        }
        let request: NetworkRequest
        let inserted: Bool
        if let existing = requestsByID[id] {
            request = existing
            inserted = false
        } else {
            guard let url = response.url else {
                skipEvent("Network.responseReceived omitted response URL for an untracked request")
                return nil
            }
            request = NetworkRequest(
                request: Network.Request(
                    id: proxyID,
                    url: url,
                    method: "GET",
                    headers: response.requestHeaders ?? [:]
                ),
                resourceType: resourceType,
                timestamp: timestamp,
                modelContext: modelContext
            )
            requestsByID[id] = request
            appendRequestID(id)
            inserted = true
        }
        request.applyResponse(response, resourceType: resourceType, timestamp: timestamp)
        return ModelChange(request: request, inserted: inserted)
    }

    private func prepareRequestServedFromMemoryCache(
        id proxyID: Network.Request.ID,
        response: Network.Response,
        resourceType: Network.ResourceType?,
        timestamp: Double,
        modelContext: WebInspectorModelContext
    ) -> ModelChange? {
        let id = NetworkRequest.ID(proxyID)
        guard !clearedRequestIDs.contains(id) else {
            return nil
        }
        let request: NetworkRequest
        let inserted: Bool
        if let existing = requestsByID[id] {
            request = existing
            inserted = false
        } else {
            guard let url = response.url else {
                skipEvent("Network.requestServedFromMemoryCache omitted response URL for a new request")
                return nil
            }
            request = NetworkRequest(
                request: Network.Request(
                    id: proxyID,
                    url: url,
                    method: "GET",
                    headers: response.requestHeaders ?? [:]
                ),
                resourceType: resourceType,
                timestamp: timestamp,
                modelContext: modelContext
            )
            requestsByID[id] = request
            appendRequestID(id)
            inserted = true
        }
        request.applyMemoryCache(response: response, resourceType: resourceType, timestamp: timestamp)
        return ModelChange(request: request, inserted: inserted)
    }

    private func prepareWebSocketEvent(
        _ event: Network.WebSocketEvent,
        modelContext: WebInspectorModelContext
    ) -> ModelChange? {
        switch event {
        case let .created(proxyID, url):
            let id = NetworkRequest.ID(proxyID)
            clearedRequestIDs.remove(id)
            let request: NetworkRequest
            let inserted: Bool
            if let existing = requestsByID[id] {
                request = existing
                inserted = false
            } else {
                request = NetworkRequest(
                    request: Network.Request(id: proxyID, url: url, method: "GET"),
                    resourceType: .webSocket,
                    timestamp: nil,
                    modelContext: modelContext
                )
                requestsByID[id] = request
                appendRequestID(id)
                inserted = true
            }
            request.applyWebSocketCreated(url: url)
            return ModelChange(request: request, inserted: inserted)
        case let .handshakeRequest(id, payload, timestamp):
            guard let request = request(for: id, method: "webSocketWillSendHandshakeRequest") else {
                return nil
            }
            request.applyWebSocketHandshakeRequest(payload, timestamp: timestamp)
            return ModelChange(request: request, inserted: false)
        case let .handshakeResponse(id, response, timestamp):
            guard let request = request(for: id, method: "webSocketHandshakeResponseReceived") else {
                return nil
            }
            request.applyWebSocketHandshakeResponse(response, timestamp: timestamp)
            return ModelChange(request: request, inserted: false)
        case let .frameSent(id, frame, timestamp):
            guard let request = request(for: id, method: "webSocketFrameSent") else {
                return nil
            }
            request.appendWebSocketFrame(frame, direction: .sent, timestamp: timestamp)
            return ModelChange(request: request, inserted: false)
        case let .frameReceived(id, frame, timestamp):
            guard let request = request(for: id, method: "webSocketFrameReceived") else {
                return nil
            }
            request.appendWebSocketFrame(frame, direction: .received, timestamp: timestamp)
            return ModelChange(request: request, inserted: false)
        case let .error(id, message, timestamp):
            guard let request = request(for: id, method: "webSocketFrameError") else {
                return nil
            }
            request.appendWebSocketError(message, timestamp: timestamp)
            return ModelChange(request: request, inserted: false)
        case let .closed(id, timestamp):
            guard let request = request(for: id, method: "webSocketClosed") else {
                return nil
            }
            request.closeWebSocket(timestamp: timestamp)
            return ModelChange(request: request, inserted: false)
        case .other:
            return nil
        }
    }

    package nonisolated(nonsending) func apply(
        _ event: Network.Event,
        modelContext: WebInspectorModelContext
    ) async {
        switch event {
        case let .requestWillBeSent(id, request, resourceType, redirectResponse, timestamp):
            await applyRequestWillBeSent(
                id: id,
                request: request,
                resourceType: resourceType,
                redirectResponse: redirectResponse,
                timestamp: timestamp,
                modelContext: modelContext
            )
        case let .responseReceived(id, response, resourceType, timestamp):
            await applyResponseReceived(
                id: id,
                response: response,
                resourceType: resourceType,
                timestamp: timestamp,
                modelContext: modelContext
            )
        case let .dataReceived(id, dataLength, encodedDataLength, timestamp):
            guard let request = request(for: id, method: "dataReceived") else {
                return
            }
            request.applyDataReceived(
                dataLength: dataLength,
                encodedDataLength: encodedDataLength,
                timestamp: timestamp
            )
            await notifyRequestMutated(request, modelContext: modelContext)
        case let .loadingFinished(id, timestamp, sourceMapURL, metrics):
            guard let request = request(for: id, method: "loadingFinished") else {
                return
            }
            request.finish(timestamp: timestamp, sourceMapURL: sourceMapURL, metrics: metrics)
            await notifyRequestMutated(request, modelContext: modelContext)
        case let .loadingFailed(id, errorText, canceled, timestamp):
            guard let request = request(for: id, method: "loadingFailed") else {
                return
            }
            request.fail(errorText: errorText, canceled: canceled, timestamp: timestamp)
            await notifyRequestMutated(request, modelContext: modelContext)
        case let .webSocket(event):
            await apply(event, modelContext: modelContext)
        case let .requestServedFromMemoryCache(id, response, resourceType, timestamp):
            await applyRequestServedFromMemoryCache(
                id: id,
                response: response,
                resourceType: resourceType,
                timestamp: timestamp,
                modelContext: modelContext
            )
        case .unknown:
            break
        }
    }

    private nonisolated(nonsending) func applyRequestWillBeSent(
        id proxyID: Network.Request.ID,
        request payload: Network.Request,
        resourceType: Network.ResourceType?,
        redirectResponse: Network.Response?,
        timestamp: Double,
        modelContext: WebInspectorModelContext
    ) async {
        let id = NetworkRequest.ID(proxyID)
        guard clearedRequestIDs.contains(id) == false || redirectResponse == nil else {
            return
        }
        clearedRequestIDs.remove(id)
        let request: NetworkRequest
        var inserted = false
        var topologyMayHaveChanged = false
        if let existing = requestsByID[id] {
            request = existing
            if let redirectResponse, existing.isActive {
                request.applyRedirect(
                    to: payload,
                    redirectResponse: redirectResponse,
                    timestamp: timestamp,
                    resourceType: resourceType
                )
                topologyMayHaveChanged = true
            } else if existing.isActive == false {
                request.applyRequestWillBeSent(request: payload, resourceType: resourceType, timestamp: timestamp)
                topologyMayHaveChanged = true
            }
        } else {
            request = NetworkRequest(
                request: payload,
                resourceType: resourceType,
                timestamp: timestamp,
                modelContext: modelContext
            )
            requestsByID[id] = request
            appendRequestID(id)
            inserted = true
        }
        if inserted {
            await notifyRequestInserted(request, modelContext: modelContext)
        } else if topologyMayHaveChanged {
            await notifyRequestMutated(request, modelContext: modelContext)
        }
    }

    private nonisolated(nonsending) func applyRequestServedFromMemoryCache(
        id proxyID: Network.Request.ID,
        response: Network.Response,
        resourceType: Network.ResourceType?,
        timestamp: Double,
        modelContext: WebInspectorModelContext
    ) async {
        let id = NetworkRequest.ID(proxyID)
        guard clearedRequestIDs.contains(id) == false else {
            return
        }
        let request: NetworkRequest
        if let existing = requestsByID[id] {
            request = existing
        } else {
            guard let url = response.url else {
                skipEvent("Network.requestServedFromMemoryCache omitted response URL for a new request")
                return
            }
            let payload = Network.Request(
                id: proxyID,
                url: url,
                method: "GET",
                headers: response.requestHeaders ?? [:]
            )
            request = NetworkRequest(
                request: payload,
                resourceType: resourceType,
                timestamp: timestamp,
                modelContext: modelContext
            )
            requestsByID[id] = request
            appendRequestID(id)
            request.applyMemoryCache(response: response, resourceType: resourceType, timestamp: timestamp)
            await notifyRequestInserted(request, modelContext: modelContext)
            return
        }
        request.applyMemoryCache(response: response, resourceType: resourceType, timestamp: timestamp)
        await notifyRequestMutated(request, modelContext: modelContext)
    }

    private nonisolated(nonsending) func applyResponseReceived(
        id proxyID: Network.Request.ID,
        response: Network.Response,
        resourceType: Network.ResourceType?,
        timestamp: Double,
        modelContext: WebInspectorModelContext
    ) async {
        let id = NetworkRequest.ID(proxyID)
        guard clearedRequestIDs.contains(id) == false else {
            return
        }
        let request: NetworkRequest
        var inserted = false
        if let existing = requestsByID[id] {
            request = existing
        } else {
            guard let url = response.url else {
                skipEvent("Network.responseReceived omitted response URL for an untracked request")
                return
            }
            // WebKit's frontend creates a resource here when inspection starts
            // after Network.requestWillBeSent. The response event has no method,
            // so keep the same GET default WebKit uses when serializing such a
            // resource later.
            let payload = Network.Request(
                id: proxyID,
                url: url,
                method: "GET",
                headers: response.requestHeaders ?? [:]
            )
            request = NetworkRequest(
                request: payload,
                resourceType: resourceType,
                timestamp: timestamp,
                modelContext: modelContext
            )
            requestsByID[id] = request
            appendRequestID(id)
            inserted = true
        }
        request.applyResponse(response, resourceType: resourceType, timestamp: timestamp)
        if inserted {
            await notifyRequestInserted(request, modelContext: modelContext)
        } else {
            await notifyRequestMutated(request, modelContext: modelContext)
        }
    }

    private nonisolated(nonsending) func apply(
        _ event: Network.WebSocketEvent,
        modelContext: WebInspectorModelContext
    ) async {
        switch event {
        case let .created(id, url):
            await applyWebSocketCreated(
                id: id,
                url: url,
                modelContext: modelContext
            )
        case let .handshakeRequest(id, payload, timestamp):
            guard let networkRequest = request(
                for: id,
                method: "webSocketWillSendHandshakeRequest"
            ) else {
                return
            }
            networkRequest.applyWebSocketHandshakeRequest(payload, timestamp: timestamp)
            await notifyRequestMutated(networkRequest, modelContext: modelContext)
        case let .handshakeResponse(id, response, timestamp):
            guard let networkRequest = request(
                for: id,
                method: "webSocketHandshakeResponseReceived"
            ) else {
                return
            }
            networkRequest.applyWebSocketHandshakeResponse(response, timestamp: timestamp)
            await notifyRequestMutated(networkRequest, modelContext: modelContext)
        case let .frameSent(id, frame, timestamp):
            guard let networkRequest = request(
                for: id,
                method: "webSocketFrameSent"
            ) else {
                return
            }
            networkRequest.appendWebSocketFrame(frame, direction: .sent, timestamp: timestamp)
            await notifyRequestMutated(networkRequest, modelContext: modelContext)
        case let .frameReceived(id, frame, timestamp):
            guard let networkRequest = request(
                for: id,
                method: "webSocketFrameReceived"
            ) else {
                return
            }
            networkRequest.appendWebSocketFrame(frame, direction: .received, timestamp: timestamp)
            await notifyRequestMutated(networkRequest, modelContext: modelContext)
        case let .error(id, message, timestamp):
            guard let networkRequest = request(
                for: id,
                method: "webSocketFrameError"
            ) else {
                return
            }
            networkRequest.appendWebSocketError(message, timestamp: timestamp)
            await notifyRequestMutated(networkRequest, modelContext: modelContext)
        case let .closed(id, timestamp):
            guard let networkRequest = request(
                for: id,
                method: "webSocketClosed"
            ) else {
                return
            }
            networkRequest.closeWebSocket(timestamp: timestamp)
            await notifyRequestMutated(networkRequest, modelContext: modelContext)
        case .other:
            break
        }
    }

    private nonisolated(nonsending) func applyWebSocketCreated(
        id proxyID: Network.Request.ID,
        url: String,
        modelContext: WebInspectorModelContext
    ) async {
        let id = NetworkRequest.ID(proxyID)
        clearedRequestIDs.remove(id)
        let request: NetworkRequest
        var inserted = false
        if let existing = requestsByID[id] {
            request = existing
        } else {
            let payload = Network.Request(id: proxyID, url: url, method: "GET")
            request = NetworkRequest(
                request: payload,
                resourceType: .webSocket,
                timestamp: nil,
                modelContext: modelContext
            )
            requestsByID[id] = request
            appendRequestID(id)
            inserted = true
        }
        request.applyWebSocketCreated(url: url)
        if inserted {
            await notifyRequestInserted(request, modelContext: modelContext)
        } else {
            await notifyRequestMutated(request, modelContext: modelContext)
        }
    }

    private func request(
        for proxyID: Network.Request.ID,
        method: String
    ) -> NetworkRequest? {
        let id = NetworkRequest.ID(proxyID)
        guard let request = requestsByID[id] else {
            if clearedRequestIDs.contains(id) == false {
                skipEvent("Network.\(method) referenced an untracked request")
            }
            return nil
        }
        return request
    }

    private func prepareRemoveAllRequests() -> QueryIndexReset {
        requestsByID = [:]
        orderedRequestIDs = []
        orderIndicesByID = [:]
        queryIndexNeedsRebuild = false
        advanceQuerySourceEpoch()
        let sequence = nextQueryIndexSequence()
        collectionState.replaceCount(0)
        let reset = QueryIndexReset(
            sequence: sequence,
            sourceEpoch: querySourceEpoch
        )
        publishEmptyConcreteQueryResults(for: reset)
        return reset
    }

    private func publishEmptyConcreteQueryResults(for reset: QueryIndexReset) {
        pruneConcreteQueryRegistrations()
        let projection = NetworkRequestIndex.QueryProjection(
            sourceEpoch: reset.sourceEpoch,
            sequence: reset.sequence,
            snapshot: WebInspectorFetchedResultsSnapshot(),
            reconfigureItemIDs: []
        )
        for registration in concreteQueryRegistrations.values {
            registration.results.value?.applyNetworkQueryProjection(
                projection,
                query: registration.activeQuery,
                generation: registration.activeGeneration,
                isReplacement: false,
                lookup: { _ in
                    preconditionFailure("An empty Network reset cannot resolve a model identity.")
                }
            )
        }
    }

    private func advanceQuerySourceEpoch() {
        precondition(
            querySourceEpoch < UInt64.max,
            "Network query source epoch overflowed."
        )
        querySourceEpoch += 1
    }

    private func appendRequestID(_ id: NetworkRequest.ID) {
        orderIndicesByID[id] = orderedRequestIDs.count
        orderedRequestIDs.append(id)
    }

    private func currentRecordInputs() -> [NetworkRequestRecordInput] {
#if DEBUG
        performanceCounters.fullRecordProjectionCount += orderedRequestIDs.count
#endif
        return orderedRequestIDs.enumerated().compactMap { index, id in
            requestsByID[id].map { NetworkRequestRecordInput(request: $0, orderIndex: index) }
        }
    }

    private func recordInput(for request: NetworkRequest) -> NetworkRequestRecordInput {
#if DEBUG
        performanceCounters.incrementalRecordProjectionCount += 1
#endif
        let orderIndex = orderIndicesByID[request.id] ?? orderedRequestIDs.count
        return NetworkRequestRecordInput(request: request, orderIndex: orderIndex)
    }

    private func isCurrent(_ request: NetworkRequest) -> Bool {
        return requestsByID[request.id] === request
    }

    private func nextQueryIndexSequence() -> UInt64 {
        // The index drains a contiguous operation log, so every allocated
        // sequence must be submitted exactly once to replace or upsert.
        precondition(
            queryIndexSequence < UInt64.max,
            "NetworkRequestIndex mutation sequence overflowed."
        )
        queryIndexSequence += 1
        return queryIndexSequence
    }

    private nonisolated(nonsending) func syncQueryIndexIfNeeded() async {
        guard queryIndexNeedsRebuild else {
            return
        }
        queryIndexNeedsRebuild = false
        let sequence = nextQueryIndexSequence()
        let inputs = currentRecordInputs()
        let deliveries = await queryIndex.replace(
            with: inputs,
            sequence: sequence,
            sourceEpoch: querySourceEpoch
        )
        await applyConcreteDeliveries(deliveries)
    }

    private nonisolated(nonsending) func notifyRequestInserted(
        _ request: NetworkRequest,
        modelContext: WebInspectorModelContext
    ) async {
        collectionState.didInsertRequest()
        await syncQueryIndexIfNeeded()
        guard isCurrent(request) else {
            return
        }
        let sequence = nextQueryIndexSequence()
        let input = recordInput(for: request)
        let deliveries = await queryIndex.upsert(input, sequence: sequence)
        await applyConcreteDeliveries(deliveries)
        guard isCurrent(request) else {
            return
        }
    }

    private nonisolated(nonsending) func notifyRequestMutated(
        _ request: NetworkRequest,
        modelContext: WebInspectorModelContext
    ) async {
        await syncQueryIndexIfNeeded()
        guard isCurrent(request) else {
            return
        }
        let sequence = nextQueryIndexSequence()
        let input = recordInput(for: request)
        let deliveries = await queryIndex.upsert(input, sequence: sequence)
        await applyConcreteDeliveries(deliveries)
        guard isCurrent(request) else {
            return
        }
    }

    private func allocateConcreteQueryRegistrationID() -> WebInspectorQueryRegistrationID {
        precondition(
            nextConcreteQueryRegistrationID < UInt64.max,
            "Network concrete query registration identity overflowed."
        )
        let id = WebInspectorQueryRegistrationID(rawValue: nextConcreteQueryRegistrationID)
        nextConcreteQueryRegistrationID += 1
        return id
    }

    private nonisolated(nonsending) func applyConcreteDeliveries(_ deliveries: [NetworkRequestIndex.QueryDelivery]) async {
        let acknowledgements = applyConcreteDeliveriesSynchronously(deliveries)
        await IndexAcknowledgementWork(
            index: queryIndex,
            entries: acknowledgements
        ).run()
    }

    private func applyConcreteDeliveriesSynchronously(
        _ deliveries: [NetworkRequestIndex.QueryDelivery]
    ) -> [IndexAcknowledgementWork.Entry] {
        pruneConcreteQueryRegistrations()
        var acknowledgements: [IndexAcknowledgementWork.Entry] = []
        for delivery in deliveries {
            guard delivery.projection.sourceEpoch == querySourceEpoch else {
                continue
            }
            let id = delivery.registrationID
            if var initialization = initializingConcreteQueries[id],
               initialization.generation == delivery.generation {
                initialization.projection = coalesce(
                    initialization.projection,
                    with: delivery.projection
                )
                initializingConcreteQueries[id] = initialization
                continue
            }
            guard var registration = concreteQueryRegistrations[id] else {
                continue
            }
            if delivery.generation == registration.activeGeneration {
                guard let results = registration.results.value else {
                    concreteQueryRegistrations[id] = nil
                    continue
                }
                let applied = results.applyNetworkQueryProjection(
                    delivery.projection,
                    query: registration.activeQuery,
                    generation: delivery.generation,
                    isReplacement: false,
                    lookup: { id in self.requestForResult(id) }
                )
                if applied {
                    acknowledgements.append(IndexAcknowledgementWork.Entry(
                        id: id,
                        generation: delivery.generation,
                        sourceEpoch: delivery.projection.sourceEpoch,
                        sequence: delivery.projection.sequence
                    ))
                }
            } else if var candidate = registration.candidate,
                      candidate.generation == delivery.generation {
                candidate.projection = coalesce(candidate.projection, with: delivery.projection)
                registration.candidate = candidate
            } else if var committing = registration.committing[delivery.generation] {
                committing.projection = coalesce(
                    committing.projection,
                    with: delivery.projection
                )
                registration.committing[delivery.generation] = committing
            }
            concreteQueryRegistrations[id] = registration
        }
        return acknowledgements
    }

    private func buffer(
        _ projection: NetworkRequestIndex.QueryProjection,
        for id: WebInspectorQueryRegistrationID,
        generation: UInt64,
        query: NetworkQuery,
        destination: ConcreteQueryBufferDestination
    ) {
        guard var registration = concreteQueryRegistrations[id] else {
            return
        }
        switch destination {
        case .candidate:
            guard var candidate = registration.candidate,
                  candidate.generation == generation,
                  candidate.query == query else {
                return
            }
            candidate.projection = coalesce(candidate.projection, with: projection)
            registration.candidate = candidate
        case .committing:
            guard var committing = registration.committing[generation],
                  committing.query == query else {
                return
            }
            committing.projection = coalesce(committing.projection, with: projection)
            registration.committing[generation] = committing
        }
        concreteQueryRegistrations[id] = registration
    }

    private func clearCandidate(
        id: WebInspectorQueryRegistrationID,
        generation: UInt64
    ) {
        guard var registration = concreteQueryRegistrations[id],
              registration.candidate?.generation == generation else {
            return
        }
        registration.candidate = nil
        concreteQueryRegistrations[id] = registration
    }

    private func clearCommitting(
        id: WebInspectorQueryRegistrationID,
        generation: UInt64
    ) {
        guard var registration = concreteQueryRegistrations[id] else {
            return
        }
        registration.committing[generation] = nil
        concreteQueryRegistrations[id] = registration
    }

    private func coalesce(
        _ current: NetworkRequestIndex.QueryProjection?,
        with incoming: NetworkRequestIndex.QueryProjection
    ) -> NetworkRequestIndex.QueryProjection {
        guard let current else {
            return incoming
        }
        let incomingIsNewer = incoming.sourceEpoch > current.sourceEpoch
            || (incoming.sourceEpoch == current.sourceEpoch && incoming.sequence > current.sequence)
        let newest = incomingIsNewer ? incoming : current
        let reconfigureItemIDs = current.reconfigureItemIDs
            .union(incoming.reconfigureItemIDs)
            .intersection(newest.snapshot.itemIDs)
        return NetworkRequestIndex.QueryProjection(
            sourceEpoch: newest.sourceEpoch,
            sequence: newest.sequence,
            snapshot: newest.snapshot,
            reconfigureItemIDs: reconfigureItemIDs
        )
    }

    private func pruneConcreteQueryRegistrations() {
        concreteQueryRegistrations = concreteQueryRegistrations.filter { _, registration in
            registration.results.value != nil
        }
    }

#if DEBUG
    package nonisolated(nonsending) func concreteQueryRegistrationCountForTesting() async -> Int {
        return await queryIndex.queryRegistrationCountForTesting()
    }
#endif

    private func requestForResult(_ id: NetworkRequest.ID) -> NetworkRequest? {
#if DEBUG
        performanceCounters.resultIdentityLookupCount += 1
#endif
        return requestsByID[id]
    }

    private func skipEvent(_ reason: String) {
        WebInspectorDataKitLog.debug("event skipped: \(reason)")
    }
}
