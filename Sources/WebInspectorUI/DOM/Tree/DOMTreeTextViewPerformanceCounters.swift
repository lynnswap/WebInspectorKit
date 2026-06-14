#if canImport(UIKit) && DEBUG
extension DOMTreeTextView {
    @MainActor
    final class PerformanceCounters {
        var reloadTreeCallCount = 0
        var buildRenderedRowsCallCount = 0
        var rebuildTextStorageCallCount = 0
        var incrementalTextStorageEditCallCount = 0
        var resetTextFragmentViewsCallCount = 0

        func reset() {
            reloadTreeCallCount = 0
            buildRenderedRowsCallCount = 0
            rebuildTextStorageCallCount = 0
            incrementalTextStorageEditCallCount = 0
            resetTextFragmentViewsCallCount = 0
        }
    }
}
#endif
