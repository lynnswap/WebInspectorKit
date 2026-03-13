import Observation
import Combine
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

    private let rebindClock: any Clock<Duration>
    private weak var connectedPageWebView: WKWebView?
    private var hasConfiguredPanelsFromUI = false
    @ObservationIgnored private var pageLoadingObservation: AnyCancellable?
    @ObservationIgnored private var lastObservedPageLoading: Bool?
    @ObservationIgnored private var navigationRebindPrepared = false
    @ObservationIgnored private var navigationRebindTask: Task<Void, Never>?
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
        self.rebindClock = rebindClock
        self.domStore.setRecoverableErrorHandler { [weak self] message in
            self?.lastRecoverableError = message
        }
    }

    public func connect(to webView: WKWebView?) {
        setPageWebViewFromUI(webView)
        activateFromUIIfPossible()
    }

    public func suspend() {
        navigationRebindTask?.cancel()
        navigationRebindTask = nil
        stopObservingPageLoading()
        resetNavigationRebindState()
        domStore.suspend()
        networkStore.suspend()
        lifecycle = .suspended
    }

    public func disconnect() {
        navigationRebindTask?.cancel()
        navigationRebindTask = nil
        stopObservingPageLoading()
        connectedPageWebView = nil
        resetNavigationRebindState()
        domStore.detach()
        networkStore.detach()
        lifecycle = .disconnected
    }

    public func configurePanels(_ panelConfigurations: [WIPanelConfiguration]) {
        hasConfiguredPanelsFromUI = true
        let didChange = self.panelConfigurations != panelConfigurations
        self.panelConfigurations = panelConfigurations
        applyNormalizedSelection(preferredPanel: selectedPanelConfiguration)
        syncRuntimeStateFromTabs()
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
        let resolvedPanel = resolveSelectionCandidate(panelConfiguration)
        if panelConfiguration != nil, resolvedPanel == nil {
            return
        }
        applyNormalizedSelection(preferredPanel: resolvedPanel)
        syncRuntimeStateFromTabs()
    }

    package var pageWebViewForUI: WKWebView? {
        connectedPageWebView
    }

    package func setPageWebViewFromUI(_ webView: WKWebView?) {
        if connectedPageWebView !== webView {
            stopObservingPageLoading()
            resetNavigationRebindState()
        }
        connectedPageWebView = webView
        guard let resolvedWebView = webView else {
            suspend()
            return
        }
        startObservingPageLoading(on: resolvedWebView)
    }

    package func activateFromUIIfPossible() {
        guard let connectedPageWebView else {
            return
        }
        lifecycle = .active
        startObservingPageLoading(on: connectedPageWebView)
        if usesNavigationAwareRebind && connectedPageWebView.isLoading {
            prepareForNavigationRebindIfNeeded()
        }
        syncRuntimeStateFromTabs()
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
}

private extension WISessionController {
    struct RuntimeAttachmentState {
        let domEnabled: Bool
        let networkEnabled: Bool
        let domAutoSnapshotEnabled: Bool
        let networkMode: NetworkLoggingMode
    }

    var usesNavigationAwareRebind: Bool {
#if os(macOS)
        lifecycle == .active
            && (
                domStore.backendSupport.backendKind == .nativeInspectorMacOS
                    || networkStore.backendSupport.backendKind == .nativeInspectorMacOS
            )
#else
        false
#endif
    }

    func notifyPanelConfigurationObservers() {
        for observer in panelConfigurationObservers.values {
            observer()
        }
    }

    func startObservingPageLoading(on webView: WKWebView) {
        guard pageLoadingObservation == nil else {
            return
        }

        pageLoadingObservation = webView.publisher(for: \.isLoading, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak webView] isLoading in
                guard let self, let webView else {
                    return
                }
                guard self.connectedPageWebView === webView else {
                    return
                }
                self.handlePageLoadingStateChange(isLoading)
            }
    }

    func stopObservingPageLoading() {
        pageLoadingObservation?.cancel()
        pageLoadingObservation = nil
        lastObservedPageLoading = nil
    }

    func resetNavigationRebindState() {
        navigationRebindPrepared = false
    }

    func handlePageLoadingStateChange(_ isLoading: Bool) {
        let previousLoading = lastObservedPageLoading
        lastObservedPageLoading = isLoading

        guard usesNavigationAwareRebind else {
            return
        }

        guard let previousLoading else {
            if isLoading {
                prepareForNavigationRebindIfNeeded()
            }
            return
        }
        guard previousLoading != isLoading else {
            return
        }

        if isLoading {
            prepareForNavigationRebindIfNeeded()
        } else {
            resumeAfterNavigationRebindIfNeeded()
        }
    }

    func prepareForNavigationRebindIfNeeded() {
        let runtimeState = currentRuntimeAttachmentState()
        guard runtimeState.domEnabled || runtimeState.networkEnabled else {
            return
        }

        navigationRebindTask?.cancel()
        navigationRebindTask = nil
        if runtimeState.domEnabled {
            domStore.session.prepareForNavigationReconnect()
        }
        if runtimeState.networkEnabled {
            networkStore.session.prepareForNavigationReconnect()
        }
        navigationRebindPrepared = true
        scheduleNavigationRebindResume()
    }

    func resumeAfterNavigationRebindIfNeeded() {
        guard navigationRebindPrepared else {
            return
        }
        scheduleNavigationRebindResume()
    }

    func scheduleNavigationRebindResume() {
        guard navigationRebindTask == nil else {
            return
        }
        guard let webView = connectedPageWebView else {
            resetNavigationRebindState()
            return
        }
        let resumeDOMAfterLoad = !webView.isLoading

        navigationRebindTask = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else {
                return
            }
            defer {
                self.navigationRebindTask = nil
            }
            guard self.connectedPageWebView === webView else {
                return
            }

            if !resumeDOMAfterLoad {
                while webView.isLoading {
                    try? await self.rebindClock.sleep(for: .milliseconds(20))
                    guard !Task.isCancelled else {
                        return
                    }
                    guard self.connectedPageWebView === webView else {
                        return
                    }
                    guard self.navigationRebindPrepared else {
                        return
                    }
                }
            }

            let runtimeState = self.currentRuntimeAttachmentState()
            if runtimeState.networkEnabled {
                self.networkStore.session.resumeAfterNavigationReconnect(to: webView)
            }
            guard runtimeState.domEnabled else {
                self.navigationRebindPrepared = false
                return
            }

            do {
                try await self.domStore.session.resumeAfterNavigationReconnect(
                    to: webView,
                    reloadDocument: true
                )
            } catch is CancellationError {
                return
            } catch {
                self.lastRecoverableError = error.localizedDescription
                return
            }

            self.navigationRebindPrepared = false
        }
    }

    func applyNormalizedSelection(preferredPanel: WIPanelConfiguration?) {
        let normalizedPanel: WIPanelConfiguration?
        if panelConfigurations.isEmpty {
            normalizedPanel = nil
        } else if let preferredPanel,
                  let resolvedPanel = resolveSelectionCandidate(preferredPanel) {
            normalizedPanel = resolvedPanel
        } else if let currentSelection = selectedPanelConfiguration,
                  let resolvedCurrent = resolveSelectionCandidate(currentSelection) {
            normalizedPanel = resolvedCurrent
        } else {
            normalizedPanel = panelConfigurations.first
        }

        if normalizedPanel != selectedPanelConfiguration {
            selectedPanelConfiguration = normalizedPanel
        }
    }

    func resolveSelectionCandidate(
        _ requestedPanelConfiguration: WIPanelConfiguration?
    ) -> WIPanelConfiguration? {
        guard let requestedPanelConfiguration else {
            return nil
        }
        if let exactMatch = panelConfigurations.first(where: { $0 == requestedPanelConfiguration }) {
            return exactMatch
        }
        let identifierMatches = panelConfigurations.filter {
            $0.identifier == requestedPanelConfiguration.identifier
        }
        if identifierMatches.count == 1, let identifierMatch = identifierMatches.first {
            return identifierMatch
        }
        return nil
    }

    func syncRuntimeStateFromTabs() {
        if lifecycle == .suspended {
            domStore.suspend()
            networkStore.suspend()
            return
        }

        let runtimeState = currentRuntimeAttachmentState()
        if navigationRebindPrepared, connectedPageWebView?.isLoading == true {
            if runtimeState.domEnabled {
                domStore.session.prepareForNavigationReconnect()
            }
            if runtimeState.networkEnabled {
                networkStore.session.prepareForNavigationReconnect()
            }
            domStore.setAutoSnapshotEnabled(runtimeState.domEnabled && runtimeState.domAutoSnapshotEnabled)
            networkStore.setMode(runtimeState.networkEnabled ? runtimeState.networkMode : .buffering)
            return
        }

        if let webView = connectedPageWebView {
            if runtimeState.domEnabled {
                domStore.attach(to: webView)
            } else {
                domStore.suspend()
            }

            if runtimeState.networkEnabled {
                networkStore.attach(to: webView)
            } else {
                networkStore.suspend()
            }
        } else {
            if runtimeState.domEnabled == false || lifecycle != .disconnected {
                domStore.suspend()
            }
            if runtimeState.networkEnabled == false || lifecycle != .disconnected {
                networkStore.suspend()
            }
        }

        domStore.setAutoSnapshotEnabled(runtimeState.domEnabled && runtimeState.domAutoSnapshotEnabled)
        networkStore.setMode(runtimeState.networkEnabled ? runtimeState.networkMode : .buffering)
    }

    func currentRuntimeAttachmentState() -> RuntimeAttachmentState {
        if hasConfiguredPanelsFromUI {
            let hasDOMTreePanel = panelConfigurations.contains { $0.kind == .domTree }
            return RuntimeAttachmentState(
                domEnabled: panelConfigurations.contains {
                    $0.kind == .domTree || $0.kind == .domDetail
                },
                networkEnabled: panelConfigurations.contains { $0.kind == .network },
                domAutoSnapshotEnabled: selectedPanelConfiguration?.kind == .domTree
                    || (selectedPanelConfiguration?.kind == .domDetail && hasDOMTreePanel == false),
                networkMode: selectedPanelConfiguration?.kind == .network ? .active : .buffering
            )
        }

        return RuntimeAttachmentState(
            domEnabled: true,
            networkEnabled: true,
            domAutoSnapshotEnabled: true,
            networkMode: .active
        )
    }
}
