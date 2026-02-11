import Observation
import WebKit
import WebInspectorKitCore

extension WebInspector {
    @MainActor
    @Observable
    public final class Controller {
        public var selectedTabID: Tab.ID? {
            didSet {
                if suppressTabActivation {
                    return
                }
                applyTabActivation(for: selectedTabID)
            }
        }

        public let dom: DOMInspector
        public let network: NetworkInspector

        private var tabs: [Tab] = []
        private var activationByTabID: [Tab.ID: Tab.Activation] = [:]
        private var configuredRequirements: Tab.FeatureRequirements?
        private var suppressTabActivation = false
        private weak var connectedPageWebView: WKWebView?

        public init(configuration: Configuration = .init()) {
            self.dom = DOMInspector(session: DOMSession(configuration: configuration.dom))
            self.network = NetworkInspector(session: NetworkSession(configuration: configuration.network))
        }

        public func connect(to webView: WKWebView?) {
            connectedPageWebView = webView
            guard let webView else {
                suspend()
                return
            }

            let requirements = effectiveRequirements
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
        }

        public func suspend() {
            connectedPageWebView = nil
            dom.suspend()
            network.suspend()
        }

        public func disconnect() {
            connectedPageWebView = nil
            dom.detach()
            network.detach()
            suppressTabActivation = true
            defer { suppressTabActivation = false }
            selectedTabID = nil
        }

        internal func synchronizeSelectedTabFromNativeUI(_ tabID: Tab.ID?) {
            guard connectedPageWebView != nil else {
                return
            }
            selectedTabID = tabID
        }

        internal func configureTabs(_ tabs: [Tab]) {
            let previousRequirements = configuredRequirements
            self.tabs = tabs
            configuredRequirements = tabs.reduce(into: Tab.FeatureRequirements()) { partialResult, tab in
                partialResult.formUnion(tab.requires)
            }
#if DEBUG
            var seenIDs = Set<Tab.ID>()
            var duplicateIDs = Set<Tab.ID>()
            for tab in tabs {
                if seenIDs.insert(tab.id).inserted == false {
                    duplicateIDs.insert(tab.id)
                }
            }
            if duplicateIDs.isEmpty == false {
                assertionFailure("Duplicate tab ids detected: \(duplicateIDs.sorted())")
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

            // Reflect requirement deltas without full reconnect. Full reconnect clears DOM selection.
            if let webView = connectedPageWebView, previousRequirements != configuredRequirements {
                let previous = previousRequirements ?? [.dom, .network]
                let current = configuredRequirements ?? [.dom, .network]
                applyRequirementTransition(from: previous, to: current, using: webView)
            }
        }

        internal func applyTabActivation(_ tab: Tab?) {
            let activation: Tab.Activation
            if let tab, let tabActivation = activationByTabID[tab.id] {
                activation = tabActivation
            } else if configuredRequirements == nil {
                // If the controller is used without `Panel` (and thus without `configureTabs(_:)`),
                // there is no way to select/activate the Network tab. Default to active logging so
                // `network.store` receives live events for controller-only integrations.
                activation = .init(networkLiveLogging: true)
            } else {
                activation = .init()
            }
            let requirements = effectiveRequirements

            if requirements.contains(.dom) {
                dom.session.setAutoSnapshot(enabled: activation.domLiveUpdates)
            }
            if requirements.contains(.network) {
                network.session.setMode(activation.networkLiveLogging ? .active : .buffering)
            }
        }
    }
}

private extension WebInspector.Controller {
    var effectiveRequirements: WebInspector.Tab.FeatureRequirements {
        // If the controller is used without `Panel` (and thus without `configureTabs(_:)`),
        // default to enabling both feature sets.
        configuredRequirements ?? [.dom, .network]
    }

    func applyTabActivation(for tabID: WebInspector.Tab.ID?) {
        guard let tabID else {
            applyTabActivation(nil)
            return
        }
        applyTabActivation(tabs.first(where: { $0.id == tabID }))
    }

    func applyRequirementTransition(
        from previous: WebInspector.Tab.FeatureRequirements,
        to current: WebInspector.Tab.FeatureRequirements,
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
