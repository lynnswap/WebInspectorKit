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
        private var lastObservedRequestRevision: UInt64?
        private(set) var pendingSelectedNodeID: DOMNode.ID?

        func observe(
            selectedNodeID: DOMNode.ID?,
            requestRevision: UInt64?,
            revealPolicy: DOMRevealPolicy
        ) -> DOMTreeTextView.SelectionObservation {
            let selectedNodeIDChanged = selectedNodeID != lastObservedSelectedNodeID
            lastObservedSelectedNodeID = selectedNodeID

            let revealRequestChanged: Bool
            if let requestRevision {
                revealRequestChanged = requestRevision != lastObservedRequestRevision
                lastObservedRequestRevision = requestRevision
            } else {
                revealRequestChanged = selectedNodeIDChanged
            }
            if revealRequestChanged {
                pendingSelectedNodeID = revealPolicy == .selectAndScroll
                    ? selectedNodeID
                    : nil
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
            lastObservedRequestRevision = nil
            pendingSelectedNodeID = nil
        }
    }
}
#endif
