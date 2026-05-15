#if canImport(UIKit)
import UIKit
import WebKit

@MainActor
public final class WebInspectorViewController: UIViewController {
    private enum HostKind {
        case compact
        case regular
    }

    public let session: WebInspectorSession

    private var activeHost: UIViewController?
    private var activeHostKind: HostKind?
    package var horizontalSizeClassOverrideForTesting: UIUserInterfaceSizeClass? {
        didSet {
            rebuildLayout(forceHostReplacement: true)
        }
    }

    public init(session: WebInspectorSession = WebInspectorSession()) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    public convenience init(tabs: [WebInspectorTab]) {
        self.init(session: WebInspectorSession(tabs: tabs))
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

    public func attach(to webView: WKWebView) async throws {
        try await session.attach(to: webView)
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
            host = CompactTabBarController(session: session)
        case .regular:
            host = RegularTabContentViewController(session: session)
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

    package var activeHostViewControllerForTesting: UIViewController? {
        activeHost
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
import WebInspectorCore
import WebInspectorRuntime

@MainActor
enum WebInspectorViewControllerPreviewFixtures {
    static func makeSession() -> WebInspectorSession {
        WebInspectorSession(
            inspector: InspectorSession(
                dom: DOMPreviewFixtures.makeDOMSession(),
                network: NetworkPreviewFixtures.makeNetworkSession(mode: .detail)
            )
        )
    }
}

#Preview("WebInspectorViewController") {
    WebInspectorViewController(session: WebInspectorViewControllerPreviewFixtures.makeSession())
}
#endif
#endif
