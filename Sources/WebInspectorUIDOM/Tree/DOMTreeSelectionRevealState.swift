#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit

extension DOMTreeTextView {
    struct SelectionObservation {
        var selectedNodeID: DOMNode.ID?
        var selectedNodeIDChanged: Bool
    }
}

extension DOMTreeTextView {
    @MainActor
    final class SelectionRevealState {
        private var lastObservedSelectedNodeID: DOMNode.ID?
        private(set) var pendingSelectedNodeID: DOMNode.ID?

        func observe(selectedNodeID: DOMNode.ID?) -> DOMTreeTextView.SelectionObservation {
            let selectedNodeIDChanged = selectedNodeID != lastObservedSelectedNodeID
            if selectedNodeIDChanged {
                lastObservedSelectedNodeID = selectedNodeID
                pendingSelectedNodeID = selectedNodeID
            }
            return DOMTreeTextView.SelectionObservation(
                selectedNodeID: selectedNodeID,
                selectedNodeIDChanged: selectedNodeIDChanged
            )
        }

        func clearPendingSelection() {
            pendingSelectedNodeID = nil
        }

        func consumePendingSelection() {
            pendingSelectedNodeID = nil
        }

        func reset() {
            lastObservedSelectedNodeID = nil
            pendingSelectedNodeID = nil
        }
    }
}
#endif
