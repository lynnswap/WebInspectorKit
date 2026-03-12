import Foundation

public struct DOMConfiguration: Sendable {
    private static let minimumSelectionRecoveryDepth = 6
    private static let minimumFullReloadDepth = 8

    /// Debounce window (seconds) for automatic DOM snapshot updates.
    public var autoUpdateDebounce: TimeInterval

    /// Preferred root snapshot depth used for the initial document bootstrap.
    public var snapshotDepth: Int {
        get { rootBootstrapDepth }
        set {
            let normalized = max(1, newValue)
            rootBootstrapDepth = normalized
            selectionRecoveryDepth = max(Self.minimumSelectionRecoveryDepth, normalized)
            fullReloadDepth = max(Self.minimumFullReloadDepth, selectionRecoveryDepth)
        }
    }

    /// Preferred subtree depth used when expanding nodes from the DOM tree.
    public var subtreeDepth: Int {
        get { expandedSubtreeFetchDepth }
        set { expandedSubtreeFetchDepth = max(1, newValue) }
    }

    package var rootBootstrapDepth: Int
    package var expandedSubtreeFetchDepth: Int
    package var selectionRecoveryDepth: Int
    package var fullReloadDepth: Int

    public init(
        autoUpdateDebounce: TimeInterval = 0.6,
        snapshotDepth: Int = 4,
        subtreeDepth: Int = 2
    ) {
        self.autoUpdateDebounce = max(0, autoUpdateDebounce)
        rootBootstrapDepth = max(1, snapshotDepth)
        expandedSubtreeFetchDepth = max(1, subtreeDepth)
        selectionRecoveryDepth = max(Self.minimumSelectionRecoveryDepth, rootBootstrapDepth)
        fullReloadDepth = max(Self.minimumFullReloadDepth, selectionRecoveryDepth)
    }

    package init(
        autoUpdateDebounce: TimeInterval = 0.6,
        rootBootstrapDepth: Int = 4,
        expandedSubtreeFetchDepth: Int = 2,
        selectionRecoveryDepth: Int = 6,
        fullReloadDepth: Int = 8
    ) {
        self.autoUpdateDebounce = max(0, autoUpdateDebounce)
        self.rootBootstrapDepth = max(1, rootBootstrapDepth)
        self.expandedSubtreeFetchDepth = max(1, expandedSubtreeFetchDepth)
        self.selectionRecoveryDepth = max(1, selectionRecoveryDepth)
        self.fullReloadDepth = max(self.selectionRecoveryDepth, fullReloadDepth)
    }
}
