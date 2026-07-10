import WebInspectorProxyKit

/// A closed query for live Console message results.
public struct ConsoleQuery: Sendable, Equatable {
    /// Message levels to include, or an empty set to include every level.
    public var levels: Set<Console.Level>

    /// The ordering applied before offset and limit.
    public var sort: ConsoleSort

    /// The optional grouping applied to visible messages.
    public var section: ConsoleSection?

    /// The number of matching messages skipped before publication.
    public var offset: Int {
        didSet {
            Self.validate(offset: offset)
        }
    }

    /// The maximum number of messages published after the offset, or `nil` for no limit.
    public var limit: Int? {
        didSet {
            Self.validate(limit: limit)
        }
    }

    /// Creates a Console message query.
    public init(
        levels: Set<Console.Level> = [],
        sort: ConsoleSort = .insertionAscending,
        section: ConsoleSection? = nil,
        offset: Int = 0,
        limit: Int? = nil
    ) {
        Self.validate(offset: offset)
        Self.validate(limit: limit)
        self.levels = levels
        self.sort = sort
        self.section = section
        self.offset = offset
        self.limit = limit
    }

    private static func validate(offset: Int) {
        precondition(offset >= 0, "ConsoleQuery offset must be non-negative.")
    }

    private static func validate(limit: Int?) {
        if let limit {
            precondition(limit >= 0, "ConsoleQuery limit must be non-negative.")
        }
    }
}

/// Supported Console message ordering.
public enum ConsoleSort: Sendable, Equatable {
    /// Preserves insertion order from oldest to newest.
    case insertionAscending

    /// Reverses insertion order from newest to oldest.
    case insertionDescending
}

/// Supported Console message grouping.
public enum ConsoleSection: Sendable, Equatable {
    /// Groups visible messages by Console level.
    case level
}
