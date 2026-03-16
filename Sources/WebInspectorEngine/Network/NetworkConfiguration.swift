import Foundation

public struct NetworkConfiguration: Sendable {
    /// Optional cap for how many `NetworkEntry` values are retained in `NetworkStore.entries`.
    /// When exceeded, the store prunes oldest entries first.
    public var maxEntries: Int?

    public init(maxEntries: Int? = nil) {
        if let maxEntries, maxEntries > 0 {
            self.maxEntries = maxEntries
        } else {
            self.maxEntries = nil
        }
    }
}

