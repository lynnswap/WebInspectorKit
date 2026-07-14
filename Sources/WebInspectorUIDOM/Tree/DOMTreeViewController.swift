#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import UIKit

@MainActor
package final class DOMTreeViewController: UIViewController {
    private let treeView: DOMTreeTextView

    package var domTreeUndoManager: UndoManager? {
        treeView.undoManager
    }

    package init(model: DOMPanelModel) {
        treeView = Self.makeTreeView(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    private static func makeTreeView(
        model: DOMPanelModel
    ) -> DOMTreeTextView {
        let context = model.context
        let requestChildren: DOMTreeTextView.RequestChildrenAction = { [weak context] nodeID in
            guard let context else {
                return false
            }
            do {
                try await context.container.dom.requestChildren(of: nodeID)
                return true
            } catch {
                WebInspectorUIDOMLog.debug("DOM tree request children failed nodeID=\(String(describing: nodeID)): \(String(describing: error))")
                return false
            }
        }
        let highlightNode: DOMTreeTextView.HighlightNodeAction = { [weak context] nodeID, _ in
            guard let context else {
                return
            }
            try await context.container.dom.highlight(nodeID)
        }
        let restoreHighlight: DOMTreeTextView.RestoreHighlightAction = { [weak context, weak model] in
            guard let context else {
                return
            }
            if let selectedNodeID = model?.selectedNodeID {
                try await context.container.dom.highlight(selectedNodeID)
            } else {
                try await context.container.dom.hideHighlight()
            }
        }
        let copyNodeText: DOMTreeTextView.CopyNodeTextAction = { [weak context] nodeID, kind in
            guard let context else {
                return nil
            }
            do {
                return try await context.container.dom.text(kind, for: nodeID)
            } catch {
                WebInspectorUIDOMLog.debug("DOM tree copy text failed nodeID=\(String(describing: nodeID)): \(String(describing: error))")
                return nil
            }
        }
        let deleteNodes: DOMTreeTextView.DeleteNodesAction = { [weak context] nodeIDs, undoManager in
            guard let context else {
                return false
            }
            return await deleteNodeIDs(
                nodeIDs,
                context: context,
                undoManager: undoManager
            )
        }
        return DOMTreeTextView(
            model: model,
            requestChildrenAction: requestChildren,
            highlightNodeAction: highlightNode,
            restoreHighlightAction: restoreHighlight,
            copyNodeTextAction: copyNodeText,
            deleteNodesAction: deleteNodes
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override package func loadView() {
        treeView.backgroundColor = webInspectorBackgroundPolicy.backgroundColor
        treeView.accessibilityIdentifier = "WebInspector.DOM.Tree.NativeTextView"
        view = treeView
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        applyBackgroundFromTraits()
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { viewController in
                viewController.applyBackgroundFromTraits()
            }
        }
    }

    private func applyBackgroundFromTraits() {
        treeView.backgroundColor = webInspectorBackgroundPolicy.backgroundColor
    }

    private static func deleteNodeIDs(
        _ nodeIDs: [DOMNode.ID],
        context: WebInspectorModelContext,
        undoManager: UndoManager?
    ) async -> Bool {
        do {
            let result = try await context.container.dom.removeNodes(nodeIDs)
            guard let undo = result.undo else {
                return false
            }
            DOMDeletionUndoRegistration.registerDeleteUndo(
                on: undoManager,
                capability: undo,
                deletedNodeCount: result.appliedNodeIDs.count
            )
            return result.appliedNodeIDs.isEmpty == false
        } catch {
            WebInspectorUIDOMLog.debug("DOM tree delete failed nodeIDs=\(nodeIDs.map { String(describing: $0) }): \(String(describing: error))")
            return false
        }
    }

    override package func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        treeView.setRenderingActive(true)
    }

    override package func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        treeView.setRenderingActive(false)
    }
}

#if DEBUG
extension DOMTreeViewController {
    var displayedDOMTreeTextViewForTesting: DOMTreeTextView {
        treeView
    }
}
#endif

#endif
