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
}
