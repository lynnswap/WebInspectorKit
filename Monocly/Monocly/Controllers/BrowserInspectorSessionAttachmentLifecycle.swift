#if canImport(UIKit)
import UIKit
import WebKit
import WebInspectorKit

@MainActor
final class BrowserInspectorSessionAttachmentLifecycle {
    typealias AttachAction = @MainActor (WKWebView) async throws -> Void
    typealias DetachAction = @MainActor () async -> Void

    enum Attachment {
        case attached
        case detached
    }

    private enum AttachmentPhase {
        case detached
        case attached
        case attaching(WKWebView, pending: Attachment?)
        case detaching(pending: Attachment?)
        case finalizingAttachThenDetach(WKWebView)
        case finalizingDetach
        case finalized

        var isFinalizing: Bool {
            switch self {
            case .finalizingAttachThenDetach, .finalizingDetach, .finalized:
                true
            case .detached, .attached, .attaching, .detaching:
                false
            }
        }

        var wantsAttachment: Bool {
            switch self {
            case .attached, .attaching:
                true
            case let .detaching(pending):
                pending == .attached
            case .detached, .finalizingAttachThenDetach, .finalizingDetach, .finalized:
                false
            }
        }

        var currentEffect: Effect? {
            switch self {
            case let .attaching(webView, _), let .finalizingAttachThenDetach(webView):
                .attach(webView)
            case .detaching, .finalizingDetach:
                .detach
            case .detached, .attached, .finalized:
                nil
            }
        }
    }

    private enum Effect {
        case attach(WKWebView)
        case detach
    }

    private enum EffectResult {
        case succeeded
        case failed
    }

    private let browserWindow: BrowserWindow
    // The lifecycle owns the session lease. Effect tasks capture only the
    // pre-bound operations, never this property or the lifecycle itself.
    private let inspectorSession: WebInspectorSession
    private let attachAction: AttachAction
    private let detachAction: DetachAction
    private var phase: AttachmentPhase = .detached
    private var lifecycleTask: Task<Void, Never>?
    private var activeEffectID: UInt64?
    private var nextEffectID: UInt64 = 0
    private weak var attachedWebView: WKWebView?
    var onAttachForTesting: ((WKWebView) -> Void)?

    init(
        browserWindow: BrowserWindow,
        inspectorSession: WebInspectorSession,
        attachAction: AttachAction? = nil,
        detachAction: DetachAction? = nil
    ) {
        self.browserWindow = browserWindow
        self.inspectorSession = inspectorSession
        self.attachAction = attachAction ?? { [weak inspectorSession] webView in
            // The async Session method owns its own call lifetime. Keeping this
            // capture weak prevents the stored effect task from extending the
            // lifecycle's Session lease before or after that call.
            guard let inspectorSession else {
                throw CancellationError()
            }
            try await inspectorSession.attach(to: webView)
        }
        self.detachAction = detachAction ?? { [weak inspectorSession] in
            guard let inspectorSession else {
                return
            }
            await inspectorSession.detach()
        }
    }

    isolated deinit {
        cancel()
    }

    /// Abandons the lifecycle during terminal owner teardown.
    func cancel() {
        phase = .finalized
        attachedWebView = nil
        activeEffectID = nil
        let lifecycleTask = lifecycleTask
        self.lifecycleTask = nil
        lifecycleTask?.cancel()
    }

    func finalize() -> Bool {
        guard phase.isFinalizing == false else {
            return false
        }
        switch phase {
        case .detached:
            phase = .finalized
        case .attached:
            phase = .finalizingDetach
            startLifecycleTaskIfNeeded()
        case let .attaching(webView, _):
            phase = .finalizingAttachThenDetach(webView)
        case .detaching:
            phase = .finalizingDetach
        case .finalizingAttachThenDetach, .finalizingDetach, .finalized:
            return false
        }
        return true
    }

    func waitForTransitions() async {
        while let lifecycleTask {
            await lifecycleTask.value
            if self.lifecycleTask == nil {
                break
            }
        }
    }

    func setAttachedForTesting(to webView: WKWebView) {
        phase = .attached
        attachedWebView = webView
    }

    func selectedWebViewDidChange(to webView: WKWebView) {
        guard phase.wantsAttachment else {
            return
        }
        guard attachedWebView !== webView || lifecycleTask != nil else {
            return
        }
        request(.attached)
    }

    func request(_ attachment: Attachment) {
        if phase.isFinalizing, attachment != .detached {
            return
        }

        switch attachment {
        case .attached:
            requestAttach()
        case .detached:
            requestDetach()
        }
    }

    private func requestAttach() {
        let webView = browserWindow.webView
        switch phase {
        case .detached:
            phase = .attaching(webView, pending: nil)
        case .attached:
            guard attachedWebView !== webView else {
                return
            }
            phase = .attaching(webView, pending: nil)
        case let .attaching(currentWebView, _):
            phase = .attaching(currentWebView, pending: .attached)
        case .detaching:
            phase = .detaching(pending: .attached)
        case .finalizingAttachThenDetach, .finalizingDetach, .finalized:
            return
        }
        startLifecycleTaskIfNeeded()
    }

    private func requestDetach() {
        switch phase {
        case .detached, .finalized:
            return
        case .attached:
            phase = .detaching(pending: nil)
        case let .attaching(webView, _):
            phase = .attaching(webView, pending: .detached)
        case .detaching:
            phase = .detaching(pending: nil)
        case .finalizingAttachThenDetach:
            return
        case .finalizingDetach:
            return
        }
        startLifecycleTaskIfNeeded()
    }

    private func startLifecycleTaskIfNeeded() {
        guard lifecycleTask == nil,
              let effect = phase.currentEffect else {
            return
        }

        if case let .attach(webView) = effect {
            onAttachForTesting?(webView)
        }

        let effectID = nextEffectID
        nextEffectID &+= 1
        activeEffectID = effectID
        let attachAction = attachAction
        let detachAction = detachAction
        lifecycleTask = Task { @MainActor [weak self, effect, effectID, attachAction, detachAction] in
            let result = await Self.perform(
                effect,
                attachAction: attachAction,
                detachAction: detachAction
            )
            self?.commit(effect, result: result, id: effectID)
        }
    }

    private static func perform(
        _ effect: Effect,
        attachAction: AttachAction,
        detachAction: DetachAction
    ) async -> EffectResult {
        switch effect {
        case let .attach(webView):
            do {
                try await attachAction(webView)
                return .succeeded
            } catch {
                return .failed
            }
        case .detach:
            await detachAction()
            return .succeeded
        }
    }

    private func commit(_ effect: Effect, result: EffectResult, id: UInt64) {
        guard activeEffectID == id else {
            return
        }
        activeEffectID = nil
        lifecycleTask = nil
        finish(effect, result: result)
        startLifecycleTaskIfNeeded()
    }

    private func finish(_ effect: Effect, result: EffectResult) {
        switch (phase, effect) {
        case let (.attaching(webView, pending), .attach(effectWebView))
            where webView === effectWebView:
            finishAttach(webView: webView, pending: pending, result: result)

        case let (.finalizingAttachThenDetach(webView), .attach(effectWebView))
            where webView === effectWebView:
            finishFinalizingAttach(webView: webView, result: result)

        case let (.detaching(pending), .detach):
            finishDetach(pending: pending)

        case (.finalizingDetach, .detach):
            attachedWebView = nil
            phase = .finalized

        default:
            break
        }
    }

    private func finishAttach(
        webView: WKWebView,
        pending: Attachment?,
        result: EffectResult
    ) {
        switch result {
        case .succeeded:
            attachedWebView = webView
            switch pending {
            case .attached:
                requestAttachAfterCurrentEffect(completedWebView: webView)
            case .detached:
                phase = .detaching(pending: nil)
            case nil:
                phase = .attached
            }
        case .failed:
            attachedWebView = nil
            switch pending {
            case .attached:
                phase = .attaching(browserWindow.webView, pending: nil)
            case .detached, nil:
                phase = .detached
            }
        }
    }

    private func finishFinalizingAttach(webView: WKWebView, result: EffectResult) {
        switch result {
        case .succeeded:
            attachedWebView = webView
            phase = .finalizingDetach
        case .failed:
            attachedWebView = nil
            phase = .finalized
        }
    }

    private func finishDetach(pending: Attachment?) {
        attachedWebView = nil
        switch pending {
        case .attached:
            phase = .attaching(browserWindow.webView, pending: nil)
        case .detached, nil:
            phase = .detached
        }
    }

    private func requestAttachAfterCurrentEffect(completedWebView: WKWebView) {
        let latestWebView = browserWindow.webView
        if latestWebView === completedWebView {
            phase = .attached
        } else {
            phase = .attaching(latestWebView, pending: nil)
        }
    }
}
#endif
