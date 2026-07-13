import Foundation
import Observation
import WebInspectorProxyKit

/// Observable model for a Runtime execution context.
@Observable
public final class RuntimeContext: WebInspectorPersistentModel {
    /// Stable identity for an execution context within a context.
    public struct ID: WebInspectorPersistentIdentifier {
        /// The persistent model identified by this value.
        public typealias Model = RuntimeContext

        enum Storage: Hashable, Sendable {
            case canonical(CanonicalRuntimeContextIDStorage)
            // Remove with RuntimeStateStore when the payload driver switches
            // to the container schema registry. This case is never accepted by
            // the canonical schema or converted into canonical authority.
            case legacyProxy(Runtime.ExecutionContext.ID)
        }

        let storage: Storage

        init(_ proxyID: Runtime.ExecutionContext.ID) {
            storage = .legacyProxy(proxyID)
        }

        package init(canonical storage: CanonicalRuntimeContextIDStorage) {
            self.storage = .canonical(storage)
        }

        package var canonicalStorage: CanonicalRuntimeContextIDStorage? {
            guard case let .canonical(storage) = storage else {
                return nil
            }
            return storage
        }

        var proxyID: Runtime.ExecutionContext.ID {
            switch storage {
            case let .canonical(storage):
                storage.rawContextID
            case let .legacyProxy(proxyID):
                proxyID
            }
        }
    }

    /// Immutable execution-context fields available to typed fetch descriptors.
    public struct QueryValue: Identifiable, Sendable {
        /// The execution-context identity.
        public let id: ID

        /// The display name for the execution context.
        public let name: String

        /// The frame associated with the execution context, if any.
        public let frameID: FrameID?

        /// The kind of execution context reported by WebKit.
        public let kind: Runtime.ContextKind

        package init(
            id: ID,
            name: String,
            frameID: FrameID?,
            kind: Runtime.ContextKind
        ) {
            self.id = id
            self.name = name
            self.frameID = frameID
            self.kind = kind
        }
    }

    /// The stable execution-context identity.
    public let id: ID

    /// The display name for the execution context.
    public private(set) var name: String

    /// The frame associated with the execution context, if any.
    public private(set) var frameID: FrameID?

    /// The kind of execution context reported by WebKit.
    public private(set) var kind: Runtime.ContextKind

    @ObservationIgnored weak var modelContext: WebInspectorModelContext?

    init(context: Runtime.ExecutionContext) {
        id = ID(context.id)
        name = context.name
        frameID = context.frameID
        kind = context.kind
        modelContext = nil
    }

    package init(
        id: ID,
        record: CanonicalRuntimeContextRecord,
        modelContext: WebInspectorModelContext
    ) {
        precondition(
            id.canonicalStorage == record.id,
            "A canonical RuntimeContext must use its record identity."
        )
        self.id = id
        name = record.name
        frameID = record.frameID
        kind = record.kind
        self.modelContext = modelContext
    }

    func update(from context: Runtime.ExecutionContext) {
        name = context.name
        frameID = context.frameID
        kind = context.kind
    }

    package func replace(
        with record: CanonicalRuntimeContextRecord,
        modelContext: WebInspectorModelContext
    ) {
        precondition(
            id.canonicalStorage == record.id,
            "A RuntimeContext replacement must preserve canonical identity."
        )
        name = record.name
        frameID = record.frameID
        kind = record.kind
        self.modelContext = modelContext
    }

    package func invalidate() {
        modelContext = nil
    }
}
