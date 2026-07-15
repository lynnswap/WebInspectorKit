import WebInspectorUIBase
#if canImport(UIKit) && DEBUG
extension DOMTreeTextView {
    @MainActor
    final class PerformanceCounters {
        var reloadTreeCallCount = 0
        var buildRowRenderPlanCallCount = 0
        var replaceRowDocumentCallCount = 0
        var incrementalRowDocumentEditCallCount = 0
        var resetTextFragmentViewsCallCount = 0
        var rowSpanDisplayInvalidationCallCount = 0
        var textSegmentRectsCallCount = 0
        var updateContentDecorationsCallCount = 0

        func reset() {
            reloadTreeCallCount = 0
            buildRowRenderPlanCallCount = 0
            replaceRowDocumentCallCount = 0
            incrementalRowDocumentEditCallCount = 0
            resetTextFragmentViewsCallCount = 0
            rowSpanDisplayInvalidationCallCount = 0
            textSegmentRectsCallCount = 0
            updateContentDecorationsCallCount = 0
        }
    }
}
#endif
