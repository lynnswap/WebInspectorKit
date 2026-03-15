import Observation
import WebKit

@MainActor
@Observable
public final class WISessionController {
    public private(set) var lifecycle: WISessionLifecycle = .disconnected
    public private(set) var lastRecoverableError: String?
    public private(set) var panelConfigurations: [WIPanelConfiguration] = []
    public private(set) var selectedPanelConfiguration: WIPanelConfiguration?
    package private(set) var panelConfigurationRevision: UInt64 = 0

    public let domStore: WIDOMStore
    public let networkStore: WINetworkStore

    private var hasConfiguredPanelsFromUI = false
    @ObservationIgnored private let runtimeCoordinator: SessionRuntimeCoordinator
    @ObservationIgnored private var panelConfigurationObservers: [UUID: @MainActor () -> Void] = [:]

    package init(
        domSession: WIDOMRuntime,
        networkSession: WINetworkRuntime,
        domFrontendBridge: (any WIDOMFrontendBridge)? = nil,
        rebindClock: any Clock<Duration> = ContinuousClock()
    ) {
        self.domStore = WIDOMStore(
            session: domSession,
            frontendBridge: domFrontendBridge
        )
        self.networkStore = WINetworkStore(session: networkSession)
        self.runtimeCoordinator = SessionRuntimeCoordinator(rebindClock: rebindClock)
        self.domStore.setRecoverableErrorHandler { [weak self] message in
            self?.lastRecoverableError = message
        }
    }

    public func connect(to webView: WKWebView?) {
        setPageWebViewFromUI(webView)
        activateFromUIIfPossible()
    }

    public func suspend() {
        runtimeCoordinator.suspend(domStore: domStore, networkStore: networkStore)
        lifecycle = .suspended
    }

    public func disconnect() {
        runtimeCoordinator.disconnect(domStore: domStore, networkStore: networkStore)
        lifecycle = .disconnected
    }

    public func configurePanels(_ panelConfigurations: [WIPanelConfiguration]) {
        hasConfiguredPanelsFromUI = true
        let didChange = self.panelConfigurations != panelConfigurations
        self.panelConfigurations = panelConfigurations
        applyActivationPlan(makeActivationPlan(preferredPanel: selectedPanelConfiguration))
        guard didChange else {
            return
        }
        panelConfigurationRevision &+= 1
        if panelConfigurationRevision == 0 {
            panelConfigurationRevision = 1
        }
        notifyPanelConfigurationObservers()
    }

    public var domBackendSupport: WIBackendSupport {
        domStore.backendSupport
    }

    public var networkBackendSupport: WIBackendSupport {
        networkStore.backendSupport
    }

    package func setSelectedPanelFromUI(_ panelConfiguration: WIPanelConfiguration?) {
        let resolvedPanel = SessionActivationPlan.resolveSelectionCandidate(
            panelConfiguration,
            in: panelConfigurations
        )
        if panelConfiguration != nil, resolvedPanel == nil {
            return
        }
        applyActivationPlan(makeActivationPlan(preferredPanel: resolvedPanel))
    }

    package var pageWebViewForUI: WKWebView? {
        runtimeCoordinator.pageWebView
    }

    package func setPageWebViewFromUI(_ webView: WKWebView?) {
        runtimeCoordinator.setPageWebView(webView) { [weak self] isLoading in
            self?.handlePageLoadingStateChange(isLoading)
        }
        guard webView != nil else {
            suspend()
            return
        }
    }

    package func activateFromUIIfPossible() {
        guard runtimeCoordinator.pageWebView != nil else {
            return
        }
        lifecycle = .active
        runtimeCoordinator.activateIfPossible(
            lifecycle: lifecycle,
            runtimeState: currentActivationPlan().runtimeState,
            currentRuntimeState: { [weak self] in
                self?.currentActivationPlan().runtimeState
                    ?? SessionActivationPlan(
                        panelConfigurations: [],
                        currentSelection: nil,
                        preferredSelection: nil,
                        hasConfiguredPanelsFromUI: false
                    ).runtimeState
            },
            usesNavigationAwareRebind: usesNavigationAwareRebind,
            domStore: domStore,
            networkStore: networkStore,
            onRecoverableError: { [weak self] message in
                self?.lastRecoverableError = message
            },
            onPageLoadingChange: { [weak self] isLoading in
                self?.handlePageLoadingStateChange(isLoading)
            }
        )
    }

    package func addPanelConfigurationObserver(
        _ observer: @escaping @MainActor () -> Void
    ) -> UUID {
        let id = UUID()
        panelConfigurationObservers[id] = observer
        return id
    }

    package func removePanelConfigurationObserver(_ id: UUID) {
        panelConfigurationObservers.removeValue(forKey: id)
    }

    isolated deinit {
        runtimeCoordinator.tearDown(domStore: domStore, networkStore: networkStore)
    }
}

private extension WISessionController {
    var usesNavigationAwareRebind: Bool {
#if os(macOS)
        lifecycle == .active
            && domStore.backendSupport.backendKind == .nativeInspectorMacOS
#else
        false
#endif
    }

    func notifyPanelConfigurationObservers() {
        for observer in panelConfigurationObservers.values {
            observer()
        }
    }

    func handlePageLoadingStateChange(_ isLoading: Bool) {
        runtimeCoordinator.handlePageLoadingStateChange(
            isLoading,
            usesNavigationAwareRebind: usesNavigationAwareRebind,
            currentRuntimeState: { [weak self] in
                self?.currentActivationPlan().runtimeState
                    ?? SessionActivationPlan(
                        panelConfigurations: [],
                        currentSelection: nil,
                        preferredSelection: nil,
                        hasConfiguredPanelsFromUI: false
                    ).runtimeState
            },
            domStore: domStore,
            onRecoverableError: { [weak self] message in
                self?.lastRecoverableError = message
            }
        )
    }

    func applyActivationPlan(_ plan: SessionActivationPlan) {
        if plan.selectedPanelConfiguration != selectedPanelConfiguration {
            selectedPanelConfiguration = plan.selectedPanelConfiguration
        }
        runtimeCoordinator.apply(
            runtimeState: plan.runtimeState,
            lifecycle: lifecycle,
            domStore: domStore,
            networkStore: networkStore
        )
    }

    func makeActivationPlan(preferredPanel: WIPanelConfiguration? = nil) -> SessionActivationPlan {
        SessionActivationPlan(
            panelConfigurations: panelConfigurations,
            currentSelection: selectedPanelConfiguration,
            preferredSelection: preferredPanel,
            hasConfiguredPanelsFromUI: hasConfiguredPanelsFromUI
        )
    }

    func currentActivationPlan() -> SessionActivationPlan {
        makeActivationPlan()
    }
}
