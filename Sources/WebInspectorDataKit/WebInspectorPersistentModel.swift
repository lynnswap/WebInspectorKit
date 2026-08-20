import Observation

/// Base protocol for identity-preserving observable DataKit models.
///
/// A model object can outlive its registration in a ``WebInspectorContext``.
/// Its last reported properties remain readable, but operations follow the
/// stale behavior documented by the concrete model. See
/// <doc:ModelRegistrationLifetimes>.
public protocol WebInspectorPersistentModel: AnyObject, Observable, Hashable, Identifiable, SendableMetatype
where ID: Hashable & Sendable {
    /// Stable identity for the lifetime of this model object.
    nonisolated var id: ID { get }
}

extension WebInspectorPersistentModel {
    /// Compares persistent models by object identity.
    public nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs === rhs
    }

    /// Hashes a persistent model by object identity.
    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
