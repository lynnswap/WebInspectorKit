import Foundation
import WebInspectorProxyKit

package struct NetworkRequestRecord: Hashable, Sendable {
    package var id: NetworkRequest.ID
    package var orderIndex: Int
    package var url: String
    package var method: String
    package var resourceCategory: NetworkRequest.ResourceCategory
    package var searchableText: String
    package var statusCode: Int?
    package var requestSentTimestamp: Double?

    package init(request: NetworkRequest, orderIndex: Int) {
        id = request.id
        self.orderIndex = orderIndex
        url = request.url
        method = request.method
        resourceCategory = request.resourceCategory
        searchableText = request.searchableText
        statusCode = request.statusCode
        requestSentTimestamp = request.requestSentTimestamp
    }
}

package struct NetworkRequestQueryPlan: Sendable {
    package typealias Predicate = @Sendable (NetworkRequestRecord) -> Bool

    package var predicate: Predicate?
    package var sortComparators: [NetworkRequestRecordSortComparator]
    package var fetchLimit: Int?
    package var fetchOffset: Int

    package init(
        descriptor: WebInspectorFetchDescriptor<NetworkRequest>,
        context: WebInspectorContext
    ) {
        predicate = descriptor.predicate.map(makeNetworkRequestRecordPredicate)
        sortComparators = descriptor.sortBy.map {
            NetworkRequestRecordSortComparator(descriptor: $0, context: context)
        }
        fetchLimit = descriptor.fetchLimit
        fetchOffset = descriptor.fetchOffset
    }

    package var requiresQuery: Bool {
        predicate != nil || sortComparators.isEmpty == false || fetchLimit != nil || fetchOffset > 0
    }

    package func matches(_ record: NetworkRequestRecord) -> Bool {
        predicate?(record) ?? true
    }

    package func visibleIDs(from matchingIDs: [NetworkRequest.ID]) -> ArraySlice<NetworkRequest.ID> {
        let lowerBound = min(fetchOffset, matchingIDs.count)
        let upperBound: Int
        if let fetchLimit {
            upperBound = min(lowerBound + fetchLimit, matchingIDs.count)
        } else {
            upperBound = matchingIDs.count
        }
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
            upsert(NetworkRequestRecord(request: request, orderIndex: index))
        }
    }

    package mutating func upsert(_ record: NetworkRequestRecord) {
        recordsByID[record.id] = record
        matchingIDs.removeAll { $0 == record.id }
        guard plan.matches(record) else {
            return
        }
        insertMatchingID(record.id)
    }

    package mutating func upsert(request: NetworkRequest) {
        let orderIndex = recordsByID[request.id]?.orderIndex ?? recordsByID.count
        upsert(NetworkRequestRecord(request: request, orderIndex: orderIndex))
    }

    package func visibleRequests(
        lookup: (NetworkRequest.ID) -> NetworkRequest?
    ) -> [NetworkRequest] {
        plan.visibleIDs(from: matchingIDs).compactMap(lookup)
    }

    private mutating func insertMatchingID(_ id: NetworkRequest.ID) {
        guard let record = recordsByID[id] else {
            return
        }
        var lowerBound = 0
        var upperBound = matchingIDs.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            guard let midpointRecord = recordsByID[matchingIDs[midpoint]] else {
                lowerBound = midpoint + 1
                continue
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

    fileprivate init(
        descriptor: SortDescriptor<NetworkRequest>,
        context: WebInspectorContext
    ) {
        guard let key = Self.key(for: descriptor, context: context) else {
            preconditionFailure("Unsupported NetworkRequest sort descriptor: \(descriptor)")
        }
        self.key = key
        order = descriptor.order
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

    private static func key(
        for descriptor: SortDescriptor<NetworkRequest>,
        context: WebInspectorContext
    ) -> Key? {
        let timestampPair = sentinelPair(
            lhsTimestamp: 1,
            rhsTimestamp: 2,
            context: context
        )
        if descriptor.compare(timestampPair.lhs, timestampPair.rhs) != .orderedSame {
            return .requestSentTimestamp
        }
        return nil
    }

    private static func sentinelPair(
        lhsTimestamp: Double,
        rhsTimestamp: Double,
        context: WebInspectorContext
    ) -> (lhs: NetworkRequest, rhs: NetworkRequest) {
        (
            lhs: NetworkRequest(
                request: Network.Request(
                    id: Network.Request.ID("__sort-lhs"),
                    url: "https://example.test/resource",
                    method: "GET"
                ),
                resourceType: .fetch,
                timestamp: lhsTimestamp,
                modelContext: context
            ),
            rhs: NetworkRequest(
                request: Network.Request(
                    id: Network.Request.ID("__sort-rhs"),
                    url: "https://example.test/resource",
                    method: "GET"
                ),
                resourceType: .fetch,
                timestamp: rhsTimestamp,
                modelContext: context
            )
        )
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

private protocol NetworkRequestRecordPredicateExpression {
    func networkRequestRecordPredicate() -> NetworkRequestQueryPlan.Predicate
}

private protocol NetworkRequestRecordStringExpression {
    func networkRequestStringExpression() -> @Sendable (NetworkRequestRecord) -> String
}

private protocol NetworkRequestRecordIntExpression {
    func networkRequestIntExpression() -> @Sendable (NetworkRequestRecord) -> Int
}

private protocol NetworkRequestRecordOptionalIntExpression {
    func networkRequestOptionalIntExpression() -> @Sendable (NetworkRequestRecord) -> Int?
}

private protocol NetworkRequestRecordResourceCategoryExpression {
    func networkRequestResourceCategoryExpression() -> @Sendable (NetworkRequestRecord) -> NetworkRequest.ResourceCategory
}

private protocol NetworkRequestRecordResourceCategorySequenceExpression {
    func networkRequestResourceCategorySequenceExpression() -> [NetworkRequest.ResourceCategory]
}

private enum NetworkRequestRecordPredicateValue: Equatable, Sendable {
    case string(String)
    case resourceCategory(NetworkRequest.ResourceCategory)
}

private protocol NetworkRequestRecordEquatableExpression {
    func networkRequestEquatableExpression() -> @Sendable (NetworkRequestRecord) -> NetworkRequestRecordPredicateValue
}

private func makeNetworkRequestRecordPredicate(
    _ predicate: Predicate<NetworkRequest>
) -> NetworkRequestQueryPlan.Predicate {
    guard let expression = predicate.expression as? any NetworkRequestRecordPredicateExpression else {
        preconditionFailure("Unsupported NetworkRequest predicate expression: \(type(of: predicate.expression))")
    }
    return expression.networkRequestRecordPredicate()
}

extension PredicateExpressions.Conjunction: NetworkRequestRecordPredicateExpression
    where LHS: NetworkRequestRecordPredicateExpression, RHS: NetworkRequestRecordPredicateExpression
{
    fileprivate func networkRequestRecordPredicate() -> NetworkRequestQueryPlan.Predicate {
        let lhsPredicate = lhs.networkRequestRecordPredicate()
        let rhsPredicate = rhs.networkRequestRecordPredicate()
        return { record in
            lhsPredicate(record) && rhsPredicate(record)
        }
    }
}

extension PredicateExpressions.Disjunction: NetworkRequestRecordPredicateExpression
    where LHS: NetworkRequestRecordPredicateExpression, RHS: NetworkRequestRecordPredicateExpression
{
    fileprivate func networkRequestRecordPredicate() -> NetworkRequestQueryPlan.Predicate {
        let lhsPredicate = lhs.networkRequestRecordPredicate()
        let rhsPredicate = rhs.networkRequestRecordPredicate()
        return { record in
            lhsPredicate(record) || rhsPredicate(record)
        }
    }
}

extension PredicateExpressions.Equal: NetworkRequestRecordPredicateExpression
    where LHS: NetworkRequestRecordEquatableExpression, RHS: NetworkRequestRecordEquatableExpression
{
    fileprivate func networkRequestRecordPredicate() -> NetworkRequestQueryPlan.Predicate {
        let lhsExpression = lhs.networkRequestEquatableExpression()
        let rhsExpression = rhs.networkRequestEquatableExpression()
        return { record in
            lhsExpression(record) == rhsExpression(record)
        }
    }
}

extension PredicateExpressions.StringLocalizedStandardContains: NetworkRequestRecordPredicateExpression
    where Root: NetworkRequestRecordStringExpression, Other: NetworkRequestRecordStringExpression
{
    fileprivate func networkRequestRecordPredicate() -> NetworkRequestQueryPlan.Predicate {
        let rootExpression = root.networkRequestStringExpression()
        let otherExpression = other.networkRequestStringExpression()
        return { record in
            rootExpression(record).localizedStandardContains(otherExpression(record))
        }
    }
}

extension PredicateExpressions.SequenceContains: NetworkRequestRecordPredicateExpression
    where LHS: NetworkRequestRecordResourceCategorySequenceExpression,
          RHS: NetworkRequestRecordResourceCategoryExpression
{
    fileprivate func networkRequestRecordPredicate() -> NetworkRequestQueryPlan.Predicate {
        let categories = Set(sequence.networkRequestResourceCategorySequenceExpression())
        let elementExpression = element.networkRequestResourceCategoryExpression()
        return { record in
            categories.contains(elementExpression(record))
        }
    }
}

extension PredicateExpressions.Comparison: NetworkRequestRecordPredicateExpression
    where LHS: NetworkRequestRecordIntExpression, RHS: NetworkRequestRecordIntExpression
{
    fileprivate func networkRequestRecordPredicate() -> NetworkRequestQueryPlan.Predicate {
        let lhsExpression = lhs.networkRequestIntExpression()
        let rhsExpression = rhs.networkRequestIntExpression()
        let op = op
        return { record in
            let lhs = lhsExpression(record)
            let rhs = rhsExpression(record)
            switch op {
            case .lessThan:
                return lhs < rhs
            case .lessThanOrEqual:
                return lhs <= rhs
            case .greaterThan:
                return lhs > rhs
            case .greaterThanOrEqual:
                return lhs >= rhs
            @unknown default:
                preconditionFailure("Unsupported NetworkRequest comparison operator: \(op)")
            }
        }
    }
}

extension PredicateExpressions.NilCoalesce: NetworkRequestRecordIntExpression
    where LHS: NetworkRequestRecordOptionalIntExpression, RHS: NetworkRequestRecordIntExpression
{
    fileprivate func networkRequestIntExpression() -> @Sendable (NetworkRequestRecord) -> Int {
        let lhsExpression = lhs.networkRequestOptionalIntExpression()
        let rhsExpression = rhs.networkRequestIntExpression()
        return { record in
            lhsExpression(record) ?? rhsExpression(record)
        }
    }
}

extension PredicateExpressions.KeyPath: NetworkRequestRecordStringExpression
    where Root == PredicateExpressions.Variable<NetworkRequest>, Output == String
{
    fileprivate func networkRequestStringExpression() -> @Sendable (NetworkRequestRecord) -> String {
        if keyPath == \NetworkRequest.method {
            return { $0.method }
        }
        if keyPath == \NetworkRequest.searchableText {
            return { $0.searchableText }
        }
        preconditionFailure("Unsupported NetworkRequest string predicate key path: \(keyPath)")
    }
}

extension PredicateExpressions.KeyPath: NetworkRequestRecordEquatableExpression
    where Root == PredicateExpressions.Variable<NetworkRequest>
{
    fileprivate func networkRequestEquatableExpression() -> @Sendable (NetworkRequestRecord) -> NetworkRequestRecordPredicateValue {
        if keyPath == \NetworkRequest.method || keyPath == \NetworkRequest.searchableText {
            let stringExpression: @Sendable (NetworkRequestRecord) -> String
            if keyPath == \NetworkRequest.method {
                stringExpression = { $0.method }
            } else {
                stringExpression = { $0.searchableText }
            }
            return { record in
                .string(stringExpression(record))
            }
        }
        if keyPath == \NetworkRequest.resourceCategory {
            return { record in
                .resourceCategory(record.resourceCategory)
            }
        }
        preconditionFailure("Unsupported NetworkRequest equality predicate key path: \(keyPath)")
    }
}

extension PredicateExpressions.KeyPath: NetworkRequestRecordOptionalIntExpression
    where Root == PredicateExpressions.Variable<NetworkRequest>, Output == Int?
{
    fileprivate func networkRequestOptionalIntExpression() -> @Sendable (NetworkRequestRecord) -> Int? {
        if keyPath == \NetworkRequest.statusCode {
            return { $0.statusCode }
        }
        preconditionFailure("Unsupported NetworkRequest optional Int predicate key path: \(keyPath)")
    }
}

extension PredicateExpressions.KeyPath: NetworkRequestRecordResourceCategoryExpression
    where Root == PredicateExpressions.Variable<NetworkRequest>, Output == NetworkRequest.ResourceCategory
{
    fileprivate func networkRequestResourceCategoryExpression() -> @Sendable (NetworkRequestRecord) -> NetworkRequest.ResourceCategory {
        if keyPath == \NetworkRequest.resourceCategory {
            return { $0.resourceCategory }
        }
        preconditionFailure("Unsupported NetworkRequest resource category predicate key path: \(keyPath)")
    }
}

extension PredicateExpressions.Value: NetworkRequestRecordStringExpression where Output == String {
    fileprivate func networkRequestStringExpression() -> @Sendable (NetworkRequestRecord) -> String {
        let value = value
        return { _ in value }
    }
}

extension PredicateExpressions.Value: NetworkRequestRecordEquatableExpression {
    fileprivate func networkRequestEquatableExpression() -> @Sendable (NetworkRequestRecord) -> NetworkRequestRecordPredicateValue {
        if let value = value as? String {
            return { _ in .string(value) }
        }
        if let value = value as? NetworkRequest.ResourceCategory {
            return { _ in .resourceCategory(value) }
        }
        preconditionFailure("Unsupported NetworkRequest equality predicate value: \(value)")
    }
}

extension PredicateExpressions.Value: NetworkRequestRecordIntExpression where Output == Int {
    fileprivate func networkRequestIntExpression() -> @Sendable (NetworkRequestRecord) -> Int {
        let value = value
        return { _ in value }
    }
}

extension PredicateExpressions.Value: NetworkRequestRecordResourceCategoryExpression
    where Output == NetworkRequest.ResourceCategory
{
    fileprivate func networkRequestResourceCategoryExpression() -> @Sendable (NetworkRequestRecord) -> NetworkRequest.ResourceCategory {
        let value = value
        return { _ in value }
    }
}

extension PredicateExpressions.Value: NetworkRequestRecordResourceCategorySequenceExpression
    where Output == [NetworkRequest.ResourceCategory]
{
    fileprivate func networkRequestResourceCategorySequenceExpression() -> [NetworkRequest.ResourceCategory] {
        value
    }
}
