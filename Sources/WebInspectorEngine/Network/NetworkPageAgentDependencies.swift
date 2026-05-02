import WebKit
import WebInspectorBridge
import WebInspectorScripts

@MainActor
package struct NetworkPageAgentDependencies {
    package var controllerStateRegistry: WIUserContentControllerStateRegistry
    package var startupMode: @MainActor @Sendable () -> WIBridgeMode
    package var modeForAttachment: @MainActor @Sendable (WKWebView?) -> WIBridgeMode
    package var loadNetworkAgentScriptSource: @MainActor @Sendable () throws -> String
    package var supportsResourceLoadDelegate: @MainActor @Sendable (WKWebView) -> Bool
    package var setResourceLoadDelegate: @MainActor @Sendable (WKWebView, AnyObject?) -> Bool

    package init(
        controllerStateRegistry: WIUserContentControllerStateRegistry = .shared,
        startupMode: @escaping @MainActor @Sendable () -> WIBridgeMode = {
            WISPIRuntime.shared.startupMode()
        },
        modeForAttachment: @escaping @MainActor @Sendable (WKWebView?) -> WIBridgeMode = { webView in
            WISPIRuntime.shared.modeForAttachment(webView: webView)
        },
        loadNetworkAgentScriptSource: @escaping @MainActor @Sendable () throws -> String = {
            try WebInspectorScripts.networkAgent()
        },
        supportsResourceLoadDelegate: @escaping @MainActor @Sendable (WKWebView) -> Bool = { webView in
            WISPIRuntime.shared.canSetResourceLoadDelegate(on: webView)
        },
        setResourceLoadDelegate: @escaping @MainActor @Sendable (WKWebView, AnyObject?) -> Bool = { webView, delegate in
            WISPIRuntime.shared.setResourceLoadDelegate(on: webView, delegate: delegate)
        }
    ) {
        self.controllerStateRegistry = controllerStateRegistry
        self.startupMode = startupMode
        self.modeForAttachment = modeForAttachment
        self.loadNetworkAgentScriptSource = loadNetworkAgentScriptSource
        self.supportsResourceLoadDelegate = supportsResourceLoadDelegate
        self.setResourceLoadDelegate = setResourceLoadDelegate
    }

    package static var liveValue: Self {
        Self()
    }

    package static var testValue: Self {
        Self(
            startupMode: { .legacyJSON },
            modeForAttachment: { _ in .legacyJSON },
            loadNetworkAgentScriptSource: { "" },
            supportsResourceLoadDelegate: { _ in false },
            setResourceLoadDelegate: { _, _ in false }
        )
    }
}
