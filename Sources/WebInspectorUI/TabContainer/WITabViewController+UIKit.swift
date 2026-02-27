import WebKit
import ObservationsCompat
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(UIKit)
import UIKit

@MainActor
public final class WITabViewController: UIViewController {
    private enum HostKind {
        case compact
        case regular
    }

    public private(set) var inspectorController: WISession

    private var networkQueryModel: WINetworkQueryModel
    private weak var pageWebView: WKWebView?
    private var requestedTabDescriptors: [WITabDescriptor]
    private var resolvedTabDescriptors: [WITabDescriptor]

    private var activeHost: (UIViewController & WIUIKitInspectorHostProtocol)?
    private var activeHostKind: HostKind?

    var horizontalSizeClassOverrideForTesting: UIUserInterfaceSizeClass?

    public init(
        _ inspectorController: WISession,
        webView: WKWebView?,
        tabs: [WITabDescriptor] = [.dom(), .network()]
    ) {
        self.inspectorController = inspectorController
        self.networkQueryModel = WINetworkQueryModel(inspector: inspectorController.network)
        self.pageWebView = webView
        self.requestedTabDescriptors = tabs
        self.resolvedTabDescriptors = tabs
        super.init(nibName: nil, bundle: nil)
        self.view.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public func setPageWebView(_ webView: WKWebView?) {
        pageWebView = webView
        if isViewLoaded {
            inspectorController.connect(to: webView)
        }
    }

    public func setInspectorController(_ inspectorController: WISession) {
        guard self.inspectorController !== inspectorController else {
            return
        }

        let previousController = self.inspectorController
        previousController.onSelectedTabIDChange = nil
        previousController.disconnect()

        self.inspectorController = inspectorController
        self.networkQueryModel = WINetworkQueryModel(inspector: inspectorController.network)
        self.inspectorController.enableUICommandRouting()
        bindSelectionCallback()

        if isViewLoaded {
            rebuildLayout(forceHostReplacement: true)
            inspectorController.connect(to: pageWebView)
        }
    }

    public func setTabs(_ tabs: [WITabDescriptor]) {
        requestedTabDescriptors = tabs
        if isViewLoaded {
            rebuildLayout()
        } else {
            applyResolvedTabDescriptors(
                WIUIKitTabLayoutPolicy.resolveTabs(
                    from: tabs,
                    horizontalSizeClass: effectiveHorizontalSizeClass
                )
            )
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        inspectorController.enableUICommandRouting()
        bindSelectionCallback()
        rebuildLayout(forceHostReplacement: true)

        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.handleHorizontalSizeClassChange()
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        inspectorController.connect(to: pageWebView)
        activeHost?.setSelectedTabID(inspectorController.selectedTabID)
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

    var resolvedTabIDsForTesting: [WITabDescriptor.ID] {
        resolvedTabDescriptors.map(\.id)
    }

    var activeHostViewControllerForTesting: UIViewController? {
        activeHost
    }

    private var effectiveHorizontalSizeClass: UIUserInterfaceSizeClass {
        horizontalSizeClassOverrideForTesting ?? traitCollection.horizontalSizeClass
    }

    private func makeContext() -> WITabContext {
        WITabContext(
            controller: inspectorController,
            networkQueryModel: networkQueryModel,
            horizontalSizeClass: effectiveHorizontalSizeClass
        )
    }

    private func rebuildLayout(forceHostReplacement: Bool = false) {
        let resolvedTabs = WIUIKitTabLayoutPolicy.resolveTabs(
            from: requestedTabDescriptors,
            horizontalSizeClass: effectiveHorizontalSizeClass
        )
        applyResolvedTabDescriptors(resolvedTabs)

        let targetHostKind: HostKind = effectiveHorizontalSizeClass == .compact ? .compact : .regular
        if forceHostReplacement || activeHostKind != targetHostKind {
            installHost(of: targetHostKind)
        }

        guard let activeHost else {
            return
        }

        activeHost.setTabDescriptors(resolvedTabDescriptors, context: makeContext())
        activeHost.setSelectedTabID(inspectorController.selectedTabID)
    }

    private func applyResolvedTabDescriptors(_ resolvedTabs: [WITabDescriptor]) {
        let normalizedSelectedTabID = WIUIKitTabLayoutPolicy.normalizedSelectedTabID(
            currentSelectedTabID: inspectorController.selectedTabID,
            resolvedTabs: resolvedTabs
        )

        if normalizedSelectedTabID != inspectorController.selectedTabID {
            inspectorController.send(.selectTab(normalizedSelectedTabID))
        }

        resolvedTabDescriptors = resolvedTabs
        inspectorController.configureTabs(resolvedTabs.map(\.sessionTabDefinition))
    }

    private func installHost(of kind: HostKind) {
        activeHost?.prepareForRemoval()
        if let current = activeHost {
            current.willMove(toParent: nil)
            current.view.removeFromSuperview()
            current.removeFromParent()
        }

        let host: (UIViewController & WIUIKitInspectorHostProtocol)
        switch kind {
        case .compact:
            host = WICompactTabHostViewController()
        case .regular:
            host = WIRegularTabHostViewController()
        }

        host.onSelectedTabIDChange = { [weak self] selectedTabID in
            guard let self else {
                return
            }
            guard inspectorController.selectedTabID != selectedTabID else {
                return
            }
            inspectorController.synchronizeSelectedTabFromNativeUI(selectedTabID)
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

    private func bindSelectionCallback() {
        inspectorController.onSelectedTabIDChange = { [weak self] tabID in
            self?.activeHost?.setSelectedTabID(tabID)
        }
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("Tab Container (UIKit)") {
    WIUIKitPreviewContainer {
        let session = WISession()
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
