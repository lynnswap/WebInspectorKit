import Foundation

public enum Page {
    public struct Client: Sendable {
        package let context: DomainClientContext

        package init(context: DomainClientContext) {
            self.context = context
        }

        public func reload(ignoringCache: Bool = false) async throws {
            throw unimplementedCommand(domain: "Page", method: "reload")
        }
    }
}
