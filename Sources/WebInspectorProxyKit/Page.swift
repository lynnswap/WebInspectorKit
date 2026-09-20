import Foundation

/// Types and commands for the Web Inspector Page domain.
public enum Page {
    /// A target-scoped client for Page commands.
    public struct Client: Sendable {
        package let context: DomainClientContext

        package init(context: DomainClientContext) {
            self.context = context
        }

        package func enable() async throws {
            try await context.dispatchVoid(
                domain: .page,
                method: "enable",
                payload: EnablePayload()
            )
        }

        package func disable() async throws {
            try await context.dispatchVoid(
                domain: .page,
                method: "disable",
                payload: DisablePayload()
            )
        }

        package func resourceTree() async throws -> WebInspectorProxyCommandReply<ResourceTree> {
            try await context.dispatchWithReplyBoundary(
                domain: .page,
                method: "getResourceTree",
                payload: ResourceTreePayload(),
                returning: ResourceTree.self
            )
        }

        package func resourceContent(frameID: FrameID, url: String) async throws -> WebInspectorProxyCommandReply<Network.Body> {
            try await context.dispatchWithReplyBoundary(
                domain: .page,
                method: "getResourceContent",
                payload: ResourceContentPayload(frameID: frameID, url: url),
                returning: Network.Body.self
            )
        }

        /// Reloads the inspected page.
        public func reload(ignoringCache: Bool = false) async throws {
            try await context.dispatchVoid(
                domain: .page,
                method: "reload",
                payload: ReloadPayload(ignoringCache: ignoringCache)
            )
        }
    }

    package struct EnablePayload: Sendable {
        package init() {}
    }

    package struct DisablePayload: Sendable {
        package init() {}
    }

    package struct ReloadPayload: Sendable {
        package let ignoringCache: Bool

        package init(ignoringCache: Bool) {
            self.ignoringCache = ignoringCache
        }
    }

    package struct ResourceTree: Decodable, Sendable {
        package struct Frame: Decodable, Sendable {
            package let id: String
            package let loaderId: String
            package let url: String
            package let mimeType: String
        }

        package struct Resource: Decodable, Sendable {
            package let url: String
            package let type: String
            package let mimeType: String
            package let failed: Bool?
            package let canceled: Bool?
            package let sourceMapURL: String?
            package let targetId: String?
        }

        package let frame: Frame
        package let childFrames: [ResourceTree]?
        package let resources: [Resource]
    }

    package struct ResourceContentPayload: Sendable {
        package let frameID: FrameID
        package let url: String
    }

    package struct ResourceTreePayload: Sendable {}
}
