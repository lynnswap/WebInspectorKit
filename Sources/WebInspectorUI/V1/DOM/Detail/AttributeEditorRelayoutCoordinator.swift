import Foundation

struct AttributeEditorRelayoutCoordinator {
    private(set) var dequeueDepth = 0
    private(set) var hasPendingRelayout = false
    private(set) var isPerformingRelayout = false

    mutating func beginCellDequeue() {
        dequeueDepth += 1
    }

    mutating func endCellDequeue() {
        dequeueDepth = max(0, dequeueDepth - 1)
    }

    mutating func requestRelayout() {
        hasPendingRelayout = true
    }

    mutating func beginRelayoutIfPossible(isViewVisible: Bool) -> Bool {
        guard
            isViewVisible,
            hasPendingRelayout,
            dequeueDepth == 0,
            !isPerformingRelayout
        else {
            return false
        }

        hasPendingRelayout = false
        isPerformingRelayout = true
        return true
    }

    mutating func finishRelayout() {
        isPerformingRelayout = false
    }
}
