import Foundation
import Observation
import WebInspectorProxyKit

@Observable
public final class RuntimeContext: WebInspectorPersistentModel {
    public struct ID: Hashable, Sendable {
        let proxyID: Runtime.ExecutionContext.ID

        init(_ proxyID: Runtime.ExecutionContext.ID) {
            self.proxyID = proxyID
        }
    }

    public let id: ID
    public private(set) var name: String
    public private(set) var frameID: FrameID?
    public private(set) var kind: Runtime.ContextKind

    @ObservationIgnored weak var modelContext: WebInspectorContext?

    init(context: Runtime.ExecutionContext, modelContext: WebInspectorContext) {
        id = ID(context.id)
        name = context.name
        frameID = context.frameID
        kind = context.kind
        self.modelContext = modelContext
    }

    func update(from context: Runtime.ExecutionContext) {
        name = context.name
        frameID = context.frameID
        kind = context.kind
    }
}
