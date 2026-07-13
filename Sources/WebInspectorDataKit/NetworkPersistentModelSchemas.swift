import Foundation
import WebInspectorProxyKit

extension CanonicalNetworkRequestRecord: WebInspectorModelRecord {}
extension CanonicalNetworkEntryRecord: WebInspectorModelRecord {}

private struct NetworkModelOwnerEffect: Sendable {}

package enum WebInspectorNetworkModelSchemas {
    package static var registrations: [WebInspectorModelSchemaRegistration] {
        [
            WebInspectorModelSchemaRegistration(request),
            WebInspectorModelSchemaRegistration(entry),
        ]
    }

    package static var request: WebInspectorModelSchema<NetworkRequest> {
        WebInspectorModelSchema(
            snapshot: { snapshot in
                let entries = snapshot.network?.requests ?? []
                return WebInspectorModelSchemaSnapshot(
                    entries: entries.map { entry in
                        let id = NetworkRequest.ID(canonical: entry.record.id)
                        return WebInspectorModelSchemaSnapshotEntry(
                            id: id,
                            record: entry.record,
                            queryValue: entry.query.queryValue,
                            canonicalRank: .init(
                                rawValue: entry.record.insertionOrdinal
                            )
                        )
                    },
                    ownerEffects: [] as [NetworkModelOwnerEffect]
                )
            },
            delta: { transaction, lookup in
                WebInspectorModelSchemaDelta(
                    changes: requestChanges(
                        transaction.network?.requestChanges ?? [],
                        lookup: lookup
                    ),
                    ownerEffects: [] as [NetworkModelOwnerEffect]
                )
            },
            makeModel: { context, id, record in
                precondition(
                    id.canonicalStorage == record.id,
                    "A NetworkRequest schema record changed persistent identity."
                )
                return NetworkRequest(
                    canonical: record,
                    modelContext: context
                )
            },
            replaceModel: { context, model, record in
                model.replaceCanonicalRecord(record, modelContext: context)
            },
            applyPatch: { _, model, patch in
                model.applyCanonicalPatch(patch)
            },
            invalidateModel: { _, model in
                model.invalidateCanonicalRecord()
            },
            applyOwnerEffect: { _, _, _ in
                preconditionFailure(
                    "Network persistent schemas do not publish owner effects."
                )
            },
            resetOwnerProjection: { _, _ in }
        ) as WebInspectorModelSchema<NetworkRequest>
    }

    package static var entry: WebInspectorModelSchema<NetworkEntry> {
        WebInspectorModelSchema(
            snapshot: { snapshot in
                let entries = snapshot.network?.entries ?? []
                return WebInspectorModelSchemaSnapshot(
                    entries: entries.map { entry in
                        let id = NetworkEntry.ID(canonical: entry.record.id)
                        return WebInspectorModelSchemaSnapshotEntry(
                            id: id,
                            record: entry.record,
                            queryValue: entry.query.queryValue,
                            canonicalRank: .init(
                                rawValue: entry.record.id.ordinal
                            )
                        )
                    },
                    ownerEffects: [] as [NetworkModelOwnerEffect]
                )
            },
            delta: { transaction, lookup in
                WebInspectorModelSchemaDelta(
                    changes: entryChanges(
                        transaction.network?.entryChanges ?? [],
                        lookup: lookup
                    ),
                    ownerEffects: [] as [NetworkModelOwnerEffect]
                )
            },
            makeModel: { context, id, record in
                precondition(
                    id.storage == record.id,
                    "A NetworkEntry schema record changed persistent identity."
                )
                return NetworkEntry(
                    canonical: record,
                    modelContext: context
                )
            },
            replaceModel: { context, model, record in
                model.replaceCanonicalRecord(record, modelContext: context)
            },
            applyPatch: { _, model, patch in
                model.applyCanonicalPatch(patch)
            },
            invalidateModel: { _, model in
                model.invalidateCanonicalRecord()
            },
            applyOwnerEffect: { _, _, _ in
                preconditionFailure(
                    "Network persistent schemas do not publish owner effects."
                )
            },
            resetOwnerProjection: { _, _ in }
        ) as WebInspectorModelSchema<NetworkEntry>
    }
}

private extension WebInspectorNetworkModelSchemas {
    enum PendingRequestChange {
        case insert(
            record: CanonicalNetworkRequestRecord,
            query: CanonicalNetworkRequestQueryProjection
        )
        case update(
            patches: [CanonicalNetworkRequestPatch],
            query: CanonicalNetworkRequestQueryProjection?,
            canonicalRank: WebInspectorFetchedResultsCanonicalRank
        )
        case delete
    }

    enum PendingEntryChange {
        case insert(
            record: CanonicalNetworkEntryRecord,
            query: CanonicalNetworkEntryQueryProjection
        )
        case update(
            patches: [CanonicalNetworkEntryPatch],
            query: CanonicalNetworkEntryQueryProjection?,
            canonicalRank: WebInspectorFetchedResultsCanonicalRank
        )
        case delete
    }

    static func requestChanges(
        _ changes: [CanonicalNetworkRequestChange],
        lookup: WebInspectorModelSchemaRecordLookup<
            NetworkRequest,
            CanonicalNetworkRequestRecord
        >
    ) -> [WebInspectorModelSchemaChange<
        NetworkRequest,
        CanonicalNetworkRequestRecord
    >] {
        var order: [NetworkRequest.ID] = []
        var pendingByID: [NetworkRequest.ID: PendingRequestChange] = [:]
        for change in changes {
            switch change {
            case let .insert(record, query):
                let id = NetworkRequest.ID(canonical: record.id)
                precondition(
                    pendingByID[id] == nil && lookup.record(for: id) == nil,
                    "Canonical Network inserted an existing request identity."
                )
                order.append(id)
                pendingByID[id] = .insert(record: record, query: query)

            case let .update(storage, patch, query):
                let id = NetworkRequest.ID(canonical: storage)
                switch pendingByID[id] {
                case nil:
                    guard let record = lookup.record(for: id) else {
                        preconditionFailure(
                            "Canonical Network updated a missing request identity."
                        )
                    }
                    order.append(id)
                    pendingByID[id] = .update(
                        patches: [patch],
                        query: query,
                        canonicalRank: .init(
                            rawValue: record.insertionOrdinal
                        )
                    )
                case let .insert(record, existingQuery):
                    var record = record
                    record.apply(patch)
                    pendingByID[id] = .insert(
                        record: record,
                        query: query ?? existingQuery
                    )
                case let .update(patches, existingQuery, canonicalRank):
                    pendingByID[id] = .update(
                        patches: patches + [patch],
                        query: query ?? existingQuery,
                        canonicalRank: canonicalRank
                    )
                case .delete:
                    preconditionFailure(
                        "Canonical Network updated a deleted request identity."
                    )
                }

            case let .delete(storage):
                let id = NetworkRequest.ID(canonical: storage)
                switch pendingByID[id] {
                case nil:
                    precondition(
                        lookup.record(for: id) != nil,
                        "Canonical Network deleted a missing request identity."
                    )
                    order.append(id)
                    pendingByID[id] = .delete
                case .insert:
                    pendingByID[id] = nil
                case .update:
                    pendingByID[id] = .delete
                case .delete:
                    preconditionFailure(
                        "Canonical Network deleted one request identity twice."
                    )
                }
            }
        }

        return order.compactMap { id in
            guard let pending = pendingByID[id] else {
                return nil
            }
            switch pending {
            case let .insert(record, query):
                return .insert(
                    id: id,
                    record: record,
                    queryValue: query.queryValue,
                    canonicalRank: .init(rawValue: record.insertionOrdinal)
                )
            case let .update(patches, query, canonicalRank):
                return .update(
                    id: id,
                    patches: WebInspectorModelRecordPatchBatch(patches),
                    queryValue: query?.queryValue,
                    canonicalRank: query.map { _ in canonicalRank }
                )
            case .delete:
                return .delete(id: id)
            }
        }
    }

    static func entryChanges(
        _ changes: [CanonicalNetworkEntryChange],
        lookup: WebInspectorModelSchemaRecordLookup<
            NetworkEntry,
            CanonicalNetworkEntryRecord
        >
    ) -> [WebInspectorModelSchemaChange<NetworkEntry, CanonicalNetworkEntryRecord>] {
        var order: [NetworkEntry.ID] = []
        var pendingByID: [NetworkEntry.ID: PendingEntryChange] = [:]
        for change in changes {
            switch change {
            case let .insert(record, query):
                let id = NetworkEntry.ID(canonical: record.id)
                precondition(
                    pendingByID[id] == nil && lookup.record(for: id) == nil,
                    "Canonical Network inserted an existing entry identity."
                )
                order.append(id)
                pendingByID[id] = .insert(record: record, query: query)

            case let .update(storage, patch, query):
                let id = NetworkEntry.ID(canonical: storage)
                switch pendingByID[id] {
                case nil:
                    precondition(
                        lookup.record(for: id) != nil,
                        "Canonical Network updated a missing entry identity."
                    )
                    order.append(id)
                    pendingByID[id] = .update(
                        patches: [patch],
                        query: query,
                        canonicalRank: .init(rawValue: storage.ordinal)
                    )
                case let .insert(record, existingQuery):
                    var record = record
                    record.apply(patch)
                    pendingByID[id] = .insert(
                        record: record,
                        query: query ?? existingQuery
                    )
                case let .update(patches, existingQuery, canonicalRank):
                    pendingByID[id] = .update(
                        patches: patches + [patch],
                        query: query ?? existingQuery,
                        canonicalRank: canonicalRank
                    )
                case .delete:
                    preconditionFailure(
                        "Canonical Network updated a deleted entry identity."
                    )
                }

            case let .delete(storage):
                let id = NetworkEntry.ID(canonical: storage)
                switch pendingByID[id] {
                case nil:
                    precondition(
                        lookup.record(for: id) != nil,
                        "Canonical Network deleted a missing entry identity."
                    )
                    order.append(id)
                    pendingByID[id] = .delete
                case .insert:
                    pendingByID[id] = nil
                case .update:
                    pendingByID[id] = .delete
                case .delete:
                    preconditionFailure(
                        "Canonical Network deleted one entry identity twice."
                    )
                }
            }
        }

        return order.compactMap { id in
            guard let pending = pendingByID[id] else {
                return nil
            }
            switch pending {
            case let .insert(record, query):
                return .insert(
                    id: id,
                    record: record,
                    queryValue: query.queryValue,
                    canonicalRank: .init(rawValue: record.id.ordinal)
                )
            case let .update(patches, query, canonicalRank):
                return .update(
                    id: id,
                    patches: WebInspectorModelRecordPatchBatch(patches),
                    queryValue: query?.queryValue,
                    canonicalRank: query.map { _ in canonicalRank }
                )
            case .delete:
                return .delete(id: id)
            }
        }
    }
}

package extension CanonicalNetworkRequestQueryProjection {
    var queryValue: NetworkRequest.QueryValue {
        precondition(
            insertionOrdinal <= UInt64(Int.max),
            "A canonical Network insertion ordinal exceeded QueryValue's legacy Int surface."
        )
        return NetworkRequest.QueryValue(
            id: NetworkRequest.ID(canonical: id),
            insertionIndex: Int(insertionOrdinal),
            url: url,
            method: method,
            resourceType: resourceType.map(
                Network.ResourceType.init(rawValue:)
            ),
            mimeType: mimeType,
            resourceCategory: resourceCategory.publicValue,
            searchableText: searchableText,
            statusCode: statusCode,
            requestSentTimestamp: chronology.timestamp,
            initiatorNodeID: canonicalInitiatorNodeID
        )
    }

    private var canonicalInitiatorNodeID: DOMNode.ID? {
        guard case let .dom(storage) = groupKey else {
            return nil
        }
        return DOMNode.ID(canonical: storage)
    }
}

package extension CanonicalNetworkEntryQueryProjection {
    var queryValue: NetworkEntry.QueryValue {
        NetworkEntry.QueryValue(
            id: NetworkEntry.ID(canonical: id),
            startedAt: chronology.timestamp,
            insertionOrdinal: chronology.insertionOrdinal,
            methods: methods,
            resourceCategories: Set(
                resourceCategories.map(\.publicValue)
            ),
            searchTexts: searchTexts
        )
    }
}

package extension CanonicalNetworkResourceCategory {
    var publicValue: NetworkRequest.ResourceCategory {
        switch self {
        case .document:
            .document
        case .stylesheet:
            .stylesheet
        case .script:
            .script
        case .image:
            .image
        case .font:
            .font
        case .xhrFetch:
            .xhrFetch
        case .media:
            .media
        case .webSocket:
            .webSocket
        case .other:
            .other
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
            referrerPolicy: referrerPolicy.map(
                Network.ReferrerPolicy.init(rawValue:)
            ),
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
            resourceType: resourceType.map(
                Network.ResourceType.init(rawValue:)
            ),
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
