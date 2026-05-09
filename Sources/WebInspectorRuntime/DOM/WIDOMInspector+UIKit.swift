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
    package static var pageEditingDismissalHandler: @MainActor (WKWebView) -> Void = {
        $0.endEditing(true)
    }
    package static var transportInspectActivationProvider: @MainActor (WKWebView) -> Bool = { _ in true }
    package static var transportInspectActivationTimeoutNanoseconds: UInt64 = 50_000_000
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

    package static func waitForSceneActivation(
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
        let sceneActivation = dependencies.platform.uiKitSceneActivation
        try await sceneActivation.activateWindowSceneIfNeeded(
            pageWindow,
            sceneActivationRequestingScene,
            sceneActivation.activationTimeout
        )
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
        _ = dependencies.webKitSPI.setNodeSearchEnabled(pageWebView, false)
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
        _ = dependencies.webKitSPI.removeNodeSearchRecognizers(webView)
    }

    private func hasActiveNativeInspectorNodeSearch(in webView: WKWebView) -> Bool {
        dependencies.webKitSPI.hasNodeSearchRecognizer(webView)
    }

    private func nativeInspectorSelectionBackend(for webView: WKWebView) -> InspectModeControlBackend {
        if dependencies.webKitSPI.hasPrivateInspectorAccess(webView) {
            return .nativeInspector
        }
        return .transportProtocol
    }

    private func isNativeInspectorConnected(on webView: WKWebView) -> Bool? {
        dependencies.webKitSPI.isInspectorConnected(webView)
    }

    private func isNativeInspectorElementSelectionActive(on webView: WKWebView) -> Bool? {
        dependencies.webKitSPI.isElementSelectionActive(webView)
    }

    private func connectNativeInspectorIfNeeded(on webView: WKWebView) -> Bool {
        if isNativeInspectorConnected(on: webView) == true {
            return true
        }
        let didRequestConnect = dependencies.webKitSPI.connectInspector(webView)
        return isNativeInspectorConnected(on: webView) ?? didRequestConnect
    }

    private func activateNativeInspectorElementSelection(on webView: WKWebView) -> Bool {
        nativeInspectorSelectionToggleNeedsDeactivation = false
        nativeInspectorNodeSearchNeedsDirectDeactivation = false
        let selectionWasActive = isNativeInspectorElementSelectionActive(on: webView) == true
        let nodeSearchWasActive = hasActiveNativeInspectorNodeSearch(in: webView)
        if selectionWasActive || nodeSearchWasActive {
            if nodeSearchWasActive {
                _ = dependencies.webKitSPI.setNodeSearchEnabled(webView, true)
            } else {
                let didEnableNodeSearch = dependencies.webKitSPI.setNodeSearchEnabled(webView, true)
                nativeInspectorNodeSearchNeedsDirectDeactivation = didEnableNodeSearch
            }
            if isNativeInspectorConnected(on: webView) == false {
                _ = connectNativeInspectorIfNeeded(on: webView)
            }
            return isNativeInspectorElementSelectionActive(on: webView) == true
                || hasActiveNativeInspectorNodeSearch(in: webView)
        }

        let didEnableNodeSearch = dependencies.webKitSPI.setNodeSearchEnabled(webView, true)
        nativeInspectorNodeSearchNeedsDirectDeactivation = didEnableNodeSearch
        if isNativeInspectorConnected(on: webView) == false {
            _ = connectNativeInspectorIfNeeded(on: webView)
        }
        if hasActiveNativeInspectorNodeSearch(in: webView) {
            return true
        }

        let didToggleSelection = dependencies.webKitSPI.toggleElementSelection(webView)
        if isNativeInspectorConnected(on: webView) == false {
            _ = connectNativeInspectorIfNeeded(on: webView)
        }
        let selectionActive = isNativeInspectorElementSelectionActive(on: webView)
        if didToggleSelection && selectionActive == nil {
            nativeInspectorSelectionToggleNeedsDeactivation = true
        }
        if selectionActive == true || hasActiveNativeInspectorNodeSearch(in: webView) {
            return true
        }
        return selectionActive == nil && (didEnableNodeSearch || didToggleSelection)
    }

    private func deactivateNativeInspectorElementSelectionIfNeeded(on webView: WKWebView) -> Bool {
        let shouldToggleOff = isNativeInspectorElementSelectionActive(on: webView) == true
            || nativeInspectorSelectionToggleNeedsDeactivation
        nativeInspectorSelectionToggleNeedsDeactivation = false
        guard shouldToggleOff else {
            return false
        }
        return dependencies.webKitSPI.toggleElementSelection(webView)
    }

    private func cleanUpNativeInspectorActivationAttempt(on webView: WKWebView) {
        _ = deactivateNativeInspectorElementSelectionIfNeeded(on: webView)
        let shouldDisableNodeSearch =
            nativeInspectorNodeSearchNeedsDirectDeactivation
                || hasActiveNativeInspectorNodeSearch(in: webView)
        nativeInspectorNodeSearchNeedsDirectDeactivation = false
        if shouldDisableNodeSearch {
            _ = dependencies.webKitSPI.setNodeSearchEnabled(webView, false)
        }
    }

    private func dismissPageEditingForInspectorSelection(on webView: WKWebView) {
        dependencies.webKitSPI.dismissPageEditing(webView)
    }

    private func nativeInspectorSelectionNeedsProtocolInspectModeReset(on webView: WKWebView) -> Bool {
        isNativeInspectorElementSelectionActive(on: webView) == true
            || hasActiveNativeInspectorNodeSearch(in: webView)
    }

    private func enableProtocolInspectModeForNativeInspectorSelection(
        on webView: WKWebView,
        contextID: DOMContextID,
        targetIdentifier: String
    ) async -> Bool {
        do {
            try await setProtocolInspectModeEnabledForInspectorLifecycle(
                true,
                targetIdentifier: targetIdentifier
            )
            nativeInspectorProtocolInspectModeNeedsDeactivation = true
            logInspectorLifecycleDiagnostics(
                "beginSelectionMode enabled protocol inspect mode for native inspector backend",
                extra: "target=\(targetIdentifier)"
            )
            return true
        } catch {
            let didRecover = await recoverProtocolInspectModeEnableAfterNativeInspectorWakeup(
                on: webView,
                contextID: contextID,
                targetIdentifier: targetIdentifier,
                initialError: error
            )
            if didRecover {
                return true
            }

            nativeInspectorProtocolInspectModeNeedsDeactivation = false
            logInspectorLifecycleDiagnostics(
                "beginSelectionMode failed to enable protocol inspect mode for native inspector backend",
                extra: "target=\(targetIdentifier) error=\(error.localizedDescription)",
                level: .error
            )
            return false
        }
    }

    private func recoverProtocolInspectModeEnableAfterNativeInspectorWakeup(
        on webView: WKWebView,
        contextID: DOMContextID,
        targetIdentifier: String,
        initialError: any Error
    ) async -> Bool {
        guard selectionLifecycleStateMatches(
            contextID: contextID,
            targetIdentifier: targetIdentifier
        ) else {
            return false
        }

        let didActivateNativeSelection = activateNativeInspectorElementSelection(on: webView)
        guard didActivateNativeSelection,
              selectionLifecycleStateMatches(
                contextID: contextID,
                targetIdentifier: targetIdentifier
              ) else {
            cleanUpNativeInspectorActivationAttempt(on: webView)
            return false
        }

        do {
            try await ContinuousClock().sleep(for: .milliseconds(20))
        } catch {
            return false
        }

        guard selectionLifecycleStateMatches(
            contextID: contextID,
            targetIdentifier: targetIdentifier
        ) else {
            cleanUpNativeInspectorActivationAttempt(on: webView)
            return false
        }

        do {
            try await setProtocolInspectModeEnabledForInspectorLifecycle(
                true,
                targetIdentifier: targetIdentifier
            )
            nativeInspectorProtocolInspectModeNeedsDeactivation = true
            logInspectorLifecycleDiagnostics(
                "beginSelectionMode enabled protocol inspect mode after native inspector wakeup",
                extra: "target=\(targetIdentifier) initialError=\(initialError.localizedDescription)"
            )
            return true
        } catch {
            logInspectorLifecycleDiagnostics(
                "beginSelectionMode failed protocol inspect mode retry after native inspector wakeup",
                extra: "target=\(targetIdentifier) initialError=\(initialError.localizedDescription) retryError=\(error.localizedDescription)",
                level: .error
            )
            return false
        }
    }

    @discardableResult
    private func resetProtocolInspectModeForNativeInspectorSelection(
        targetIdentifier: String
    ) async -> Bool {
        do {
            try await setProtocolInspectModeEnabledForInspectorLifecycle(
                false,
                targetIdentifier: targetIdentifier
            )
            logInspectorLifecycleDiagnostics(
                "beginSelectionMode reset protocol inspect mode before native inspector backend",
                extra: "target=\(targetIdentifier)"
            )
            return true
        } catch {
            logInspectorLifecycleDiagnostics(
                "beginSelectionMode failed to reset protocol inspect mode before native inspector backend",
                extra: "target=\(targetIdentifier) error=\(error.localizedDescription)",
                level: .debug
            )
            return false
        }
    }

    private func disableProtocolInspectModeForNativeInspectorSelectionIfNeeded(
        targetIdentifier: String?
    ) async -> Bool {
        guard nativeInspectorProtocolInspectModeNeedsDeactivation else {
            return false
        }
        nativeInspectorProtocolInspectModeNeedsDeactivation = false
        guard let targetIdentifier else {
            logInspectorLifecycleDiagnostics(
                "disableInspectorSelectionModeIfNeeded skipped protocol inspect mode disable",
                extra: "missing target identifier",
                level: .error
            )
            return false
        }

        do {
            try await setProtocolInspectModeEnabledForInspectorLifecycle(
                false,
                targetIdentifier: targetIdentifier
            )
            return true
        } catch {
            logInspectorLifecycleDiagnostics(
                "disableInspectorSelectionModeIfNeeded failed to disable protocol inspect mode for native inspector backend",
                extra: "target=\(targetIdentifier) error=\(error.localizedDescription)",
                level: .error
            )
            return false
        }
    }

    private func waitForTransportInspectModeActivation(on webView: WKWebView) async -> Bool {
        if dependencies.webKitSPI.transportInspectActivationProvider(webView) {
            return true
        }

        let timeoutNanoseconds = dependencies.webKitSPI.transportInspectActivationTimeoutNanoseconds
        guard timeoutNanoseconds > 0 else {
            return false
        }

        let clock = ContinuousClock()
        let clampedTimeout = min(timeoutNanoseconds, UInt64(Int64.max))
        let deadline = clock.now.advanced(by: .nanoseconds(Int64(clampedTimeout)))
        while clock.now < deadline {
            do {
                try await clock.sleep(for: .milliseconds(10))
            } catch {
                return dependencies.webKitSPI.transportInspectActivationProvider(webView)
            }
            if dependencies.webKitSPI.transportInspectActivationProvider(webView) {
                return true
            }
        }

        return dependencies.webKitSPI.transportInspectActivationProvider(webView)
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

        dismissPageEditingForInspectorSelection(on: pageWebView)

        if nativeInspectorSelectionBackend(for: pageWebView) == .nativeInspector {
            nativeInspectorProtocolInspectModeNeedsDeactivation = false
            let didConnect = connectNativeInspectorIfNeeded(on: pageWebView)
            let shouldResetProtocolInspectMode = nativeInspectorSelectionNeedsProtocolInspectModeReset(
                on: pageWebView
            )
            if shouldResetProtocolInspectMode {
                await resetProtocolInspectModeForNativeInspectorSelection(
                    targetIdentifier: targetIdentifier
                )
            }
            let didEnableProtocolInspectMode = await enableProtocolInspectModeForNativeInspectorSelection(
                on: pageWebView,
                contextID: contextID,
                targetIdentifier: targetIdentifier
            )
            guard didEnableProtocolInspectMode else {
                guard selectionLifecycleStateMatches(
                    contextID: contextID,
                    targetIdentifier: targetIdentifier
                ) else {
                    cleanUpNativeInspectorActivationAttempt(on: pageWebView)
                    throw DOMOperationError.contextInvalidated
                }
                logInspectorLifecycleDiagnostics(
                    "beginSelectionMode skipped native inspector backend because protocol inspect mode did not enable",
                    extra: "contextID=\(contextID) target=\(targetIdentifier) nativeState=\(nativeInspectorInteractionStateSummaryForDiagnostics() ?? "nil")",
                    level: .error
                )
                cleanUpNativeInspectorActivationAttempt(on: pageWebView)
                return try await enableTransportProtocolInspectorSelectionMode(
                    on: pageWebView,
                    contextID: contextID,
                    targetIdentifier: targetIdentifier
                )
            }
            guard selectionLifecycleStateMatches(
                contextID: contextID,
                targetIdentifier: targetIdentifier
            ) else {
                _ = await disableProtocolInspectModeForNativeInspectorSelectionIfNeeded(
                    targetIdentifier: targetIdentifier
                )
                cleanUpNativeInspectorActivationAttempt(on: pageWebView)
                throw DOMOperationError.contextInvalidated
            }
            let didEnable = activateNativeInspectorElementSelection(on: pageWebView)
            logInspectorLifecycleDiagnostics(
                "beginSelectionMode using native inspector backend",
                extra: "backend=\(InspectModeControlBackend.nativeInspector.rawValue) contextID=\(contextID) target=\(targetIdentifier) connected=\(didConnect) protocolInspectMode=\(didEnableProtocolInspectMode) enabled=\(didEnable) nativeState=\(nativeInspectorInteractionStateSummaryForDiagnostics() ?? "nil")"
            )
            guard selectionLifecycleStateMatches(
                contextID: contextID,
                targetIdentifier: targetIdentifier
            ) else {
                _ = await disableProtocolInspectModeForNativeInspectorSelectionIfNeeded(
                    targetIdentifier: targetIdentifier
                )
                cleanUpNativeInspectorActivationAttempt(on: pageWebView)
                throw DOMOperationError.contextInvalidated
            }
            if didEnable {
                return .nativeInspector
            }

            logInspectorLifecycleDiagnostics(
                "beginSelectionMode native inspector failed; falling back to transport protocol",
                extra: "contextID=\(contextID) target=\(targetIdentifier) nativeState=\(nativeInspectorInteractionStateSummaryForDiagnostics() ?? "nil")",
                level: .error
            )
            if await waitForTransportInspectModeActivation(on: pageWebView) {
                guard selectionLifecycleStateMatches(
                    contextID: contextID,
                    targetIdentifier: targetIdentifier
                ) else {
                    _ = await disableProtocolInspectModeForNativeInspectorSelectionIfNeeded(
                        targetIdentifier: targetIdentifier
                    )
                    cleanUpNativeInspectorActivationAttempt(on: pageWebView)
                    throw DOMOperationError.contextInvalidated
                }
                cleanUpNativeInspectorActivationAttempt(on: pageWebView)
                nativeInspectorProtocolInspectModeNeedsDeactivation = false
                return .transportProtocol
            } else {
                _ = await disableProtocolInspectModeForNativeInspectorSelectionIfNeeded(
                    targetIdentifier: targetIdentifier
                )
            }
            cleanUpNativeInspectorActivationAttempt(on: pageWebView)
        }

        return try await enableTransportProtocolInspectorSelectionMode(
            on: pageWebView,
            contextID: contextID,
            targetIdentifier: targetIdentifier
        )
    }

    private func enableTransportProtocolInspectorSelectionMode(
        on pageWebView: WKWebView,
        contextID: DOMContextID,
        targetIdentifier: String
    ) async throws -> InspectModeControlBackend {
        do {
            logInspectorLifecycleDiagnostics(
                "beginSelectionMode using transport protocol backend",
                extra: "backend=\(InspectModeControlBackend.transportProtocol.rawValue) contextID=\(contextID) target=\(targetIdentifier) nativeState=\(nativeInspectorInteractionStateSummaryForDiagnostics() ?? "nil")"
            )
            try await setProtocolInspectModeEnabledForInspectorLifecycle(true, targetIdentifier: targetIdentifier)
            guard selectionLifecycleStateMatches(
                contextID: contextID,
                targetIdentifier: targetIdentifier
            ) else {
                try? await setProtocolInspectModeEnabledForInspectorLifecycle(false, targetIdentifier: targetIdentifier)
                throw DOMOperationError.contextInvalidated
            }
            if await waitForTransportInspectModeActivation(on: pageWebView) {
                guard selectionLifecycleStateMatches(
                    contextID: contextID,
                    targetIdentifier: targetIdentifier
                ) else {
                    try? await setProtocolInspectModeEnabledForInspectorLifecycle(false, targetIdentifier: targetIdentifier)
                    throw DOMOperationError.contextInvalidated
                }
                return .transportProtocol
            }
            logInspectorLifecycleDiagnostics(
                "beginSelectionMode transport protocol did not activate",
                extra: "contextID=\(contextID) target=\(targetIdentifier) nativeState=\(nativeInspectorInteractionStateSummaryForDiagnostics() ?? "nil")",
                level: .error
            )
            try? await setProtocolInspectModeEnabledForInspectorLifecycle(false, targetIdentifier: targetIdentifier)
            throw DOMOperationError.scriptFailure("Transport inspect mode did not activate.")
        } catch {
            logInspectorLifecycleDiagnostics(
                "beginSelectionMode transport protocol failed",
                extra: "contextID=\(contextID) target=\(targetIdentifier) error=\(error.localizedDescription) nativeState=\(nativeInspectorInteractionStateSummaryForDiagnostics() ?? "nil")",
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
            let didDisableProtocolInspectMode =
                await disableProtocolInspectModeForNativeInspectorSelectionIfNeeded(
                    targetIdentifier: targetIdentifier
                )
            let shouldDisableNodeSearchDirectly =
                nativeInspectorNodeSearchNeedsDirectDeactivation
                    || didDisableProtocolInspectMode == false
                    || hasActiveNativeInspectorNodeSearch(in: pageWebView)
            nativeInspectorNodeSearchNeedsDirectDeactivation = false
            let didDisableNodeSearch = shouldDisableNodeSearchDirectly
                ? dependencies.webKitSPI.setNodeSearchEnabled(pageWebView, false)
                : false
            logInspectorLifecycleDiagnostics(
                "disableInspectorSelectionModeIfNeeded used native inspector backend",
                extra: "backend=\(InspectModeControlBackend.nativeInspector.rawValue) target=\(targetIdentifier ?? "nil") toggledOff=\(didToggleOff) disabledProtocolInspectMode=\(didDisableProtocolInspectMode) disabledNodeSearch=\(didDisableNodeSearch) nativeState=\(nativeInspectorInteractionStateSummaryForDiagnostics() ?? "nil")"
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
        await restoreInspectorHighlightAfterPointerDisconnect()
    }

    func nativeInspectorInteractionStateSummaryForDiagnostics() -> String? {
        guard let pageWebView else {
            return nil
        }

        let hasPrivateInspectorAccess = dependencies.webKitSPI.hasPrivateInspectorAccess(pageWebView)
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
