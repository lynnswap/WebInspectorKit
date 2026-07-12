import Foundation

/// A typed fetch request evaluated against immutable persistent-model values.
public struct WebInspectorFetchDescriptor<Model>: Sendable
where Model: WebInspectorPersistentModel {
    /// The predicate used to select matching values, or `nil` to include all values.
    public var predicate: Predicate<Model.QueryValue>?

    /// The ordered descriptors applied before offset and limit.
    public var sortBy: [SortDescriptor<Model.QueryValue>]

    /// The number of matching values skipped before publication.
    public var fetchOffset: Int = 0 {
        didSet {
            precondition(
                fetchOffset >= 0,
                "WebInspectorFetchDescriptor fetchOffset must be non-negative."
            )
        }
    }

    /// The maximum number of values published after the offset, or `nil` for no limit.
    public var fetchLimit: Int? {
        didSet {
            if let fetchLimit {
                precondition(
                    fetchLimit >= 0,
                    "WebInspectorFetchDescriptor fetchLimit must be non-negative."
                )
            }
        }
    }

    /// Creates a persistent-model fetch descriptor.
    public init(
        predicate: Predicate<Model.QueryValue>? = nil,
        sortBy: [SortDescriptor<Model.QueryValue>] = []
    ) {
        self.predicate = predicate
        self.sortBy = sortBy
        fetchLimit = nil
    }
}
