import Observation
import WebKit
import WebInspectorKitCore

@MainActor
@Observable
public final class WISessionController {
    public var selectedTabID: WIPaneDescriptor.ID? {
        didSet {
            if suppressTabActivation {
                return
            }
            applyTabActivation(for: selectedTabID)
            onSelectedTabIDChange?(selectedTabID)
            dispatchRuntime(.selectPane(selectedTabID))
        }
    }

    public let dom: WIDOMPaneViewModel
    public let network: WINetworkPaneViewModel
    public let runtime: WIRuntimeActor
    public let store: WISessionStore

    private let pageBridge: WIWeakPageRuntimeBridge

    private var tabs: [WIPaneDescriptor] = []
    private var activationByTabID: [WIPaneDescriptor.ID: WIPaneDescriptor.Activation] = [:]
    private var configuredRequirements: WIPaneDescriptor.FeatureRequirements?
    private var suppressTabActivation = false
    private weak var connectedPageWebView: WKWebView?

    // Observed by native container to keep selected tab synchronized.
    var onSelectedTabIDChange: ((WIPaneDescriptor.ID?) -> Void)?

    public init(configuration: WIConfiguration = .init()) {
        let domSession = DOMSession(configuration: configuration.dom)
        let networkSession = NetworkSession(configuration: configuration.network)
        let runtimeActor = WIRuntimeActor(
            domRuntime: WIDOMRuntimeActor(session: domSession),
            networkRuntime: WINetworkRuntimeActor(session: networkSession)
        )

        self.pageBridge = WIWeakPageRuntimeBridge()
        self.runtime = runtimeActor

        self.dom = WIDOMPaneViewModel(session: domSession) { [runtimeActor] message in
            Task {
                await runtimeActor.dispatch(.recoverableError(message))
            }
        }
        self.network = WINetworkPaneViewModel(session: networkSession)
        self.store = WISessionStore()

        Task { [runtimeActor, store] in
            let events = await runtimeActor.events()
            await MainActor.run {
                store.bind(to: events)
            }
            await runtimeActor.dispatch(.refreshState)
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
        dispatchRuntime(.connected)
        dispatchRuntime(.refreshState)
    }

    public func suspend() {
        connectedPageWebView = nil
        pageBridge.setPageWebView(nil)
        dom.suspend()
        network.suspend()
        dispatchRuntime(.suspended)
        dispatchRuntime(.refreshState)
    }

    public func disconnect() {
        connectedPageWebView = nil
        pageBridge.setPageWebView(nil)
        dom.detach()
        network.detach()
        suppressTabActivation = true
        defer { suppressTabActivation = false }
        selectedTabID = nil
        onSelectedTabIDChange?(nil)
        dispatchRuntime(.disconnected)
        dispatchRuntime(.refreshState)
    }

    internal func synchronizeSelectedTabFromNativeUI(_ tabID: WIPaneDescriptor.ID?) {
        guard connectedPageWebView != nil else {
            return
        }
        selectedTabID = tabID
    }

    internal func configureTabs(_ tabs: [WIPaneDescriptor]) {
        let previousRequirements = configuredRequirements
        self.tabs = tabs
        configuredRequirements = tabs.reduce(into: WIPaneDescriptor.FeatureRequirements()) { partialResult, tab in
            partialResult.formUnion(tab.requires)
        }

#if DEBUG
        var seenIDs = Set<WIPaneDescriptor.ID>()
        var duplicateIDs = Set<WIPaneDescriptor.ID>()
        for tab in tabs {
            if seenIDs.insert(tab.id).inserted == false {
                duplicateIDs.insert(tab.id)
            }
        }
        if duplicateIDs.isEmpty == false {
            print("WISessionController duplicate tab ids detected: \(duplicateIDs.sorted())")
        }
#endif

        // Avoid crashing on duplicate ids. In that case, the last tab wins.
        activationByTabID = tabs.reduce(into: [:]) { partialResult, tab in
            partialResult[tab.id] = tab.activation
        }

        if selectedTabID == nil {
            self.selectedTabID = tabs.first?.id
        } else if let currentSelectedTabID = selectedTabID, tabs.contains(where: { $0.id == currentSelectedTabID }) == false {
            self.selectedTabID = tabs.first?.id
        } else {
            applyTabActivation(for: selectedTabID)
        }

        if let webView = connectedPageWebView, previousRequirements != configuredRequirements {
            let previous = previousRequirements ?? [.dom, .network]
            let current = configuredRequirements ?? [.dom, .network]
            applyRequirementTransition(from: previous, to: current, using: webView)
        }

        dispatchRuntime(.configurePanes(tabs.map(\.runtimeDescriptor)))
        dispatchRuntime(.selectPane(selectedTabID))
        dispatchRuntime(.refreshState)

        onSelectedTabIDChange?(selectedTabID)
    }

    internal func applyTabActivation(_ tab: WIPaneDescriptor?) {
        let activation = resolvedActivation(for: tab)
        let requirements = effectiveRequirements

        if requirements.contains(.dom) {
            dom.session.setAutoSnapshot(enabled: activation.domLiveUpdates)
        }
        if requirements.contains(.network) {
            network.session.setMode(activation.networkLiveLogging ? .active : .buffering)
        }
        dispatchRuntime(.refreshState)
    }
}

private extension WISessionController {
    func dispatchRuntime(_ command: WISessionCommand) {
        Task {
            await runtime.dispatch(command)
        }
    }

    func resolvedActivationForTabID(_ tabID: WIPaneDescriptor.ID?) -> WIPaneDescriptor.Activation {
        guard let tabID else {
            return resolvedActivation(for: nil)
        }
        return resolvedActivation(for: tabs.first(where: { $0.id == tabID }))
    }

    func resolvedActivation(for tab: WIPaneDescriptor?) -> WIPaneDescriptor.Activation {
        if let tab, let tabActivation = activationByTabID[tab.id] {
            return tabActivation
        }
        if configuredRequirements == nil {
            return .init(networkLiveLogging: true)
        }
        return .init()
    }

    var effectiveRequirements: WIPaneDescriptor.FeatureRequirements {
        configuredRequirements ?? [.dom, .network]
    }

    func applyTabActivation(for tabID: WIPaneDescriptor.ID?) {
        guard let tabID else {
            applyTabActivation(nil)
            return
        }
        applyTabActivation(tabs.first(where: { $0.id == tabID }))
    }

    func applyRequirementTransition(
        from previous: WIPaneDescriptor.FeatureRequirements,
        to current: WIPaneDescriptor.FeatureRequirements,
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
