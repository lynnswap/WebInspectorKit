/// A change to an ordered collection of inspector models, such as the
/// Network requests or the Console messages of a context.
public enum WebInspectorCollectionChange<ID: Hashable & Sendable>: Hashable, Sendable {
    /// The collection was replaced. Read it again.
    case reset

    /// Models were appended, in this order.
    case inserted([ID])

    /// Models already in the collection changed.
    case updated([ID])
}
