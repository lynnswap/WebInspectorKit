#if canImport(UIKit)
import UIKit
import WebKit
import WebInspectorRuntime

@MainActor
final class V2_DOMTreeViewController: UIViewController {
    private let dom: V2_WIDOMRuntime
    private let containerView = UIView()
    private weak var displayedDOMTreeWebView: WKWebView?

    init(dom: V2_WIDOMRuntime) {
        self.dom = dom
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        containerView.backgroundColor = .clear
        view = containerView
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        guard parent != nil, isViewLoaded else {
            return
        }
        attachDOMTreeWebView()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        attachDOMTreeWebView()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncDOMTreeWebViewFrame()
    }

    private func attachDOMTreeWebView() {
        let domTreeWebView = dom.treeWebViewForPresentation()
        if let displayedDOMTreeWebView,
           displayedDOMTreeWebView !== domTreeWebView,
           displayedDOMTreeWebView.superview === containerView {
            displayedDOMTreeWebView.removeFromSuperview()
        }
        displayedDOMTreeWebView = domTreeWebView
        guard domTreeWebView.superview !== containerView else {
            return
        }

        domTreeWebView.removeFromSuperview()
        domTreeWebView.translatesAutoresizingMaskIntoConstraints = true
        domTreeWebView.frame = containerView.bounds
        domTreeWebView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        containerView.addSubview(domTreeWebView)
    }

    private func syncDOMTreeWebViewFrame() {
        guard let displayedDOMTreeWebView,
              displayedDOMTreeWebView.superview === containerView,
              displayedDOMTreeWebView.frame != containerView.bounds else {
            return
        }

        displayedDOMTreeWebView.frame = containerView.bounds
    }
}

#if DEBUG
extension V2_DOMTreeViewController {
    var displayedDOMTreeWebViewForTesting: WKWebView? {
        displayedDOMTreeWebView
    }
}
#endif
#endif
