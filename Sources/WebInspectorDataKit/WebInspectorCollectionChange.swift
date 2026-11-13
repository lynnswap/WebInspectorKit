/// A change to an ordered collection of inspector models, such as the
/// Network requests or the Console messages of a context.
///
/// Changes describe the collection completely. Copy the collection when you
/// subscribe, with no suspension in between, and apply every change in order
/// to keep the copy current. Reading the live collection again while changes
/// are still buffered can show models whose `inserted` change has not arrived
/// yet.
public enum WebInspectorCollectionChange<ID: Hashable & Sendable>: Hashable, Sendable {
    /// Every model was removed.
    case removedAll

    /// Models were appended, in this order.
    case inserted([ID])

    /// Models already in the collection changed.
    case updated([ID])

    /// Models were removed.
    case removed([ID])
}
