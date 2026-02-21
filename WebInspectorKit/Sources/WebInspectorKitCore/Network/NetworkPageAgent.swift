import Foundation
import OSLog
import ObjectiveC.runtime
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
private let networkPrivateUnavailableSentinel = "__wi_private_unavailable__"
private let networkControlTokenWindowKey = "__wiNetworkControlToken"
private let networkPageHookModeWindowKey = "__wiNetworkPageHookMode"
@MainActor private var networkBridgeScriptInstalledKey: UInt8 = 0
@MainActor private var networkTokenBootstrapSignatureKey: UInt8 = 0

@MainActor
private extension WKUserContentController {
    var wi_networkBridgeScriptInstalled: Bool {
        get {
            (objc_getAssociatedObject(self, &networkBridgeScriptInstalledKey) as? NSNumber)?.boolValue ?? false
        }
        set {
            objc_setAssociatedObject(
                self,
                &networkBridgeScriptInstalledKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    var wi_networkTokenBootstrapSignature: String? {
        get {
            objc_getAssociatedObject(self, &networkTokenBootstrapSignatureKey) as? String
        }
        set {
            objc_setAssociatedObject(
                self,
                &networkTokenBootstrapSignatureKey,
                newValue,
                .OBJC_ASSOCIATION_COPY_NONATOMIC
            )
        }
    }
}

@MainActor
public final class NetworkPageAgent: NSObject, PageAgent {
    private enum HandlerName: String, CaseIterable {
        case networkEvents = "webInspectorNetworkEvents"
        case networkReset = "webInspectorNetworkReset"
    }

    private enum AuthTokenValidationResult {
        case valid
        case missing
        case mismatched
    }

    weak var webView: WKWebView?
    let store = NetworkStore()
    private var loggingMode: NetworkLoggingMode = .buffering
    private var configureTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var nativeResourceObserver: NetworkResourceLoadObserver?
    private var nativeObserverEnabled = false
    private var nativeSessionID = ""
    private var networkMessageAuthToken = UUID().uuidString.lowercased()
    // Native observer is the primary source for non-XHR resources.
    // XHR/fetch remain page-hooked to preserve reliable body capture.
    private let nativeObserverIncludesFetchAndXHR = false

    private let runtime: WISPIRuntime
    private var bridgeMode: WIBridgeMode
    private var bridgeModeLocked = false

    package var currentBridgeMode: WIBridgeMode {
        bridgeMode
    }

    override init() {
        runtime = .shared
        bridgeMode = runtime.startupMode()
        super.init()
    }

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
        detachNativeResourceObserver(from: webView)
        detachMessageHandlers(from: webView)
    }

    func didAttachPageWebView(_ webView: WKWebView, previousWebView: WKWebView?) {
        resolveBridgeModeIfNeeded(with: webView)
        if previousWebView !== webView {
            store.reset()
        }
        attachNativeResourceObserver(to: webView)
        registerMessageHandlers()
        scheduleConfigure(mode: loggingMode, clearExisting: true, on: webView)
    }

    func didClearPageWebView() {
        nativeResourceObserver = nil
        nativeObserverEnabled = false
        nativeSessionID = ""
        store.reset()
    }

    func fetchBody(bodyRef: String?, bodyHandle: AnyObject?, role: NetworkBody.Role) async -> NetworkBody? {
        guard let webView else { return nil }

        if let bodyHandle {
            if let body = await fetchBodyFromHandle(bodyHandle, role: role, in: webView) {
                return body
            }
        }

        guard let bodyRef, !bodyRef.isEmpty else {
            return nil
        }
        return await fetchBodyFromReference(bodyRef, role: role, in: webView)
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
            handleNetworkReset(message)
        }
    }

    private func handleNetworkEventsMessage(_ message: WKScriptMessage) {
        switch validateMessageAuthToken(message.body) {
        case .valid:
            break
        case .missing:
            networkLogger.notice("network batch missing auth token, reconfiguring page token")
            scheduleConfigure(mode: loggingMode, clearExisting: false, on: webView)
            return
        case .mismatched:
            networkLogger.error("dropped network batch: auth token mismatch")
            return
        }
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

    private func handleNetworkReset(_ message: WKScriptMessage) {
        switch validateMessageAuthToken(message.body) {
        case .valid:
            break
        case .missing:
            networkLogger.notice("network reset missing auth token, reconfiguring page token")
            scheduleConfigure(mode: loggingMode, clearExisting: false, on: webView)
            return
        case .mismatched:
            networkLogger.error("dropped network reset: auth token mismatch")
            return
        }
        store.reset()
    }
}

private extension NetworkPageAgent {
    func resolveBridgeModeIfNeeded(with webView: WKWebView) {
        guard !bridgeModeLocked else {
            return
        }
        bridgeMode = runtime.modeForAttachment(webView: webView)
        bridgeModeLocked = true
        networkLogger.notice("bridge_mode=\(self.bridgeMode.rawValue, privacy: .public)")
    }

    func lockToLegacyMode(_ reason: String) {
        guard bridgeMode != .legacyJSON else {
            return
        }
        bridgeMode = .legacyJSON
        bridgeModeLocked = true
        networkLogger.error("bridge_mode=legacyJSON \(reason, privacy: .public)")
    }

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
        let escapedToken = networkMessageAuthToken
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let pageHookMode = resolvedPageHookMode()
        let tokenBootstrapSignature = "\(networkMessageAuthToken)|\(pageHookMode)"
        let tokenBootstrapScript = """
        (function(token, pageHookMode) {
            Object.defineProperty(window, "\(networkControlTokenWindowKey)", {
                value: token,
                configurable: true,
                writable: false,
                enumerable: false
            });
            Object.defineProperty(window, "\(networkPageHookModeWindowKey)", {
                value: pageHookMode,
                configurable: true,
                writable: false,
                enumerable: false
            });
            if (typeof window.__wiBootstrapNetworkAuthToken === "function") {
                window.__wiBootstrapNetworkAuthToken(token);
            }
            if (
                window.webInspectorNetworkAgent &&
                typeof window.webInspectorNetworkAgent.bootstrapAuthToken === "function"
            ) {
                window.webInspectorNetworkAgent.bootstrapAuthToken(token);
            }
        })("\(escapedToken)", "\(pageHookMode)");
        """
        let tokenScript = WKUserScript(
            source: tokenBootstrapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )

        if controller.wi_networkBridgeScriptInstalled {
            // Avoid repeatedly appending the same bootstrap script on reconfigure/reattach.
            if controller.wi_networkTokenBootstrapSignature != tokenBootstrapSignature {
                controller.addUserScript(tokenScript)
                controller.wi_networkTokenBootstrapSignature = tokenBootstrapSignature
            }
            do {
                _ = try await webView.evaluateJavaScript(tokenBootstrapScript, in: nil, contentWorld: .page)
            } catch {
                networkLogger.error("failed to refresh network control token: \(error.localizedDescription, privacy: .public)")
            }
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
            forMainFrameOnly: true,
            in: .page
        )
        let checkScript = WKUserScript(
            source: networkPresenceProbeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
        controller.addUserScript(tokenScript)
        controller.wi_networkTokenBootstrapSignature = tokenBootstrapSignature
        controller.addUserScript(userScript)
        controller.addUserScript(checkScript)
        controller.wi_networkBridgeScriptInstalled = true

        do {
            _ = try await webView.evaluateJavaScript(tokenBootstrapScript, in: nil, contentWorld: .page)
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
        let networkInstalled = controller.wi_networkBridgeScriptInstalled
        let modeRequiresAgent = mode != .stopped
        let shouldInstallNetworkAgent = modeRequiresAgent || (networkInstalled && clearExisting)

        if shouldInstallNetworkAgent {
            await installNetworkAgentScriptIfNeeded(on: webView)
        }

        let networkReady = webView.configuration.userContentController.wi_networkBridgeScriptInstalled
        let nativeObserverShouldOwnResources = nativeObserverEnabled && mode == .active
        let resourceObserverMode = nativeObserverShouldOwnResources ? "disabled" : "enabled"
        let pageHookMode = resolvedPageHookMode()
        networkLogger.notice(
            "network_page_hook mode=\(pageHookMode, privacy: .public) resource_observer=\(resourceObserverMode, privacy: .public) native_enabled=\(self.nativeObserverEnabled, privacy: .public) native_session=\(self.nativeSessionID, privacy: .public)"
        )

        let script = """
        (function(mode, clearExisting, resourceObserverMode, pageHookMode, messageAuthToken) {
            if (!window.webInspectorNetworkAgent || typeof window.webInspectorNetworkAgent.configure !== "function") {
                return;
            }
            window.webInspectorNetworkAgent.configure({
                mode: mode,
                clear: clearExisting,
                controlAuthToken: messageAuthToken,
                resourceObserverMode: resourceObserverMode,
                pageHookMode: pageHookMode,
                messageAuthToken: messageAuthToken
            });
        })(mode, clearExisting, resourceObserverMode, pageHookMode, messageAuthToken);
        """
        guard networkReady else { return }

        do {
            try await webView.callAsyncVoidJavaScript(
                script,
                arguments: [
                    "clearExisting": clearExisting,
                    "mode": mode.rawValue,
                    "messageAuthToken": networkMessageAuthToken,
                    "pageHookMode": pageHookMode,
                    "resourceObserverMode": resourceObserverMode,
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
                "window.webInspectorNetworkAgent.clear(options);",
                arguments: [
                    "options": [
                        "controlAuthToken": networkMessageAuthToken
                    ]
                ],
                contentWorld: .page
            )
        } catch {
            networkLogger.error("clear network records failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func decodeNetworkBatch(from payload: Any?) -> NetworkEventBatch? {
        NetworkEventBatch.decode(from: payload)
    }

    private func validateMessageAuthToken(_ payload: Any?) -> AuthTokenValidationResult {
        guard let dictionary = payload as? NSDictionary else {
            return .mismatched
        }
        guard let receivedToken = dictionary["authToken"] as? String else {
            return .missing
        }
        if receivedToken.isEmpty {
            return .missing
        }
        if receivedToken == networkMessageAuthToken {
            return .valid
        }
        return .mismatched
    }

    func fetchBodyFromHandle(_ handle: AnyObject, role: NetworkBody.Role, in webView: WKWebView) async -> NetworkBody? {
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                return (function(handle, unavailable) {
                    if (!window.webInspectorNetworkAgent || typeof window.webInspectorNetworkAgent.getBodyForHandle !== "function") {
                        return unavailable;
                    }
                    return window.webInspectorNetworkAgent.getBodyForHandle(handle, options);
                })(handle, unavailable);
                """,
                arguments: [
                    "handle": handle,
                    "options": [
                        "controlAuthToken": networkMessageAuthToken
                    ],
                    "unavailable": networkPrivateUnavailableSentinel,
                ],
                in: nil,
                contentWorld: .page
            )

            if let sentinel = result as? String, sentinel == networkPrivateUnavailableSentinel {
                lockToLegacyMode("selector_missing=getBodyForHandle")
                return nil
            }

            return decodeNetworkBody(from: result, role: role)
        } catch {
            lockToLegacyMode("runtime_probe_failed=getBodyForHandle")
            networkLogger.error("getBodyForHandle failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func fetchBodyFromReference(_ bodyRef: String, role: NetworkBody.Role, in webView: WKWebView) async -> NetworkBody? {
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                return (function(ref) {
                    if (!window.webInspectorNetworkAgent || typeof window.webInspectorNetworkAgent.getBody !== "function") {
                        return null;
                    }
                    return window.webInspectorNetworkAgent.getBody(ref, options);
                })(ref);
                """,
                arguments: [
                    "options": [
                        "controlAuthToken": networkMessageAuthToken
                    ],
                    "ref": bodyRef
                ],
                in: nil,
                contentWorld: .page
            )
            return decodeNetworkBody(from: result, role: role)
        } catch {
            networkLogger.error("getBody failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func decodeNetworkBody(from payload: Any?, role: NetworkBody.Role) -> NetworkBody? {
        guard let payload else {
            return nil
        }

        let resolved = unwrapOptionalPayload(payload)
        if let bodyPayload = resolved as? NetworkBodyPayload {
            return NetworkBody.from(payload: bodyPayload, role: role)
        }

        if let dictionary = resolved as? NSDictionary {
            let bodyPayload = NetworkBodyPayload(dictionary: dictionary)
            return NetworkBody.from(payload: bodyPayload, role: role)
        }

        if let jsonString = resolved as? String,
           let data = jsonString.data(using: .utf8),
           let bodyPayload = try? JSONDecoder().decode(NetworkBodyPayload.self, from: data) {
            return NetworkBody.from(payload: bodyPayload, role: role)
        }

        if let inlineString = resolved as? String {
            return NetworkBody(
                kind: .text,
                preview: inlineString,
                full: inlineString,
                size: inlineString.count,
                isBase64Encoded: false,
                isTruncated: false,
                role: role
            )
        }

        return nil
    }

    func unwrapOptionalPayload(_ value: Any?) -> Any {
        guard let value else {
            return NSNull()
        }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else {
            return value
        }
        guard let child = mirror.children.first else {
            return NSNull()
        }
        return unwrapOptionalPayload(child.value)
    }

    func attachNativeResourceObserver(to webView: WKWebView) {
        let sessionID = "native-\(UUID().uuidString.lowercased())"
        let observer = NetworkResourceLoadObserver(
            sessionID: sessionID,
            includeFetchAndXHR: nativeObserverIncludesFetchAndXHR,
            isEventEmissionEnabled: { [weak self] in
                guard let self else {
                    return false
                }
                return self.loggingMode == .active
            }
        ) { [weak self] event in
            self?.store.applyEvent(event)
        }
        let attached = observer.attach(to: webView)
        nativeObserverEnabled = attached
        nativeSessionID = sessionID

        if attached {
            nativeResourceObserver = observer
            networkLogger.notice(
                "native_resource_observer attached session=\(sessionID, privacy: .public) include_fetch_xhr=\(self.nativeObserverIncludesFetchAndXHR, privacy: .public)"
            )
        } else {
            nativeResourceObserver = nil
            networkLogger.notice("native_resource_observer unavailable, fallback=js_only")
        }
    }

    func resolvedPageHookMode() -> String {
        // Keep page hook enabled so XHR/fetch body handles/refs are always captured.
        return "enabled"
    }

    func detachNativeResourceObserver(from webView: WKWebView) {
        nativeResourceObserver?.detach(from: webView)
        nativeResourceObserver = nil
        nativeObserverEnabled = false
        nativeSessionID = ""
        networkLogger.debug("native_resource_observer detached")
    }
}
