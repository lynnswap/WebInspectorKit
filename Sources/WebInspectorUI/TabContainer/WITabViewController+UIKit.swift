import Foundation
import OSLog
import ObservationBridge
import WebKit
import WebInspectorRuntime

#if canImport(UIKit)
import UIKit

private let tabContainerLogger = Logger(subsystem: "WebInspectorKit", category: "WITabContainer")
private let verboseConsoleDiagnosticsEnabled =
    ProcessInfo.processInfo.environment["WEBSPECTOR_VERBOSE_CONSOLE_LOGS"] == "1"

@MainActor
private protocol WIUIKitTabHost where Self: UIViewController {
    func prepareForRemoval()
}

@MainActor
func wiCompactDisplayTabs(
    from tabs: [WITab],
    synthesizedElementTab: WITab
) -> [WITab] {
    let hasDOMTab = tabs.contains { $0.identifier == WITab.domTabID }
    let hasElementTab = tabs.contains { $0.identifier == WITab.elementTabID }
    guard hasDOMTab, hasElementTab == false else {
        return tabs
    }

    var displayTabs: [WITab] = []
    displayTabs.reserveCapacity(tabs.count + 1)
    var didInsertSyntheticElement = false
    for tab in tabs {
        displayTabs.append(tab)
        guard didInsertSyntheticElement == false, tab.identifier == WITab.domTabID else {
            continue
        }
        displayTabs.append(synthesizedElementTab)
        didInsertSyntheticElement = true
    }
    return displayTabs
}

@MainActor
final class WIUIKitTabRenderCache {
    private var rootViewControllerByTabID: [ObjectIdentifier: UIViewController] = [:]
    private var compactTabByTabID: [ObjectIdentifier: UITab] = [:]
    private var modelTabIDByCompactTabID: [ObjectIdentifier: ObjectIdentifier] = [:]

    func rootViewController(for tab: WITab) -> UIViewController? {
        rootViewControllerByTabID[ObjectIdentifier(tab)]
    }

    func setRootViewController(_ viewController: UIViewController, for tab: WITab) {
        rootViewControllerByTabID[ObjectIdentifier(tab)] = viewController
    }

    func compactTab(for tab: WITab) -> UITab? {
        compactTabByTabID[ObjectIdentifier(tab)]
    }

    func setCompactTab(_ compactTab: UITab, for tab: WITab) {
        let tabID = ObjectIdentifier(tab)
        if let previousCompactTab = compactTabByTabID[tabID] {
            modelTabIDByCompactTabID.removeValue(forKey: ObjectIdentifier(previousCompactTab))
        }
        compactTabByTabID[tabID] = compactTab
        modelTabIDByCompactTabID[ObjectIdentifier(compactTab)] = tabID
    }

    func modelTab(for compactTab: UITab, among tabs: [WITab]) -> WITab? {
        guard let modelTabID = modelTabIDByCompactTabID[ObjectIdentifier(compactTab)] else {
            return nil
        }
        return tabs.first(where: { ObjectIdentifier($0) == modelTabID })
    }

    func prune(activeTabs: [WITab]) {
        let activeTabIDs = Set(activeTabs.map { ObjectIdentifier($0) })
        rootViewControllerByTabID = rootViewControllerByTabID.filter { activeTabIDs.contains($0.key) }
        compactTabByTabID = compactTabByTabID.filter { activeTabIDs.contains($0.key) }

        let activeCompactTabIDs = Set(compactTabByTabID.values.map { ObjectIdentifier($0) })
        modelTabIDByCompactTabID = modelTabIDByCompactTabID.filter { activeCompactTabIDs.contains($0.key) }
    }

    func resetAll() {
        rootViewControllerByTabID.removeAll()
        compactTabByTabID.removeAll()
        modelTabIDByCompactTabID.removeAll()
    }

    func resetCompactTabs() {
        compactTabByTabID.removeAll()
        modelTabIDByCompactTabID.removeAll()
    }
}

@MainActor
public final class WITabViewController: UIViewController {
    private enum HostKind {
        case compact
        case regular
    }

    private struct PendingControllerSwap {
        let controller: WIInspectorController
        let hostKindAtRequest: HostKind
    }

    public private(set) var inspectorController: WIInspectorController

    private var hostID: WIInspectorHostID
    private var requestedTabs: [WITab]
    private var requestedPageWebView: WKWebView?
    private let renderCache = WIUIKitTabRenderCache()
    private var pendingControllerSwap: PendingControllerSwap?
    private var controllerSwapTask: Task<Void, Never>?
    private var needsHostStateSyncAfterSwap = false

    private var activeHost: (UIViewController & WIUIKitTabHost)?
    private var activeHostKind: HostKind?

    var horizontalSizeClassOverrideForTesting: UIUserInterfaceSizeClass? {
        didSet {
            if isViewLoaded {
                handleHorizontalSizeClassChange()
            }
        }
    }

    public init(
        _ inspectorController: WIInspectorController,
        webView: WKWebView?,
        tabs: [WITab] = [.dom(), .network()]
    ) {
        self.inspectorController = inspectorController
        self.hostID = inspectorController.registerHost()
        self.requestedTabs = tabs
        self.requestedPageWebView = webView
        super.init(nibName: nil, bundle: nil)
        inspectorController.prepareHiddenHostForSameWebViewHandoff(hostID)
        inspectorController.setTabsFromUI(tabs)
        inspectorController.updateHost(
            hostID,
            pageWebView: webView,
            visibility: .hidden,
            isAttached: true,
            sceneActivationRequestingScene: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public func setPageWebView(_ webView: WKWebView?) {
        requestedPageWebView = webView
        syncRegisteredHostState()
    }

    public func setInspectorController(_ inspectorController: WIInspectorController) {
        let hostKindAtRequest = activeHostKind
            ?? (effectiveHorizontalSizeClass == .compact ? .compact : .regular)
        if self.inspectorController === inspectorController {
            if let pendingControllerSwap,
               pendingControllerSwap.controller === inspectorController,
               pendingControllerSwap.hostKindAtRequest == hostKindAtRequest {
                return
            }
            guard pendingControllerSwap == nil, controllerSwapTask == nil else {
                pendingControllerSwap = .init(
                    controller: inspectorController,
                    hostKindAtRequest: hostKindAtRequest
                )
                return
            }
            syncRegisteredHostState()
            return
        }
        if let pendingControllerSwap,
           pendingControllerSwap.controller === inspectorController,
           pendingControllerSwap.hostKindAtRequest == hostKindAtRequest {
            return
        }
        invalidatePresentationStateForControllerSwap()
        pendingControllerSwap = .init(
            controller: inspectorController,
            hostKindAtRequest: hostKindAtRequest
        )
        startControllerSwapIfNeeded()
    }

    private func takePendingControllerSwap() -> PendingControllerSwap? {
        let pending = pendingControllerSwap
        pendingControllerSwap = nil
        return pending
    }

    private func invalidatePresentationStateForControllerSwap() {
        renderCache.resetAll()
        if let activeHost {
            activeHost.prepareForRemoval()
            activeHost.willMove(toParent: nil)
            activeHost.view.removeFromSuperview()
            activeHost.removeFromParent()
        }
        activeHost = nil
        activeHostKind = nil
    }

    public func setTabs(_ tabs: [WITab]) {
        requestedTabs = tabs
        inspectorController.setTabs(tabs)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        rebuildLayout(forceHostReplacement: true)

        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.handleHorizontalSizeClassChange()
        }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        logTabContainerDiagnostics("viewDidAppear animated=\(animated)")
        syncRegisteredHostState()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard view.window == nil else {
            return
        }
        logTabContainerDiagnostics("viewDidDisappear animated=\(animated) windowDetached=true")
        syncRegisteredHostState()
    }

    isolated deinit {
        inspectorController.unregisterHost(hostID)
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
        inspectorController.tabs.map(\.identifier)
    }

    var activeHostViewControllerForTesting: UIViewController? {
        activeHost
    }

    private var effectiveHorizontalSizeClass: UIUserInterfaceSizeClass {
        horizontalSizeClassOverrideForTesting ?? traitCollection.horizontalSizeClass
    }

    private var currentHostVisibility: WIHostVisibility {
        guard isViewLoaded, view.window != nil else {
            return .hidden
        }
        return .visible
    }

    private var isDismissOrRemovalTransition: Bool {
        isBeingDismissed
            || navigationController?.isBeingDismissed == true
            || isMovingFromParent
            || navigationController?.isMovingFromParent == true
    }

    private func syncRegisteredHostState(
        allowDuringSwap: Bool = false,
        forcedVisibility: WIHostVisibility? = nil
    ) {
        guard allowDuringSwap || controllerSwapTask == nil else {
            needsHostStateSyncAfterSwap = true
            return
        }
        needsHostStateSyncAfterSwap = false
        let resolvedVisibility = forcedVisibility ?? currentHostVisibility
        logTabContainerDiagnostics(
            "syncRegisteredHostState allowDuringSwap=\(allowDuringSwap) visibility=\(visibilitySummary(resolvedVisibility))"
        )
        inspectorController.updateHost(
            hostID,
            pageWebView: requestedPageWebView,
            visibility: resolvedVisibility,
            isAttached: true,
            sceneActivationRequestingScene: view.window?.windowScene
        )
    }

    private func replayDeferredHostStateSyncAfterSwapIfNeeded() {
        guard controllerSwapTask == nil, needsHostStateSyncAfterSwap else {
            return
        }
        syncRegisteredHostState()
    }

    private func restoreCurrentControllerPresentationAfterNoOpSwapIfNeeded() {
        guard isViewLoaded else {
            return
        }
        rebuildLayout(forceHostReplacement: activeHost == nil || activeHostKind == nil)
    }

    private func startControllerSwapIfNeeded() {
        guard controllerSwapTask == nil else {
            return
        }
        controllerSwapTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.controllerSwapTask = nil
                let shouldRestartSwap = self.pendingControllerSwap != nil
                if shouldRestartSwap {
                    self.startControllerSwapIfNeeded()
                } else {
                    self.replayDeferredHostStateSyncAfterSwapIfNeeded()
                }
            }

            while let requestedSwap = self.takePendingControllerSwap() {
                guard self.inspectorController !== requestedSwap.controller else {
                    self.syncRegisteredHostState(allowDuringSwap: true)
                    self.restoreCurrentControllerPresentationAfterNoOpSwapIfNeeded()
                    continue
                }

                let previousController = self.inspectorController
                let previousHostID = self.hostID
                let preferredRole = previousController.preferredRole(for: previousHostID)
                self.logTabContainerDiagnostics(
                    "controllerSwap begin previousHostID=\(self.compactHostID(previousHostID)) requestedHostKind=\(self.hostKindSummary(requestedSwap.hostKindAtRequest)) selectedTab=\(previousController.selectedTab?.identifier ?? "nil")"
                )
                await previousController.waitForRuntimeApplyForTesting()
                let currentSelectedTab = previousController.selectedTab
                let currentPreferredCompactSelectedTabIdentifier = previousController.preferredCompactSelectedTabIdentifier
                if let pendingControllerSwap,
                   (pendingControllerSwap.controller !== requestedSwap.controller
                    || pendingControllerSwap.hostKindAtRequest != requestedSwap.hostKindAtRequest) {
                    continue
                }

                previousController.unregisterHost(previousHostID)
                previousController.finalizeForControllerSwap()
                await previousController.waitForRuntimeApplyForTesting()
                guard Task.isCancelled == false else {
                    return
                }

                let preservedCompactSelectedTabIdentifier: String?
                if requestedSwap.hostKindAtRequest == .compact {
                    preservedCompactSelectedTabIdentifier = currentSelectedTab?.identifier
                        ?? currentPreferredCompactSelectedTabIdentifier
                } else {
                    preservedCompactSelectedTabIdentifier = currentPreferredCompactSelectedTabIdentifier
                }

                let nextInspectorController = requestedSwap.controller
                self.inspectorController = nextInspectorController
                self.hostID = nextInspectorController.registerHost(preferredRole: preferredRole)
                nextInspectorController.prepareHiddenHostForSameWebViewHandoff(self.hostID)
                nextInspectorController.setTabsFromUI(self.requestedTabs)
                if let preservedCompactSelectedTabIdentifier {
                    nextInspectorController.setPreferredCompactSelectedTabIdentifierFromUI(
                        preservedCompactSelectedTabIdentifier
                    )
                }
                if let currentSelectedTab {
                    _ = nextInspectorController.projectSelectedTabFromUI(currentSelectedTab)
                }
                self.syncRegisteredHostState(allowDuringSwap: true)
                self.logTabContainerDiagnostics(
                    "controllerSwap installed nextHostID=\(self.compactHostID(self.hostID)) selectedTab=\(nextInspectorController.selectedTab?.identifier ?? "nil") preferredCompact=\(nextInspectorController.preferredCompactSelectedTabIdentifier ?? "nil")"
                )

                if self.isViewLoaded {
                    self.invalidatePresentationStateForControllerSwap()
                    self.rebuildLayout(forceHostReplacement: true)
                }
            }
        }
    }

    private func rebuildLayout(forceHostReplacement: Bool = false) {
        renderCache.prune(activeTabs: inspectorController.tabs)

        let targetHostKind: HostKind = effectiveHorizontalSizeClass == .compact ? .compact : .regular

        if activeHostKind == .compact, targetHostKind == .regular {
            // Compact UITab closures retain wrapped controllers; drop only compact caches
            // so regular host can reuse the shared root cache without cross-stack leakage.
            renderCache.resetCompactTabs()
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
            host = WICompactTabHostViewController(
                inspector: inspectorController,
                renderCache: renderCache
            )
        case .regular:
            host = WIRegularTabHostViewController(
                inspector: inspectorController,
                renderCache: renderCache
            )
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

    func makeTabRootViewController(for tab: WITab) -> UIViewController? {
        if let cached = renderCache.rootViewController(for: tab) {
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
        renderCache.setRootViewController(viewController, for: tab)
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

    private func logTabContainerDiagnostics(
        _ message: String,
        level: OSLogType = .default
    ) {
        if verboseConsoleDiagnosticsEnabled == false,
           level != .error,
           level != .fault {
            return
        }
        let state = "hostID=\(compactHostID(hostID)) activeHostKind=\(hostKindSummary(activeHostKind)) windowAttached=\(viewIfLoaded?.window != nil) currentVisibility=\(visibilitySummary(currentHostVisibility)) requestedWebView=\(webViewSummary(requestedPageWebView)) selectedTab=\(inspectorController.selectedTab?.identifier ?? "nil")"
        let composed = "\(message) \(state)"
        switch level {
        case .error, .fault:
            tabContainerLogger.error("\(composed, privacy: .public)")
        case .debug:
            tabContainerLogger.debug("\(composed, privacy: .public)")
        default:
            tabContainerLogger.notice("\(composed, privacy: .public)")
        }
    }

    private func compactHostID(_ hostID: WIInspectorHostID) -> String {
        String(hostID.hashValue, radix: 16)
    }

    private func hostKindSummary(_ hostKind: HostKind?) -> String {
        switch hostKind {
        case .compact:
            return "compact"
        case .regular:
            return "regular"
        case nil:
            return "nil"
        }
    }

    private func visibilitySummary(_ visibility: WIHostVisibility) -> String {
        switch visibility {
        case .visible:
            return "visible"
        case .hidden:
            return "hidden"
        case .finalizing:
            return "finalizing"
        }
    }

    private func webViewSummary(_ webView: WKWebView?) -> String {
        guard let webView else {
            return "nil"
        }
        return String(describing: ObjectIdentifier(webView))
    }
}

extension WICompactTabHostViewController: WIUIKitTabHost {}
extension WIRegularTabHostViewController: WIUIKitTabHost {}

#if DEBUG && canImport(SwiftUI)
import SwiftUI

extension WITabViewController {
    func waitForRuntimeStateSyncForTesting() async {
        while let controllerSwapTask {
            await controllerSwapTask.value
        }
        await inspectorController.waitForRuntimeApplyForTesting()
    }
}

#Preview("Tab Container (UIKit)") {
    WIUIKitPreviewContainer {
        let session = WIInspectorController()
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
