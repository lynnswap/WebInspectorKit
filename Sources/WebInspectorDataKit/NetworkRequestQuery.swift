import Foundation
import WebInspectorProxyKit

package struct NetworkRequestRecordInput: Hashable, Sendable {
    package var id: NetworkRequest.ID
    package var orderIndex: Int
    package var url: String
    package var method: String
    package var resourceTypeRawValue: String?
    package var mimeType: String?
    package var responseURL: String?
    package var responseHeaders: [String: String]
    package var statusCode: Int?
    package var statusText: String?
    package var searchableText: String
    package var requestSentTimestamp: Double?
    package var hasResponse: Bool

    package init(request: NetworkRequest, orderIndex: Int) {
        id = request.id
        self.orderIndex = orderIndex
        url = request.url
        method = request.method
        resourceTypeRawValue = request.resourceType?.rawValue
        mimeType = request.mimeType
        responseURL = request.responseURL
        responseHeaders = request.responseHeaders
        statusCode = request.statusCode
        statusText = request.statusText
        searchableText = request.searchableText
        requestSentTimestamp = request.requestSentTimestamp
        hasResponse = request.hasResponse
    }

    init(registration: NetworkRequestStore.Registration) {
        self.init(
            request: registration.request,
            orderIndex: registration.orderIndex
        )
    }
}

package struct NetworkRequestRecord: Hashable, Sendable {
    package var id: NetworkRequest.ID
    package var orderIndex: Int
    package var url: String
    package var method: String
    package var resourceTypeRawValue: String?
    package var mimeType: String?
    package var resourceCategory: NetworkRequest.ResourceCategory
    package var searchableText: String
    package var statusCode: Int?
    package var requestSentTimestamp: Double?

    package init(input: NetworkRequestRecordInput) {
        id = input.id
        orderIndex = input.orderIndex
        url = input.url
        method = input.method
        resourceTypeRawValue = input.resourceTypeRawValue
        mimeType = input.mimeType
        let resourceType = input.resourceTypeRawValue.map(Network.ResourceType.init(rawValue:))
        let effectiveMIMEType = NetworkRequest.effectiveMIMEType(
            mimeType: input.mimeType,
            headers: input.responseHeaders
        )
        let category = NetworkRequest.resourceCategory(
            resourceType: resourceType,
            mimeType: effectiveMIMEType,
            url: input.responseURL ?? input.url,
            hasResponse: input.hasResponse
        )
        resourceCategory = category
        searchableText = input.searchableText
        statusCode = input.statusCode
        requestSentTimestamp = input.requestSentTimestamp
    }

    package init(request: NetworkRequest, orderIndex: Int) {
        self.init(input: NetworkRequestRecordInput(request: request, orderIndex: orderIndex))
    }
}

package struct NetworkRequestQueryPlan: Sendable {
    package var filter: NetworkRequestQuery.Filter?
    package var sortComparators: [NetworkRequestRecordSortComparator]
    package var fetchLimit: Int?
    package var fetchOffset: Int

    package init(
        query: NetworkRequestQuery
    ) {
        filter = query.filter
        sortComparators = query.sortBy.map(NetworkRequestRecordSortComparator.init)
        fetchLimit = query.fetchLimitAsInt
        fetchOffset = query.fetchOffsetAsInt
    }

    package var requiresQuery: Bool {
        filter != nil || sortComparators.isEmpty == false || fetchLimit != nil || fetchOffset > 0
    }

    package func matches(record: NetworkRequestRecord) -> Bool {
        filter?.matches(record: record) ?? true
    }

    package func visibleIDs(from matchingIDs: [NetworkRequest.ID]) -> ArraySlice<NetworkRequest.ID> {
        let lowerBound = min(fetchOffset, matchingIDs.count)
        let remainingCount = matchingIDs.count - lowerBound
        let visibleCount = min(fetchLimit ?? remainingCount, remainingCount)
        let upperBound = lowerBound + visibleCount
        return matchingIDs[lowerBound..<upperBound]
    }

    package func ordersBefore(_ lhs: NetworkRequestRecord, _ rhs: NetworkRequestRecord) -> Bool {
        for comparator in sortComparators {
            switch comparator.compare(lhs, rhs) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                continue
            }
        }
        if sortComparators.first?.usesReverseOrder == true {
            return lhs.orderIndex > rhs.orderIndex
        }
        return lhs.orderIndex < rhs.orderIndex
    }
}

package struct NetworkRequestQueryState {
    package var plan: NetworkRequestQueryPlan
    private var recordsByID: [NetworkRequest.ID: NetworkRequestRecord]
    private var matchingIDs: [NetworkRequest.ID]

    package init(plan: NetworkRequestQueryPlan, requests: [NetworkRequest]) {
        self.plan = plan
        recordsByID = [:]
        recordsByID.reserveCapacity(requests.count)
        matchingIDs = []
        matchingIDs.reserveCapacity(requests.count)
        for (index, request) in requests.enumerated() {
            upsert(request: request, orderIndex: index)
        }
    }

    private mutating func upsert(request: NetworkRequest, orderIndex: Int) {
        let record = NetworkRequestRecord(request: request, orderIndex: orderIndex)
        recordsByID[record.id] = record
        matchingIDs.removeAll { $0 == record.id }
        guard plan.matches(record: record) else {
            return
        }
        insertMatchingID(record.id)
    }

    package func visibleRequests(
        lookup: (NetworkRequest.ID) -> NetworkRequest
    ) -> [NetworkRequest] {
        plan.visibleIDs(from: matchingIDs).map(lookup)
    }

    private mutating func insertMatchingID(_ id: NetworkRequest.ID) {
        guard let record = recordsByID[id] else {
            preconditionFailure("Network query membership must reference an owned record.")
        }
        var lowerBound = 0
        var upperBound = matchingIDs.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            guard let midpointRecord = recordsByID[matchingIDs[midpoint]] else {
                preconditionFailure("Network query membership must reference an owned record.")
            }
            if plan.ordersBefore(midpointRecord, record) {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        matchingIDs.insert(id, at: lowerBound)
    }
}

package struct NetworkRequestRecordSortComparator: Sendable {
    private enum Key: Sendable {
        case requestSentTimestamp
    }

    private var key: Key
    private var order: SortOrder

    fileprivate init(_ sort: NetworkRequestQuery.Sort) {
        switch sort.storage {
        case let .requestSentTimestamp(order):
            key = .requestSentTimestamp
            self.order = order
        }
    }

    fileprivate func compare(
        _ lhs: NetworkRequestRecord,
        _ rhs: NetworkRequestRecord
    ) -> ComparisonResult {
        let result: ComparisonResult
        switch key {
        case .requestSentTimestamp:
            result = compareOptional(lhs.requestSentTimestamp, rhs.requestSentTimestamp)
        }
        switch order {
        case .forward:
            return result
        case .reverse:
            return result.reversed
        }
    }

    fileprivate var usesReverseOrder: Bool {
        order == .reverse
    }

    private func compareOptional<Value: Comparable>(
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

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending:
            return .orderedDescending
        case .orderedDescending:
            return .orderedAscending
        case .orderedSame:
            return .orderedSame
        }
    }
}

extension NetworkRequestQuery.Filter {
    func matches(record: NetworkRequestRecord) -> Bool {
        switch storage {
        case let .method(method):
            return record.method == method
        case let .methodContains(text):
            return record.method.localizedStandardContains(text)
        case let .urlEquals(url):
            return record.url == url
        case let .urlContains(text):
            return record.url.localizedStandardContains(text)
        case let .searchableTextEquals(text):
            return record.searchableText == text
        case let .searchableTextContains(text):
            return record.searchableText.localizedStandardContains(text)
        case let .mimeType(mimeType):
            return record.mimeType == mimeType
        case let .resourceCategories(categories):
            return categories.contains(record.resourceCategory)
        case let .statusCode(comparison, missingValue):
            let statusCode = record.statusCode ?? missingValue
            switch comparison {
            case let .lessThan(value): return statusCode < value
            case let .atMost(value): return statusCode <= value
            case let .greaterThan(value): return statusCode > value
            case let .atLeast(value): return statusCode >= value
            }
        case let .all(filters):
            return filters.allSatisfy { $0.matches(record: record) }
        case let .any(filters):
            return filters.contains { $0.matches(record: record) }
        }
    }

}
