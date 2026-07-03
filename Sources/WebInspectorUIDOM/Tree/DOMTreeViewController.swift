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
                    try await context.requestChildren(for: nodeID)
                    return true
                } catch {
                    return false
                }
            },
            highlightNodeAction: { [weak context] nodeID, _ in
                try? await context?.highlightNode(for: nodeID)
            },
            restoreHighlightAction: { [weak context] in
                guard let context else {
                    return
                }
                if let selectedNode = context.selectedNode {
                    try? await selectedNode.highlight()
                } else {
                    try? await context.hideHighlight()
                }
            },
            copyNodeTextAction: { [weak context] nodeID, kind in
                guard let context else {
                    return nil
                }
                return try? await context.copyText(kind, for: nodeID)
            },
            deleteNodesAction: { [weak context] nodeIDs, _ in
                guard let context else {
                    return false
                }
                do {
                    try await context.delete(nodeIDs: nodeIDs)
                    return true
                } catch {
                    return false
                }
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
