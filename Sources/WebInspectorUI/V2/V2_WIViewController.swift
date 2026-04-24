#if canImport(UIKit)
import UIKit
import WebKit

@MainActor
public final class V2_WIViewController: UIViewController {
    private enum HostKind {
        case compact
        case regular
    }

    public let session: V2_WISession

    private var activeHost: UIViewController?
    private var activeHostKind: HostKind?

    public init(session: V2_WISession = V2_WISession()) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    public convenience init(tabs: [V2_WITab]) {
        self.init(session: V2_WISession(tabs: tabs))
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
        traitCollection.horizontalSizeClass == .compact ? .compact : .regular
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

        let host: UIViewController
        switch kind {
        case .compact:
            host = V2_WICompactTabBarController(session: session)
        case .regular:
            host = V2_WIRegularTabContentViewController(session: session)
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
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI

#Preview("V2_WIViewController") {
    V2_WIViewController()
}
#endif
#endif
