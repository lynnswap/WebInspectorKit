#if canImport(UIKit)
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
    package static var availabilityProvider: @MainActor (WKWebView) -> Bool = {
        WIInspectorSelectionPrivateBridge.canControlSelection(in: $0)
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
    package static var customSelectionOverlayOverride: Bool?
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
    func ensureNativeInspectorSelectionAvailableIfNeeded() throws {
        guard usesCustomSelectionHitTestOverlay == false else {
            return
        }

        guard let pageWebView else {
            return
        }

        guard WIDOMUIKitInspectorSelectionEnvironment.availabilityProvider(pageWebView) else {
            throw DOMOperationError.scriptFailure("Native inspector selection private API unavailable.")
        }
    }

    func setNativeInspectorNodeSearchEnabled(_ enabled: Bool) {
        if usesCustomSelectionHitTestOverlay {
            if enabled {
                installSelectionHitTestOverlay()
            } else {
                removeSelectionHitTestOverlay()
            }
            return
        }

        guard let pageWebView else {
            return
        }

        guard WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter(pageWebView, enabled) else {
            domWindowActivationLogger.error(
                "native inspector node search \(enabled ? "enable" : "disable", privacy: .public) unavailable"
            )
            return
        }
    }

    private func installSelectionHitTestOverlay() {
#if DEBUG
        guard let pageWebView else {
            return
        }

        if selectionHitTestOverlay?.superview === pageWebView {
            selectionHitTestOverlay?.frame = pageWebView.bounds
            return
        }

        removeSelectionHitTestOverlay()
        let overlay = WIDOMSelectionHitTestOverlay(inspector: self)
        overlay.frame = pageWebView.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pageWebView.addSubview(overlay)
        selectionHitTestOverlay = overlay
#endif
    }

    private func removeSelectionHitTestOverlay() {
#if DEBUG
        selectionHitTestOverlay?.removeFromSuperview()
        selectionHitTestOverlay = nil
#endif
    }

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
        guard usesCustomSelectionHitTestOverlay == false else {
            removeSelectionHitTestOverlay()
            return
        }

        guard let pageWebView else {
            return
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

    var usesCustomSelectionHitTestOverlay: Bool {
#if DEBUG
        if let override = WIDOMUIKitInspectorSelectionEnvironment.customSelectionOverlayOverride {
            return override
        }
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || Bundle.main.bundlePath.hasSuffix(".xctest")
#else
        false
#endif
    }

    private func removeLingeringNativeInspectorNodeSearchRecognizers(in webView: WKWebView) {
        _ = WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover(webView)
    }

    private func hasActiveNativeInspectorNodeSearch(in webView: WKWebView) -> Bool {
        WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider(webView)
    }

    private func isNativeInspectorElementSelectionActive(on webView: WKWebView) -> Bool? {
        WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider(webView)
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

        let selectionActive = isNativeInspectorElementSelectionActive(on: pageWebView)
        let contentViewActive = hasActiveNativeInspectorNodeSearch(in: pageWebView)

        let selectionValue = selectionActive.map { $0 ? "1" : "0" } ?? "n/a"
        let contentViewValue = contentViewActive ? "1" : "0"
        return "nativeSelectionActive=\(selectionValue) contentViewActive=\(contentViewValue)"
    }
}

#if DEBUG
private final class WIDOMSelectionHitTestOverlay: UIView {
    private weak var inspector: WIDOMInspector?

    init(inspector: WIDOMInspector) {
        self.inspector = inspector
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tapRecognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    @objc
    private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let inspector else {
            return
        }
        let point = recognizer.location(in: self)
        Task { @MainActor in
            await inspector.handlePointerInspectSelection(at: point)
        }
    }
}
#endif
#endif
