#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import SwiftUI
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
                guard let node = context.dom.node(for: nodeID) else {
                    WebInspectorUIDOMLog.debug("DOM tree request children ignored an unregistered nodeID=\(String(describing: nodeID))")
                    return false
                }
                await context.dom.requestChildren(of: node)
                return true
            },
            highlightNodeAction: { [weak context] nodeID, _ in
                guard let context, let node = context.dom.node(for: nodeID) else {
                    return
                }
                try await context.dom.highlight(node)
            },
            restoreHighlightAction: { [weak context] in
                guard let context else {
                    return
                }
                if let selectedNode = context.dom.selectedNode {
                    try await context.dom.highlight(selectedNode)
                } else {
                    try await context.dom.hideHighlight()
                }
            },
            copyNodeTextAction: { [weak context] nodeID, kind in
                guard let context, let node = context.dom.node(for: nodeID) else {
                    return nil
                }
                do {
                    return try await context.dom.copyText(kind, of: node)
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
        var nodes: [DOMNode] = []
        for nodeID in nodeIDs {
            guard let node = context.dom.node(for: nodeID) else {
                WebInspectorUIDOMLog.debug("DOM tree delete ignored an unregistered nodeID=\(String(describing: nodeID))")
                return false
            }
            nodes.append(node)
        }
        let deletedNodeCount: Int
        let undoCommands: WebInspectorContext.DOMUndoRedoCommands
        do {
            deletedNodeCount = try await context.dom.remove(nodes).count
            undoCommands = try context.domUndoRedoCommands()
        } catch let error as WebInspectorContext.DOMDeletionPartialFailure {
            guard let partialUndoCommands = try? context.domUndoRedoCommands() else {
                return false
            }
            DOMDeletionUndoRegistration.registerDeleteUndo(
                on: undoManager,
                commands: partialUndoCommands,
                deletedNodeCount: error.deletedNodeCount
            )
            return error.deletedNodeCount > 0
        } catch {
            WebInspectorUIDOMLog.debug("DOM tree delete failed nodeIDs=\(nodeIDs.map { String(describing: $0) }): \(String(describing: error))")
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

#Preview("DOM Tree", traits: .modifier(DOMPreviewPreparation())) {
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
