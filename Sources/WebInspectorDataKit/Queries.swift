import Foundation
import WebInspectorProxyKit

/// Query capabilities supported for Network request results.
public struct NetworkRequestQuery: Hashable, Sendable {
    /// A nonthrowing Network request membership test.
    public struct Filter: Hashable, Sendable {
        package indirect enum Storage: Hashable, Sendable {
            case method(String)
            case methodContains(String)
            case urlEquals(String)
            case urlContains(String)
            case searchableTextEquals(String)
            case searchableTextContains(String)
            case mimeType(String?)
            case resourceCategories(Set<NetworkRequest.ResourceCategory>)
            case statusCode(StatusCodeComparison, missingValue: Int)
            case all([Filter])
            case any([Filter])
        }

        package let storage: Storage

        /// Matches one HTTP method.
        public static func method(equals method: String) -> Filter {
            Filter(storage: .method(method))
        }

        /// Matches HTTP methods using localized standard containment.
        public static func method(containing text: String) -> Filter {
            Filter(storage: .methodContains(text))
        }

        /// Matches one request URL.
        public static func url(equals url: String) -> Filter {
            Filter(storage: .urlEquals(url))
        }

        /// Matches request URLs using localized standard containment.
        public static func url(containing text: String) -> Filter {
            Filter(storage: .urlContains(text))
        }

        /// Matches the request's aggregate searchable text.
        public static func searchableText(containing text: String) -> Filter {
            Filter(storage: .searchableTextContains(text))
        }

        /// Matches the request's aggregate searchable text exactly.
        public static func searchableText(equals text: String) -> Filter {
            Filter(storage: .searchableTextEquals(text))
        }

        /// Matches one reported MIME type, including an unreported value.
        public static func mimeType(equals mimeType: String?) -> Filter {
            Filter(storage: .mimeType(mimeType))
        }

        /// Matches one resource category.
        public static func resourceCategory(_ category: NetworkRequest.ResourceCategory) -> Filter {
            resourceCategories([category])
        }

        /// Matches any resource category in the supplied sequence.
        public static func resourceCategories(
            _ categories: some Sequence<NetworkRequest.ResourceCategory>
        ) -> Filter {
            Filter(storage: .resourceCategories(Set(categories)))
        }

        /// Matches status codes greater than or equal to a value.
        ///
        /// The filter substitutes `whenMissing` when WebKit has not reported a
        /// status code before applying the comparison.
        public static func statusCode(
            atLeast minimum: Int,
            whenMissing missingValue: Int = 0
        ) -> Filter {
            Filter(storage: .statusCode(.atLeast(minimum), missingValue: missingValue))
        }

        /// Matches status codes greater than a value.
        ///
        /// The filter substitutes `whenMissing` when WebKit has not reported a
        /// status code before applying the comparison.
        public static func statusCode(
            greaterThan minimum: Int,
            whenMissing missingValue: Int = 0
        ) -> Filter {
            Filter(storage: .statusCode(.greaterThan(minimum), missingValue: missingValue))
        }

        /// Matches status codes less than a value.
        ///
        /// The filter substitutes `whenMissing` when WebKit has not reported a
        /// status code before applying the comparison.
        public static func statusCode(
            lessThan maximum: Int,
            whenMissing missingValue: Int = 0
        ) -> Filter {
            Filter(storage: .statusCode(.lessThan(maximum), missingValue: missingValue))
        }

        /// Matches status codes less than or equal to a value.
        ///
        /// The filter substitutes `whenMissing` when WebKit has not reported a
        /// status code before applying the comparison.
        public static func statusCode(
            atMost maximum: Int,
            whenMissing missingValue: Int = 0
        ) -> Filter {
            Filter(storage: .statusCode(.atMost(maximum), missingValue: missingValue))
        }

        /// Matches when every filter matches. An empty collection matches.
        public static func all(_ filters: [Filter]) -> Filter {
            Filter(storage: .all(filters))
        }

        /// Matches when any filter matches. An empty collection does not match.
        public static func any(_ filters: [Filter]) -> Filter {
            Filter(storage: .any(filters))
        }

        package init(storage: Storage) {
            self.storage = storage
        }
    }

    package enum StatusCodeComparison: Hashable, Sendable {
        case lessThan(Int)
        case atMost(Int)
        case greaterThan(Int)
        case atLeast(Int)
    }

    /// A supported Network request ordering.
    public struct Sort: Hashable, Sendable {
        package enum Storage: Hashable, Sendable {
            case requestSentTimestamp(SortOrder)
        }

        package let storage: Storage

        /// Orders requests by the timestamp at which WebKit reported them sent.
        ///
        /// Unreported timestamps precede reported timestamps in forward order
        /// and follow them in reverse order. Equal timestamps retain insertion
        /// order in forward order and reverse insertion order in reverse order.
        public static func requestSentTimestamp(order: SortOrder = .forward) -> Sort {
            Sort(storage: .requestSentTimestamp(order))
        }

        package init(storage: Storage) {
            self.storage = storage
        }
    }

    /// A supported Network request section identity.
    public struct Section: Hashable, Sendable {
        package enum Storage: Hashable, Sendable {
            case method
            case resourceType
            case resourceCategory
            case mimeType
        }

        package let storage: Storage

        /// Sections requests by HTTP method.
        public static let method = Section(storage: .method)

        /// Sections requests by WebKit's reported resource type.
        public static let resourceType = Section(storage: .resourceType)

        /// Sections requests by DataKit's coarse resource category.
        public static let resourceCategory = Section(storage: .resourceCategory)

        /// Sections requests by reported MIME type.
        public static let mimeType = Section(storage: .mimeType)

        package init(storage: Storage) {
            self.storage = storage
        }
    }

    /// Membership test applied to each current request.
    public var filter: Filter?

    /// Sort criteria applied in order.
    public var sortBy: [Sort]

    /// Optional result sectioning.
    public var sectionBy: Section?

    /// Maximum number of visible requests.
    public var fetchLimit: UInt?

    /// Number of matching requests skipped before results begin.
    public var fetchOffset: UInt

    /// Creates a Network request query.
    public init(
        filter: Filter? = nil,
        sortBy: [Sort] = [],
        sectionBy: Section? = nil,
        fetchLimit: UInt? = nil,
        fetchOffset: UInt = 0
    ) {
        self.filter = filter
        self.sortBy = sortBy
        self.sectionBy = sectionBy
        self.fetchLimit = fetchLimit
        self.fetchOffset = fetchOffset
    }

    package var fetchLimitAsInt: Int? {
        fetchLimit.map { Int(clamping: $0) }
    }

    package var fetchOffsetAsInt: Int {
        Int(clamping: fetchOffset)
    }
}

/// Query capabilities supported for Console message results.
public struct ConsoleMessageQuery: Hashable, Sendable {
    /// A nonthrowing Console message membership test.
    public struct Filter: Hashable, Sendable {
        package indirect enum Storage: Hashable, Sendable {
            case source(Console.Source)
            case level(Console.Level)
            case kind(Console.Kind?)
            case url(String?)
            case textContains(String)
            case all([Filter])
            case any([Filter])
        }

        package let storage: Storage

        /// Matches one Console source.
        public static func source(_ source: Console.Source) -> Filter {
            Filter(storage: .source(source))
        }

        /// Matches one Console severity level.
        public static func level(_ level: Console.Level) -> Filter {
            Filter(storage: .level(level))
        }

        /// Matches one reported Console message kind, including an unreported value.
        public static func kind(_ kind: Console.Kind?) -> Filter {
            Filter(storage: .kind(kind))
        }

        /// Matches one source URL, including an unreported value.
        public static func url(_ url: String?) -> Filter {
            Filter(storage: .url(url))
        }

        /// Matches message text using localized standard containment.
        public static func text(containing text: String) -> Filter {
            Filter(storage: .textContains(text))
        }

        /// Matches when every filter matches. An empty collection matches.
        public static func all(_ filters: [Filter]) -> Filter {
            Filter(storage: .all(filters))
        }

        /// Matches when any filter matches. An empty collection does not match.
        public static func any(_ filters: [Filter]) -> Filter {
            Filter(storage: .any(filters))
        }

        package init(storage: Storage) {
            self.storage = storage
        }
    }

    /// String comparison used by a text sort.
    public struct TextComparison: Hashable, Sendable {
        package enum Storage: Hashable, Sendable {
            case localizedStandard
            case lexical
        }

        package let storage: Storage

        /// Localized, Finder-style comparison.
        public static let localizedStandard = TextComparison(storage: .localizedStandard)

        /// Unicode lexical comparison.
        public static let lexical = TextComparison(storage: .lexical)

        package init(storage: Storage) {
            self.storage = storage
        }
    }

    /// A supported Console message ordering.
    public struct Sort: Hashable, Sendable {
        package enum Storage: Hashable, Sendable {
            case text(TextComparison, SortOrder)
            case level(SortOrder)
        }

        package let storage: Storage

        /// Orders messages by their text.
        ///
        /// Equal text retains message insertion order in either direction.
        public static func text(
            comparison: TextComparison = .localizedStandard,
            order: SortOrder = .forward
        ) -> Sort {
            Sort(storage: .text(comparison, order))
        }

        /// Orders messages by their severity level's raw value using localized
        /// standard comparison. Equal values retain insertion order in either
        /// direction.
        public static func level(order: SortOrder = .forward) -> Sort {
            Sort(storage: .level(order))
        }

        package init(storage: Storage) {
            self.storage = storage
        }
    }

    /// A supported Console message section identity.
    public struct Section: Hashable, Sendable {
        package enum Storage: Hashable, Sendable {
            case source
            case level
            case kind
            case url
        }

        package let storage: Storage

        /// Sections messages by source.
        public static let source = Section(storage: .source)

        /// Sections messages by severity level.
        public static let level = Section(storage: .level)

        /// Sections messages by reported kind.
        public static let kind = Section(storage: .kind)

        /// Sections messages by source URL.
        public static let url = Section(storage: .url)

        package init(storage: Storage) {
            self.storage = storage
        }
    }

    /// Membership test applied to each current message.
    public var filter: Filter?

    /// Sort criteria applied in order.
    public var sortBy: [Sort]

    /// Optional result sectioning.
    public var sectionBy: Section?

    /// Maximum number of visible messages.
    public var fetchLimit: UInt?

    /// Number of matching messages skipped before results begin.
    public var fetchOffset: UInt

    /// Creates a Console message query.
    public init(
        filter: Filter? = nil,
        sortBy: [Sort] = [],
        sectionBy: Section? = nil,
        fetchLimit: UInt? = nil,
        fetchOffset: UInt = 0
    ) {
        self.filter = filter
        self.sortBy = sortBy
        self.sectionBy = sectionBy
        self.fetchLimit = fetchLimit
        self.fetchOffset = fetchOffset
    }

    package var fetchLimitAsInt: Int? {
        fetchLimit.map { Int(clamping: $0) }
    }

    package var fetchOffsetAsInt: Int {
        Int(clamping: fetchOffset)
    }
}

extension ConsoleMessageQuery.Filter {
    package func matches(_ message: ConsoleMessage) -> Bool {
        switch storage {
        case let .source(source):
            return message.source == source
        case let .level(level):
            return message.level == level
        case let .kind(kind):
            return message.kind == kind
        case let .url(url):
            return message.url == url
        case let .textContains(text):
            return message.text.localizedStandardContains(text)
        case let .all(filters):
            return filters.allSatisfy { $0.matches(message) }
        case let .any(filters):
            return filters.contains { $0.matches(message) }
        }
    }
}

extension ConsoleMessageQuery.Sort {
    package func compare(_ lhs: ConsoleMessage, _ rhs: ConsoleMessage) -> ComparisonResult {
        let comparison: ComparisonResult
        let order: SortOrder
        switch storage {
        case let .text(textComparison, sortOrder):
            order = sortOrder
            switch textComparison.storage {
            case .localizedStandard:
                comparison = lhs.text.localizedStandardCompare(rhs.text)
            case .lexical:
                if lhs.text < rhs.text {
                    comparison = .orderedAscending
                } else if lhs.text > rhs.text {
                    comparison = .orderedDescending
                } else {
                    comparison = .orderedSame
                }
            }
        case let .level(sortOrder):
            order = sortOrder
            comparison = lhs.level.rawValue.localizedStandardCompare(rhs.level.rawValue)
        }
        guard order == .reverse else {
            return comparison
        }
        switch comparison {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

package enum WebInspectorQueryStorage: Sendable {
    case network(NetworkRequestQuery)
    case console(ConsoleMessageQuery)

    package var isSectioned: Bool {
        switch self {
        case let .network(query): query.sectionBy != nil
        case let .console(query): query.sectionBy != nil
        }
    }
}
