#if canImport(UIKit)
import UIKit
import WebInspectorCore
import WebInspectorRuntime

@MainActor
package final class DOMElementViewController: UIViewController {
    package let dom: DOMSession
    package let css: CSSSession

    package convenience init(session: InspectorSession) {
        self.init(
            dom: session.dom,
            css: session.css
        )
    }

    package convenience init(dom: DOMSession) {
        self.init(
            dom: dom,
            css: CSSSession()
        )
    }

    package init(
        dom: DOMSession,
        css: CSSSession
    ) {
        self.dom = dom
        self.css = css
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }
}

#Preview("DOM Element") {
    DOMElementViewControllerPreview.makeViewController()
}

@MainActor
private enum DOMElementViewControllerPreview {
    static func makeViewController() -> UINavigationController {
        let dom = DOMPreviewFixtures.makeDOMSession()
        if let root = dom.currentPageRootNode,
           let body = dom.visibleDOMTreeChildren(of: root).last,
           let selectedNode = dom.visibleDOMTreeChildren(of: body).first {
            dom.selectNode(selectedNode.id)
        }
        return UINavigationController(rootViewController: DOMElementViewController(dom: dom))
    }
}
#endif
