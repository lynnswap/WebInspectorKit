import Foundation

package struct WebInspectorQueryRegistrationID: Hashable, Sendable {
    package let rawValue: UUID

    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

package struct _WebInspectorQueryRecord<
    Model: WebInspectorPersistentModel
>: Sendable {
    package let queryValue: Model.QueryValue
    package let canonicalRank: WebInspectorModelCanonicalRank

    package var id: Model.ID { queryValue.id }
}

package enum _WebInspectorQueryMutation<
    Model: WebInspectorPersistentModel
>: Sendable {
    case upsert(_WebInspectorQueryRecord<Model>)
    case updateContent(Model.ID)
    case delete(Model.ID)
}

package enum _WebInspectorQueryAttempt<Model>
where Model: WebInspectorPersistentModel {
    case pending
    case success(itemIDs: [Model.ID], disposition: SuccessDisposition)
    case failure(WebInspectorFetchError)

    package enum SuccessDisposition: Sendable {
        case initial
        case reset
    }
}

package struct _WebInspectorQueryDelivery<
    Model: WebInspectorPersistentModel
>: Sendable {
    package enum Kind: Sendable {
        case initial(itemIDs: [Model.ID])
        case changes(
            itemIDs: [Model.ID],
            difference: WebInspectorFetchedResultsDifference<Model.ID>
        )
        case reset(itemIDs: [Model.ID])
        case failure(WebInspectorFetchError)
    }

    package let registrationID: WebInspectorQueryRegistrationID
    package let kind: Kind
    package let clearsFetchError: Bool
}

private enum _WebInspectorQueryEvaluationDisposition: Equatable {
    case waitingForReadiness
    case featureUnsupported
    case deterministicFailure
}

private struct _WebInspectorAcceptedQuery<Model>
where Model: WebInspectorPersistentModel {
    var descriptor: WebInspectorFetchDescriptor<Model>
    var matchingItemIDs: [Model.ID]
    var itemIDs: [Model.ID]
}

private struct _WebInspectorQueryRegistration<Model>
where Model: WebInspectorPersistentModel {
    var accepted: _WebInspectorAcceptedQuery<Model>?
    var requestedDescriptor: WebInspectorFetchDescriptor<Model>
    var evaluationDisposition: _WebInspectorQueryEvaluationDisposition?
}

private final class _WebInspectorTypedQueryIndex<Model>
where Model: WebInspectorPersistentModel {
    let featureID: WebInspectorFeatureID
    var featureState: WebInspectorFeatureState
    var records: [Model.ID: _WebInspectorQueryRecord<Model>]
    var registrations: [WebInspectorQueryRegistrationID: _WebInspectorQueryRegistration<Model>] = [:]

    init(
        featureID: WebInspectorFeatureID,
        featureState: WebInspectorFeatureState,
        records: [Model.ID: _WebInspectorQueryRecord<Model>]
    ) {
        self.featureID = featureID
        self.featureState = featureState
        self.records = records
    }
}

/// Actor-owned, immutable-value query index shared by all registrations in
/// one model context. Observable model references never enter this actor.
package actor WebInspectorContextQueryIndex {
    #if DEBUG
        package struct PerformanceCounters: Equatable, Sendable {
            package var fullRangeMembershipRebuildCount = 0
            package var fullRangeMembershipRebuildMemberVisitCount = 0
        }

        private var performanceCounters = PerformanceCounters()

        package var performanceCountersForTesting: PerformanceCounters {
            performanceCounters
        }

        package func resetPerformanceCountersForTesting() {
            performanceCounters = PerformanceCounters()
        }
    #endif

    private var indexes: [ObjectIdentifier: Any] = [:]

    package init() {}

    package func replaceSource<Model>(
        for model: Model.Type,
        featureID: WebInspectorFeatureID,
        featureState: WebInspectorFeatureState,
        records: [_WebInspectorQueryRecord<Model>]
    ) -> [_WebInspectorQueryDelivery<Model>]
    where Model: WebInspectorPersistentModel {
        let index: _WebInspectorTypedQueryIndex<Model>
        if let existing = indexes[ObjectIdentifier(model)] {
            guard
                let typed = existing as? _WebInspectorTypedQueryIndex<Model>,
                typed.featureID == featureID
            else {
                return []
            }
            index = typed
        } else {
            index = _WebInspectorTypedQueryIndex(
                featureID: featureID,
                featureState: featureState,
                records: [:]
            )
            indexes[ObjectIdentifier(model)] = index
        }

        index.featureState = featureState
        index.records = Dictionary(
            uniqueKeysWithValues: records.map { ($0.id, $0) }
        )
        return reevaluateRegistrations(in: index)
    }

    package func updateFeatureState(
        _ state: WebInspectorFeatureState,
        for featureID: WebInspectorFeatureID
    ) -> [any _WebInspectorAnyQueryDelivery] {
        var deliveries: [any _WebInspectorAnyQueryDelivery] = []
        for index in indexes.values {
            guard
                let erased = index as? _WebInspectorAnyTypedQueryIndex,
                erased.featureID == featureID
            else {
                continue
            }
            deliveries.append(
                contentsOf: erased.updateFeatureState(
                    state,
                    owner: self
                )
            )
        }
        return deliveries
    }

    package func apply<Model>(
        _ mutations: [_WebInspectorQueryMutation<Model>]
    ) -> [_WebInspectorQueryDelivery<Model>]
    where Model: WebInspectorPersistentModel {
        guard
            let index = indexes[ObjectIdentifier(Model.self)]
                as? _WebInspectorTypedQueryIndex<Model>
        else {
            return []
        }

        var touchedItemIDs: Set<Model.ID> = []
        var originalCanonicalRanksByID:
            [Model.ID: WebInspectorModelCanonicalRank] = [:]
        for mutation in mutations {
            switch mutation {
            case let .upsert(record):
                if touchedItemIDs.insert(record.id).inserted,
                   let original = index.records[record.id] {
                    originalCanonicalRanksByID[record.id] =
                        original.canonicalRank
                }
                index.records[record.id] = record
            case let .updateContent(id):
                if touchedItemIDs.insert(id).inserted,
                   let original = index.records[id] {
                    originalCanonicalRanksByID[id] = original.canonicalRank
                }
            case let .delete(id):
                if touchedItemIDs.insert(id).inserted,
                   let original = index.records[id] {
                    originalCanonicalRanksByID[id] = original.canonicalRank
                }
                index.records[id] = nil
            }
        }

        guard case .ready = index.featureState else {
            return []
        }

        let stableFullRangeDifference = stableFullRangeDifference(
            mutations: mutations,
            touchedItemIDs: touchedItemIDs,
            originalCanonicalRanksByID: originalCanonicalRanksByID,
            records: index.records
        )
        var deliveries: [_WebInspectorQueryDelivery<Model>] = []
        for (registrationID, currentRegistration) in Array(index.registrations) {
            guard
                var accepted = currentRegistration.accepted
            else {
                continue
            }
            var registration = currentRegistration

            let oldItemIDs = accepted.itemIDs
            let isFullRange = isUnfilteredFullRange(accepted.descriptor)
            if isFullRange,
               let difference = stableFullRangeDifference {
                if !difference.isEmpty {
                    deliveries.append(
                        _WebInspectorQueryDelivery(
                            registrationID: registrationID,
                            kind: .changes(
                                itemIDs: oldItemIDs,
                                difference: difference
                            ),
                            clearsFetchError:
                                registration.evaluationDisposition == nil
                        )
                    )
                }
                continue
            }
            #if DEBUG
                if isFullRange {
                    performanceCounters.fullRangeMembershipRebuildCount += 1
                    performanceCounters
                        .fullRangeMembershipRebuildMemberVisitCount +=
                        accepted.matchingItemIDs.count
                }
            #endif
            do {
                var matchingItemIDs = accepted.matchingItemIDs
                var changedContentIDs: Set<Model.ID> = []
                for mutation in mutations {
                    let id: Model.ID
                    switch mutation {
                    case let .upsert(record):
                        id = record.id
                        matchingItemIDs.removeAll { $0 == id }
                        if try matches(
                            record.queryValue,
                            descriptor: accepted.descriptor,
                            model: Model.self
                        ) {
                            insert(
                                id,
                                into: &matchingItemIDs,
                                records: index.records,
                                descriptor: accepted.descriptor,
                                model: Model.self
                            )
                        }
                        if originalCanonicalRanksByID[id] != nil {
                            changedContentIDs.insert(id)
                        }
                    case let .updateContent(contentID):
                        id = contentID
                        changedContentIDs.insert(id)
                    case let .delete(deletedID):
                        id = deletedID
                        matchingItemIDs.removeAll { $0 == id }
                    }
                }

                let newItemIDs = try window(
                    matchingItemIDs,
                    descriptor: accepted.descriptor,
                    model: Model.self
                )
                let difference = webInspectorFetchedResultsDifference(
                    from: oldItemIDs,
                    to: newItemIDs,
                    updatedItemIDs: changedContentIDs
                )
                accepted.matchingItemIDs = matchingItemIDs
                accepted.itemIDs = newItemIDs
                registration.accepted = accepted
                index.registrations[registrationID] = registration
                if !difference.isEmpty {
                    deliveries.append(
                        _WebInspectorQueryDelivery(
                            registrationID: registrationID,
                            kind: .changes(
                                itemIDs: newItemIDs,
                                difference: difference
                            ),
                            clearsFetchError:
                                registration.evaluationDisposition == nil
                        )
                    )
                }
            } catch {
                registration.evaluationDisposition =
                    _WebInspectorQueryEvaluationDisposition.deterministicFailure
                index.registrations[registrationID] = registration
                deliveries.append(
                    _WebInspectorQueryDelivery(
                        registrationID: registrationID,
                        kind: .failure(predicateFailure(error)),
                        clearsFetchError: false
                    )
                )
            }
        }
        return deliveries
    }

    package func register<Model>(
        _ registrationID: WebInspectorQueryRegistrationID,
        descriptor: WebInspectorFetchDescriptor<Model>
    ) -> _WebInspectorQueryAttempt<Model>
    where Model: WebInspectorPersistentModel {
        guard
            let index = indexes[ObjectIdentifier(Model.self)]
                as? _WebInspectorTypedQueryIndex<Model>
        else {
            return .failure(
                .unsupportedModel(String(reflecting: Model.self))
            )
        }

        var registration = _WebInspectorQueryRegistration<Model>(
            accepted: nil,
            requestedDescriptor: descriptor,
            evaluationDisposition: nil
        )
        let attempt = evaluateRequested(
            registration: &registration,
            index: index,
            disposition: .initial
        )
        index.registrations[registrationID] = registration
        return attempt
    }

    package func refetch<Model>(
        _ registrationID: WebInspectorQueryRegistrationID,
        descriptor: WebInspectorFetchDescriptor<Model>
    ) -> _WebInspectorQueryAttempt<Model>
    where Model: WebInspectorPersistentModel {
        guard
            let index = indexes[ObjectIdentifier(Model.self)]
                as? _WebInspectorTypedQueryIndex<Model>,
            var registration = index.registrations[registrationID]
        else {
            return .failure(.contextClosed)
        }

        registration.requestedDescriptor = descriptor
        registration.evaluationDisposition = nil
        let disposition: _WebInspectorQueryAttempt<Model>.SuccessDisposition =
            registration.accepted == nil ? .initial : .reset
        let attempt = evaluateRequested(
            registration: &registration,
            index: index,
            disposition: disposition
        )
        index.registrations[registrationID] = registration
        return attempt
    }

    package func fetch<Model>(
        descriptor: WebInspectorFetchDescriptor<Model>
    ) -> Result<[Model.ID], WebInspectorFetchError>
    where Model: WebInspectorPersistentModel {
        guard
            let index = indexes[ObjectIdentifier(Model.self)]
                as? _WebInspectorTypedQueryIndex<Model>
        else {
            return .failure(
                .unsupportedModel(String(reflecting: Model.self))
            )
        }
        switch index.featureState {
        case .ready:
            break
        case let .unsupported(requirements):
            return .failure(
                .featureUnsupported(
                    index.featureID,
                    requirements: requirements
                )
            )
        case .disabled, .synchronizing:
            return .failure(.contextClosed)
        }
        do {
            return .success(
                try evaluate(descriptor: descriptor, records: index.records)
                    .itemIDs
            )
        } catch let error as WebInspectorFetchError {
            return .failure(error)
        } catch {
            return .failure(predicateFailure(error))
        }
    }

    package func remove<Model>(
        _ registrationID: WebInspectorQueryRegistrationID,
        model: Model.Type
    ) where Model: WebInspectorPersistentModel {
        let index =
            indexes[ObjectIdentifier(model)]
            as? _WebInspectorTypedQueryIndex<Model>
        index?.registrations[registrationID] = nil
    }

    package func removeAllRegistrations() {
        for index in indexes.values {
            (index as? _WebInspectorAnyTypedQueryIndex)?
                .removeAllRegistrations()
        }
    }

    fileprivate func reevaluateRegistrations<Model>(
        in index: _WebInspectorTypedQueryIndex<Model>
    ) -> [_WebInspectorQueryDelivery<Model>]
    where Model: WebInspectorPersistentModel {
        switch index.featureState {
        case let .unsupported(requirements):
            var deliveries: [_WebInspectorQueryDelivery<Model>] = []
            for (registrationID, currentRegistration) in Array(index.registrations) {
                guard currentRegistration.evaluationDisposition != .featureUnsupported else {
                    continue
                }
                var registration = currentRegistration
                registration.evaluationDisposition = .featureUnsupported
                index.registrations[registrationID] = registration
                deliveries.append(
                    _WebInspectorQueryDelivery(
                        registrationID: registrationID,
                        kind: .failure(
                            .featureUnsupported(
                                index.featureID,
                                requirements: requirements
                            )
                        ),
                        clearsFetchError: false
                )
                )
            }
            return deliveries
        case .disabled, .synchronizing:
            for (registrationID, currentRegistration) in Array(index.registrations) {
                var registration = currentRegistration
                if registration.evaluationDisposition != .deterministicFailure {
                    registration.evaluationDisposition = .waitingForReadiness
                    index.registrations[registrationID] = registration
                }
            }
            return []
        case .ready:
            break
        }

        var deliveries: [_WebInspectorQueryDelivery<Model>] = []
        for (registrationID, currentRegistration) in Array(index.registrations) {
            var registration = currentRegistration
            if registration.evaluationDisposition == .deterministicFailure {
                guard var accepted = registration.accepted else { continue }
                do {
                    let evaluation = try evaluate(
                        descriptor: accepted.descriptor,
                        records: index.records
                    )
                    accepted.matchingItemIDs = evaluation.matchingItemIDs
                    accepted.itemIDs = evaluation.itemIDs
                    registration.accepted = accepted
                    index.registrations[registrationID] = registration
                    deliveries.append(
                        _WebInspectorQueryDelivery(
                            registrationID: registrationID,
                            kind: .reset(itemIDs: evaluation.itemIDs),
                            clearsFetchError: false
                        )
                    )
                } catch {
                    index.registrations[registrationID] = registration
                }
                continue
            }
            let hadAcceptedResult = registration.accepted != nil
            let descriptor =
                registration.evaluationDisposition == nil
                ? registration.accepted?.descriptor
                    ?? registration.requestedDescriptor
                : registration.requestedDescriptor
            do {
                let evaluation = try evaluate(
                    descriptor: descriptor,
                    records: index.records
                )
                registration.accepted = _WebInspectorAcceptedQuery(
                    descriptor: descriptor,
                    matchingItemIDs: evaluation.matchingItemIDs,
                    itemIDs: evaluation.itemIDs
                )
                registration.requestedDescriptor = descriptor
                registration.evaluationDisposition = nil
                index.registrations[registrationID] = registration
                deliveries.append(
                    _WebInspectorQueryDelivery(
                        registrationID: registrationID,
                        kind: hadAcceptedResult
                            ? .reset(itemIDs: evaluation.itemIDs)
                            : .initial(itemIDs: evaluation.itemIDs),
                        clearsFetchError: true
                    )
                )
            } catch {
                registration.evaluationDisposition = .deterministicFailure
                index.registrations[registrationID] = registration
                deliveries.append(
                    _WebInspectorQueryDelivery(
                        registrationID: registrationID,
                        kind: .failure(normalizeFetchError(error)),
                        clearsFetchError: false
                    )
                )
            }
        }
        return deliveries
    }

    private func evaluateRequested<Model>(
        registration: inout _WebInspectorQueryRegistration<Model>,
        index: _WebInspectorTypedQueryIndex<Model>,
        disposition: _WebInspectorQueryAttempt<Model>.SuccessDisposition
    ) -> _WebInspectorQueryAttempt<Model>
    where Model: WebInspectorPersistentModel {
        switch index.featureState {
        case let .unsupported(requirements):
            registration.evaluationDisposition = .featureUnsupported
            return .failure(
                .featureUnsupported(
                    index.featureID,
                    requirements: requirements
                )
            )
        case .disabled, .synchronizing:
            registration.evaluationDisposition = .waitingForReadiness
            return .pending
        case .ready:
            break
        }
        do {
            let evaluation = try evaluate(
                descriptor: registration.requestedDescriptor,
                records: index.records
            )
            registration.accepted = _WebInspectorAcceptedQuery(
                descriptor: registration.requestedDescriptor,
                matchingItemIDs: evaluation.matchingItemIDs,
                itemIDs: evaluation.itemIDs
            )
            registration.evaluationDisposition = nil
            return .success(
                itemIDs: evaluation.itemIDs,
                disposition: disposition
            )
        } catch {
            registration.evaluationDisposition = .deterministicFailure
            return .failure(normalizeFetchError(error))
        }
    }

    private func evaluate<Model>(
        descriptor: WebInspectorFetchDescriptor<Model>,
        records: [Model.ID: _WebInspectorQueryRecord<Model>]
    ) throws -> (matchingItemIDs: [Model.ID], itemIDs: [Model.ID])
    where Model: WebInspectorPersistentModel {
        try validate(descriptor)
        var matchingRecords: [_WebInspectorQueryRecord<Model>] = []
        matchingRecords.reserveCapacity(records.count)
        for record in records.values
        where try matches(record.queryValue, descriptor: descriptor) {
            matchingRecords.append(record)
        }
        matchingRecords.sort {
            orderedBefore($0, $1, descriptor: descriptor)
        }
        let matchingItemIDs = matchingRecords.map(\.id)
        return (
            matchingItemIDs,
            try window(matchingItemIDs, descriptor: descriptor)
        )
    }

    private func matches<Model>(
        _ value: Model.QueryValue,
        descriptor: WebInspectorFetchDescriptor<Model>,
        model: Model.Type = Model.self
    ) throws -> Bool
    where Model: WebInspectorPersistentModel {
        guard let predicate = descriptor.predicate else {
            return true
        }
        do {
            return try predicate.evaluate(value)
        } catch {
            throw predicateFailure(error)
        }
    }

    private func orderedBefore<Model>(
        _ lhs: _WebInspectorQueryRecord<Model>,
        _ rhs: _WebInspectorQueryRecord<Model>,
        descriptor: WebInspectorFetchDescriptor<Model>
    ) -> Bool
    where Model: WebInspectorPersistentModel {
        for sortDescriptor in descriptor.sortBy {
            switch sortDescriptor.compare(lhs.queryValue, rhs.queryValue) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                continue
            }
        }
        return lhs.canonicalRank < rhs.canonicalRank
    }

    private func insert<Model>(
        _ id: Model.ID,
        into itemIDs: inout [Model.ID],
        records: [Model.ID: _WebInspectorQueryRecord<Model>],
        descriptor: WebInspectorFetchDescriptor<Model>,
        model: Model.Type = Model.self
    ) where Model: WebInspectorPersistentModel {
        guard let candidate = records[id] else { return }
        let index =
            itemIDs.firstIndex { existingID in
                guard let existing = records[existingID] else { return false }
                return orderedBefore(candidate, existing, descriptor: descriptor)
            } ?? itemIDs.endIndex
        itemIDs.insert(id, at: index)
    }

    private func window<Model>(
        _ matchingItemIDs: [Model.ID],
        descriptor: WebInspectorFetchDescriptor<Model>,
        model: Model.Type = Model.self
    ) throws -> [Model.ID]
    where Model: WebInspectorPersistentModel {
        try validate(descriptor)
        let offset = descriptor.fetchOffset ?? 0
        guard offset < matchingItemIDs.count else { return [] }
        let suffix = matchingItemIDs.dropFirst(offset)
        guard let limit = descriptor.fetchLimit else {
            return Array(suffix)
        }
        return Array(suffix.prefix(limit))
    }

    private func validate<Model>(
        _ descriptor: WebInspectorFetchDescriptor<Model>
    ) throws where Model: WebInspectorPersistentModel {
        if let limit = descriptor.fetchLimit, limit < 0 {
            throw WebInspectorFetchError.invalidLimit(limit)
        }
        if let offset = descriptor.fetchOffset, offset < 0 {
            throw WebInspectorFetchError.invalidOffset(offset)
        }
    }

    private func isUnfilteredFullRange<Model>(
        _ descriptor: WebInspectorFetchDescriptor<Model>
    ) -> Bool where Model: WebInspectorPersistentModel {
        descriptor.predicate == nil
            && descriptor.sortBy.isEmpty
            && (descriptor.fetchOffset ?? 0) == 0
            && descriptor.fetchLimit == nil
    }

    private func stableFullRangeDifference<Model>(
        mutations: [_WebInspectorQueryMutation<Model>],
        touchedItemIDs: Set<Model.ID>,
        originalCanonicalRanksByID:
            [Model.ID: WebInspectorModelCanonicalRank],
        records: [Model.ID: _WebInspectorQueryRecord<Model>]
    ) -> WebInspectorFetchedResultsDifference<Model.ID>?
    where Model: WebInspectorPersistentModel {
        // An unfiltered full-range query is ordered only by the store's unique
        // canonical rank, so same-rank replacements cannot change its result.
        guard touchedItemIDs.allSatisfy({ id in
            originalCanonicalRanksByID[id] == records[id]?.canonicalRank
        }) else {
            return nil
        }

        var updatedItemIDs: Set<Model.ID> = []
        for mutation in mutations {
            let id: Model.ID
            switch mutation {
            case let .upsert(record):
                id = record.id
            case let .updateContent(contentID):
                id = contentID
            case .delete:
                continue
            }
            if originalCanonicalRanksByID[id] != nil,
               records[id] != nil {
                updatedItemIDs.insert(id)
            }
        }
        return WebInspectorFetchedResultsDifference(
            updatedItemIDs: updatedItemIDs
        )
    }

    private func predicateFailure(_ error: any Error)
        -> WebInspectorFetchError
    {
        if let error = error as? WebInspectorFetchError {
            return error
        }
        return .predicateEvaluation(
            WebInspectorFailureDescription(
                code: "predicate-evaluation",
                phase: "query",
                message: String(describing: error)
            )
        )
    }

    private func normalizeFetchError(_ error: any Error)
        -> WebInspectorFetchError
    {
        (error as? WebInspectorFetchError) ?? predicateFailure(error)
    }
}

package protocol _WebInspectorAnyQueryDelivery: Sendable {
    func apply(to lifecycle: WebInspectorModelContextLifecycle)
}

package final class _WebInspectorTypedAnyQueryDelivery<
    Model: WebInspectorPersistentModel
>: _WebInspectorAnyQueryDelivery, @unchecked Sendable {
    private let delivery: _WebInspectorQueryDelivery<Model>

    package init(_ delivery: _WebInspectorQueryDelivery<Model>) {
        self.delivery = delivery
    }

    package func apply(
        to lifecycle: WebInspectorModelContextLifecycle
    ) {
        lifecycle.applyQueryDelivery(delivery)
    }
}

private protocol _WebInspectorAnyTypedQueryIndex: AnyObject {
    var featureID: WebInspectorFeatureID { get }
    func updateFeatureState(
        _ state: WebInspectorFeatureState,
        owner: isolated WebInspectorContextQueryIndex
    ) -> [any _WebInspectorAnyQueryDelivery]
    func removeAllRegistrations()
}

extension _WebInspectorTypedQueryIndex: _WebInspectorAnyTypedQueryIndex {
    fileprivate func updateFeatureState(
        _ state: WebInspectorFeatureState,
        owner: isolated WebInspectorContextQueryIndex
    ) -> [any _WebInspectorAnyQueryDelivery] {
        featureState = state
        return owner.reevaluateRegistrations(in: self)
            .map(_WebInspectorTypedAnyQueryDelivery.init)
    }

    fileprivate func removeAllRegistrations() {
        registrations.removeAll(keepingCapacity: false)
    }
}
