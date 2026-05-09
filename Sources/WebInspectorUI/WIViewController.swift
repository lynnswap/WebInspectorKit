#if canImport(UIKit)
import UIKit
import WebKit
import WebInspectorRuntime

@MainActor
public final class WIViewController: UIViewController {
    private enum HostKind {
        case compact
        case regular
    }

    public let session: WISession

    private var activeHost: UIViewController?
    private var activeHostKind: HostKind?
    var horizontalSizeClassOverrideForTesting: UIUserInterfaceSizeClass? {
        didSet {
            rebuildLayout(forceHostReplacement: true)
        }
    }

    public init(session: WISession = WISession()) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    public convenience init(
        configuration: WIModelConfiguration,
        dependencies: WIInspectorDependencies = .liveValue,
        tabs: [WITab] = [.dom, .network]
    ) {
        self.init(
            session: WISession(
                configuration: configuration,
                dependencies: dependencies,
                tabs: tabs
            )
        )
    }

    public convenience init(
        dependencies: WIInspectorDependencies,
        tabs: [WITab] = [.dom, .network]
    ) {
        self.init(
            configuration: .init(),
            dependencies: dependencies,
            tabs: tabs
        )
    }

    public convenience init(tabs: [WITab]) {
        self.init(
            session: WISession(tabs: tabs)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        rebuildLayout(forceHostReplacement: true)
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.handleHorizontalSizeClassChange()
        }
    }

    public func attach(to webView: WKWebView) async {
        await session.attach(to: webView)
    }

    public func detach() async {
        await session.detach()
    }

    private var effectiveHostKind: HostKind {
        (horizontalSizeClassOverrideForTesting ?? traitCollection.horizontalSizeClass) == .compact ? .compact : .regular
    }

    private func handleHorizontalSizeClassChange() {
        rebuildLayout()
    }

    private func rebuildLayout(forceHostReplacement: Bool = false) {
        let targetHostKind = effectiveHostKind
        guard forceHostReplacement || activeHostKind != targetHostKind else {
            return
        }
        installHost(of: targetHostKind)
    }

    private func installHost(of kind: HostKind) {
        if let activeHost {
            activeHost.willMove(toParent: nil)
            activeHost.view.removeFromSuperview()
            activeHost.removeFromParent()
        }
        activeHost = nil
        activeHostKind = nil

        let host: UIViewController
        switch kind {
        case .compact:
            host = WICompactTabBarController(session: session)
        case .regular:
            host = WIRegularTabContentViewController(session: session)
        }

        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        activeHost = host
        activeHostKind = kind
    }

    var activeHostViewControllerForTesting: UIViewController? {
        activeHost
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI

#Preview("WIViewController") {
    WIViewController()
}

#Preview("WIViewController Sheet") {
    WIPreviewSheetHostViewController()
}

@MainActor
private final class WIPreviewSheetHostViewController: UIViewController, WKNavigationDelegate {
    private let webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }()

    private let inspector = WIViewController()
    private var didAppear = false
    private var didFinishLoading = false
    private var didStartInspectorPresentation = false

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        webView.loadHTMLString(
            Self.loadPreviewHTML(),
            baseURL: Self.previewBaseURL
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppear = true
        presentInspectorIfReady()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishLoading = true
        presentInspectorIfReady()
    }

    private func presentInspectorIfReady() {
        guard didAppear, didFinishLoading, !didStartInspectorPresentation else {
            return
        }
        didStartInspectorPresentation = true

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await inspector.attach(to: webView)
            inspector.modalPresentationStyle = .pageSheet
            if let sheet = inspector.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.selectedDetentIdentifier = .medium
                sheet.prefersGrabberVisible = true
                sheet.prefersScrollingExpandsWhenScrolledToEdge = false
                sheet.largestUndimmedDetentIdentifier = .medium
            }
            guard presentedViewController == nil else {
                return
            }
            present(inspector, animated: false)
        }
    }

    private static let previewBaseURL = URL(string: "https://preview.local")

    private static func loadPreviewHTML() -> String {
        guard
            let url = Bundle.module.url(
                forResource: "WebInspectorPreviewPage",
                withExtension: "html"
            ),
            let html = try? String(contentsOf: url, encoding: .utf8)
        else {
            return missingPreviewHTML
        }
        return html
    }

    private static let missingPreviewHTML = """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Missing WebInspectorKit Preview Resource</title>
      </head>
      <body>
        <main>
          <h1>Missing WebInspectorKit preview resource</h1>
          <p>WebInspectorPreviewPage.html could not be loaded.</p>
        </main>
      </body>
    </html>
    """
}
#endif
#endif
