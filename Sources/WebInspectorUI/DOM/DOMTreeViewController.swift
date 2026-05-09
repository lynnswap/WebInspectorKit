#if canImport(UIKit)
import UIKit
import WebInspectorRuntime

@MainActor
final class DOMTreeViewController: UIViewController {
    private let dom: WIDOMRuntime
    private let treeView: DOMTreeTextView

    init(dom: WIDOMRuntime) {
        self.dom = dom
        self.treeView = DOMTreeTextView(dom: dom)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
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
#endif
#endif
