import Foundation
import OSLog
import WebKit
import WebInspectorScripts
import WebInspectorBridge

private let domLogger = Logger(subsystem: "WebInspectorKit", category: "DOMPageBridge")
private let domAgentBootstrapWindowKey = "__wiDOMAgentBootstrap"
private let domAgentBootstrapScriptMarker = "__wiDOMAgentBootstrapUserScript"
package typealias DOMBridgeScriptInstaller = @MainActor (WKWebView, String, WKContentWorld) async throws -> Void

private struct DOMBootstrapConfiguration {
    let contextID: DOMContextID
    let autoSnapshotEnabled: Bool
    let autoSnapshotMaxDepth: Int
    let autoSnapshotDebounceMilliseconds: Int

    var signature: String {
        "\(contextID)|\(autoSnapshotEnabled ? 1 : 0)|\(autoSnapshotMaxDepth)|\(autoSnapshotDebounceMilliseconds)"
    }

    var autoSnapshotOptions: NSDictionary {
        [
            "enabled": NSNumber(value: autoSnapshotEnabled),
            "maxDepth": NSNumber(value: autoSnapshotMaxDepth),
            "debounce": NSNumber(value: autoSnapshotDebounceMilliseconds),
        ]
    }

    var scriptSource: String {
        let enabledLiteral = autoSnapshotEnabled ? "true" : "false"
        return """
        (function() {
            /* \(domAgentBootstrapScriptMarker) */
            const bootstrap = {
                contextID: \(contextID),
                autoSnapshot: {
                    enabled: \(enabledLiteral),
                    maxDepth: \(autoSnapshotMaxDepth),
                    debounce: \(autoSnapshotDebounceMilliseconds)
                }
            };
            Object.defineProperty(window, "\(domAgentBootstrapWindowKey)", {
                value: bootstrap,
                configurable: true,
                writable: false,
                enumerable: false
            });
            if (
                window.webInspectorDOM &&
                typeof window.webInspectorDOM.bootstrap === "function"
            ) {
                window.webInspectorDOM.bootstrap(bootstrap);
            }
        })();
        """
    }
}

@MainActor
public final class DOMPageBridge: NSObject {
    private weak var webView: WKWebView?
    private var configuration: DOMConfiguration
    private var currentContextID: DOMContextID?
    private var documentURL: String?
    private var autoSnapshotEnabled = false

    private let bridgeWorld: WKContentWorld
    private let controllerStateRegistry: WIUserContentControllerStateRegistry
    private let installDOMBridgeScript: DOMBridgeScriptInstaller

    package var attachedWebView: WKWebView? {
        webView
    }

    package convenience init(configuration: DOMConfiguration) {
        self.init(
            configuration: configuration,
            controllerStateRegistry: .shared,
            installDOMBridgeScript: DOMPageBridge.evaluateDOMBridgeScript
        )
    }

    package init(
        configuration: DOMConfiguration,
        controllerStateRegistry: WIUserContentControllerStateRegistry,
        installDOMBridgeScript: @escaping DOMBridgeScriptInstaller = DOMPageBridge.evaluateDOMBridgeScript
    ) {
        self.configuration = configuration
        self.controllerStateRegistry = controllerStateRegistry
        self.installDOMBridgeScript = installDOMBridgeScript
        self.bridgeWorld = WISPIContentWorldProvider.bridgeWorld()
    }

    isolated deinit {
        tearDownPageWebViewForDeinit()
    }

    public func updateConfiguration(_ configuration: DOMConfiguration) {
        self.configuration = configuration
    }

    func tearDownForDeinit() {
        tearDownPageWebViewForDeinit()
    }
}

extension DOMPageBridge {
    package func attach(to webView: WKWebView) {
        guard self.webView !== webView else {
            return
        }
        self.webView = webView
    }

    package func detach() async {
        guard let webView else {
            currentContextID = nil
            documentURL = nil
            return
        }
        self.webView = nil
        currentContextID = nil
        documentURL = nil
        await performDetachCleanup(on: webView)
    }

    package func installOrUpdateBootstrap(
        on webView: WKWebView,
        contextID: DOMContextID,
        configuration: DOMConfiguration? = nil,
        autoSnapshotEnabled: Bool
    ) async {
        if let configuration {
            updateConfiguration(configuration)
        }
        attach(to: webView)
        currentContextID = contextID
        self.autoSnapshotEnabled = autoSnapshotEnabled
        await installDOMAgentScriptIfNeeded(on: webView)
        await refreshBootstrap(on: webView)
        await configureAutoSnapshotIfPossible(on: webView)
    }

    package func readContext(on webView: WKWebView) async -> DOMContext? {
        guard self.webView === webView else {
            return nil
        }
        do {
            let rawResult = try await webView.callAsyncJavaScriptCompat(
                """
                return (function() {
                    const status = window.webInspectorDOM?.debugStatus?.();
                    if (!status || typeof status !== "object") {
                        return null;
                    }
                    return {
                        contextID: typeof status.contextID === "number" ? status.contextID : null,
                        documentURL: typeof status.documentURL === "string" ? status.documentURL : null
                    };
                })();
                """,
                arguments: [:],
                in: nil,
                contentWorld: bridgeWorld
            )
            guard let context = rawResult as? [String: Any] ?? (rawResult as? NSDictionary as? [String: Any]),
                  let contextID = (context["contextID"] as? NSNumber)?.uint64Value ?? (context["contextID"] as? UInt64)
            else {
                return nil
            }
            let documentURL = normalizedDocumentURL(context["documentURL"] as? String)
            self.currentContextID = contextID
            self.documentURL = documentURL
            return DOMContext(contextID: contextID, documentURL: documentURL)
        } catch {
            domLogger.debug("read context skipped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    package func selectionCopyText(target: DOMRequestNodeTarget, kind: DOMSelectionCopyKind) async throws -> String {
        let webView = try requireWebView()
        guard let targetArgument = target.jsArgument else {
            return ""
        }
        let rawResult = try await webView.callAsyncJavaScriptCompat(
            "return window.webInspectorDOM?.\(kind.jsFunction)?.(target) ?? \"\"",
            arguments: ["target": targetArgument],
            in: nil,
            contentWorld: bridgeWorld
        )
        return rawResult as? String ?? ""
    }
}

private extension DOMPageBridge {
    static func evaluateDOMBridgeScript(
        on webView: WKWebView,
        scriptSource: String,
        contentWorld: WKContentWorld
    ) async throws {
        try await webView.callAsyncVoidJavaScript(
            scriptSource,
            contentWorld: contentWorld
        )
    }

    func requireWebView() throws -> WKWebView {
        guard let webView else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        return webView
    }

    func currentBootstrapConfiguration() -> DOMBootstrapConfiguration {
        DOMBootstrapConfiguration(
            contextID: currentContextID ?? 0,
            autoSnapshotEnabled: autoSnapshotEnabled,
            autoSnapshotMaxDepth: max(1, configuration.snapshotDepth),
            autoSnapshotDebounceMilliseconds: max(50, Int(configuration.autoUpdateDebounce * 1000))
        )
    }

    func makeBootstrapUserScript(_ bootstrap: DOMBootstrapConfiguration) -> WKUserScript {
        WKUserScript(
            source: bootstrap.scriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: bridgeWorld
        )
    }

    func replaceBootstrapUserScript(
        on controller: WKUserContentController,
        with bootstrapScript: WKUserScript
    ) {
        var replaced = false
        let updatedScripts = controller.userScripts.compactMap { script in
            guard script.source.contains(domAgentBootstrapScriptMarker) else {
                return script
            }
            guard !replaced else {
                return nil
            }
            replaced = true
            return bootstrapScript
        }

        controller.removeAllUserScripts()
        if !replaced {
            controller.addUserScript(bootstrapScript)
        }
        updatedScripts.forEach { controller.addUserScript($0) }
    }

    func installDOMAgentScriptIfNeeded(on webView: WKWebView) async {
        let controller = webView.configuration.userContentController
        if controllerStateRegistry.domBridgeScriptInstalled(on: controller) {
            return
        }

        let bootstrap = currentBootstrapConfiguration()
        let scriptSource: String
        do {
            scriptSource = try WebInspectorScripts.domAgent()
        } catch {
            domLogger.error("failed to load DOM agent: \(error.localizedDescription, privacy: .public)")
            return
        }

        controller.addUserScript(makeBootstrapUserScript(bootstrap))
        controllerStateRegistry.setDOMBootstrapSignature(bootstrap.signature, on: controller)
        controller.addUserScript(
            WKUserScript(
                source: scriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: bridgeWorld
            )
        )
        controllerStateRegistry.setDOMBridgeScriptInstalled(true, on: controller)

        do {
            try await webView.callAsyncVoidJavaScript(
                bootstrap.scriptSource,
                contentWorld: bridgeWorld
            )
            try await installDOMBridgeScript(webView, scriptSource, bridgeWorld)
        } catch {
            domLogger.error("failed to evaluate DOM agent: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshBootstrap(on webView: WKWebView) async {
        guard self.webView === webView else {
            return
        }
        let controller = webView.configuration.userContentController
        let bootstrap = currentBootstrapConfiguration()
        if controllerStateRegistry.domBootstrapSignature(on: controller) != bootstrap.signature {
            replaceBootstrapUserScript(on: controller, with: makeBootstrapUserScript(bootstrap))
            controllerStateRegistry.setDOMBootstrapSignature(bootstrap.signature, on: controller)
        }

        do {
            try await webView.callAsyncVoidJavaScript(
                bootstrap.scriptSource,
                contentWorld: bridgeWorld
            )
        } catch {
            domLogger.debug("refresh bootstrap skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    func configureAutoSnapshotIfPossible(on webView: WKWebView) async {
        let options = currentBootstrapConfiguration().autoSnapshotOptions
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOM?.configureAutoSnapshot?.(options)",
                arguments: ["options": options],
                contentWorld: bridgeWorld
            )
        } catch {
            domLogger.debug("configure auto snapshot skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    func performDetachCleanup(on webView: WKWebView) async {
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOM?.detach?.()",
                contentWorld: bridgeWorld
            )
        } catch {
            domLogger.debug("detach cleanup skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    func tearDownPageWebViewForDeinit() {
        guard let webView else {
            return
        }
        webView.evaluateJavaScriptCompat(
            "window.webInspectorDOM?.detach?.()",
            in: nil,
            in: bridgeWorld,
            completionHandler: nil
        )
    }

}

private func normalizedDocumentURL(_ documentURL: String?) -> String? {
    guard let documentURL, !documentURL.isEmpty else {
        return nil
    }
    guard var components = URLComponents(string: documentURL) else {
        return documentURL
    }
    components.fragment = nil
    return components.string ?? documentURL
}
