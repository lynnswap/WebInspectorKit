import Observation

/// Base protocol for identity-preserving observable DataKit models.
public protocol WebInspectorPersistentModel: AnyObject, Observable, Hashable, Identifiable, SendableMetatype
where ID: Hashable & Sendable {
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
