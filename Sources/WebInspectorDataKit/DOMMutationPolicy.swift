/// Closed internal policy passed through one mutation transaction.
package struct DOMMutationPolicy: Sendable, Hashable {
    package let undo: WebInspectorUndoPolicy

    package init(undo: WebInspectorUndoPolicy = .automatic) {
        self.undo = undo
    }
}

/// Controls whether a mutation participates in WebKit inspector undo history.
public enum WebInspectorUndoPolicy: Sendable, Hashable {
    /// Let DataKit record undoable WebKit DOM mutations where supported.
    case automatic

    /// Do not record an undo checkpoint for the mutation.
    case disabled
}
