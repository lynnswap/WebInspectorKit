#if canImport(UIKit)
import WebInspectorCore

struct DOMTreeSelectionObservation {
    var selectedNodeID: DOMNode.ID?
    var selectedNodeIDChanged: Bool
}

@MainActor
final class DOMTreeSelectionRevealState {
    private var lastObservedSelectedNodeID: DOMNode.ID?
    private(set) var pendingSelectedNodeID: DOMNode.ID?

    func observe(selectedNodeID: DOMNode.ID?) -> DOMTreeSelectionObservation {
        let selectedNodeIDChanged = selectedNodeID != lastObservedSelectedNodeID
        if selectedNodeIDChanged {
            lastObservedSelectedNodeID = selectedNodeID
            pendingSelectedNodeID = selectedNodeID
        }
        return DOMTreeSelectionObservation(
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
#endif
