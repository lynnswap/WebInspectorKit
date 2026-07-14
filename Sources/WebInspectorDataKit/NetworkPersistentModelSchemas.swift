import WebInspectorProxyKit

package let webInspectorNetworkRequestSchema = WebInspectorModelSchema<
    NetworkRequest,
    CanonicalNetworkRequestRecord
>(
    featureID: .network,
    makeModel: { context, _, record in
        NetworkRequest(canonical: record, modelContext: context)
    },
    updateModel: { context, model, record in
        model.replaceCanonicalRecord(record, modelContext: context)
    },
    invalidateModel: { _, model in
        model.invalidateCanonicalRecord()
    }
)

package let webInspectorNetworkEntrySchema = WebInspectorModelSchema<
    NetworkEntry,
    CanonicalNetworkEntryRecord
>(
    featureID: .network,
    makeModel: { context, _, record in
        NetworkEntry(canonical: record, modelContext: context)
    },
    updateModel: { context, model, record in
        model.replaceCanonicalRecord(record, modelContext: context)
    },
    invalidateModel: { _, model in
        model.invalidateCanonicalRecord()
    }
)

package func webInspectorNetworkSnapshotMutations(
    _ snapshot: CanonicalNetworkSnapshot
) -> (
    requests: [WebInspectorModelMutation<NetworkRequest>],
    entries: [WebInspectorModelMutation<NetworkEntry>]
) {
    (
        requests: snapshot.requests.map { entry in
            webInspectorNetworkRequestSchema.upsert(
                record: entry.record,
                queryValue: entry.query.queryValue,
                canonicalRank: WebInspectorModelCanonicalRank(
                    rawValue: entry.record.insertionOrdinal
                )
            )
        },
        entries: snapshot.entries.map { entry in
            webInspectorNetworkEntrySchema.upsert(
                record: entry.record,
                queryValue: entry.query.queryValue,
                canonicalRank: WebInspectorModelCanonicalRank(
                    rawValue: entry.record.id.ordinal
                )
            )
        }
    )
}

package func webInspectorNetworkMutations(
    _ transaction: CanonicalNetworkTransaction,
    staged store: CanonicalNetworkStore
) -> (
    requests: [WebInspectorModelMutation<NetworkRequest>],
    entries: [WebInspectorModelMutation<NetworkEntry>]
) {
    var requestOrder: [CanonicalNetworkRequestIDStorage] = []
    var requestIDs: Set<CanonicalNetworkRequestIDStorage> = []
    for change in transaction.requestChanges {
        let id: CanonicalNetworkRequestIDStorage = switch change {
        case let .insert(record, _): record.id
        case let .update(id, _, _), let .delete(id): id
        }
        if requestIDs.insert(id).inserted { requestOrder.append(id) }
    }
    let requestMutations = requestOrder.compactMap { id in
        guard let record = store.request(for: id),
              let query = store.requestQuery(for: id)
        else {
            return webInspectorNetworkRequestSchema.delete(
                id: NetworkRequest.ID(canonical: id)
            )
        }
        return webInspectorNetworkRequestSchema.upsert(
            record: record,
            queryValue: query.queryValue,
            canonicalRank: WebInspectorModelCanonicalRank(
                rawValue: record.insertionOrdinal
            )
        )
    }

    var entryOrder: [CanonicalNetworkEntryIDStorage] = []
    var entryIDs: Set<CanonicalNetworkEntryIDStorage> = []
    for change in transaction.entryChanges {
        let id: CanonicalNetworkEntryIDStorage = switch change {
        case let .insert(record, _): record.id
        case let .update(id, _, _), let .delete(id): id
        }
        if entryIDs.insert(id).inserted { entryOrder.append(id) }
    }
    let entryMutations = entryOrder.compactMap { id in
        guard let record = store.entry(for: id),
              let query = store.entryQuery(for: id)
        else {
            return webInspectorNetworkEntrySchema.delete(
                id: NetworkEntry.ID(canonical: id)
            )
        }
        return webInspectorNetworkEntrySchema.upsert(
            record: record,
            queryValue: query.queryValue,
            canonicalRank: WebInspectorModelCanonicalRank(
                rawValue: record.id.ordinal
            )
        )
    }
    return (requestMutations, entryMutations)
}

package extension CanonicalNetworkRequestQueryProjection {
    var queryValue: NetworkRequest.QueryValue {
        NetworkRequest.QueryValue(
            id: NetworkRequest.ID(canonical: id),
            insertionIndex: Int(clamping: insertionOrdinal),
            url: url,
            method: method,
            resourceType: resourceType.map(Network.ResourceType.init(rawValue:)),
            mimeType: mimeType,
            resourceCategory: resourceCategory.publicValue,
            searchableText: searchableText,
            statusCode: statusCode,
            requestSentTimestamp: chronology.timestamp,
            initiatorNodeID: canonicalInitiatorNodeID
        )
    }

    private var canonicalInitiatorNodeID: DOMNode.ID? {
        guard case let .dom(storage) = groupKey else { return nil }
        return DOMNode.ID(canonical: storage)
    }
}

package extension CanonicalNetworkEntryQueryProjection {
    var queryValue: NetworkEntry.QueryValue {
        NetworkEntry.QueryValue(
            id: NetworkEntry.ID(canonical: id),
            startedAt: chronology.timestamp,
            insertionOrdinal: chronology.insertionOrdinal,
            methods: Set(methods),
            resourceCategories: Set(resourceCategories.map(\.publicValue)),
            memberCount: searchTexts.count,
            searchableText: searchTexts.joined(separator: "\n")
        )
    }
}

package extension CanonicalNetworkResourceCategory {
    var publicValue: NetworkRequest.ResourceCategory {
        switch self {
        case .document: .document
        case .stylesheet: .stylesheet
        case .script: .script
        case .image: .image
        case .font: .font
        case .xhrFetch: .xhrFetch
        case .media: .media
        case .webSocket: .webSocket
        case .other: .other
        }
    }
}

package extension CanonicalNetworkRequestPayload {
    var proxyValue: Network.Request {
        proxyValue(overridingHeaders: nil)
    }

    func proxyValue(
        overridingHeaders: [String: String]?
    ) -> Network.Request {
        Network.Request(
            id: rawID,
            url: url,
            method: method,
            headers: overridingHeaders ?? headers,
            postData: postData,
            referrerPolicy: referrerPolicy.map(Network.ReferrerPolicy.init(rawValue:)),
            integrity: integrity,
            backendResourceIdentifier: backendResourceIdentifier.map {
                Network.BackendResourceID(
                    sourceProcessID: $0.sourceProcessID,
                    resourceID: $0.resourceID
                )
            }
        )
    }
}

package extension CanonicalNetworkResponsePayload {
    var proxyValue: Network.Response {
        Network.Response(
            url: url,
            status: status,
            statusText: statusText,
            mimeType: mimeType,
            headers: headers,
            source: source.map(Network.Source.init(rawValue:)),
            requestHeaders: requestHeaders,
            bodySize: bodySize
        )
    }
}

package extension CanonicalNetworkMetrics {
    var proxyValue: Network.Metrics {
        Network.Metrics(
            timestamp: timestamp,
            networkProtocol: networkProtocol,
            remoteAddress: remoteAddress,
            encodedDataLength: encodedDataLength,
            decodedBodyLength: decodedBodyLength
        )
    }
}

package extension CanonicalNetworkInitiator {
    var proxyValue: Network.Initiator {
        Network.Initiator(
            kind: kind,
            url: url,
            line: line,
            column: column,
            nodeID: rawNodeID
        )
    }
}

package extension CanonicalNetworkRedirectHop {
    var publicValue: RedirectHop {
        RedirectHop(
            request: NetworkRequestSnapshot(request.proxyValue),
            response: NetworkResponseSnapshot(response.proxyValue),
            timestamp: redirectTimestamp,
            resourceType: resourceType.map(Network.ResourceType.init(rawValue:)),
            requestSentTimestamp: requestSentTimestamp,
            responseReceivedTimestamp: responseReceivedTimestamp,
            lastDataReceivedTimestamp: lastDataReceivedTimestamp,
            decodedDataLength: decodedDataLength,
            encodedDataLength: encodedDataLength
        )
    }
}

package extension Network.Request {
    func replacingHeaders(_ headers: [String: String]) -> Self {
        Self(
            id: id,
            url: url,
            method: method,
            headers: headers,
            postData: postData,
            referrerPolicy: referrerPolicy,
            integrity: integrity,
            backendResourceIdentifier: backendResourceIdentifier
        )
    }
}
