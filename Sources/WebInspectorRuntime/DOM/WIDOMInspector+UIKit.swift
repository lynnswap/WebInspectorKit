#if canImport(UIKit)
import Foundation
import GameController
import OSLog
import UIKit
import WebKit
import WebInspectorBridge
import WebInspectorEngine

private let domWindowActivationLogger = Logger(subsystem: "WebInspectorKit", category: "WIDOMWindowActivation")

@MainActor
private final class WIDOMUIKitSceneActivationWaitState {
    private var continuation: CheckedContinuation<Void, Error>?
    private var observer: (any NSObjectProtocol)?
    private var timeoutTask: Task<Void, Never>?
    private var didComplete = false

    func install(
        continuation: CheckedContinuation<Void, Error>,
        observer: any NSObjectProtocol,
        timeoutTask: Task<Void, Never>
    ) {
        self.continuation = continuation
        self.observer = observer
        self.timeoutTask = timeoutTask
    }

    func complete(_ result: Result<Void, Error>) {
        guard didComplete == false else {
            return
        }

        didComplete = true
        timeoutTask?.cancel()
        timeoutTask = nil

        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }

        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

@MainActor
private final class WIDOMUIKitSceneActivationRequestErrorState {
    private(set) var error: Error?

    func signal(_ error: Error) {
        self.error = error
    }
}

@MainActor
package protocol WIDOMUIKitSceneActivationTarget: AnyObject {
    var activationState: UIScene.ActivationState { get }
    var sceneSession: UISceneSession? { get }
}

extension UIWindowScene: WIDOMUIKitSceneActivationTarget {
    package var sceneSession: UISceneSession? {
        session
    }
}

@MainActor
package protocol WIDOMUIKitSceneActivationRequesting {
    func requestActivation(
        of target: any WIDOMUIKitSceneActivationTarget,
        requestingScene: UIScene?,
        errorHandler: ((any Error) -> Void)?
    )
}

extension UIApplication: WIDOMUIKitSceneActivationRequesting {
    package func requestActivation(
        of target: any WIDOMUIKitSceneActivationTarget,
        requestingScene: UIScene?,
        errorHandler: ((any Error) -> Void)?
    ) {
        guard let sceneSession = target.sceneSession else {
            return
        }

        let options = UIScene.ActivationRequestOptions()
        options.requestingScene = requestingScene

        requestSceneSessionActivation(
            sceneSession,
            userActivity: nil,
            options: options,
            errorHandler: errorHandler
        )
    }
}

@MainActor
package enum WIDOMUIKitInspectorSelectionEnvironment {
    package static var privateInspectorAccessProvider: @MainActor (WKWebView) -> Bool = {
        WIInspectorSelectionPrivateBridge.hasPrivateInspectorAccess(in: $0)
    }
    package static var inspectorConnectedProvider: @MainActor (WKWebView) -> Bool? = {
        WIInspectorSelectionPrivateBridge.isInspectorConnected(in: $0)
    }
    package static var inspectorConnector: @MainActor (WKWebView) -> Bool = {
        WIInspectorSelectionPrivateBridge.connectInspector(in: $0)
    }
    package static var elementSelectionToggler: @MainActor (WKWebView) -> Bool = {
        WIInspectorSelectionPrivateBridge.toggleElementSelection(in: $0)
    }
    package static var nodeSearchSetter: @MainActor (WKWebView, Bool) -> Bool = { webView, enabled in
        WIInspectorSelectionPrivateBridge.setNodeSearchEnabled(enabled, in: webView)
    }
    package static var recognizerPresenceProvider: @MainActor (WKWebView) -> Bool = {
        WIInspectorSelectionPrivateBridge.hasNodeSearchRecognizer(in: $0)
    }
    package static var recognizerRemover: @MainActor (WKWebView) -> Bool = {
        WIInspectorSelectionPrivateBridge.removeNodeSearchRecognizers(in: $0)
    }
    package static var selectionActiveProvider: @MainActor (WKWebView) -> Bool? = {
        WIInspectorSelectionPrivateBridge.isElementSelectionActive(in: $0)
    }
}

@MainActor
package enum WIDOMUIKitSceneActivationEnvironment {
    package static var requester: any WIDOMUIKitSceneActivationRequesting = UIApplication.shared
    package static var sceneProvider: @MainActor (UIWindow) -> (any WIDOMUIKitSceneActivationTarget)? = { $0.windowScene }
    package static var requestingSceneProvider: @MainActor (any WIDOMUIKitSceneActivationTarget) -> UIScene? = { _ in nil }
    package static var activationTimeout: Duration = .seconds(5)
    package static var activationWaiter: @MainActor (any WIDOMUIKitSceneActivationTarget, Duration) async throws -> Void = {
        target,
        timeout in
        try await waitForSceneActivation(target, timeout: timeout)
    }

    private static func waitForSceneActivation(
        _ target: any WIDOMUIKitSceneActivationTarget,
        timeout: Duration
    ) async throws {
        guard target.activationState != .foregroundActive else {
            return
        }

        let state = WIDOMUIKitSceneActivationWaitState()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { @MainActor in
                    do {
                        try await ContinuousClock().sleep(for: timeout)
                    } catch {
                        return
                    }

                    state.complete(
                        .failure(DOMOperationError.scriptFailure("Page scene activation timed out."))
                    )
                }
                let observer = NotificationCenter.default.addObserver(
                    forName: UIScene.didActivateNotification,
                    object: target,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        state.complete(.success(()))
                    }
                }

                state.install(
                    continuation: continuation,
                    observer: observer,
                    timeoutTask: timeoutTask
                )

                if target.activationState == .foregroundActive {
                    state.complete(.success(()))
                }
            }
        } onCancel: {
            Task { @MainActor in
                state.complete(.failure(CancellationError()))
            }
        }
    }
}

extension WIDOMInspector {
    func activatePageWindowForSelectionIfPossible() {
        guard let pageWindow = pageWebView?.window else {
            return
        }

        pageWindow.makeKey()
    }

    func requestPageWindowActivationIfNeeded() async throws {
        guard let pageWindow = pageWebView?.window else {
            return
        }
        guard let pageScene = WIDOMUIKitSceneActivationEnvironment.sceneProvider(pageWindow) else {
            return
        }
        guard pageScene.activationState != .foregroundActive else {
            return
        }

        let requestingScene = sceneActivationRequestingScene
            ?? WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider(pageScene)
        let requestErrorState = WIDOMUIKitSceneActivationRequestErrorState()
        let activationTask = Task { @MainActor in
            try await WIDOMUIKitSceneActivationEnvironment.activationWaiter(
                pageScene,
                WIDOMUIKitSceneActivationEnvironment.activationTimeout
            )
        }

        defer {
            activationTask.cancel()
        }

        WIDOMUIKitSceneActivationEnvironment.requester.requestActivation(
            of: pageScene,
            requestingScene: requestingScene
        ) { error in
            Task { @MainActor in
                domWindowActivationLogger.error("page scene activation failed: \(error.localizedDescription, privacy: .public)")
                requestErrorState.signal(error)
                activationTask.cancel()
            }
        }

        do {
            try await activationTask.value
        } catch is CancellationError {
            if let error = requestErrorState.error {
                throw DOMOperationError.scriptFailure(error.localizedDescription)
            }
            throw CancellationError()
        }
    }

    func awaitInspectModeInactive() async {
        guard let pageWebView else {
            return
        }

        let selectionActive = isNativeInspectorElementSelectionActive(on: pageWebView) ?? false
        let contentViewActive = hasActiveNativeInspectorNodeSearch(in: pageWebView)
        guard selectionActive || contentViewActive else {
            return
        }

        if selectionActive {
            _ = deactivateNativeInspectorElementSelectionIfNeeded(on: pageWebView)
        }
        _ = WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter(pageWebView, false)
        if hasActiveNativeInspectorNodeSearch(in: pageWebView) == false {
            return
        }

        removeLingeringNativeInspectorNodeSearchRecognizers(in: pageWebView)
        if hasActiveNativeInspectorNodeSearch(in: pageWebView) == false {
            return
        }

        domWindowActivationLogger.error("native inspector node search teardown did not settle")
    }

    private func removeLingeringNativeInspectorNodeSearchRecognizers(in webView: WKWebView) {
        _ = WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover(webView)
    }

    private func hasActiveNativeInspectorNodeSearch(in webView: WKWebView) -> Bool {
        WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider(webView)
    }

    private func nativeInspectorSelectionBackend(for webView: WKWebView) -> InspectModeControlBackend {
        if WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider(webView) {
            return .nativeInspector
        }
        return .transportProtocol
    }

    private func isNativeInspectorConnected(on webView: WKWebView) -> Bool? {
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider(webView)
    }

    private func isNativeInspectorElementSelectionActive(on webView: WKWebView) -> Bool? {
        WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider(webView)
    }

    private func connectNativeInspectorIfNeeded(on webView: WKWebView) -> Bool {
        if isNativeInspectorConnected(on: webView) == true {
            return true
        }
        let didRequestConnect = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector(webView)
        return isNativeInspectorConnected(on: webView) ?? didRequestConnect
    }

    private func activateNativeInspectorElementSelection(on webView: WKWebView) -> Bool {
        let selectionWasActive = isNativeInspectorElementSelectionActive(on: webView) == true
        let nodeSearchWasActive = hasActiveNativeInspectorNodeSearch(in: webView)
        if selectionWasActive || nodeSearchWasActive {
            if nodeSearchWasActive == false {
                _ = WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter(webView, true)
            }
            if isNativeInspectorConnected(on: webView) == false {
                _ = connectNativeInspectorIfNeeded(on: webView)
            }
            return isNativeInspectorElementSelectionActive(on: webView) == true
                || hasActiveNativeInspectorNodeSearch(in: webView)
        }

        let didEnableNodeSearch = WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter(webView, true)
        if isNativeInspectorConnected(on: webView) == false {
            _ = connectNativeInspectorIfNeeded(on: webView)
        }
        if hasActiveNativeInspectorNodeSearch(in: webView) {
            return true
        }

        let didToggleSelection = WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler(webView)
        if isNativeInspectorConnected(on: webView) == false {
            _ = connectNativeInspectorIfNeeded(on: webView)
        }
        return isNativeInspectorElementSelectionActive(on: webView) == true
            || hasActiveNativeInspectorNodeSearch(in: webView)
            || didEnableNodeSearch
            || didToggleSelection
    }

    private func deactivateNativeInspectorElementSelectionIfNeeded(on webView: WKWebView) -> Bool {
        guard isNativeInspectorElementSelectionActive(on: webView) == true else {
            return false
        }
        return WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler(webView)
    }

    func enableInspectorSelectionMode(
        hadSelectedNode: Bool,
        contextID: DOMContextID,
        targetIdentifier: String
    ) async throws -> InspectModeControlBackend {
        guard let pageWebView else {
            throw DOMOperationError.pageUnavailable
        }

        if hadSelectedNode {
            try? await hideHighlightForInspectorLifecycle()
        }

        do {
            logInspectorLifecycleDiagnostics(
                "beginSelectionMode using transport protocol backend",
                extra: "backend=\(InspectModeControlBackend.transportProtocol.rawValue) contextID=\(contextID) target=\(targetIdentifier) nativeState=\(nativeInspectorInteractionStateSummaryForDiagnostics() ?? "nil")"
            )
            try await setProtocolInspectModeEnabledForInspectorLifecycle(true, targetIdentifier: targetIdentifier)
            return .transportProtocol
        } catch {
            logInspectorLifecycleDiagnostics(
                "beginSelectionMode transport protocol failed; evaluating native fallback",
                extra: "contextID=\(contextID) target=\(targetIdentifier) error=\(error.localizedDescription) nativeState=\(nativeInspectorInteractionStateSummaryForDiagnostics() ?? "nil")",
                level: .error
            )

            guard nativeInspectorSelectionBackend(for: pageWebView) == .nativeInspector else {
                throw error
            }

            let didConnect = connectNativeInspectorIfNeeded(on: pageWebView)
            let didEnable = activateNativeInspectorElementSelection(on: pageWebView)
            logInspectorLifecycleDiagnostics(
                "beginSelectionMode using native inspector fallback backend",
                extra: "backend=\(InspectModeControlBackend.nativeInspector.rawValue) contextID=\(contextID) target=\(targetIdentifier) connected=\(didConnect) enabled=\(didEnable) nativeState=\(nativeInspectorInteractionStateSummaryForDiagnostics() ?? "nil")"
            )
            if didEnable {
                return .nativeInspector
            }

            logInspectorLifecycleDiagnostics(
                "beginSelectionMode native inspector fallback failed",
                extra: "contextID=\(contextID) target=\(targetIdentifier) nativeState=\(nativeInspectorInteractionStateSummaryForDiagnostics() ?? "nil")",
                level: .error
            )
            throw error
        }
    }

    func disableInspectorSelectionModeIfNeeded(
        targetIdentifier: String?,
        backend: InspectModeControlBackend? = nil
    ) async {
        guard let pageWebView else {
            return
        }

        switch backend ?? inspectModeControlBackend ?? nativeInspectorSelectionBackend(for: pageWebView) {
        case .nativeInspector:
            let didToggleOff = deactivateNativeInspectorElementSelectionIfNeeded(on: pageWebView)
            let didDisableNodeSearch = WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter(pageWebView, false)
            logInspectorLifecycleDiagnostics(
                "disableInspectorSelectionModeIfNeeded used native inspector backend",
                extra: "backend=\(InspectModeControlBackend.nativeInspector.rawValue) target=\(targetIdentifier ?? "nil") toggledOff=\(didToggleOff) disabledNodeSearch=\(didDisableNodeSearch) nativeState=\(nativeInspectorInteractionStateSummaryForDiagnostics() ?? "nil")"
            )
        case .transportProtocol:
            guard let targetIdentifier else {
                return
            }
            do {
                try await setProtocolInspectModeEnabledForInspectorLifecycle(false, targetIdentifier: targetIdentifier)
            } catch {
                logInspectorLifecycleDiagnostics(
                    "disableInspectorSelectionModeIfNeeded failed to disable inspect mode",
                    extra: error.localizedDescription,
                    level: .error
                )
            }
        }
    }

    func resetNativeInspectorSelectionStateForFreshContext(
        reason: String,
        contextID: DOMContextID
    ) async {
        let beforeState = nativeInspectorInteractionStateSummaryForDiagnostics()
        await awaitInspectModeInactive()
        let afterState = nativeInspectorInteractionStateSummaryForDiagnostics()
        if ProcessInfo.processInfo.environment["WEBSPECTOR_VERBOSE_CONSOLE_LOGS"] == "1" {
            domWindowActivationLogger.debug(
                "native inspector node search reset reason=\(reason, privacy: .public) contextID=\(contextID, privacy: .public) before=\(beforeState ?? "nil", privacy: .public) after=\(afterState ?? "nil", privacy: .public)"
            )
        }
    }

    func installPointerDisconnectObserverIfNeeded() {
        guard pointerDisconnectObserver == nil else {
            return
        }

        pointerDisconnectObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.GCMouseDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else {
                return
            }
            Task { @MainActor in
                await self.handlePointerDisconnectForInspectorHover()
            }
        }
    }

    func removePointerDisconnectObserver() {
        guard let pointerDisconnectObserver else {
            return
        }
        NotificationCenter.default.removeObserver(pointerDisconnectObserver)
        self.pointerDisconnectObserver = nil
    }

    private func handlePointerDisconnectForInspectorHover() async {
        await inspectorBridge.clearPointerHoverState()
        await restoreInspectorHighlightAfterPointerDisconnect()
    }

    func nativeInspectorInteractionStateSummaryForDiagnostics() -> String? {
        guard let pageWebView else {
            return nil
        }

        let hasPrivateInspectorAccess = WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider(pageWebView)
        let connected = isNativeInspectorConnected(on: pageWebView)
        let selectionActive = isNativeInspectorElementSelectionActive(on: pageWebView)
        let contentViewActive = hasActiveNativeInspectorNodeSearch(in: pageWebView)
        let nodeSearchSummary = WIInspectorSelectionPrivateBridge.nodeSearchDebugSummary(in: pageWebView)

        let accessValue = hasPrivateInspectorAccess ? "1" : "0"
        let connectedValue = connected.map { $0 ? "1" : "0" } ?? "n/a"
        let selectionValue = selectionActive.map { $0 ? "1" : "0" } ?? "n/a"
        let contentViewValue = contentViewActive ? "1" : "0"
        let nodeSearchValue = nodeSearchSummary ?? "n/a"
        return "privateInspectorAccess=\(accessValue) nativeInspectorConnected=\(connectedValue) nativeSelectionActive=\(selectionValue) contentViewActive=\(contentViewValue) nodeSearch=\(nodeSearchValue)"
    }
}
#endif
