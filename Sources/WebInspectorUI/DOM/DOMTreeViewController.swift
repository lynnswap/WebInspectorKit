#if canImport(UIKit)
import UIKit
import WebInspectorCore
import WebInspectorRuntime

@MainActor
package final class DOMTreeViewController: UIViewController {
    private let treeView: DOMTreeTextView

    package init(session: InspectorSession) {
        self.treeView = DOMTreeTextView(
            dom: session.dom,
            requestChildrenAction: { [weak session] nodeID in
                await session?.requestChildNodes(for: nodeID) ?? false
            },
            highlightNodeAction: { [weak session] nodeID in
                await session?.highlightNode(for: nodeID)
            },
            hideHighlightAction: { [weak session] in
                await session?.hideNodeHighlight()
            }
        )
        super.init(nibName: nil, bundle: nil)
    }

    package init(dom: DOMSession) {
        self.treeView = DOMTreeTextView(dom: dom)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override package func loadView() {
        treeView.backgroundColor = .clear
        treeView.accessibilityIdentifier = "WebInspector.DOM.Tree.NativeTextView"
        view = treeView
    }
}

#if DEBUG
extension DOMTreeViewController {
    var displayedDOMTreeTextViewForTesting: DOMTreeTextView {
        treeView
    }
}

#Preview("DOM Tree") {
    let viewController = DOMTreeViewController(dom: DOMPreviewFixtures.makeDOMSession())
    return UINavigationController(rootViewController: viewController)
}
#endif
#endif
