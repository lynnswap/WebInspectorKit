import Foundation
import OSLog
import WebKit
import WebInspectorScripts
import WebInspectorBridge

public enum NetworkLoggingMode: String, Sendable {
    case active
    case buffering
    case stopped
}

private let networkLogger = Logger(subsystem: "WebInspectorKit", category: "NetworkPageAgent")
private let networkPresenceProbeScript: String = """
(function() { /* webInspectorNetworkAgent */ })();
"""
private let networkBodyFetchSentinelKey = "__wiBodyFetchState"
private let networkAgentUnavailableSentinelValue = "agentUnavailable"
private let networkBodyUnavailableSentinelValue = "bodyUnavailable"
private let networkControlTokenWindowKey = "__wiNetworkControlToken"
private let networkPageHookModeWindowKey = "__wiNetworkPageHookMode"

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

    private struct BodyFetchAvailability {
        let hasGetBody: Bool
        let hasGetBodyForHandle: Bool

        func satisfies(requiresReferenceAPI: Bool, requiresHandleAPI: Bool) -> Bool {
            (!requiresReferenceAPI || hasGetBody) && (!requiresHandleAPI || hasGetBodyForHandle)
        }
    }

    package weak var webView: WKWebView?
    package let store = NetworkStore()
    private var loggingMode: NetworkLoggingMode = .buffering
    private var nativeResourceObserver: NetworkResourceLoadObserver?
    private var nativeObserverEnabled = false
    private var nativeSessionID = ""
    private var networkMessageAuthToken = UUID().uuidString.lowercased()
    private var preservesStoreAcrossNextAttach = false
    // Native observer is the primary source for non-XHR resources.
    // XHR/fetch remain page-hooked to preserve reliable body capture.
    private let nativeObserverIncludesFetchAndXHR = false

    private let runtime: WISPIRuntime
    private let controllerStateRegistry: WIUserContentControllerStateRegistry
    private var bridgeMode: WIBridgeMode
    private var bridgeModeLocked = false
    private var pendingConfigurationTask: Task<Void, Never>?
    private var pendingConfigurationGeneration: UInt64 = 0

    package var currentBridgeMode: WIBridgeMode {
        bridgeMode
    }

    package init(controllerStateRegistry: WIUserContentControllerStateRegistry = .shared) {
        runtime = .shared
        self.controllerStateRegistry = controllerStateRegistry
        bridgeMode = runtime.startupMode()
        super.init()
    }

    isolated deinit {
        cancelPendingConfigurationTask()
        detachPageWebView()
    }

    package func setMode(_ mode: NetworkLoggingMode) async {
        cancelPendingConfigurationTask()
        loggingMode = mode
        store.setRecording(mode != .stopped)
        if mode == .stopped {
            preservesStoreAcrossNextAttach = false
            store.reset()
        }
        await configureNetworkLogging(mode: mode, clearExisting: false, on: webView)
    }

    func waitForPendingConfigurationForTesting() async {
        await pendingConfigurationTask?.value
    }

    package func clearNetworkLogs() async {
        store.clear()
        await clearRemoteNetworkRecords(on: webView)
    }

    package func tearDownForDeinit() {
        cancelPendingConfigurationTask()
        preservesStoreAcrossNextAttach = false
        loggingMode = .stopped
        store.setRecording(false)
        detachPageWebView()
        store.reset()
    }
}

// MARK: - WIPageAgent

extension NetworkPageAgent {
    package func attachPageWebView(_ newWebView: WKWebView?) async {
        cancelPendingConfigurationTask()
        let shouldClearExisting = preservesStoreAcrossNextAttach == false
        replacePageWebView(with: newWebView)
        guard let newWebView else {
            return
        }
        await configureNetworkLogging(mode: loggingMode, clearExisting: shouldClearExisting, on: newWebView)
    }

    package func detachPageWebView(preparing modeBeforeDetach: NetworkLoggingMode? = nil) async {
        cancelPendingConfigurationTask()
        if let modeBeforeDetach {
            loggingMode = modeBeforeDetach
            store.setRecording(modeBeforeDetach != .stopped)
            preservesStoreAcrossNextAttach = modeBeforeDetach != .stopped
            if modeBeforeDetach == .stopped {
                store.reset()
            }
        } else {
            preservesStoreAcrossNextAttach = false
        }
        replacePageWebView(with: nil)
    }

    func willDetachPageWebView(_ webView: WKWebView) {
        detachNativeResourceObserver(from: webView)
        detachMessageHandlers(from: webView)
    }

    func didAttachPageWebView(_ webView: WKWebView, previousWebView: WKWebView?) {
        resolveBridgeModeIfNeeded(with: webView)
        let preservesExistingStore = preservesStoreAcrossNextAttach
        preservesStoreAcrossNextAttach = false
        if previousWebView !== webView && preservesExistingStore == false {
            store.reset()
        }
        attachNativeResourceObserver(to: webView)
        registerMessageHandlers()
    }

    func didClearPageWebView() {
        nativeResourceObserver = nil
        nativeObserverEnabled = false
        nativeSessionID = ""
        if preservesStoreAcrossNextAttach == false {
            store.reset()
        }
    }

    func fetchBody(bodyRef: String?, bodyHandle: AnyObject?, role: NetworkBody.Role) async -> NetworkBody? {
        switch await fetchBodyResult(bodyRef: bodyRef, bodyHandle: bodyHandle, role: role) {
        case .fetched(let body):
            return body
        case .agentUnavailable, .bodyUnavailable:
            return nil
        }
    }

    func fetchBodyResult(
        bodyRef: String?,
        bodyHandle: AnyObject?,
        role: NetworkBody.Role
    ) async -> NetworkBodyFetchResult {
        await runFetchBodyResult(
            bodyRef: bodyRef,
            bodyHandle: bodyHandle,
            role: role
        )
    }
}

extension NetworkPageAgent: NetworkBodyFetching {
    package func supportsDeferredLoading(for role: NetworkBody.Role) -> Bool {
        switch role {
        case .request, .response:
            true
        }
    }

    package func fetchBodyResult(
        locator: NetworkDeferredBodyLocator,
        role: NetworkBody.Role
    ) async -> NetworkBodyFetchResult {
        switch locator {
        case .networkRequest(let requestID, _):
            return await fetchBodyResult(bodyRef: requestID, bodyHandle: nil, role: role)
        case .pageResource:
            return .bodyUnavailable
        case .opaqueHandle(let handle):
            return await fetchBodyResult(bodyRef: nil, bodyHandle: handle, role: role)
        }
    }
}

extension NetworkPageAgent: WINetworkBackend {
    package var support: WIBackendSupport {
        WIBackendSupport(
            availability: .supported,
            backendKind: .unsupported,
            failureReason: "Using page-hook network backend."
        )
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
            startPendingConfiguration(on: webView)
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
            startPendingConfiguration(on: webView)
            return
        case .mismatched:
            networkLogger.error("dropped network reset: auth token mismatch")
            return
        }
        store.reset()
    }
}

private extension NetworkPageAgent {
    func runFetchBodyResult(
        bodyRef: String?,
        bodyHandle: AnyObject?,
        role: NetworkBody.Role
    ) async -> NetworkBodyFetchResult {
        guard let webView else {
            return .agentUnavailable
        }
        let currentConfigurationTask = pendingConfigurationTask
        await currentConfigurationTask?.value
        guard self.webView === webView else {
            return .agentUnavailable
        }

        let hasReference = bodyRef?.isEmpty == false
        let hasHandle = bodyHandle != nil
        let requiresHandleAPI = hasHandle && (hasReference == false || bridgeMode != .legacyJSON)
        guard hasReference || hasHandle else {
            return .bodyUnavailable
        }

        let availability = await ensureBodyFetchAvailability(
            in: webView,
            requiresReferenceAPI: hasReference,
            requiresHandleAPI: requiresHandleAPI
        )
        let initialResult = await performBodyFetch(
            bodyRef: bodyRef,
            bodyHandle: bodyHandle,
            role: role,
            in: webView,
            availability: availability
        )
        guard case .agentUnavailable = initialResult else {
            return initialResult
        }

        let recoveredAvailability = await ensureBodyFetchAvailability(
            in: webView,
            requiresReferenceAPI: hasReference,
            requiresHandleAPI: requiresHandleAPI
        )
        return await performBodyFetch(
            bodyRef: bodyRef,
            bodyHandle: bodyHandle,
            role: role,
            in: webView,
            availability: recoveredAvailability
        )
    }

    func startPendingConfiguration(on webView: WKWebView?) {
        cancelPendingConfigurationTask()
        let loggingMode = loggingMode
        pendingConfigurationGeneration &+= 1
        let generation = pendingConfigurationGeneration
        pendingConfigurationTask = Task.immediateIfAvailable { [weak self, weak webView] in
            guard let self else {
                return
            }
            defer {
                if self.pendingConfigurationGeneration == generation {
                    self.pendingConfigurationTask = nil
                }
            }
            await self.configureNetworkLogging(mode: loggingMode, clearExisting: false, on: webView)
        }
    }

    func cancelPendingConfigurationTask() {
        pendingConfigurationGeneration &+= 1
        pendingConfigurationTask?.cancel()
        pendingConfigurationTask = nil
    }

    private func performBodyFetch(
        bodyRef: String?,
        bodyHandle: AnyObject?,
        role: NetworkBody.Role,
        in webView: WKWebView,
        availability: BodyFetchAvailability
    ) async -> NetworkBodyFetchResult {
        let hasReference = bodyRef?.isEmpty == false

        if let bodyHandle {
            if availability.hasGetBodyForHandle {
                switch await fetchBodyFromHandle(bodyHandle, role: role, in: webView) {
                case .fetched(let body):
                    return .fetched(body)
                case .agentUnavailable:
                    if hasReference == false {
                        return .agentUnavailable
                    }
                case .bodyUnavailable:
                    if hasReference == false {
                        return .bodyUnavailable
                    }
                }
            } else {
                lockToLegacyMode("selector_missing=getBodyForHandle")
                if hasReference == false {
                    return .agentUnavailable
                }
            }
        }

        if let bodyRef, !bodyRef.isEmpty {
            guard availability.hasGetBody else {
                return .agentUnavailable
            }
            return await fetchBodyFromReference(bodyRef, role: role, in: webView)
        }

        return .bodyUnavailable
    }

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

    func installNetworkAgentScriptIfNeeded(
        on webView: WKWebView,
        forceCurrentPageAgentInjection: Bool = false
    ) async {
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
        let scriptWasInstalled = controllerStateRegistry.networkBridgeScriptInstalled(on: controller)
        let shouldEvaluateAgentScript = forceCurrentPageAgentInjection || !scriptWasInstalled
        let scriptSource = shouldEvaluateAgentScript ? loadNetworkAgentScriptSource() : nil

        if scriptWasInstalled {
            // Avoid repeatedly appending the same bootstrap script on reconfigure/reattach.
            if controllerStateRegistry.networkTokenBootstrapSignature(on: controller) != tokenBootstrapSignature {
                controller.addUserScript(tokenScript)
                controllerStateRegistry.setNetworkTokenBootstrapSignature(tokenBootstrapSignature, on: controller)
            }
            if forceCurrentPageAgentInjection,
               let scriptSource,
               controller.userScripts.contains(where: { $0.source == scriptSource }) == false {
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
                controller.addUserScript(userScript)
                controller.addUserScript(checkScript)
            }
            do {
                _ = try await webView.evaluateJavaScript(tokenBootstrapScript, in: nil, contentWorld: .page)
                if let scriptSource {
                    _ = try await webView.evaluateJavaScript(scriptSource, in: nil, contentWorld: .page)
                }
            } catch {
                networkLogger.error("failed to refresh network agent bootstrap: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        guard let scriptSource else {
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
        controllerStateRegistry.setNetworkTokenBootstrapSignature(tokenBootstrapSignature, on: controller)
        controller.addUserScript(userScript)
        controller.addUserScript(checkScript)
        controllerStateRegistry.setNetworkBridgeScriptInstalled(true, on: controller)

        do {
            _ = try await webView.evaluateJavaScript(tokenBootstrapScript, in: nil, contentWorld: .page)
            _ = try await webView.evaluateJavaScript(scriptSource, in: nil, contentWorld: .page)
        } catch {
            networkLogger.error("failed to install network agent: \(error.localizedDescription, privacy: .public)")
        }
        networkLogger.debug("installed network agent user script")
    }

    func loadNetworkAgentScriptSource() -> String? {
        do {
            return try WebInspectorScripts.networkAgent()
        } catch {
            networkLogger.error("failed to prepare network inspector script: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func ensureBodyFetchAvailability(
        in webView: WKWebView,
        requiresReferenceAPI: Bool,
        requiresHandleAPI: Bool
    ) async -> BodyFetchAvailability {
        let initialAvailability = await probeBodyFetchAvailability(in: webView)
        guard initialAvailability.satisfies(
            requiresReferenceAPI: requiresReferenceAPI,
            requiresHandleAPI: requiresHandleAPI
        ) == false else {
            return initialAvailability
        }

        return await repairBodyFetchAvailability(
            in: webView,
            requiresReferenceAPI: requiresReferenceAPI,
            requiresHandleAPI: requiresHandleAPI
        )
    }

    private func repairBodyFetchAvailability(
        in webView: WKWebView,
        requiresReferenceAPI: Bool,
        requiresHandleAPI: Bool
    ) async -> BodyFetchAvailability {
        networkLogger.notice("network body api unavailable, reinstalling page agent")
        await installNetworkAgentScriptIfNeeded(on: webView, forceCurrentPageAgentInjection: true)
        await configureNetworkLogging(mode: loggingMode, clearExisting: false, on: webView)
        return await probeBodyFetchAvailability(in: webView)
    }

    private func fetchSentinelState(from result: Any?) -> String? {
        guard let payload = result as? NSDictionary else {
            return nil
        }
        return payload[networkBodyFetchSentinelKey] as? String
    }

    private func probeBodyFetchAvailability(in webView: WKWebView) async -> BodyFetchAvailability {
        do {
            let raw = try await webView.evaluateJavaScript(
                """
                (() => ({
                    hasGetBody: Boolean(
                        window.webInspectorNetworkAgent &&
                        typeof window.webInspectorNetworkAgent.getBody === "function"
                    ),
                    hasGetBodyForHandle: Boolean(
                        window.webInspectorNetworkAgent &&
                        typeof window.webInspectorNetworkAgent.getBodyForHandle === "function"
                    )
                }))();
                """,
                in: nil,
                contentWorld: .page
            )
            let payload = raw as? NSDictionary
            let hasGetBody = (payload?["hasGetBody"] as? Bool) ?? ((payload?["hasGetBody"] as? NSNumber)?.boolValue ?? false)
            let hasGetBodyForHandle = (payload?["hasGetBodyForHandle"] as? Bool)
                ?? ((payload?["hasGetBodyForHandle"] as? NSNumber)?.boolValue ?? false)
            return BodyFetchAvailability(
                hasGetBody: hasGetBody,
                hasGetBodyForHandle: hasGetBodyForHandle
            )
        } catch {
            networkLogger.error("failed to probe network body api: \(error.localizedDescription, privacy: .public)")
            return BodyFetchAvailability(hasGetBody: false, hasGetBodyForHandle: false)
        }
    }

    func configureNetworkLogging(
        mode: NetworkLoggingMode,
        clearExisting: Bool,
        on targetWebView: WKWebView?
    ) async {
        guard let webView = targetWebView ?? self.webView else { return }
        let controller = webView.configuration.userContentController
        let networkInstalled = controllerStateRegistry.networkBridgeScriptInstalled(on: controller)
        let modeRequiresAgent = mode != .stopped
        let shouldInstallNetworkAgent = modeRequiresAgent || (networkInstalled && clearExisting)

        if shouldInstallNetworkAgent {
            await installNetworkAgentScriptIfNeeded(on: webView)
        }

        let networkReady = controllerStateRegistry.networkBridgeScriptInstalled(on: controller)
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

    func decodeNetworkBatch(from payload: Any?) -> NetworkWire.PageHook.Batch? {
        NetworkWire.PageHook.Batch.decode(from: payload)
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

    func fetchBodyFromHandle(
        _ handle: AnyObject,
        role: NetworkBody.Role,
        in webView: WKWebView
    ) async -> NetworkBodyFetchResult {
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                return (function(handle, agentUnavailable, bodyUnavailable) {
                    if (!window.webInspectorNetworkAgent || typeof window.webInspectorNetworkAgent.getBodyForHandle !== "function") {
                        return agentUnavailable;
                    }
                    const body = window.webInspectorNetworkAgent.getBodyForHandle(handle, options);
                    return body == null ? bodyUnavailable : body;
                })(handle, agentUnavailable, bodyUnavailable);
                """,
                arguments: [
                    "handle": handle,
                    "options": [
                        "controlAuthToken": networkMessageAuthToken
                    ],
                    "agentUnavailable": [
                        networkBodyFetchSentinelKey: networkAgentUnavailableSentinelValue
                    ],
                    "bodyUnavailable": [
                        networkBodyFetchSentinelKey: networkBodyUnavailableSentinelValue
                    ],
                ],
                in: nil,
                contentWorld: .page
            )

            if let sentinelState = fetchSentinelState(from: result) {
                switch sentinelState {
                case networkAgentUnavailableSentinelValue:
                    lockToLegacyMode("selector_missing=getBodyForHandle")
                    return .agentUnavailable
                case networkBodyUnavailableSentinelValue:
                    return .bodyUnavailable
                default:
                    break
                }
            }

            guard let body = decodeNetworkBody(from: result, role: role) else {
                return .bodyUnavailable
            }
            return .fetched(body)
        } catch {
            lockToLegacyMode("runtime_probe_failed=getBodyForHandle")
            networkLogger.error("getBodyForHandle failed: \(error.localizedDescription, privacy: .public)")
            return .agentUnavailable
        }
    }

    func fetchBodyFromReference(
        _ bodyRef: String,
        role: NetworkBody.Role,
        in webView: WKWebView
    ) async -> NetworkBodyFetchResult {
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                return (function(ref, agentUnavailable, bodyUnavailable) {
                    if (!window.webInspectorNetworkAgent || typeof window.webInspectorNetworkAgent.getBody !== "function") {
                        return agentUnavailable;
                    }
                    const body = window.webInspectorNetworkAgent.getBody(ref, options);
                    return body == null ? bodyUnavailable : body;
                })(ref, agentUnavailable, bodyUnavailable);
                """,
                arguments: [
                    "agentUnavailable": [
                        networkBodyFetchSentinelKey: networkAgentUnavailableSentinelValue
                    ],
                    "bodyUnavailable": [
                        networkBodyFetchSentinelKey: networkBodyUnavailableSentinelValue
                    ],
                    "options": [
                        "controlAuthToken": networkMessageAuthToken
                    ],
                    "ref": bodyRef
                ],
                in: nil,
                contentWorld: .page
            )
            if let sentinelState = fetchSentinelState(from: result) {
                switch sentinelState {
                case networkAgentUnavailableSentinelValue:
                    return .agentUnavailable
                case networkBodyUnavailableSentinelValue:
                    return .bodyUnavailable
                default:
                    break
                }
            }
            guard let body = decodeNetworkBody(from: result, role: role) else {
                return .bodyUnavailable
            }
            return .fetched(body)
        } catch {
            networkLogger.error("getBody failed: \(error.localizedDescription, privacy: .public)")
            return .agentUnavailable
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
            store: store,
            includeFetchAndXHR: nativeObserverIncludesFetchAndXHR,
            isEventEmissionEnabled: { [weak self] in
                guard let self else {
                    return false
                }
                return self.loggingMode == .active
            }
        )
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
