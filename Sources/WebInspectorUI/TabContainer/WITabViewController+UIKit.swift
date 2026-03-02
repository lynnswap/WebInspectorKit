import WebKit
import WebInspectorRuntime

#if canImport(UIKit)
import UIKit

@MainActor
private protocol WIUIKitTabHost where Self: UIViewController {
    func prepareForRemoval()
}

@MainActor
public final class WITabViewController: UIViewController {
    private enum HostKind {
        case compact
        case regular
    }

    public private(set) var inspectorController: WIModel

    private var activeHost: (UIViewController & WIUIKitTabHost)?
    private var activeHostKind: HostKind?

    var horizontalSizeClassOverrideForTesting: UIUserInterfaceSizeClass?

    public init(
        _ inspectorController: WIModel,
        webView: WKWebView?,
        tabs: [WITab] = [.dom(), .network()]
    ) {
        self.inspectorController = inspectorController
        super.init(nibName: nil, bundle: nil)
        if let webView {
            inspectorController.setPageWebViewFromUI(webView)
        }
        inspectorController.setTabs(tabs)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public func setPageWebView(_ webView: WKWebView?) {
        inspectorController.setPageWebViewFromUI(webView)
        if isViewLoaded {
            inspectorController.activateFromUIIfPossible()
        }
    }

    public func setInspectorController(_ inspectorController: WIModel) {
        guard self.inspectorController !== inspectorController else {
            return
        }

        let currentTabs = self.inspectorController.tabs
        let currentSelectedTab = self.inspectorController.selectedTab
        let currentPageWebView = self.inspectorController.pageWebViewForUI
        let previousController = self.inspectorController
        resetCachedContentViewControllers(for: currentTabs)
        previousController.disconnect()

        self.inspectorController = inspectorController
        inspectorController.setPageWebViewFromUI(currentPageWebView)
        inspectorController.setTabs(currentTabs)
        inspectorController.setSelectedTabFromUI(currentSelectedTab)

        if isViewLoaded {
            rebuildLayout(forceHostReplacement: true)
            inspectorController.activateFromUIIfPossible()
        }
    }

    public func setTabs(_ tabs: [WITab]) {
        inspectorController.setTabs(tabs)
        if isViewLoaded {
            rebuildLayout()
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        rebuildLayout(forceHostReplacement: true)

        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.handleHorizontalSizeClassChange()
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        inspectorController.activateFromUIIfPossible()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if view.window == nil {
            inspectorController.suspend()
        }
    }

    var activeHostKindForTesting: String? {
        switch activeHostKind {
        case .compact:
            return "compact"
        case .regular:
            return "regular"
        case nil:
            return nil
        }
    }

    var resolvedTabIDsForTesting: [String] {
        resolvedTabsForCurrentLayout(requestedTabs: inspectorController.tabs).map(\.identifier)
    }

    var activeHostViewControllerForTesting: UIViewController? {
        activeHost
    }

    private var effectiveHorizontalSizeClass: UIUserInterfaceSizeClass {
        horizontalSizeClassOverrideForTesting ?? traitCollection.horizontalSizeClass
    }

    private func rebuildLayout(forceHostReplacement: Bool = false) {
        let targetHostKind: HostKind = effectiveHorizontalSizeClass == .compact ? .compact : .regular

        if activeHostKind == .compact,
           targetHostKind == .regular,
           inspectorController.selectedTab?.identifier == WITab.elementTabID {
            let domTab = inspectorController.tabs.first(where: { $0.identifier == WITab.domTabID })
            inspectorController.setSelectedTabFromUI(domTab)
        }

        if forceHostReplacement || activeHostKind != targetHostKind {
            installHost(of: targetHostKind)
        }
    }

    private func installHost(of kind: HostKind) {
        if let activeHost {
            activeHost.prepareForRemoval()
            activeHost.willMove(toParent: nil)
            activeHost.view.removeFromSuperview()
            activeHost.removeFromParent()
        }

        let host: UIViewController & WIUIKitTabHost
        switch kind {
        case .compact:
            host = WICompactTabHostViewController(model: inspectorController)
        case .regular:
            host = WIRegularTabHostViewController(model: inspectorController)
        }

        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)

        activeHost = host
        activeHostKind = kind
    }

    private func handleHorizontalSizeClassChange() {
        rebuildLayout()
    }

    private func resolvedTabsForCurrentLayout(requestedTabs: [WITab]) -> [WITab] {
        guard effectiveHorizontalSizeClass == .compact else {
            return requestedTabs.filter { $0.identifier != WITab.elementTabID }
        }
        return requestedTabs
    }

    private func resetCachedContentViewControllers(for tabs: [WITab]) {
        for tab in tabs {
            tab.resetCachedContentViewController()
        }
    }

    func makeTabRootViewController(for tab: WITab) -> UIViewController? {
        if let cached = tab.cachedContentViewController {
            applyHorizontalSizeClassOverrideIfNeeded(to: cached)
            return cached
        }

        let viewController: UIViewController?
        if let customViewController = tab.viewControllerProvider?(tab) {
            viewController = customViewController
        } else {
            switch tab.identifier {
            case WITab.domTabID:
                viewController = WIDOMViewController(inspector: inspectorController.dom)
            case WITab.elementTabID:
                viewController = WIDOMDetailViewController(inspector: inspectorController.dom)
            case WITab.networkTabID:
                viewController = WINetworkViewController(inspector: inspectorController.network)
            default:
                viewController = nil
            }
        }

        guard let viewController else {
            return nil
        }
        applyHorizontalSizeClassOverrideIfNeeded(to: viewController)
        tab.cachedContentViewController = viewController
        return viewController
    }

    private func applyHorizontalSizeClassOverrideIfNeeded(to viewController: UIViewController) {
        if let domViewController = viewController as? WIDOMViewController {
            domViewController.horizontalSizeClassOverrideForTesting = effectiveHorizontalSizeClass
        }
        if let networkViewController = viewController as? WINetworkViewController {
            networkViewController.horizontalSizeClassOverrideForTesting = effectiveHorizontalSizeClass
        }
    }
}

extension WICompactTabHostViewController: WIUIKitTabHost {}
extension WIRegularTabHostViewController: WIUIKitTabHost {}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("Tab Container (UIKit)") {
    WIUIKitPreviewContainer {
        let session = WIModel()
        WIDOMPreviewFixtures.applySampleSelection(to: session.dom, mode: .selected)
        let previewWebView = WIDOMPreviewFixtures.bootstrapDOMTreeForPreview(session.dom)
        WINetworkPreviewFixtures.applySampleData(to: session.network, mode: .detail)
        return WITabViewController(
            session,
            webView: previewWebView,
            tabs: [.dom(), .network()]
        )
    }
}
#endif


#endif
