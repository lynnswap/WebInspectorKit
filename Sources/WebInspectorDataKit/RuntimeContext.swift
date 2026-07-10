import Foundation
import Observation
import WebInspectorProxyKit

/// Observable model for a Runtime execution context.
@Observable
public final class RuntimeContext: WebInspectorPersistentModel {
    /// Stable identity for an execution context within a context.
    public struct ID: Hashable, Sendable {
        let proxyID: Runtime.ExecutionContext.ID

        init(_ proxyID: Runtime.ExecutionContext.ID) {
            self.proxyID = proxyID
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

    init(context: Runtime.ExecutionContext) {
        id = ID(context.id)
        name = context.name
        frameID = context.frameID
        kind = context.kind
    }

    func update(from context: Runtime.ExecutionContext) {
        name = context.name
        frameID = context.frameID
        kind = context.kind
    }
}
