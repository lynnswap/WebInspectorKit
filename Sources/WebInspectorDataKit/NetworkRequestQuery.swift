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
        requestSentTimestamp = request.requestSentTimestamp
        hasResponse = request.hasResponse
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
        searchableText = NetworkRequest.uniqueNonEmpty([
            input.url,
            input.responseURL,
            NetworkRequest.urlSearchText(input.url),
            input.responseURL.map(NetworkRequest.urlSearchText),
            input.method,
            input.statusCode.map(String.init),
            input.statusText,
            input.mimeType,
            input.resourceTypeRawValue,
            category.rawValue,
        ])
        .joined(separator: "\n")
        statusCode = input.statusCode
        requestSentTimestamp = input.requestSentTimestamp
    }

    package init(request: NetworkRequest, orderIndex: Int) {
        self.init(input: NetworkRequestRecordInput(request: request, orderIndex: orderIndex))
    }
}

package struct NetworkRequestQueryPlan: Sendable {
    package typealias RecordPredicate = @Sendable (NetworkRequestRecord) -> Bool

    package enum Filter: Sendable {
        case record(RecordPredicate)
        case model(Predicate<NetworkRequest>)

        package func matches(record: NetworkRequestRecord) -> Bool? {
            switch self {
            case let .record(predicate):
                return predicate(record)
            case .model:
                return nil
            }
        }

        package func matches(record: NetworkRequestRecord, request: NetworkRequest) -> Bool {
            switch self {
            case let .record(predicate):
                return predicate(record)
            case let .model(predicate):
                do {
                    return try predicate.evaluate(request)
                } catch {
                    preconditionFailure("NetworkRequest predicate evaluation failed: \(error)")
                }
            }
        }
    }

    package var filter: Filter?
    package var sortComparators: [NetworkRequestRecordSortComparator]
    package var fetchLimit: Int?
    package var fetchOffset: Int

    package init(
        descriptor: WebInspectorFetchDescriptor<NetworkRequest>,
        context: WebInspectorContext
    ) {
        filter = descriptor.predicate.map(makeNetworkRequestFilter)
        sortComparators = descriptor.sortBy.map {
            NetworkRequestRecordSortComparator(descriptor: $0, context: context)
        }
        fetchLimit = descriptor.fetchLimit
        fetchOffset = descriptor.fetchOffset
    }

    package var requiresQuery: Bool {
        filter != nil || sortComparators.isEmpty == false || fetchLimit != nil || fetchOffset > 0
    }

    package var requiresModelPredicate: Bool {
        guard case .model = filter else {
            return false
        }
        return true
    }

    package func matches(record: NetworkRequestRecord) -> Bool? {
        filter?.matches(record: record) ?? true
    }

    package func matches(record: NetworkRequestRecord, request: NetworkRequest) -> Bool {
        filter?.matches(record: record, request: request) ?? true
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
            upsert(request: request, orderIndex: index)
        }
    }

    private mutating func upsert(request: NetworkRequest, orderIndex: Int) {
        let record = NetworkRequestRecord(request: request, orderIndex: orderIndex)
        recordsByID[record.id] = record
        matchingIDs.removeAll { $0 == record.id }
        guard plan.matches(record: record, request: request) else {
            return
        }
        insertMatchingID(record.id)
    }

    package mutating func upsert(request: NetworkRequest) {
        let orderIndex = recordsByID[request.id]?.orderIndex ?? recordsByID.count
        upsert(request: request, orderIndex: orderIndex)
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
    func networkRequestRecordPredicate() throws -> NetworkRequestQueryPlan.RecordPredicate
}

private protocol NetworkRequestRecordStringExpression {
    func networkRequestStringExpression() throws -> @Sendable (NetworkRequestRecord) -> String
}

private protocol NetworkRequestRecordIntExpression {
    func networkRequestIntExpression() throws -> @Sendable (NetworkRequestRecord) -> Int
}

private protocol NetworkRequestRecordOptionalIntExpression {
    func networkRequestOptionalIntExpression() throws -> @Sendable (NetworkRequestRecord) -> Int?
}

private protocol NetworkRequestRecordResourceCategoryExpression {
    func networkRequestResourceCategoryExpression() throws -> @Sendable (NetworkRequestRecord) -> NetworkRequest.ResourceCategory
}

private protocol NetworkRequestRecordResourceCategorySequenceExpression {
    func networkRequestResourceCategorySequenceExpression() throws -> [NetworkRequest.ResourceCategory]
}

private enum NetworkRequestRecordPredicateValue: Equatable, Sendable {
    case string(String)
    case optionalString(String?)
    case resourceCategory(NetworkRequest.ResourceCategory)
}

private protocol NetworkRequestRecordEquatableExpression {
    func networkRequestEquatableExpression() throws -> @Sendable (NetworkRequestRecord) -> NetworkRequestRecordPredicateValue
}

private struct UnsupportedNetworkRequestRecordPredicate: Error {}

private func makeNetworkRequestFilter(
    _ predicate: Predicate<NetworkRequest>
) -> NetworkRequestQueryPlan.Filter {
    guard let expression = predicate.expression as? any NetworkRequestRecordPredicateExpression else {
        return .model(predicate)
    }
    do {
        return .record(try expression.networkRequestRecordPredicate())
    } catch is UnsupportedNetworkRequestRecordPredicate {
        return .model(predicate)
    } catch {
        preconditionFailure("NetworkRequest predicate planning failed: \(error)")
    }
}

extension PredicateExpressions.Conjunction: NetworkRequestRecordPredicateExpression
    where LHS: NetworkRequestRecordPredicateExpression, RHS: NetworkRequestRecordPredicateExpression
{
    fileprivate func networkRequestRecordPredicate() throws -> NetworkRequestQueryPlan.RecordPredicate {
        let lhsPredicate = try lhs.networkRequestRecordPredicate()
        let rhsPredicate = try rhs.networkRequestRecordPredicate()
        return { record in
            lhsPredicate(record) && rhsPredicate(record)
        }
    }
}

extension PredicateExpressions.Disjunction: NetworkRequestRecordPredicateExpression
    where LHS: NetworkRequestRecordPredicateExpression, RHS: NetworkRequestRecordPredicateExpression
{
    fileprivate func networkRequestRecordPredicate() throws -> NetworkRequestQueryPlan.RecordPredicate {
        let lhsPredicate = try lhs.networkRequestRecordPredicate()
        let rhsPredicate = try rhs.networkRequestRecordPredicate()
        return { record in
            lhsPredicate(record) || rhsPredicate(record)
        }
    }
}

extension PredicateExpressions.Equal: NetworkRequestRecordPredicateExpression
    where LHS: NetworkRequestRecordEquatableExpression, RHS: NetworkRequestRecordEquatableExpression
{
    fileprivate func networkRequestRecordPredicate() throws -> NetworkRequestQueryPlan.RecordPredicate {
        let lhsExpression = try lhs.networkRequestEquatableExpression()
        let rhsExpression = try rhs.networkRequestEquatableExpression()
        return { record in
            networkRequestRecordPredicateValuesEqual(lhsExpression(record), rhsExpression(record))
        }
    }
}

private func networkRequestRecordPredicateValuesEqual(
    _ lhs: NetworkRequestRecordPredicateValue,
    _ rhs: NetworkRequestRecordPredicateValue
) -> Bool {
    switch (lhs, rhs) {
    case let (.string(lhs), .string(rhs)):
        return lhs == rhs
    case let (.optionalString(lhs), .optionalString(rhs)):
        return lhs == rhs
    case let (.optionalString(lhs), .string(rhs)):
        return lhs == rhs
    case let (.string(lhs), .optionalString(rhs)):
        return lhs == rhs
    case let (.resourceCategory(lhs), .resourceCategory(rhs)):
        return lhs == rhs
    case (.string, _),
         (.optionalString, _),
         (.resourceCategory, _):
        return false
    }
}

extension PredicateExpressions.StringLocalizedStandardContains: NetworkRequestRecordPredicateExpression
    where Root: NetworkRequestRecordStringExpression, Other: NetworkRequestRecordStringExpression
{
    fileprivate func networkRequestRecordPredicate() throws -> NetworkRequestQueryPlan.RecordPredicate {
        let rootExpression = try root.networkRequestStringExpression()
        let otherExpression = try other.networkRequestStringExpression()
        return { record in
            rootExpression(record).localizedStandardContains(otherExpression(record))
        }
    }
}

extension PredicateExpressions.SequenceContains: NetworkRequestRecordPredicateExpression
    where LHS: NetworkRequestRecordResourceCategorySequenceExpression,
          RHS: NetworkRequestRecordResourceCategoryExpression
{
    fileprivate func networkRequestRecordPredicate() throws -> NetworkRequestQueryPlan.RecordPredicate {
        let categories = Set(try sequence.networkRequestResourceCategorySequenceExpression())
        let elementExpression = try element.networkRequestResourceCategoryExpression()
        return { record in
            categories.contains(elementExpression(record))
        }
    }
}

extension PredicateExpressions.Comparison: NetworkRequestRecordPredicateExpression
    where LHS: NetworkRequestRecordIntExpression, RHS: NetworkRequestRecordIntExpression
{
    fileprivate func networkRequestRecordPredicate() throws -> NetworkRequestQueryPlan.RecordPredicate {
        let lhsExpression = try lhs.networkRequestIntExpression()
        let rhsExpression = try rhs.networkRequestIntExpression()
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
    fileprivate func networkRequestIntExpression() throws -> @Sendable (NetworkRequestRecord) -> Int {
        let lhsExpression = try lhs.networkRequestOptionalIntExpression()
        let rhsExpression = try rhs.networkRequestIntExpression()
        return { record in
            lhsExpression(record) ?? rhsExpression(record)
        }
    }
}

extension PredicateExpressions.KeyPath: NetworkRequestRecordStringExpression
    where Root == PredicateExpressions.Variable<NetworkRequest>, Output == String
{
    fileprivate func networkRequestStringExpression() throws -> @Sendable (NetworkRequestRecord) -> String {
        if keyPath == \NetworkRequest.url {
            return { $0.url }
        }
        if keyPath == \NetworkRequest.method {
            return { $0.method }
        }
        if keyPath == \NetworkRequest.searchableText {
            return { $0.searchableText }
        }
        throw UnsupportedNetworkRequestRecordPredicate()
    }
}

extension PredicateExpressions.KeyPath: NetworkRequestRecordEquatableExpression
    where Root == PredicateExpressions.Variable<NetworkRequest>
{
    fileprivate func networkRequestEquatableExpression() throws -> @Sendable (NetworkRequestRecord) -> NetworkRequestRecordPredicateValue {
        if keyPath == \NetworkRequest.url || keyPath == \NetworkRequest.method || keyPath == \NetworkRequest.searchableText {
            let stringExpression: @Sendable (NetworkRequestRecord) -> String
            if keyPath == \NetworkRequest.url {
                stringExpression = { $0.url }
            } else if keyPath == \NetworkRequest.method {
                stringExpression = { $0.method }
            } else {
                stringExpression = { $0.searchableText }
            }
            return { record in
                .string(stringExpression(record))
            }
        }
        if keyPath == \NetworkRequest.mimeType {
            return { record in
                .optionalString(record.mimeType)
            }
        }
        if keyPath == \NetworkRequest.resourceCategory {
            return { record in
                .resourceCategory(record.resourceCategory)
            }
        }
        throw UnsupportedNetworkRequestRecordPredicate()
    }
}

extension PredicateExpressions.KeyPath: NetworkRequestRecordOptionalIntExpression
    where Root == PredicateExpressions.Variable<NetworkRequest>, Output == Int?
{
    fileprivate func networkRequestOptionalIntExpression() throws -> @Sendable (NetworkRequestRecord) -> Int? {
        if keyPath == \NetworkRequest.statusCode {
            return { $0.statusCode }
        }
        throw UnsupportedNetworkRequestRecordPredicate()
    }
}

extension PredicateExpressions.KeyPath: NetworkRequestRecordResourceCategoryExpression
    where Root == PredicateExpressions.Variable<NetworkRequest>, Output == NetworkRequest.ResourceCategory
{
    fileprivate func networkRequestResourceCategoryExpression() throws -> @Sendable (NetworkRequestRecord) -> NetworkRequest.ResourceCategory {
        if keyPath == \NetworkRequest.resourceCategory {
            return { $0.resourceCategory }
        }
        throw UnsupportedNetworkRequestRecordPredicate()
    }
}

extension PredicateExpressions.Value: NetworkRequestRecordStringExpression where Output == String {
    fileprivate func networkRequestStringExpression() throws -> @Sendable (NetworkRequestRecord) -> String {
        let value = value
        return { _ in value }
    }
}

extension PredicateExpressions.Value: NetworkRequestRecordEquatableExpression {
    fileprivate func networkRequestEquatableExpression() throws -> @Sendable (NetworkRequestRecord) -> NetworkRequestRecordPredicateValue {
        if let value = value as? String {
            return { _ in .string(value) }
        }
        if Output.self == Optional<String>.self {
            let value = value as! String?
            return { _ in .optionalString(value) }
        }
        if let value = value as? NetworkRequest.ResourceCategory {
            return { _ in .resourceCategory(value) }
        }
        throw UnsupportedNetworkRequestRecordPredicate()
    }
}

extension PredicateExpressions.Value: NetworkRequestRecordIntExpression where Output == Int {
    fileprivate func networkRequestIntExpression() throws -> @Sendable (NetworkRequestRecord) -> Int {
        let value = value
        return { _ in value }
    }
}

extension PredicateExpressions.Value: NetworkRequestRecordResourceCategoryExpression
    where Output == NetworkRequest.ResourceCategory
{
    fileprivate func networkRequestResourceCategoryExpression() throws -> @Sendable (NetworkRequestRecord) -> NetworkRequest.ResourceCategory {
        let value = value
        return { _ in value }
    }
}

extension PredicateExpressions.Value: NetworkRequestRecordResourceCategorySequenceExpression
    where Output == [NetworkRequest.ResourceCategory]
{
    fileprivate func networkRequestResourceCategorySequenceExpression() throws -> [NetworkRequest.ResourceCategory] {
        value
    }
}
