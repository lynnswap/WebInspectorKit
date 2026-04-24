#if canImport(UIKit)
import UIKit
import WebKit
import WebInspectorRuntime

@MainActor
final class V2_DOMTreeViewController: UINavigationController {
    init(dom: V2_WIDOMRuntime) {
        super.init(rootViewController: V2_DOMTreeContentViewController(dom: dom))
        wiApplyClearNavigationBarStyle(to: self)
        setNavigationBarHidden(true, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
private final class V2_DOMTreeContentViewController: UIViewController {
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
        let domTreeWebView = displayedDOMTreeWebView ?? dom.treeWebViewForPresentation()
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
#endif
