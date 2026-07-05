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

    package init(context: WebInspectorContext) {
        self.treeView = DOMTreeTextView(
            context: context,
            requestChildrenAction: { [weak context] nodeID in
                guard let context else {
                    return false
                }
                do {
                    try await context.dom.requestChildren(of: nodeID)
                    return true
                } catch {
                    WebInspectorUIDOMLog.debug("DOM tree request children failed nodeID=\(String(describing: nodeID)): \(String(describing: error))")
                    return false
                }
            },
            highlightNodeAction: { [weak context] nodeID, _ in
                guard let context else {
                    return
                }
                try await context.dom.highlight(nodeID)
            },
            restoreHighlightAction: { [weak context] in
                guard let context else {
                    return
                }
                if let selectedNode = context.selectedNode {
                    try await context.dom.highlight(selectedNode.id)
                } else {
                    try await context.dom.hideHighlight()
                }
            },
            copyNodeTextAction: { [weak context] nodeID, kind in
                guard let context else {
                    return nil
                }
                do {
                    return try await context.copyText(kind, for: nodeID)
                } catch {
                    WebInspectorUIDOMLog.debug("DOM tree copy text failed nodeID=\(String(describing: nodeID)): \(String(describing: error))")
                    return nil
                }
            },
            deleteNodesAction: { [weak context] nodeIDs, undoManager in
                guard let context else {
                    return false
                }
                return await Self.deleteNodeIDs(
                    nodeIDs,
                    context: context,
                    undoManager: undoManager
                )
            }
        )
        super.init(nibName: nil, bundle: nil)
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
        context: WebInspectorContext,
        undoManager: UndoManager?
    ) async -> Bool {
        var undoCommands: WebInspectorContext.DOMUndoRedoCommands?
        let deletedNodeCount: Int
        do {
            let commands = try context.domUndoRedoCommands()
            undoCommands = commands
            let result = try await context.dom.remove(nodeIDs)
            deletedNodeCount = result.acceptedNodeIDs.count
        } catch let error as WebInspectorContext.DOMDeletionPartialFailure {
            guard let undoCommands else {
                return false
            }
            DOMDeletionUndoRegistration.registerDeleteUndo(
                on: undoManager,
                commands: undoCommands,
                deletedNodeCount: error.deletedNodeCount
            )
            return error.deletedNodeCount > 0
        } catch {
            WebInspectorUIDOMLog.debug("DOM tree delete failed nodeIDs=\(nodeIDs.map { String(describing: $0) }): \(String(describing: error))")
            return false
        }
        guard let undoCommands else {
            return false
        }
        DOMDeletionUndoRegistration.registerDeleteUndo(
            on: undoManager,
            commands: undoCommands,
            deletedNodeCount: deletedNodeCount
        )
        return deletedNodeCount > 0
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

#Preview("DOM Tree") {
    DOMTreeViewControllerPreview.makeViewController()
}

@MainActor
private enum DOMTreeViewControllerPreview {
    static func makeViewController() -> UINavigationController {
        let viewController = DOMTreeViewController(context: DOMPreviewFixtures.makeWebInspectorContext())
        return UINavigationController(rootViewController: viewController)
    }
}
#endif
