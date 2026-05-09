#if canImport(UIKit)
import UIKit
import WebKit
import WebInspectorRuntime

@MainActor
final class DOMTreeViewController: UIViewController {
    private let dom: WIDOMRuntime
    private let containerView = UIView()
    private weak var displayedDOMTreeWebView: WKWebView?

    init(dom: WIDOMRuntime) {
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

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        attachDOMTreeWebView()
        syncDOMTreeWebViewFrame()
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
extension DOMTreeViewController {
    var displayedDOMTreeWebViewForTesting: WKWebView? {
        displayedDOMTreeWebView
    }
}
#endif
#endif
