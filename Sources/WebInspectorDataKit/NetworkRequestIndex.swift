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
        switch query.sort {
        case .requestTimeAscending:
            return NetworkRequestChronologyKey.ordersBefore(
                lhs.chronologyKey,
                rhs.chronologyKey
            )
        case .requestTimeDescending:
            return NetworkRequestChronologyKey.ordersBefore(
                rhs.chronologyKey,
                lhs.chronologyKey
            )
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

        switch query.section {
        case .initiatorNode:
            guard previous.groupID == current.groupID,
                  previous.chronologyKey == current.chronologyKey else {
                return .topology
            }
        case .method:
            if previouslyMatched,
               previous.method != current.method {
                return .topology
            }
            if previouslyMatched,
               previous.chronologyKey != current.chronologyKey {
                return .topology
            }
        case nil:
            if previouslyMatched,
               previous.chronologyKey != current.chronologyKey {
                return .topology
            }
        }
        return .contentOnly
    }

    package static func makeSnapshot(
        allItemIDsInSourceOrder: [ItemID],
        matchingItemIDs: [ItemID],
        recordsByID: [ItemID: Record],
        query: Query
    ) -> WebInspectorFetchedResultsSnapshot<ItemID, WebInspectorFetchSectionID> {
        if query.section == .initiatorNode {
            return makeInitiatorNodeSnapshot(
                allItemIDsInSourceOrder: allItemIDsInSourceOrder,
                matchingItemIDs: matchingItemIDs,
                recordsByID: recordsByID,
                query: query
            )
        }
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
                name: section.id,
                title: section.id.rawValue,
                itemIDs: section.itemIDs
            )
        })
    }

    private struct InitiatorGroup {
        var id: WebInspectorFetchSectionID
        var itemIDs: [ItemID]
    }

    private static func makeInitiatorNodeSnapshot(
        allItemIDsInSourceOrder: [ItemID],
        matchingItemIDs: [ItemID],
        recordsByID: [ItemID: Record],
        query: Query
    ) -> WebInspectorFetchedResultsSnapshot<ItemID, WebInspectorFetchSectionID> {
        let matchingGroupIDs = Set(matchingItemIDs.map { id in
            guard let record = recordsByID[id] else {
                preconditionFailure(
                    "NetworkRequestQueryDomain lost a matching record while grouping a query."
                )
            }
            return record.groupID
        })
        guard matchingGroupIDs.isEmpty == false else {
            return WebInspectorFetchedResultsSnapshot()
        }

        var itemIDsByGroupID: [WebInspectorFetchSectionID: [ItemID]] = [:]
        itemIDsByGroupID.reserveCapacity(matchingGroupIDs.count)
        for id in allItemIDsInSourceOrder {
            guard let record = recordsByID[id] else {
                preconditionFailure(
                    "NetworkRequestQueryDomain lost an ordered record while grouping a query."
                )
            }
            guard matchingGroupIDs.contains(record.groupID) else {
                continue
            }
            itemIDsByGroupID[record.groupID, default: []].append(id)
        }

        var groups = itemIDsByGroupID.map { groupID, itemIDs in
            InitiatorGroup(
                id: groupID,
                itemIDs: itemIDs.sorted { lhsID, rhsID in
                    guard let lhs = recordsByID[lhsID], let rhs = recordsByID[rhsID] else {
                        preconditionFailure(
                            "NetworkRequestQueryDomain lost a group member while ordering a query."
                        )
                    }
                    return NetworkRequestChronologyKey.ordersBefore(
                        lhs.chronologyKey,
                        rhs.chronologyKey
                    )
                }
            )
        }
        groups.sort { lhsGroup, rhsGroup in
            guard let lhsID = lhsGroup.itemIDs.first,
                  let rhsID = rhsGroup.itemIDs.first,
                  let lhs = recordsByID[lhsID],
                  let rhs = recordsByID[rhsID] else {
                preconditionFailure(
                    "NetworkRequestQueryDomain created an empty initiator group."
                )
            }
            return ordersBefore(lhs, rhs, query: query)
        }

        let lowerBound = min(query.offset, groups.count)
        let upperBound: Int
        if let limit = query.limit {
            upperBound = min(lowerBound + limit, groups.count)
        } else {
            upperBound = groups.count
        }
        return WebInspectorFetchedResultsSnapshot(sections: groups[lowerBound..<upperBound].map {
            WebInspectorFetchedResultsSnapshot.Section(
                name: $0.id,
                title: nil,
                itemIDs: $0.itemIDs
            )
        })
    }
}

package typealias NetworkRequestIndex = WebInspectorQueryIndex<NetworkRequestQueryDomain>
