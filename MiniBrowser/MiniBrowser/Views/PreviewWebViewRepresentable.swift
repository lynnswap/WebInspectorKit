import SwiftUI
import WebKit
import WebInspectorKit

#if os(macOS)
struct PreviewWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
import UIKit

struct PreviewWebViewRepresentable: UIViewControllerRepresentable {
    let webView: WKWebView

    func makeUIViewController(context: Context) -> BrowserPreviewWebViewController {
        BrowserPreviewWebViewController(webView: webView)
    }

    func updateUIViewController(_ uiViewController: BrowserPreviewWebViewController, context: Context) {
        uiViewController.setWebView(webView)
    }
}

@MainActor
final class BrowserPreviewWebViewController: UIViewController {
    private var currentWebView: WKWebView
    private var viewportCoordinator: WIWebViewViewportCoordinator?

    init(webView: WKWebView) {
        self.currentWebView = webView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installWebViewIfNeeded(currentWebView)
        viewportCoordinator = WIWebViewViewportCoordinator(
            hostViewController: self,
            webView: currentWebView
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        viewportCoordinator?.handleViewDidAppear()
    }

    func setWebView(_ webView: WKWebView) {
        if currentWebView === webView {
            viewportCoordinator?.updateChromeState()
            return
        }

        currentWebView.removeFromSuperview()
        currentWebView = webView
        installWebViewIfNeeded(webView)
        viewportCoordinator?.invalidate()
        viewportCoordinator = WIWebViewViewportCoordinator(
            hostViewController: self,
            webView: webView
        )
        viewportCoordinator?.updateChromeState()
    }

    private func installWebViewIfNeeded(_ webView: WKWebView) {
        guard webView.superview !== view else {
            return
        }

        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}
#endif
