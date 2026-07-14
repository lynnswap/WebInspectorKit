import Foundation

/// A typed fetch request evaluated against immutable persistent-model values.
public struct WebInspectorFetchDescriptor<Model>: Sendable
where Model: WebInspectorPersistentModel {
    /// The predicate used to select matching values, or `nil` to include all values.
    public var predicate: Predicate<Model.QueryValue>?

    /// The ordered descriptors applied before offset and limit.
    public var sortBy: [SortDescriptor<Model.QueryValue>]

    /// The number of matching values skipped before publication.
    ///
    /// Invalid negative values are reported by fetch operations as
    /// ``WebInspectorFetchError/invalidOffset(_:)``.
    public var fetchOffset: Int?

    /// The maximum number of values published after the offset, or `nil` for no limit.
    /// Invalid negative values are reported by fetch operations as
    /// ``WebInspectorFetchError/invalidLimit(_:)``.
    public var fetchLimit: Int?

    /// Creates a persistent-model fetch descriptor.
    public init(
        predicate: Predicate<Model.QueryValue>? = nil,
        sortBy: [SortDescriptor<Model.QueryValue>] = []
    ) {
        self.predicate = predicate
        self.sortBy = sortBy
        fetchOffset = nil
        fetchLimit = nil
    }
}
