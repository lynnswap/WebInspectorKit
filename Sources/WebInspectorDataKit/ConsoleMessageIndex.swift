import Foundation

package struct ConsoleResultSetDelta: Sendable {
    package var sequence: UInt64
    package var snapshot: WebInspectorFetchedResultsSnapshot<ConsoleMessage.ID>
    package var transaction: WebInspectorFetchedResultsTransaction<ConsoleMessage.ID>
    package var reconfigureItemIDs: Set<ConsoleMessage.ID>
}

/// Owns compact Console query records away from the model-context actor.
package actor ConsoleMessageIndex {
    private enum Mutation {
        case replace([ConsoleMessageRecordInput])
        case upsert(ConsoleMessageRecordInput)
    }

    private struct PendingMutation {
        var mutation: Mutation
        var continuation: CheckedContinuation<Void, Never>
    }

    private var recordsByID: [ConsoleMessage.ID: ConsoleMessageRecord] = [:]
    private var orderedIDs: [ConsoleMessage.ID] = []
    private var lastUpdatedSequenceByID: [ConsoleMessage.ID: UInt64] = [:]
    private var lastAppliedSequence: UInt64 = 0
    private var pendingMutationsBySequence: [UInt64: PendingMutation] = [:]

    package init() {}

    package func replace(with inputs: [ConsoleMessageRecordInput], sequence: UInt64) async {
        await enqueue(.replace(inputs), sequence: sequence)
    }

    package func upsert(_ input: ConsoleMessageRecordInput, sequence: UInt64) async {
        await enqueue(.upsert(input), sequence: sequence)
    }

    private func enqueue(_ mutation: Mutation, sequence: UInt64) async {
        precondition(
            sequence > lastAppliedSequence,
            "ConsoleMessageIndex received an already-applied mutation sequence."
        )
        precondition(
            pendingMutationsBySequence[sequence] == nil,
            "ConsoleMessageIndex received a duplicate mutation sequence."
        )
        await withCheckedContinuation { continuation in
            pendingMutationsBySequence[sequence] = PendingMutation(
                mutation: mutation,
                continuation: continuation
            )
            drainContiguousMutations()
        }
    }

    private func drainContiguousMutations() {
        while lastAppliedSequence < UInt64.max {
            let sequence = lastAppliedSequence + 1
            guard let pending = pendingMutationsBySequence.removeValue(forKey: sequence) else {
                return
            }
            apply(pending.mutation, sequence: sequence)
            lastAppliedSequence = sequence
            pending.continuation.resume()
        }
        precondition(
            pendingMutationsBySequence.isEmpty,
            "ConsoleMessageIndex mutation sequence overflowed."
        )
    }

    private func apply(_ mutation: Mutation, sequence: UInt64) {
        switch mutation {
        case let .replace(inputs):
            recordsByID = [:]
            recordsByID.reserveCapacity(inputs.count)
            orderedIDs = []
            orderedIDs.reserveCapacity(inputs.count)
            lastUpdatedSequenceByID = [:]
            lastUpdatedSequenceByID.reserveCapacity(inputs.count)
            for input in inputs {
                upsertRecord(input, sequence: sequence)
            }
        case let .upsert(input):
            upsertRecord(input, sequence: sequence)
        }
    }

    private func upsertRecord(_ input: ConsoleMessageRecordInput, sequence: UInt64) {
        let isNewRecord = recordsByID[input.id] == nil
        let record = ConsoleMessageRecord(input: input)
        recordsByID[record.id] = record
        lastUpdatedSequenceByID[record.id] = sequence
        if isNewRecord {
            orderedIDs.append(record.id)
        }
    }

    package func delta(
        plan: ConsoleMessageQueryPlan,
        sectionBy: WebInspectorSectionDescriptor<ConsoleMessage>?,
        oldSnapshot: WebInspectorFetchedResultsSnapshot<ConsoleMessage.ID>,
        changedSince sequence: UInt64
    ) -> ConsoleResultSetDelta {
        precondition(plan.requiresModelPredicate == false)
        let indexSequence = lastAppliedSequence
        let newSnapshot = snapshot(plan: plan, sectionBy: sectionBy)
        let oldItemIDs = Set(oldSnapshot.itemIDs)
        let updatedItemIDs = Set(newSnapshot.itemIDs.filter { id in
            oldItemIDs.contains(id) && lastUpdatedSequenceByID[id, default: 0] > sequence
        })
        let transaction = WebInspectorFetchedResultsTransaction(
            oldSnapshot: oldSnapshot,
            newSnapshot: newSnapshot,
            updatedItemIDs: updatedItemIDs
        )
        return ConsoleResultSetDelta(
            sequence: indexSequence,
            snapshot: newSnapshot,
            transaction: transaction,
            reconfigureItemIDs: updatedItemIDs
        )
    }

#if DEBUG
    package func isMutationPendingForTesting(sequence: UInt64) -> Bool {
        pendingMutationsBySequence[sequence] != nil
    }
#endif

    private func snapshot(
        plan: ConsoleMessageQueryPlan,
        sectionBy: WebInspectorSectionDescriptor<ConsoleMessage>?
    ) -> WebInspectorFetchedResultsSnapshot<ConsoleMessage.ID> {
        let matchingRecords = visibleRecords(plan: plan)
        guard matchingRecords.isEmpty == false else {
            return WebInspectorFetchedResultsSnapshot()
        }
        guard let sectionBy else {
            return WebInspectorFetchedResultsSnapshot(itemIDs: matchingRecords.map(\.id))
        }

        var sections: [(
            id: WebInspectorFetchSectionID,
            title: String?,
            itemIDs: [ConsoleMessage.ID]
        )] = []
        for record in matchingRecords {
            let identity = sectionIdentity(for: record, sectionBy: sectionBy)
            if let index = sections.firstIndex(where: { $0.id == identity.id }) {
                sections[index].itemIDs.append(record.id)
            } else {
                sections.append((
                    id: identity.id,
                    title: identity.title,
                    itemIDs: [record.id]
                ))
            }
        }
        return WebInspectorFetchedResultsSnapshot(sections: sections.map { section in
            WebInspectorFetchedResultsSnapshot.Section(
                id: section.id,
                title: section.title,
                itemIDs: section.itemIDs
            )
        })
    }

    private func visibleRecords(plan: ConsoleMessageQueryPlan) -> [ConsoleMessageRecord] {
        var records: [ConsoleMessageRecord] = []
        records.reserveCapacity(orderedIDs.count)
        for id in orderedIDs {
            guard let record = recordsByID[id] else {
                continue
            }
            guard plan.matches(record: record) == true else {
                continue
            }
            records.append(record)
        }

        if plan.sortComparators.isEmpty == false {
            records.sort { lhs, rhs in
                plan.ordersBefore(lhs, rhs)
            }
        }

        let lowerBound = min(plan.fetchOffset, records.count)
        let upperBound: Int
        if let fetchLimit = plan.fetchLimit {
            upperBound = min(lowerBound + fetchLimit, records.count)
        } else {
            upperBound = records.count
        }
        return Array(records[lowerBound..<upperBound])
    }

    private func sectionIdentity(
        for record: ConsoleMessageRecord,
        sectionBy: WebInspectorSectionDescriptor<ConsoleMessage>
    ) -> (id: WebInspectorFetchSectionID, title: String?) {
        let value: String?
        switch sectionBy.key {
        case .consoleSource:
            value = record.sourceRawValue
        case .consoleLevel:
            value = record.levelRawValue
        case .consoleKind:
            value = record.kindRawValue
        case .consoleURL:
            value = record.url
        case .networkMethod,
             .networkResourceType,
             .networkResourceCategory,
             .networkMIMEType:
            preconditionFailure("Network section descriptors cannot be applied to ConsoleMessage results.")
        }

        let title = value ?? ""
        return (WebInspectorFetchSectionID(rawValue: title), title)
    }
}
