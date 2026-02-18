import Foundation
import OSLog
import WebKit

public enum NetworkLoggingMode: String, Sendable {
    case active
    case buffering
    case stopped
}

private let networkLogger = Logger(subsystem: "WebInspectorKit", category: "NetworkPageAgent")
private let networkPresenceProbeScript: String = """
(function() { /* webInspectorNetworkAgent */ })();
"""

@MainActor
public final class NetworkPageAgent: NSObject, PageAgent {
    private enum HandlerName: String, CaseIterable {
        case networkEvents = "webInspectorNetworkEvents"
        case networkReset = "webInspectorNetworkReset"
    }

    weak var webView: WKWebView?
    let store = NetworkStore()
    private var loggingMode: NetworkLoggingMode = .buffering
    private var configureTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?

    @MainActor deinit {
        configureTask?.cancel()
        clearTask?.cancel()
        detachPageWebView()
    }

    func setMode(_ mode: NetworkLoggingMode) {
        loggingMode = mode
        store.setRecording(mode != .stopped)
        if mode == .stopped {
            store.reset()
        }
        scheduleConfigure(mode: mode, clearExisting: false, on: webView)
    }

    func clearNetworkLogs() {
        store.clear()
        scheduleClear(on: webView)
    }
}

// MARK: - WIPageAgent

extension NetworkPageAgent {
    func attachPageWebView(_ newWebView: WKWebView?) {
        replacePageWebView(with: newWebView)
    }

    func detachPageWebView(preparing modeBeforeDetach: NetworkLoggingMode? = nil) {
        if let modeBeforeDetach {
            loggingMode = modeBeforeDetach
            store.setRecording(modeBeforeDetach != .stopped)
            if modeBeforeDetach == .stopped {
                store.reset()
            }
        }
        if let modeBeforeDetach, let webView {
            scheduleConfigure(mode: modeBeforeDetach, clearExisting: false, on: webView)
        }
        replacePageWebView(with: nil)
    }

    func willDetachPageWebView(_ webView: WKWebView) {
        detachMessageHandlers(from: webView)
    }

    func didAttachPageWebView(_ webView: WKWebView, previousWebView: WKWebView?) {
        if previousWebView !== webView {
            store.reset()
        }
        registerMessageHandlers()
        scheduleConfigure(mode: loggingMode, clearExisting: true, on: webView)
    }

    func didClearPageWebView() {
        store.reset()
    }

    func fetchBody(bodyRef: String, role: NetworkBody.Role) async -> NetworkBody? {
        guard let webView else { return nil }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                return (function(ref) {
                    if (!window.webInspectorNetworkAgent || typeof window.webInspectorNetworkAgent.getBody !== "function") {
                        return null;
                    }
                    const body = window.webInspectorNetworkAgent.getBody(ref);
                    if (body == null) {
                        return null;
                    }
                    try {
                        return JSON.stringify(body);
                    } catch (error) {
                        return null;
                    }
                })(ref);
                """,
                arguments: ["ref": bodyRef],
                in: nil,
                contentWorld: .page
            )
            let payload: NetworkBodyPayload?
            if let jsonString = result as? String,
               let data = jsonString.data(using: .utf8) {
                payload = try? JSONDecoder().decode(NetworkBodyPayload.self, from: data)
            } else if let dictionary = result as? NSDictionary,
                      let data = try? JSONSerialization.data(withJSONObject: dictionary) {
                payload = try? JSONDecoder().decode(NetworkBodyPayload.self, from: data)
            } else {
                payload = nil
            }
            guard let payload else {
                return nil
            }
            return NetworkBody.from(payload: payload, role: role)
        } catch {
            networkLogger.error("getBody failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

extension NetworkPageAgent: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else {
            return
        }
        guard let handlerName = HandlerName(rawValue: message.name) else { return }
        switch handlerName {
        case .networkEvents:
            handleNetworkEventsMessage(message)
        case .networkReset:
            handleNetworkReset()
        }
    }

    private func handleNetworkEventsMessage(_ message: WKScriptMessage) {
        guard let batch = decodeNetworkBatch(from: message.body) else { return }
        if batch.version != 1 {
            networkLogger.debug("unsupported network batch version: \(batch.version, privacy: .public)")
            return
        }
        if let dropped = batch.dropped, dropped > 0 {
            // TODO: Surface dropped event counts in the store/UI.
            networkLogger.debug("network batch dropped events: \(dropped, privacy: .public)")
        }
        store.applyNetworkBatch(batch)
    }
    
    private func handleNetworkReset() {
        store.reset()
    }
}

private extension NetworkPageAgent {
    func scheduleConfigure(mode: NetworkLoggingMode, clearExisting: Bool, on targetWebView: WKWebView?) {
        configureTask?.cancel()
        configureTask = Task { [weak self] in
            guard let self else { return }
            await configureNetworkLogging(
                mode: mode,
                clearExisting: clearExisting,
                on: targetWebView
            )
        }
    }

    func scheduleClear(on targetWebView: WKWebView?) {
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            guard let self else { return }
            await clearRemoteNetworkRecords(on: targetWebView)
        }
    }

    func registerMessageHandlers() {
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue, contentWorld: .page)
            controller.add(self, contentWorld: .page, name: $0.rawValue)
        }
    }

    func detachMessageHandlers(from webView: WKWebView?) {
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue, contentWorld: .page)
        }
        networkLogger.debug("detached network message handlers")
    }

    func installNetworkAgentScriptIfNeeded(on webView: WKWebView) async {
        let controller = webView.configuration.userContentController
        if controller.userScripts.contains(where: { $0.source == networkPresenceProbeScript }) {
            return
        }

        let scriptSource: String
        do {
            scriptSource = try WebInspectorScripts.networkAgent()
        } catch {
            networkLogger.error("failed to prepare network inspector script: \(error.localizedDescription, privacy: .public)")
            return
        }

        let userScript = WKUserScript(
            source: scriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        let checkScript = WKUserScript(
            source: networkPresenceProbeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(userScript)
        controller.addUserScript(checkScript)

        do {
            _ = try await webView.evaluateJavaScript(scriptSource, in: nil, contentWorld: .page)
        } catch {
            networkLogger.error("failed to install network agent: \(error.localizedDescription, privacy: .public)")
        }
        networkLogger.debug("installed network agent user script")
    }

    func configureNetworkLogging(
        mode: NetworkLoggingMode,
        clearExisting: Bool,
        on targetWebView: WKWebView?
    ) async {
        guard let webView = targetWebView ?? self.webView else { return }
        let controller = webView.configuration.userContentController
        let networkInstalled = controller.userScripts.contains { $0.source == networkPresenceProbeScript }
        let modeRequiresAgent = mode != .stopped
        let shouldInstallNetworkAgent = modeRequiresAgent || (networkInstalled && clearExisting)

        if shouldInstallNetworkAgent {
            await installNetworkAgentScriptIfNeeded(on: webView)
        }

        let networkReady = webView.configuration.userContentController.userScripts.contains { $0.source == networkPresenceProbeScript }
        let script = """
        (function(mode, clearExisting) {
            if (!window.webInspectorNetworkAgent || typeof window.webInspectorNetworkAgent.configure !== "function") {
                return;
            }
            window.webInspectorNetworkAgent.configure({mode: mode, clear: clearExisting});
        })(mode, clearExisting);
        """
        guard networkReady else { return }

        do {
            try await webView.callAsyncVoidJavaScript(
                script,
                arguments: [
                    "clearExisting": clearExisting,
                    "mode": mode.rawValue
                ],
                contentWorld: .page
            )
        } catch {
            networkLogger.error("configure network logging failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clearRemoteNetworkRecords(on targetWebView: WKWebView?) async {
        guard let webView = targetWebView ?? self.webView else { return }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorNetworkAgent.clear();",
                arguments: [:],
                contentWorld: .page
            )
        } catch {
            networkLogger.error("clear network records failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func decodeNetworkBatch(from payload: Any?) -> NetworkEventBatch? {
        NetworkEventBatch.decode(from: payload)
    }
}
