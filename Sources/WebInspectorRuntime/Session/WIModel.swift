import Observation
import Combine
import WebKit
import WebInspectorEngine
import WebInspectorTransport

@MainActor
@Observable
public final class WIModel {
    public private(set) var lifecycle: WISessionLifecycle = .disconnected
    public private(set) var lastRecoverableError: String?
    public private(set) var tabs: [WITab] = []
    public private(set) var selectedTab: WITab?

    public let dom: WIDOMModel
    public let network: WINetworkModel

    private weak var connectedPageWebView: WKWebView?
    private var hasConfiguredTabsFromUI = false
    @ObservationIgnored private var pageLoadingObservation: AnyCancellable?
    @ObservationIgnored private var lastObservedPageLoading: Bool?
    @ObservationIgnored private var navigationRebindPrepared = false
    @ObservationIgnored private var navigationRebindTask: Task<Void, Never>?

    public convenience init(configuration: WIModelConfiguration = .init()) {
        self.init(
            domSession: DOMSession(configuration: configuration.dom),
            networkSession: NetworkSession(configuration: configuration.network)
        )
    }

    init(
        domSession: DOMSession,
        networkSession: NetworkSession
    ) {
        self.dom = WIDOMModel(session: domSession)
        self.network = WINetworkModel(session: networkSession)
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

    public func setTabs(_ tabs: [WITab]) {
        hasConfiguredTabsFromUI = true
        self.tabs = tabs
        applyNormalizedSelection(preferredTab: selectedTab)
        syncRuntimeStateFromTabs()
    }

    public var domTransportSupportSnapshot: WITransportSupportSnapshot? {
        dom.transportSupportSnapshot
    }

    public var networkTransportSupportSnapshot: WITransportSupportSnapshot? {
        network.transportSupportSnapshot
    }

    package func setSelectedTabFromUI(_ tab: WITab?) {
        let resolvedTab = resolveSelectionCandidate(tab)
        if tab != nil, resolvedTab == nil {
            return
        }
        applyNormalizedSelection(preferredTab: resolvedTab)
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
}

private extension WIModel {
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
                    try? await Task.sleep(nanoseconds: 20_000_000)
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

    func applyNormalizedSelection(preferredTab: WITab?) {
        let normalizedTab: WITab?
        if tabs.isEmpty {
            normalizedTab = nil
        } else if let preferredTab,
                  let resolvedTab = resolveSelectionCandidate(preferredTab) {
            normalizedTab = resolvedTab
        } else if let currentSelection = selectedTab,
                  let resolvedCurrent = resolveSelectionCandidate(currentSelection) {
            normalizedTab = resolvedCurrent
        } else {
            normalizedTab = tabs.first
        }

        if normalizedTab !== selectedTab {
            selectedTab = normalizedTab
        }
    }

    func resolveSelectionCandidate(_ requestedTab: WITab?) -> WITab? {
        guard let requestedTab else {
            return nil
        }
        if let exactMatch = tabs.first(where: { $0 === requestedTab }) {
            return exactMatch
        }
        if let identifierMatch = tabs.first(where: { $0.identifier == requestedTab.identifier }) {
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
        if hasConfiguredTabsFromUI {
            let hasDOMTab = tabs.contains { $0.identifier == WITab.domTabID }
            return RuntimeAttachmentState(
                domEnabled: tabs.contains { $0.identifier == WITab.domTabID || $0.identifier == WITab.elementTabID },
                networkEnabled: tabs.contains { $0.identifier == WITab.networkTabID },
                domAutoSnapshotEnabled: selectedTab?.identifier == WITab.domTabID
                    || (selectedTab?.identifier == WITab.elementTabID && hasDOMTab == false),
                networkMode: selectedTab?.identifier == WITab.networkTabID ? .active : .buffering
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
