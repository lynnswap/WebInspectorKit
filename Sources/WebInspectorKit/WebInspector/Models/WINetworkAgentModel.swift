//
//  WINetworkAgentModel.swift
//  WebInspectorKit
//
//  Created by Codex on 2025/02/26.
//

import SwiftUI
import OSLog
import WebKit
import Observation

private let networkLogger = Logger(subsystem: "WebInspectorKit", category: "WINetworkAgentModel")
private let networkPresenceProbeScript: String = """
(function() { /* webInspectorNetwork */ })();
"""

@MainActor
@Observable
final class WINetworkAgentModel: NSObject {
    private enum HandlerName: String, CaseIterable {
        case network = "webInspectorNetworkUpdate"
    }

    private(set) weak var webView: WKWebView?
    let store = WINetworkStore()

    @MainActor deinit {
        detachPageWebView()
    }

    func attachPageWebView(_ newWebView: WKWebView?) {
        guard self.webView !== newWebView else { return }
        guard let newWebView else {
            detachPageWebView()
            return
        }
        if let previousWebView = self.webView {
            detachMessageHandlers(from: previousWebView)
        }
        self.webView = newWebView
        registerMessageHandlers()
        Task {
            await self.configureNetworkLogging(
                enabled: self.store.isRecording,
                clearExisting: true,
                on: newWebView
            )
        }
    }

    func detachPageWebView(disableNetworkLogging: Bool = false) {
        guard let currentWebView = webView else { return }
        if disableNetworkLogging {
            Task {
                await self.configureNetworkLogging(
                    enabled: false,
                    clearExisting: false,
                    on: currentWebView
                )
            }
        }
        detachMessageHandlers(from: currentWebView)
        webView = nil
    }

    func setRecording(_ enabled: Bool) {
        store.setRecording(enabled)
        Task {
            await self.configureNetworkLogging(
                enabled: enabled,
                clearExisting: false,
                on: self.webView
            )
        }
    }

    func clearNetworkLogs() {
        store.clear()
        Task {
            await self.configureNetworkLogging(
                enabled: nil,
                clearExisting: true,
                on: self.webView
            )
        }
    }
}

extension WINetworkAgentModel: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else {
            return
        }
        guard let handlerName = HandlerName(rawValue: message.name) else { return }
        switch handlerName {
        case .network:
            handleNetworkMessage(message)
        }
    }

    private func handleNetworkMessage(_ message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let event = WINetworkEventPayload(dictionary: payload) else {
            return
        }
        store.applyEvent(event)
    }
}

private extension WINetworkAgentModel {
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
        enabled: Bool?,
        clearExisting: Bool,
        on targetWebView: WKWebView?
    ) async {
        guard let webView = targetWebView ?? self.webView else { return }
        let controller = webView.configuration.userContentController
        let networkInstalled = controller.userScripts.contains { $0.source == networkPresenceProbeScript }
        let shouldInstallNetworkAgent = (enabled == true) || (networkInstalled && (enabled != nil || clearExisting))

        if shouldInstallNetworkAgent {
            await installNetworkAgentScriptIfNeeded(on: webView)
        }

        let networkReady = webView.configuration.userContentController.userScripts.contains { $0.source == networkPresenceProbeScript }
        var script = ""
        if enabled != nil {
            script += "window.webInspectorNetwork.setLoggingEnabled(enabled);"
        }
        if clearExisting {
            script += "window.webInspectorNetwork.clearRecords();"
        }
        guard !script.isEmpty, networkReady else { return }

        do {
            try await webView.callAsyncVoidJavaScript(
                script,
                arguments: ["enabled": enabled as Any, "clearExisting": clearExisting],
                contentWorld: .page
            )
        } catch {
            networkLogger.error("configure network logging failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
