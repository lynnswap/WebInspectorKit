import Foundation

/// A target-scoped handle for Web Inspector Page commands.
public struct Page: Sendable, WebInspectorDomainHandle {
    package static let commandDomain = WebInspectorProxyDomain.page

    package let endpoint: DomainEndpoint

    package init(endpoint: DomainEndpoint) {
        self.endpoint = endpoint
    }

    /// Reloads the inspected page.
    public func reload(ignoringCache: Bool = false) async throws {
        try await dispatchVoid(
            method: "reload",
            payload: ReloadPayload(ignoringCache: ignoringCache)
        )
    }

    package struct ReloadPayload: Sendable {
        package let ignoringCache: Bool

        package init(ignoringCache: Bool) {
            self.ignoringCache = ignoringCache
        }
    }
}
