/// Shared options for DataKit model mutations.
public struct WebInspectorMutationOptions: Sendable, Hashable {
    /// Default mutation behavior: participate in WebKit undo history and fail
    /// on stale model references.
    public static let automatic = WebInspectorMutationOptions(
        undo: .automatic,
        staleModel: .fail
    )

    /// The undo policy for the mutation.
    public var undo: WebInspectorUndoPolicy

    /// The stale-model handling policy for the mutation.
    public var staleModel: WebInspectorStaleModelPolicy

    /// Creates mutation options.
    public init(
        undo: WebInspectorUndoPolicy = .automatic,
        staleModel: WebInspectorStaleModelPolicy = .fail
    ) {
        self.undo = undo
        self.staleModel = staleModel
    }
}

/// Controls whether a mutation participates in WebKit inspector undo history.
public enum WebInspectorUndoPolicy: Sendable, Hashable {
    /// Let DataKit record undoable WebKit DOM mutations where supported.
    case automatic

    /// Do not record an undo checkpoint for the mutation.
    case disabled
}

/// Controls how DataKit handles stale model references.
public enum WebInspectorStaleModelPolicy: Sendable, Hashable {
    /// Fail when a model no longer belongs to the current context state.
    case fail
}
