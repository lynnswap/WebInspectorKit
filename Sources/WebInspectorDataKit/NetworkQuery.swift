import Foundation

/// A closed query for live Network request results.
public struct NetworkQuery: Sendable, Equatable {
    /// Text matched against the request's searchable Network fields.
    ///
    /// Leading and trailing whitespace is removed. Empty and whitespace-only
    /// values are normalized to `nil`.
    public var search: String? {
        didSet {
            search = Self.normalize(search)
        }
    }

    /// Resource categories to include, or an empty set to include every category.
    public var resourceCategories: Set<NetworkRequest.ResourceCategory>

    /// HTTP methods to include, or an empty set to include every method.
    public var methods: Set<String>

    /// The ordering applied before offset and limit.
    public var sort: NetworkSort

    /// The optional grouping applied to visible requests.
    public var section: NetworkSection?

    /// The number of matching requests skipped before publication.
    public var offset: Int {
        didSet {
            Self.validate(offset: offset)
        }
    }

    /// The maximum number of requests published after the offset, or `nil` for no limit.
    public var limit: Int? {
        didSet {
            Self.validate(limit: limit)
        }
    }

    /// Creates a Network request query.
    public init(
        search: String? = nil,
        resourceCategories: Set<NetworkRequest.ResourceCategory> = [],
        methods: Set<String> = [],
        sort: NetworkSort = .requestTimeDescending,
        section: NetworkSection? = nil,
        offset: Int = 0,
        limit: Int? = nil
    ) {
        Self.validate(offset: offset)
        Self.validate(limit: limit)
        self.search = Self.normalize(search)
        self.resourceCategories = resourceCategories
        self.methods = methods
        self.sort = sort
        self.section = section
        self.offset = offset
        self.limit = limit
    }

    private static func normalize(_ search: String?) -> String? {
        guard let normalized = search?.trimmingCharacters(in: .whitespacesAndNewlines),
              normalized.isEmpty == false else {
            return nil
        }
        return normalized
    }

    private static func validate(offset: Int) {
        precondition(offset >= 0, "NetworkQuery offset must be non-negative.")
    }

    private static func validate(limit: Int?) {
        if let limit {
            precondition(limit >= 0, "NetworkQuery limit must be non-negative.")
        }
    }
}

/// Supported Network request ordering.
public enum NetworkSort: Sendable, Equatable {
    /// Orders requests from the earliest request time to the latest.
    case requestTimeAscending

    /// Orders requests from the latest request time to the earliest.
    case requestTimeDescending
}

/// Supported Network request grouping.
public enum NetworkSection: Sendable, Equatable {
    /// Groups visible requests by HTTP method.
    case method
}
