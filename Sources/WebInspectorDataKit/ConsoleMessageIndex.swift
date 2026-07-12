import Foundation

package enum ConsoleMessageQueryDomain: WebInspectorIndexedQueryDomain {
    package typealias ItemID = ConsoleMessage.ID
    package typealias Input = ConsoleMessageRecordInput
    package typealias Record = ConsoleMessageRecord
    package typealias Query = ConsoleQuery

    package static func makeRecord(from input: Input) -> Record {
        ConsoleMessageRecord(input: input)
    }

    package static func matches(_ record: Record, query: Query) -> Bool {
        query.levels.isEmpty || query.levels.contains { level in
            level.rawValue == record.levelRawValue
        }
    }

    package static func ordersBefore(
        _ lhs: Record,
        _ rhs: Record,
        query: Query
    ) -> Bool {
        switch query.sort {
        case .insertionAscending:
            return lhs.orderIndex < rhs.orderIndex
        case .insertionDescending:
            return lhs.orderIndex > rhs.orderIndex
        }
    }

    package static func mutationImpact(
        previous: Record?,
        current: Record,
        query: Query
    ) -> WebInspectorIndexedQueryMutationImpact {
        guard let previous else {
            return .topology
        }
        guard previous != current else {
            return .contentOnly
        }

        let previouslyMatched = matches(previous, query: query)
        let currentlyMatches = matches(current, query: query)
        guard previouslyMatched == currentlyMatches else {
            return .topology
        }
        guard previouslyMatched else {
            return .contentOnly
        }
        if previous.orderIndex != current.orderIndex {
            return .topology
        }
        if query.section == .level,
           previous.levelRawValue != current.levelRawValue {
            return .topology
        }
        return .contentOnly
    }

    package static func makeSnapshot(
        allItemIDsInSourceOrder _: [ItemID],
        matchingItemIDs: [ItemID],
        recordsByID: [ItemID: Record],
        query: Query
    ) -> WebInspectorFetchedResultsSnapshot<ItemID> {
        let lowerBound = min(query.offset, matchingItemIDs.count)
        let upperBound: Int
        if let limit = query.limit {
            upperBound = min(lowerBound + limit, matchingItemIDs.count)
        } else {
            upperBound = matchingItemIDs.count
        }
        let visibleIDs = Array(matchingItemIDs[lowerBound..<upperBound])
        guard visibleIDs.isEmpty == false else {
            return WebInspectorFetchedResultsSnapshot()
        }
        guard query.section == .level else {
            return WebInspectorFetchedResultsSnapshot(itemIDs: visibleIDs)
        }
        var sections: [(id: WebInspectorFetchSectionID, itemIDs: [ItemID])] = []
        for id in visibleIDs {
            guard let level = recordsByID[id]?.levelRawValue else {
                preconditionFailure("ConsoleMessageQueryDomain lost a visible record while sectioning a query.")
            }
            let sectionID = WebInspectorFetchSectionID(rawValue: level)
            if let index = sections.firstIndex(where: { $0.id == sectionID }) {
                sections[index].itemIDs.append(id)
            } else {
                sections.append((sectionID, [id]))
            }
        }
        return WebInspectorFetchedResultsSnapshot(sections: sections.map { section in
            WebInspectorFetchedResultsSnapshot.Section(
                id: section.id,
                title: section.id.rawValue,
                itemIDs: section.itemIDs
            )
        })
    }
}

package typealias ConsoleMessageIndex = WebInspectorQueryIndex<ConsoleMessageQueryDomain>
