import Foundation

public struct WebInspectorConfiguration: Sendable {
    /// Maximum DOM depth captured in the initial/full document snapshot.
    public var snapshotDepth: Int
    /// Depth used when requesting child subtrees (DOM.requestChildNodes).
    public var subtreeDepth: Int
    /// Debounce window (seconds) for automatic DOM snapshot updates.
    public var autoUpdateDebounce: TimeInterval

    public init(
        snapshotDepth: Int = 4,
        subtreeDepth: Int = 3,
        autoUpdateDebounce: TimeInterval = 0.6
    ) {
        self.snapshotDepth = max(1, snapshotDepth)
        self.subtreeDepth = max(1, subtreeDepth)
        self.autoUpdateDebounce = max(0, autoUpdateDebounce)
    }
}
