import Observation
import WebKit
import WebInspectorEngine

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

    public init(configuration: WIModelConfiguration = .init()) {
        let domSession = DOMSession(configuration: configuration.dom)
        let networkSession = NetworkSession(configuration: configuration.network)

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
        dom.suspend()
        network.suspend()
        lifecycle = .suspended
    }

    public func disconnect() {
        connectedPageWebView = nil
        dom.detach()
        network.detach()
        lifecycle = .disconnected
    }

    public func setTabs(_ tabs: [WITab]) {
        hasConfiguredTabsFromUI = true
        self.tabs = tabs

        if tabs.isEmpty {
            selectedTab = nil
        } else if let selectedTab {
            if let exactMatch = tabs.first(where: { $0 === selectedTab }) {
                self.selectedTab = exactMatch
            } else if let identifierMatch = tabs.first(where: { $0.identifier == selectedTab.identifier }) {
                self.selectedTab = identifierMatch
            } else {
                self.selectedTab = tabs.first
            }
        } else {
            selectedTab = tabs.first
        }

        syncRuntimeStateFromTabs()
    }

    package func setSelectedTabFromUI(_ tab: WITab?) {
        let resolvedTab = resolveSelectionCandidate(tab)
        if tab != nil, resolvedTab == nil {
            return
        }
        let normalizedSelection: WITab?
        if let resolvedTab {
            normalizedSelection = resolvedTab
        } else if tabs.isEmpty {
            normalizedSelection = nil
        } else {
            normalizedSelection = tabs.first
        }

        if normalizedSelection !== selectedTab {
            selectedTab = normalizedSelection
        }
        syncRuntimeStateFromTabs()
    }

    package var pageWebViewForUI: WKWebView? {
        connectedPageWebView
    }

    package func setPageWebViewFromUI(_ webView: WKWebView?) {
        connectedPageWebView = webView
        guard webView != nil else {
            suspend()
            return
        }
    }

    package func activateFromUIIfPossible() {
        guard connectedPageWebView != nil else {
            return
        }
        syncRuntimeStateFromTabs()
        lifecycle = .active
    }
}

private extension WIModel {
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
        let domEnabled: Bool
        let networkEnabled: Bool
        let domAutoSnapshotEnabled: Bool
        let networkMode: NetworkLoggingMode

        if hasConfiguredTabsFromUI {
            domEnabled = tabs.contains { $0.identifier == WITab.domTabID || $0.identifier == WITab.elementTabID }
            networkEnabled = tabs.contains { $0.identifier == WITab.networkTabID }
            domAutoSnapshotEnabled = selectedTab?.identifier == WITab.domTabID
            networkMode = selectedTab?.identifier == WITab.networkTabID ? .active : .buffering
        } else {
            domEnabled = true
            networkEnabled = true
            domAutoSnapshotEnabled = true
            networkMode = .active
        }

        if let webView = connectedPageWebView {
            if domEnabled {
                dom.attach(to: webView)
            } else {
                dom.suspend()
            }

            if networkEnabled {
                network.attach(to: webView)
            } else {
                network.suspend()
            }
        } else {
            if domEnabled == false || lifecycle != .disconnected {
                dom.suspend()
            }
            if networkEnabled == false || lifecycle != .disconnected {
                network.suspend()
            }
        }

        dom.setAutoSnapshotEnabled(domEnabled && domAutoSnapshotEnabled)
        network.setMode(networkEnabled ? networkMode : .buffering)
    }
}
