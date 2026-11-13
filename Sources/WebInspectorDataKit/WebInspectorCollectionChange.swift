/// A change to an ordered collection of inspector models, such as the
/// Network requests or the Console messages of a context.
///
/// Changes describe the collection completely and carry the model objects
/// they are about. Copy the collection when you subscribe, with no suspension
/// in between, and apply every change in order to keep the copy current.
/// Reading the live collection while changes are still buffered can show a
/// later state than the change you are applying.
public enum WebInspectorCollectionChange<Model: Hashable & Sendable>: Hashable, Sendable {
    /// Every model was removed.
    case removedAll

    /// Models were appended, in this order.
    case inserted([Model])

    /// Models already in the collection changed.
    case updated([Model])

    /// Models were removed.
    case removed([Model])
}
