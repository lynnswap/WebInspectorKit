#if canImport(UIKit)
import UIKit
import V2_WebInspectorCore
import V2_WebInspectorRuntime

@MainActor
package final class V2_DOMTreeViewController: UIViewController {
    private let treeView: V2_DOMTreeTextView

    package init(session: V2_InspectorSession) {
        self.treeView = V2_DOMTreeTextView(
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
        self.treeView = V2_DOMTreeTextView(dom: dom)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override package func loadView() {
        treeView.backgroundColor = .clear
        treeView.accessibilityIdentifier = "WebInspector.DOM.Tree.NativeTextView.V2"
        view = treeView
    }
}

#if DEBUG
extension V2_DOMTreeViewController {
    var displayedDOMTreeTextViewForTesting: V2_DOMTreeTextView {
        treeView
    }
}

#Preview("V2 DOM Tree") {
    let viewController = V2_DOMTreeViewController(dom: V2_DOMPreviewFixtures.makeDOMSession())
    return UINavigationController(rootViewController: viewController)
}
#endif
#endif
