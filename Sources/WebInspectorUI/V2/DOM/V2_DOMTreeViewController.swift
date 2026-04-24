#if canImport(UIKit)
import UIKit
import WebKit
import WebInspectorRuntime

@MainActor
final class V2_DOMTreeViewController: UIViewController {
    private let dom: V2_WIDOMRuntime
    private let domTreeWebViewContainer = UIView()
    private var domTreeWebViewConstraints: [NSLayoutConstraint] = []

    init(dom: V2_WIDOMRuntime) {
        self.dom = dom
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureDOMTreeWebViewContainer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        attachDOMTreeWebViewIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if view.window == nil {
            detachDOMTreeWebViewIfNeeded()
        }
    }

    private func configureDOMTreeWebViewContainer() {
        domTreeWebViewContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(domTreeWebViewContainer)
        NSLayoutConstraint.activate([
            domTreeWebViewContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            domTreeWebViewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            domTreeWebViewContainer.topAnchor.constraint(equalTo: view.topAnchor),
            domTreeWebViewContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func attachDOMTreeWebViewIfNeeded() {
        guard isViewLoaded, view.window != nil else {
            return
        }

        let domTreeWebView = dom.treeWebViewForPresentation()
        guard domTreeWebView.superview !== domTreeWebViewContainer else {
            return
        }

        NSLayoutConstraint.deactivate(domTreeWebViewConstraints)
        domTreeWebViewConstraints.removeAll(keepingCapacity: true)
        domTreeWebView.removeFromSuperview()
        domTreeWebView.translatesAutoresizingMaskIntoConstraints = false
        domTreeWebViewContainer.addSubview(domTreeWebView)

        let constraints = [
            domTreeWebView.leadingAnchor.constraint(equalTo: domTreeWebViewContainer.leadingAnchor),
            domTreeWebView.trailingAnchor.constraint(equalTo: domTreeWebViewContainer.trailingAnchor),
            domTreeWebView.topAnchor.constraint(equalTo: domTreeWebViewContainer.topAnchor),
            domTreeWebView.bottomAnchor.constraint(equalTo: domTreeWebViewContainer.bottomAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        domTreeWebViewConstraints = constraints
    }

    private func detachDOMTreeWebViewIfNeeded() {
        NSLayoutConstraint.deactivate(domTreeWebViewConstraints)
        domTreeWebViewConstraints.removeAll(keepingCapacity: true)
        domTreeWebViewContainer.subviews.forEach { $0.removeFromSuperview() }
    }
}
#endif
