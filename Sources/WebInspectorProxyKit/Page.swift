import Foundation

public enum Page {
    public struct Client: Sendable {
        package let context: DomainClientContext

        package init(context: DomainClientContext) {
            self.context = context
        }

        public func reload(ignoringCache: Bool = false) async throws {
            try await context.dispatchVoid(
                domain: .page,
                method: "reload",
                payload: ReloadPayload(ignoringCache: ignoringCache)
            )
        }
    }

    package struct ReloadPayload: Sendable {
        package let ignoringCache: Bool

        package init(ignoringCache: Bool) {
            self.ignoringCache = ignoringCache
        }
    }
}
