import Observation
import Combine
import WebKit
import WebInspectorCore
import WebInspectorDOM
import WebInspectorNetwork
import WebInspectorTransport

@MainActor
@Observable
public final class WIInspectorController {
    public private(set) var lifecycle: WISessionLifecycle = .disconnected
    public private(set) var lastRecoverableError: String?
    public private(set) var panelConfigurations: [WIInspectorPanelConfiguration] = []
    public private(set) var selectedPanelConfiguration: WIInspectorPanelConfiguration?
    package private(set) var panelConfigurationRevision: UInt64 = 0

    public let dom: WIDOMInspectorStore
    public let network: WINetworkInspectorStore

    private let rebindClock: any Clock<Duration>
    private weak var connectedPageWebView: WKWebView?
    private var hasConfiguredPanelsFromUI = false
    @ObservationIgnored private var pageLoadingObservation: AnyCancellable?
    @ObservationIgnored private var lastObservedPageLoading: Bool?
    @ObservationIgnored private var navigationRebindPrepared = false
    @ObservationIgnored private var navigationRebindTask: Task<Void, Never>?
    @ObservationIgnored private var panelConfigurationObservers: [UUID: @MainActor () -> Void] = [:]

    public convenience init(configuration: WIInspectorConfiguration = .init()) {
        self.init(
            domSession: DOMSession(configuration: configuration.dom),
            networkSession: NetworkSession(configuration: configuration.network),
            rebindClock: ContinuousClock()
        )
    }

    init(
        domSession: DOMSession,
        networkSession: NetworkSession,
        rebindClock: any Clock<Duration> = ContinuousClock()
    ) {
        self.dom = WIDOMInspectorStore(session: domSession)
        self.network = WINetworkInspectorStore(session: networkSession)
        self.rebindClock = rebindClock
        self.dom.setRecoverableErrorHandler { [weak self] message in
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
        dom.suspend()
        network.suspend()
        lifecycle = .suspended
    }

    public func disconnect() {
        navigationRebindTask?.cancel()
        navigationRebindTask = nil
        stopObservingPageLoading()
        connectedPageWebView = nil
        resetNavigationRebindState()
        dom.detach()
        network.detach()
        lifecycle = .disconnected
    }

    public func configurePanels(_ panelConfigurations: [WIInspectorPanelConfiguration]) {
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

    public var domTransportSupportSnapshot: WITransportSupportSnapshot? {
        dom.transportSupportSnapshot
    }

    public var networkTransportSupportSnapshot: WITransportSupportSnapshot? {
        network.transportSupportSnapshot
    }

    package func setSelectedPanelFromUI(_ panelConfiguration: WIInspectorPanelConfiguration?) {
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

private extension WIInspectorController {
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
                dom.transportSupportSnapshot?.backendKind == .macOSNativeInspector
                    || network.transportSupportSnapshot?.backendKind == .macOSNativeInspector
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
            dom.session.prepareForTransportRebind()
        }
        if runtimeState.networkEnabled {
            network.session.prepareForTransportRebind()
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
                self.network.session.resumeAfterTransportRebind(to: webView)
            }
            guard runtimeState.domEnabled else {
                self.navigationRebindPrepared = false
                return
            }

            do {
                try await self.dom.session.resumeAfterTransportRebind(
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

    func applyNormalizedSelection(preferredPanel: WIInspectorPanelConfiguration?) {
        let normalizedPanel: WIInspectorPanelConfiguration?
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
        _ requestedPanelConfiguration: WIInspectorPanelConfiguration?
    ) -> WIInspectorPanelConfiguration? {
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
            dom.suspend()
            network.suspend()
            return
        }

        let runtimeState = currentRuntimeAttachmentState()
        if navigationRebindPrepared, connectedPageWebView?.isLoading == true {
            if runtimeState.domEnabled {
                dom.session.prepareForTransportRebind()
            }
            if runtimeState.networkEnabled {
                network.session.prepareForTransportRebind()
            }
            dom.setAutoSnapshotEnabled(runtimeState.domEnabled && runtimeState.domAutoSnapshotEnabled)
            network.setMode(runtimeState.networkEnabled ? runtimeState.networkMode : .buffering)
            return
        }

        if let webView = connectedPageWebView {
            if runtimeState.domEnabled {
                dom.attach(to: webView)
            } else {
                dom.suspend()
            }

            if runtimeState.networkEnabled {
                network.attach(to: webView)
            } else {
                network.suspend()
            }
        } else {
            if runtimeState.domEnabled == false || lifecycle != .disconnected {
                dom.suspend()
            }
            if runtimeState.networkEnabled == false || lifecycle != .disconnected {
                network.suspend()
            }
        }

        dom.setAutoSnapshotEnabled(runtimeState.domEnabled && runtimeState.domAutoSnapshotEnabled)
        network.setMode(runtimeState.networkEnabled ? runtimeState.networkMode : .buffering)
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
