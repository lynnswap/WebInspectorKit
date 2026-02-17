import Observation
import WebKit
import WebInspectorKitCore

extension WebInspector {
    @MainActor
    @Observable
    public final class Controller {
        public var selectedTabID: TabDescriptor.ID? {
            didSet {
                if suppressTabActivation {
                    return
                }
                applyTabActivation(for: selectedTabID)
                onSelectedTabIDChange?(selectedTabID)
            }
        }

        public let dom: DOMInspector
        public let network: NetworkInspector

        private var tabs: [TabDescriptor] = []
        private var activationByTabID: [TabDescriptor.ID: TabDescriptor.Activation] = [:]
        private var configuredRequirements: TabDescriptor.FeatureRequirements?
        private var suppressTabActivation = false
        private weak var connectedPageWebView: WKWebView?

        // Observed by native container to keep selected tab synchronized.
        var onSelectedTabIDChange: ((TabDescriptor.ID?) -> Void)?

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
            onSelectedTabIDChange?(nil)
        }

        internal func synchronizeSelectedTabFromNativeUI(_ tabID: TabDescriptor.ID?) {
            guard connectedPageWebView != nil else {
                return
            }
            selectedTabID = tabID
        }

        internal func configureTabs(_ tabs: [TabDescriptor]) {
            let previousRequirements = configuredRequirements
            self.tabs = tabs
            configuredRequirements = tabs.reduce(into: TabDescriptor.FeatureRequirements()) { partialResult, tab in
                partialResult.formUnion(tab.requires)
            }

#if DEBUG
            var seenIDs = Set<TabDescriptor.ID>()
            var duplicateIDs = Set<TabDescriptor.ID>()
            for tab in tabs {
                if seenIDs.insert(tab.id).inserted == false {
                    duplicateIDs.insert(tab.id)
                }
            }
            if duplicateIDs.isEmpty == false {
                print("WebInspector.Controller duplicate tab ids detected: \(duplicateIDs.sorted())")
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

            onSelectedTabIDChange?(selectedTabID)
        }

        internal func applyTabActivation(_ tab: TabDescriptor?) {
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
}

private extension WebInspector.Controller {
    func resolvedActivationForTabID(_ tabID: WebInspector.TabDescriptor.ID?) -> WebInspector.TabDescriptor.Activation {
        guard let tabID else {
            return resolvedActivation(for: nil)
        }
        return resolvedActivation(for: tabs.first(where: { $0.id == tabID }))
    }

    func resolvedActivation(for tab: WebInspector.TabDescriptor?) -> WebInspector.TabDescriptor.Activation {
        if let tab, let tabActivation = activationByTabID[tab.id] {
            return tabActivation
        }
        if configuredRequirements == nil {
            return .init(networkLiveLogging: true)
        }
        return .init()
    }

    var effectiveRequirements: WebInspector.TabDescriptor.FeatureRequirements {
        configuredRequirements ?? [.dom, .network]
    }

    func applyTabActivation(for tabID: WebInspector.TabDescriptor.ID?) {
        guard let tabID else {
            applyTabActivation(nil)
            return
        }
        applyTabActivation(tabs.first(where: { $0.id == tabID }))
    }

    func applyRequirementTransition(
        from previous: WebInspector.TabDescriptor.FeatureRequirements,
        to current: WebInspector.TabDescriptor.FeatureRequirements,
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
