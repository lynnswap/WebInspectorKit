import Observation

public protocol WebInspectorPersistentModel: AnyObject, Observable, Hashable, Identifiable, SendableMetatype
where ID: Hashable & Sendable {
    nonisolated var id: ID { get }
}

extension WebInspectorPersistentModel {
    public nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs === rhs
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

public protocol WebInspectorFetchableModel: WebInspectorPersistentModel {}
