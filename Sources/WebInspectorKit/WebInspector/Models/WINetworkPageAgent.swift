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
(function() { /* webInspectorNetworkAgent */ })();
"""

@MainActor
@Observable
final class WINetworkPageAgent: NSObject, WIPageAgent {
    private enum HandlerName: String, CaseIterable {
        case networkEvents = "webInspectorNetworkEvents"
        case networkReset = "webInspectorNetworkReset"
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

    func fetchBody(bodyRef: String, role: WINetworkBody.Role) async -> WINetworkBody? {
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
            } else if let dictionary = result as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: dictionary) {
                payload = try? JSONDecoder().decode(NetworkBodyPayload.self, from: data)
            } else {
                payload = nil
            }
            guard let payload else {
                return nil
            }
            return WINetworkBody.from(payload: payload, role: role)
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
        for event in batch.events {
            store.applyHTTPEvent(event)
        }
    }
    
    private func handleNetworkReset() {
        store.reset()
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
        if let data = payload as? Data {
            return try? JSONDecoder().decode(NetworkEventBatch.self, from: data)
        }
        if let jsonString = payload as? String,
           let data = jsonString.data(using: .utf8) {
            return try? JSONDecoder().decode(NetworkEventBatch.self, from: data)
        }
        if let dictionary = payload as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: dictionary) {
            return try? JSONDecoder().decode(NetworkEventBatch.self, from: data)
        }
        return nil
    }
}
