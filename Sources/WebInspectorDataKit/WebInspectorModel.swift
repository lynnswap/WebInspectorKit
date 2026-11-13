import Observation

/// An observable model of a ``WebInspector`` that is identified by object
/// identity.
///
/// A model object can outlive its registration in the inspector. Its last
/// reported properties remain readable, but a command that takes it follows
/// the stale behavior described in <doc:ModelRegistrationLifetimes>.
public protocol WebInspectorModel: AnyObject, Observable, Hashable, Identifiable, SendableMetatype
where ID: Hashable & Sendable {
    /// Stable identity for the lifetime of this model object.
    nonisolated var id: ID { get }
}

extension WebInspectorModel {
    /// Compares models by object identity.
    public nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs === rhs
    }

    /// Hashes a model by object identity.
    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
