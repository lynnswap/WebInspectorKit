import Observation
import ObservationsCompat
import WebKit
import WebInspectorModel
import WebInspectorEngine

@MainActor
@Observable
public final class WISession {
    public private(set) var lifecycle: WISessionLifecycle = .disconnected
    public private(set) var lastRecoverableError: String?
    public private(set) var state: WISessionState

    public var selectedTabID: String? {
        didSet {
            if isApplyingStateProjection == false, state.selectedTabID != selectedTabID {
                state.selectedTabID = selectedTabID
            }
            if suppressTabActivation {
                return
            }
            applyTabActivation(for: selectedTabID)
            onSelectedTabIDChange?(selectedTabID)
        }
    }

    public let dom: WIDOMModel
    public let network: WINetworkModel

    private let pageBridge: WIWeakPageRuntimeBridge

    private var tabs: [WISessionTabDefinition] = []
    private var activationByTabID: [String: WISessionTabActivation] = [:]
    private var configuredRequirements: WISessionFeatureRequirements?
    private var suppressTabActivation = false
    private var isApplyingStateProjection = false
    private var hasStartedObservingModelEvents = false
    private var uiCommandRoutingEnabled = false
    private weak var connectedPageWebView: WKWebView?
    private let effectRunner = WISessionEffectRunner()

    // Observed by native container to keep selected tab synchronized.
    package var onSelectedTabIDChange: ((String?) -> Void)?

    public init(configuration: WISessionConfiguration = .init()) {
        let domSession = DOMSession(configuration: configuration.dom)
        let networkSession = NetworkSession(configuration: configuration.network)

        self.pageBridge = WIWeakPageRuntimeBridge()

        self.dom = WIDOMModel(session: domSession)
        self.network = WINetworkModel(session: networkSession)
        self.state = WISessionState.makeInitial(dom: self.dom, network: self.network)
        self.dom.setRecoverableErrorHandler { [weak self] message in
            self?.lastRecoverableError = message
        }
        startObservingModelEventsIfNeeded()
    }

    public func send(_ command: WISessionCommand) {
        var nextState = state
        let effects = WISessionReducer.reduce(state: &nextState, command: command)
        guard nextState != state || effects.isEmpty == false else {
            return
        }
        state = nextState

        if case .event = command {
            // Observable updates already originated from models.
        } else {
            projectState()
        }

        effectRunner.run(effects, in: self)
    }

    package func enableUICommandRouting() {
        guard uiCommandRoutingEnabled == false else {
            return
        }
        uiCommandRoutingEnabled = true
        dom.commandSink = { [weak self] command in
            self?.send(.dom(command))
        }
        network.commandSink = { [weak self] command in
            self?.send(.network(command))
        }
    }

    public func connect(to webView: WKWebView?) {
        connectedPageWebView = webView
        pageBridge.setPageWebView(webView)
        guard let webView else {
            suspend()
            return
        }

        let requirements = effectiveRequirements
        if requirements.contains(.network) {
            let activation = resolvedActivationForTabID(selectedTabID)
            network.session.setMode(activation.networkLiveLogging ? .active : .buffering)
        }

        if requirements.contains(.dom) {
            dom.attach(to: webView)
        } else {
            dom.suspend()
        }

        if requirements.contains(.network) {
            network.attach(to: webView)
        } else {
            network.suspend()
        }

        applyTabActivation(for: selectedTabID)
        lifecycle = .active
    }

    public func suspend() {
        connectedPageWebView = nil
        pageBridge.setPageWebView(nil)
        dom.suspend()
        network.suspend()
        lifecycle = .suspended
    }

    public func disconnect() {
        connectedPageWebView = nil
        pageBridge.setPageWebView(nil)
        effectRunner.cancel()
        dom.detach()
        network.detach()
        suppressTabActivation = true
        defer { suppressTabActivation = false }
        selectedTabID = nil
        onSelectedTabIDChange?(nil)
        lifecycle = .disconnected
    }

    package func synchronizeSelectedTabFromNativeUI(_ tabID: String?) {
        guard connectedPageWebView != nil else {
            return
        }
        send(.selectTab(tabID))
    }

    package func configureTabs(_ tabs: [WISessionTabDefinition]) {
        let previousRequirements = configuredRequirements
        self.tabs = tabs
        configuredRequirements = tabs.reduce(into: WISessionFeatureRequirements()) { partialResult, tab in
            partialResult.formUnion(tab.requires)
        }

#if DEBUG
        var seenIDs = Set<String>()
        var duplicateIDs = Set<String>()
        for tab in tabs {
            if seenIDs.insert(tab.id).inserted == false {
                duplicateIDs.insert(tab.id)
            }
        }
        if duplicateIDs.isEmpty == false {
            print("WISession duplicate tab ids detected: \(duplicateIDs.sorted())")
        }
#endif

        // Avoid crashing on duplicate ids. In that case, the last tab wins.
        activationByTabID = tabs.reduce(into: [:]) { partialResult, tab in
            partialResult[tab.id] = tab.activation
        }

        if selectedTabID == nil {
            send(.selectTab(tabs.first?.id))
        } else if let currentSelectedTabID = selectedTabID, tabs.contains(where: { $0.id == currentSelectedTabID }) == false {
            send(.selectTab(tabs.first?.id))
        } else {
            applyTabActivation(for: selectedTabID)
        }

        if let webView = connectedPageWebView, previousRequirements != configuredRequirements {
            let previous = previousRequirements ?? [.dom, .network]
            let current = configuredRequirements ?? [.dom, .network]
            applyRequirementTransition(from: previous, to: current, using: webView)
        }

        onSelectedTabIDChange?(selectedTabID)
    }

    package func applyTabActivation(_ tab: WISessionTabDefinition?) {
        let activation = resolvedActivation(for: tab)
        let requirements = effectiveRequirements

        if requirements.contains(.dom) {
            dom.session.setAutoSnapshot(enabled: activation.domLiveUpdates)
        }
        if requirements.contains(.network) {
            network.session.setMode(activation.networkLiveLogging ? .active : .buffering)
        }
    }
}

private extension WISession {
    func projectState() {
        guard isApplyingStateProjection == false else {
            return
        }
        isApplyingStateProjection = true
        defer { isApplyingStateProjection = false }
        WISessionStateProjector.project(state, onto: self)
    }

    func startObservingModelEventsIfNeeded() {
        guard hasStartedObservingModelEvents == false else {
            return
        }
        hasStartedObservingModelEvents = true

        dom.observe(\.hasPageWebView, options: [.removeDuplicates]) { [weak self] value in
            self?.send(.event(.dom(.pageWebViewAvailabilityChanged(value))))
        }
        dom.observe(\.isSelectingElement, options: [.removeDuplicates]) { [weak self] value in
            self?.send(.event(.dom(.selectingElementChanged(value))))
        }
        dom.selection.observe(\.nodeId, options: [.removeDuplicates]) { [weak self] nodeID in
            self?.send(.event(.dom(.selectionNodeChanged(nodeID))))
        }
        network.observeTask([\.selectedEntry]) { [weak self] in
            self?.send(.event(.network(.selectedEntryChanged(self?.network.selectedEntry?.id))))
        }
    }

    func resolvedActivationForTabID(_ tabID: String?) -> WISessionTabActivation {
        guard let tabID else {
            return resolvedActivation(for: nil)
        }
        return resolvedActivation(for: tabs.first(where: { $0.id == tabID }))
    }

    func resolvedActivation(for tab: WISessionTabDefinition?) -> WISessionTabActivation {
        if let tab, let tabActivation = activationByTabID[tab.id] {
            return tabActivation
        }
        if configuredRequirements == nil {
            return .init(networkLiveLogging: true)
        }
        return .init()
    }

    var effectiveRequirements: WISessionFeatureRequirements {
        configuredRequirements ?? [.dom, .network]
    }

    func applyTabActivation(for tabID: String?) {
        guard let tabID else {
            applyTabActivation(nil)
            return
        }
        applyTabActivation(tabs.first(where: { $0.id == tabID }))
    }

    func applyRequirementTransition(
        from previous: WISessionFeatureRequirements,
        to current: WISessionFeatureRequirements,
        using webView: WKWebView
    ) {
        let hadDOM = previous.contains(.dom)
        let hasDOM = current.contains(.dom)
        if hadDOM != hasDOM {
            if hasDOM {
                dom.attach(to: webView)
            } else {
                dom.suspend()
            }
        }

        let hadNetwork = previous.contains(.network)
        let hasNetwork = current.contains(.network)
        if hadNetwork != hasNetwork {
            if hasNetwork {
                network.attach(to: webView)
            } else {
                network.suspend()
            }
        }
    }
}
