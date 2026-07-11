import Foundation

package enum NetworkRequestQueryDomain: WebInspectorIndexedQueryDomain {
    package typealias ItemID = NetworkRequest.ID
    package typealias Input = NetworkRequestRecordInput
    package typealias Record = NetworkRequestRecord
    package typealias Query = NetworkQuery

    package static func makeRecord(from input: Input) -> Record {
        NetworkRequestRecord(input: input)
    }

    package static func matches(_ record: Record, query: Query) -> Bool {
        if let search = query.search,
           record.searchableText.localizedStandardContains(search) == false {
            return false
        }
        if query.resourceCategories.isEmpty == false,
           query.resourceCategories.contains(record.resourceCategory) == false {
            return false
        }
        if query.methods.isEmpty == false,
           query.methods.contains(record.method) == false {
            return false
        }
        return true
    }

    package static func ordersBefore(
        _ lhs: Record,
        _ rhs: Record,
        query: Query
    ) -> Bool {
        let timestampOrder = compareOptional(lhs.requestSentTimestamp, rhs.requestSentTimestamp)
        switch (query.sort, timestampOrder) {
        case (.requestTimeAscending, .orderedAscending),
             (.requestTimeDescending, .orderedDescending):
            return true
        case (.requestTimeAscending, .orderedDescending),
             (.requestTimeDescending, .orderedAscending):
            return false
        case (_, .orderedSame):
            switch query.sort {
            case .requestTimeAscending:
                return lhs.orderIndex < rhs.orderIndex
            case .requestTimeDescending:
                return lhs.orderIndex > rhs.orderIndex
            }
        }
    }

    package static func makeSnapshot(
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
        guard query.section == .method else {
            return WebInspectorFetchedResultsSnapshot(itemIDs: visibleIDs)
        }
        var sections: [(id: WebInspectorFetchSectionID, itemIDs: [ItemID])] = []
        for id in visibleIDs {
            guard let method = recordsByID[id]?.method else {
                preconditionFailure("NetworkRequestQueryDomain lost a visible record while sectioning a query.")
            }
            let sectionID = WebInspectorFetchSectionID(rawValue: method)
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

    private static func compareOptional<Value: Comparable>(
        _ lhs: Value?,
        _ rhs: Value?
    ) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil):
            return .orderedSame
        case (nil, _):
            return .orderedAscending
        case (_, nil):
            return .orderedDescending
        case let (lhs?, rhs?):
            if lhs < rhs {
                return .orderedAscending
            }
            if lhs > rhs {
                return .orderedDescending
            }
            return .orderedSame
        }
    }
}

package typealias NetworkRequestIndex = WebInspectorQueryIndex<NetworkRequestQueryDomain>
