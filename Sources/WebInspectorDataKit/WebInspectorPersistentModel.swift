import Observation

/// A stable identifier associated with the persistent model it identifies.
public protocol WebInspectorPersistentIdentifier: Hashable, Sendable {
    /// The persistent model resolved from this identifier.
    associatedtype Model: WebInspectorPersistentModel
}

/// Base protocol for identity-preserving observable DataKit models.
public protocol WebInspectorPersistentModel: AnyObject, Observable, Hashable, Identifiable, SendableMetatype
where ID: WebInspectorPersistentIdentifier,
      ID.Model == Self,
      QueryValue: Identifiable & Sendable,
      QueryValue.ID == ID {
    /// Immutable state used to evaluate this model's fetch descriptors.
    associatedtype QueryValue

    /// Stable model identity within a ``WebInspectorModelContext``.
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
