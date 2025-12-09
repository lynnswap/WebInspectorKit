import SwiftUI
import Foundation
import OSLog
import WebKit
import Observation

public enum WINetworkLoggingMode: String {
    case active
    case buffering
    case stopped
}

private let networkLogger = Logger(subsystem: "WebInspectorKit", category: "WINetworkPageAgent")
private let networkPresenceProbeScript: String = """
(function() { /* webInspectorNetwork */ })();
"""

@MainActor
@Observable
final class WINetworkPageAgent: NSObject, WIPageAgent {
    private enum HandlerName: String, CaseIterable {
        case http = "webInspectorHTTPUpdate"
        case httpBatch = "webInspectorHTTPBatchUpdate"
        
        case webSocket = "webInspectorWSUpdate"
        case networkReset = "webInspectorNetworkReset"
        
        case queuedBatch = "webInspectorNetworkQueuedUpdate"
    }

    weak var webView: WKWebView?
    let store = WINetworkStore()
    private var loggingMode: WINetworkLoggingMode = .active

    @MainActor deinit {
        detachPageWebView()
    }

    func setRecording(_ mode: WINetworkLoggingMode) {
        loggingMode = mode
        store.setRecording(mode != .stopped)
        if mode == .stopped {
            store.reset()
        }
        Task {
            await self.configureNetworkLogging(
                mode: mode,
                clearExisting: false,
                on: self.webView
            )
        }
    }

    func clearNetworkLogs() {
        store.clear()
        Task {
            await self.clearRemoteNetworkRecords(on: self.webView)
        }
    }
}

// MARK: - WIPageAgent

extension WINetworkPageAgent {
    func attachPageWebView(_ newWebView: WKWebView?) {
        replacePageWebView(with: newWebView)
    }

    func detachPageWebView(disableNetworkLogging: Bool = false) {
        if disableNetworkLogging, let webView {
            Task {
                let mode: WINetworkLoggingMode = loggingMode == .stopped ? .stopped : .buffering
                await self.configureNetworkLogging(
                    mode: mode,
                    clearExisting: false,
                    on: webView
                )
            }
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
        Task {
            await self.configureNetworkLogging(
                mode: self.loggingMode,
                clearExisting: true,
                on: webView
            )
        }
    }

    func didClearPageWebView() {
        store.reset()
    }

    func fetchBody(requestID: Int, role: WINetworkBody.Role) async -> WINetworkBody? {
        guard let webView else { return nil }
        do {
            let isRequest = role == .request
            let result = try await webView.callAsyncJavaScript(
                """
                return (function(requestId, isRequest) {
                    if (!window.webInspectorNetwork) {
                        return null;
                    }
                    const getter = isRequest ? window.webInspectorNetwork.getRequestBody : window.webInspectorNetwork.getResponseBody;
                    if (typeof getter !== "function") {
                        return null;
                    }
                    const body = getter(requestId);
                    if (body == null) {
                        return null;
                    }
                    try {
                        return JSON.stringify(body);
                    } catch (error) {
                        return null;
                    }
                })(requestId, isRequest);
                """,
                arguments: [
                    "requestId": requestID,
                    "isRequest": isRequest
                ],
                in: nil,
                contentWorld: .page
            )
            let decoded: Any
            if let jsonString = result as? String,
               let data = jsonString.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                decoded = object
            } else {
                decoded = result as Any
            }
            return WINetworkBody.decode(from: decoded)
        } catch {
            networkLogger.error("getBody failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

extension WINetworkPageAgent: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else {
            return
        }
        guard let handlerName = HandlerName(rawValue: message.name) else { return }
        switch handlerName {
        case .http:
            handleHTTPMessage(message)
        case .httpBatch:
            handleNetworkBatchMessage(message)
        case .webSocket:
            handleWebSocketMessage(message)
        case .networkReset:
            handleNetworkReset()
        case .queuedBatch:
            handleQueuedBatchMessage(message)
        }
    }

    private func handleHTTPMessage(_ message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let event = HTTPNetworkEvent(dictionary: payload) else {
            return
        }
        store.applyHTTPEvent(event)
    }

    private func handleWebSocketMessage(_ message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let event = WSNetworkEvent(dictionary: payload) else {
            return
        }
        store.applyWSEvent(event)
    }

    private func handleNetworkReset() {
        store.reset()
    }

    private func handleNetworkBatchMessage(_ message: WKScriptMessage) {
        if let dictionary = message.body as? [String: Any],
           let batch = NetworkEventBatch(dictionary: dictionary) {
            store.applyBatchedInsertions(batch)
            return
        }
    }

    private func handleQueuedBatchMessage(_ message: WKScriptMessage) {
        guard let dictionary = message.body as? [String: Any],
              let events = dictionary["events"] as? [[String: Any]] else {
            return
        }
        for event in events {
            guard let kind = event["kind"] as? String else { continue }
            switch kind {
            case "http":
                guard let payload = event["payload"] as? [String: Any],
                      let parsed = HTTPNetworkEvent(dictionary: payload) else {
                    continue
                }
                store.applyHTTPEvent(parsed)
            case "httpBatch":
                let payloads = event["payloads"] as? [[String: Any]] ?? []
                for payload in payloads {
                    guard let parsed = HTTPNetworkEvent(dictionary: payload) else { continue }
                    store.applyHTTPEvent(parsed)
                }
            case "websocket":
                guard let payload = event["payload"] as? [String: Any],
                      let parsed = WSNetworkEvent(dictionary: payload) else {
                    continue
                }
                store.applyWSEvent(parsed)
            default:
                continue
            }
        }
    }
}

private extension WINetworkPageAgent {
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
            scriptSource = try WIScript.bootstrapNetworkAgent()
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
        mode: WINetworkLoggingMode,
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
        var script = ""
        script += "window.webInspectorNetwork.setLoggingMode(mode);"
        if clearExisting {
            script += "window.webInspectorNetwork.clearRecords();"
        }
        guard !script.isEmpty, networkReady else { return }

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
                "window.webInspectorNetwork.clearRecords();",
                arguments: [:],
                contentWorld: .page
            )
        } catch {
            networkLogger.error("clear network records failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
