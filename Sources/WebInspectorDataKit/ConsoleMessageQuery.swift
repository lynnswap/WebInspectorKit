import Foundation
import WebInspectorProxyKit

package struct ConsoleMessageRecordInput: Hashable, Sendable {
    package var id: ConsoleMessage.ID
    package var orderIndex: Int
    package var sourceRawValue: String
    package var levelRawValue: String
    package var kindRawValue: String?
    package var text: String
    package var url: String?
    package var line: Int?
    package var column: Int?
    package var repeatCount: Int
    package var timestamp: Double?

    package init(message: ConsoleMessage, orderIndex: Int) {
        id = message.id
        self.orderIndex = orderIndex
        sourceRawValue = message.source.rawValue
        levelRawValue = message.level.rawValue
        kindRawValue = message.kind?.rawValue
        text = message.text
        url = message.url
        line = message.line
        column = message.column
        repeatCount = message.repeatCount
        timestamp = message.timestamp
    }
}

package struct ConsoleMessageRecord: Hashable, Sendable {
    package var id: ConsoleMessage.ID
    package var orderIndex: Int
    package var sourceRawValue: String
    package var levelRawValue: String
    package var kindRawValue: String?
    package var text: String
    package var url: String?
    package var line: Int?
    package var column: Int?
    package var repeatCount: Int
    package var timestamp: Double?

    package init(input: ConsoleMessageRecordInput) {
        id = input.id
        orderIndex = input.orderIndex
        sourceRawValue = input.sourceRawValue
        levelRawValue = input.levelRawValue
        kindRawValue = input.kindRawValue
        text = input.text
        url = input.url
        line = input.line
        column = input.column
        repeatCount = input.repeatCount
        timestamp = input.timestamp
    }

    package init(message: ConsoleMessage, orderIndex: Int) {
        self.init(input: ConsoleMessageRecordInput(message: message, orderIndex: orderIndex))
    }
}

package struct ConsoleMessageQueryPlan: Sendable {
    package typealias RecordPredicate = @Sendable (ConsoleMessageRecord) -> Bool

    package enum Filter: Sendable {
        case record(RecordPredicate)
        case model(Predicate<ConsoleMessage>)

        package func matches(record: ConsoleMessageRecord) -> Bool? {
            switch self {
            case let .record(predicate):
                return predicate(record)
            case .model:
                return nil
            }
        }

        package func matches(record: ConsoleMessageRecord, message: ConsoleMessage) -> Bool {
            switch self {
            case let .record(predicate):
                return predicate(record)
            case let .model(predicate):
                do {
                    return try predicate.evaluate(message)
                } catch {
                    preconditionFailure("ConsoleMessage predicate evaluation failed: \(error)")
                }
            }
        }
    }

    package var filter: Filter?
    package var sortComparators: [ConsoleMessageRecordSortComparator]
    package var fetchLimit: Int?
    package var fetchOffset: Int

    package init(
        descriptor: WebInspectorFetchDescriptor<ConsoleMessage>,
        context: WebInspectorContext
    ) {
        filter = descriptor.predicate.map(makeConsoleMessageFilter)
        sortComparators = descriptor.sortBy.map {
            ConsoleMessageRecordSortComparator(descriptor: $0, context: context)
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

    package func matches(record: ConsoleMessageRecord) -> Bool? {
        filter?.matches(record: record) ?? true
    }

    package func matches(record: ConsoleMessageRecord, message: ConsoleMessage) -> Bool {
        filter?.matches(record: record, message: message) ?? true
    }

    package func visibleIDs(from matchingIDs: [ConsoleMessage.ID]) -> ArraySlice<ConsoleMessage.ID> {
        let lowerBound = min(fetchOffset, matchingIDs.count)
        let upperBound: Int
        if let fetchLimit {
            upperBound = min(lowerBound + fetchLimit, matchingIDs.count)
        } else {
            upperBound = matchingIDs.count
        }
        return matchingIDs[lowerBound..<upperBound]
    }

    package func ordersBefore(_ lhs: ConsoleMessageRecord, _ rhs: ConsoleMessageRecord) -> Bool {
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
        return lhs.orderIndex < rhs.orderIndex
    }
}

package struct ConsoleMessageQueryState {
    package var plan: ConsoleMessageQueryPlan
    private var recordsByID: [ConsoleMessage.ID: ConsoleMessageRecord]
    private var matchingIDs: [ConsoleMessage.ID]

    package init(plan: ConsoleMessageQueryPlan, messages: [ConsoleMessage]) {
        self.plan = plan
        recordsByID = [:]
        recordsByID.reserveCapacity(messages.count)
        matchingIDs = []
        matchingIDs.reserveCapacity(messages.count)
        for (index, message) in messages.enumerated() {
            upsert(message: message, orderIndex: index)
        }
    }

    private mutating func upsert(message: ConsoleMessage, orderIndex: Int) {
        let record = ConsoleMessageRecord(message: message, orderIndex: orderIndex)
        recordsByID[record.id] = record
        matchingIDs.removeAll { $0 == record.id }
        guard plan.matches(record: record, message: message) else {
            return
        }
        insertMatchingID(record.id)
    }

    package mutating func upsert(message: ConsoleMessage) {
        let orderIndex = recordsByID[message.id]?.orderIndex ?? recordsByID.count
        upsert(message: message, orderIndex: orderIndex)
    }

    package func visibleMessages(
        lookup: (ConsoleMessage.ID) -> ConsoleMessage?
    ) -> [ConsoleMessage] {
        plan.visibleIDs(from: matchingIDs).compactMap(lookup)
    }

    private mutating func insertMatchingID(_ id: ConsoleMessage.ID) {
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

package struct ConsoleMessageRecordSortComparator: Sendable {
    private enum Key: Sendable {
        case source
        case level
        case kind
        case text
        case url
        case line
        case column
        case repeatCount
        case timestamp
        case id
    }

    private var key: Key
    private var order: SortOrder

    fileprivate init(
        descriptor: SortDescriptor<ConsoleMessage>,
        context: WebInspectorContext
    ) {
        guard let key = Self.key(for: descriptor, context: context) else {
            preconditionFailure("Unsupported ConsoleMessage sort descriptor: \(descriptor)")
        }
        self.key = key
        order = descriptor.order
    }

    fileprivate func compare(
        _ lhs: ConsoleMessageRecord,
        _ rhs: ConsoleMessageRecord
    ) -> ComparisonResult {
        let result: ComparisonResult
        switch key {
        case .source:
            result = compareValues(lhs.sourceRawValue, rhs.sourceRawValue)
        case .level:
            result = compareValues(lhs.levelRawValue, rhs.levelRawValue)
        case .kind:
            result = compareOptional(lhs.kindRawValue, rhs.kindRawValue)
        case .text:
            result = compareValues(lhs.text, rhs.text)
        case .url:
            result = compareOptional(lhs.url, rhs.url)
        case .line:
            result = compareOptional(lhs.line, rhs.line)
        case .column:
            result = compareOptional(lhs.column, rhs.column)
        case .repeatCount:
            result = compareValues(lhs.repeatCount, rhs.repeatCount)
        case .timestamp:
            result = compareOptional(lhs.timestamp, rhs.timestamp)
        case .id:
            result = compareValues(lhs.id, rhs.id)
        }
        switch order {
        case .forward:
            return result
        case .reverse:
            return result.reversedForConsoleQuery
        }
    }

    private static func key(
        for descriptor: SortDescriptor<ConsoleMessage>,
        context: WebInspectorContext
    ) -> Key? {
        let candidates: [(Key, Console.Message, Console.Message, ConsoleMessage.ID, ConsoleMessage.ID)] = [
            (.source, payload(source: "a"), payload(source: "b"), .init(0), .init(0)),
            (.level, payload(level: "a"), payload(level: "b"), .init(0), .init(0)),
            (.kind, payload(kind: "a"), payload(kind: "b"), .init(0), .init(0)),
            (.text, payload(text: "a"), payload(text: "b"), .init(0), .init(0)),
            (.url, payload(url: "a"), payload(url: "b"), .init(0), .init(0)),
            (.line, payload(line: 1), payload(line: 2), .init(0), .init(0)),
            (.column, payload(column: 1), payload(column: 2), .init(0), .init(0)),
            (.repeatCount, payload(repeatCount: 1), payload(repeatCount: 2), .init(0), .init(0)),
            (.timestamp, payload(timestamp: 1), payload(timestamp: 2), .init(0), .init(0)),
            (.id, payload(), payload(), .init(1), .init(2)),
        ]
        for (key, lhsPayload, rhsPayload, lhsID, rhsID) in candidates {
            let lhs = ConsoleMessage(
                id: lhsID,
                message: lhsPayload,
                parameters: [],
                targetID: nil,
                modelContext: context
            )
            let rhs = ConsoleMessage(
                id: rhsID,
                message: rhsPayload,
                parameters: [],
                targetID: nil,
                modelContext: context
            )
            if descriptor.compare(lhs, rhs) != .orderedSame {
                return key
            }
        }
        return nil
    }

    private static func payload(
        source: String = "source",
        level: String = "level",
        kind: String? = nil,
        text: String = "text",
        url: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        repeatCount: Int = 1,
        timestamp: Double? = nil
    ) -> Console.Message {
        Console.Message(
            source: Console.Source(rawValue: source),
            level: Console.Level(rawValue: level),
            type: kind.map(Console.Kind.init(rawValue:)),
            text: text,
            url: url,
            line: line,
            column: column,
            repeatCount: repeatCount,
            timestamp: timestamp
        )
    }

    private func compareValues<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> ComparisonResult {
        if lhs < rhs {
            return .orderedAscending
        }
        if lhs > rhs {
            return .orderedDescending
        }
        return .orderedSame
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
            return compareValues(lhs, rhs)
        }
    }
}

private extension ComparisonResult {
    var reversedForConsoleQuery: ComparisonResult {
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

private protocol ConsoleMessageRecordPredicateExpression {
    func consoleMessageRecordPredicate() throws -> ConsoleMessageQueryPlan.RecordPredicate
}

private enum ConsoleMessageRecordPredicateValue: Equatable, Sendable {
    case string(String)
    case optionalString(String?)
    case integer(Int)
    case optionalInteger(Int?)
}

private protocol ConsoleMessageRecordEquatableExpression {
    func consoleMessageEquatableExpression() throws
        -> @Sendable (ConsoleMessageRecord) -> ConsoleMessageRecordPredicateValue
}

private protocol ConsoleMessageRecordStringExpression {
    func consoleMessageStringExpression() throws -> @Sendable (ConsoleMessageRecord) -> String
}

private protocol ConsoleMessageRecordLevelExpression {
    func consoleMessageLevelExpression() throws -> @Sendable (ConsoleMessageRecord) -> Console.Level
}

private struct UnsupportedConsoleMessageRecordPredicate: Error {}

private func makeConsoleMessageFilter(
    _ predicate: Predicate<ConsoleMessage>
) -> ConsoleMessageQueryPlan.Filter {
    guard let expression = predicate.expression as? any ConsoleMessageRecordPredicateExpression else {
        return .model(predicate)
    }
    do {
        return .record(try expression.consoleMessageRecordPredicate())
    } catch is UnsupportedConsoleMessageRecordPredicate {
        return .model(predicate)
    } catch {
        preconditionFailure("ConsoleMessage predicate planning failed: \(error)")
    }
}

extension PredicateExpressions.Conjunction: ConsoleMessageRecordPredicateExpression
    where LHS: ConsoleMessageRecordPredicateExpression, RHS: ConsoleMessageRecordPredicateExpression
{
    fileprivate func consoleMessageRecordPredicate() throws -> ConsoleMessageQueryPlan.RecordPredicate {
        let lhsPredicate = try lhs.consoleMessageRecordPredicate()
        let rhsPredicate = try rhs.consoleMessageRecordPredicate()
        return { record in
            lhsPredicate(record) && rhsPredicate(record)
        }
    }
}

extension PredicateExpressions.Disjunction: ConsoleMessageRecordPredicateExpression
    where LHS: ConsoleMessageRecordPredicateExpression, RHS: ConsoleMessageRecordPredicateExpression
{
    fileprivate func consoleMessageRecordPredicate() throws -> ConsoleMessageQueryPlan.RecordPredicate {
        let lhsPredicate = try lhs.consoleMessageRecordPredicate()
        let rhsPredicate = try rhs.consoleMessageRecordPredicate()
        return { record in
            lhsPredicate(record) || rhsPredicate(record)
        }
    }
}

extension PredicateExpressions.Equal: ConsoleMessageRecordPredicateExpression
    where LHS: ConsoleMessageRecordEquatableExpression, RHS: ConsoleMessageRecordEquatableExpression
{
    fileprivate func consoleMessageRecordPredicate() throws -> ConsoleMessageQueryPlan.RecordPredicate {
        let lhsExpression = try lhs.consoleMessageEquatableExpression()
        let rhsExpression = try rhs.consoleMessageEquatableExpression()
        return { record in
            consoleMessagePredicateValuesEqual(lhsExpression(record), rhsExpression(record))
        }
    }
}

private func consoleMessagePredicateValuesEqual(
    _ lhs: ConsoleMessageRecordPredicateValue,
    _ rhs: ConsoleMessageRecordPredicateValue
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
    case let (.integer(lhs), .integer(rhs)):
        return lhs == rhs
    case let (.optionalInteger(lhs), .optionalInteger(rhs)):
        return lhs == rhs
    case let (.optionalInteger(lhs), .integer(rhs)):
        return lhs == rhs
    case let (.integer(lhs), .optionalInteger(rhs)):
        return lhs == rhs
    default:
        return false
    }
}

extension PredicateExpressions.StringLocalizedStandardContains: ConsoleMessageRecordPredicateExpression
    where Root: ConsoleMessageRecordStringExpression, Other: ConsoleMessageRecordStringExpression
{
    fileprivate func consoleMessageRecordPredicate() throws -> ConsoleMessageQueryPlan.RecordPredicate {
        let rootExpression = try root.consoleMessageStringExpression()
        let otherExpression = try other.consoleMessageStringExpression()
        return { record in
            rootExpression(record).localizedStandardContains(otherExpression(record))
        }
    }
}

extension PredicateExpressions.KeyPath: ConsoleMessageRecordStringExpression {
    fileprivate func consoleMessageStringExpression() throws
        -> @Sendable (ConsoleMessageRecord) -> String {
        let keyPath = keyPath as AnyKeyPath
        if let levelRoot = root as? any ConsoleMessageRecordLevelExpression,
           keyPath == (\Console.Level.rawValue as AnyKeyPath) {
            let levelExpression = try levelRoot.consoleMessageLevelExpression()
            return { levelExpression($0).rawValue }
        }
        if keyPath == (\ConsoleMessage.text as AnyKeyPath) {
            return { $0.text }
        }
        throw UnsupportedConsoleMessageRecordPredicate()
    }
}

extension PredicateExpressions.KeyPath: ConsoleMessageRecordLevelExpression
    where Root == PredicateExpressions.Variable<ConsoleMessage>, Output == Console.Level
{
    fileprivate func consoleMessageLevelExpression() throws
        -> @Sendable (ConsoleMessageRecord) -> Console.Level {
        guard keyPath == \ConsoleMessage.level else {
            throw UnsupportedConsoleMessageRecordPredicate()
        }
        return { Console.Level(rawValue: $0.levelRawValue) }
    }
}

extension PredicateExpressions.KeyPath: ConsoleMessageRecordEquatableExpression {
    fileprivate func consoleMessageEquatableExpression() throws
        -> @Sendable (ConsoleMessageRecord) -> ConsoleMessageRecordPredicateValue {
        if let stringExpression = try? consoleMessageStringExpression() {
            return { .string(stringExpression($0)) }
        }
        let keyPath = keyPath as AnyKeyPath
        if keyPath == (\ConsoleMessage.kind?.rawValue as AnyKeyPath) {
            return { .optionalString($0.kindRawValue) }
        }
        if keyPath == (\ConsoleMessage.url as AnyKeyPath) {
            return { .optionalString($0.url) }
        }
        if keyPath == (\ConsoleMessage.repeatCount as AnyKeyPath) {
            return { .integer($0.repeatCount) }
        }
        if keyPath == (\ConsoleMessage.line as AnyKeyPath) {
            return { .optionalInteger($0.line) }
        }
        if keyPath == (\ConsoleMessage.column as AnyKeyPath) {
            return { .optionalInteger($0.column) }
        }
        throw UnsupportedConsoleMessageRecordPredicate()
    }
}

extension PredicateExpressions.Value: ConsoleMessageRecordStringExpression where Output == String {
    fileprivate func consoleMessageStringExpression() throws
        -> @Sendable (ConsoleMessageRecord) -> String {
        let value = value
        return { _ in value }
    }
}

extension PredicateExpressions.Value: ConsoleMessageRecordEquatableExpression {
    fileprivate func consoleMessageEquatableExpression() throws
        -> @Sendable (ConsoleMessageRecord) -> ConsoleMessageRecordPredicateValue {
        if let value = value as? String {
            return { _ in .string(value) }
        }
        if Output.self == Optional<String>.self {
            let value = value as! String?
            return { _ in .optionalString(value) }
        }
        if let value = value as? Int {
            return { _ in .integer(value) }
        }
        if Output.self == Optional<Int>.self {
            let value = value as! Int?
            return { _ in .optionalInteger(value) }
        }
        throw UnsupportedConsoleMessageRecordPredicate()
    }
}
