import Foundation
import Observation
import WebViewProxyKit

@MainActor
@Observable
public final class RuntimeContext: Identifiable {
    public struct ID: Hashable, Sendable {
        package let proxyID: Runtime.ExecutionContext.ID

        package init(_ proxyID: Runtime.ExecutionContext.ID) {
            self.proxyID = proxyID
        }
    }

    public let id: ID
    public private(set) var name: String
    public private(set) var frameID: FrameID?
    public private(set) var kind: Runtime.ContextKind

    package init(context: Runtime.ExecutionContext) {
        id = ID(context.id)
        name = context.name
        frameID = context.frameID
        kind = context.kind
    }

    package func update(from context: Runtime.ExecutionContext) {
        name = context.name
        frameID = context.frameID
        kind = context.kind
    }
}
