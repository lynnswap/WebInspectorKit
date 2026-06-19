#if canImport(UIKit)
import UIKit
import WebKit
import WebInspectorKit

@MainActor
final class BrowserInspectorSessionAttachmentLifecycle {
    typealias AttachAction = @MainActor (WebInspectorSession, WKWebView) async throws -> Void
    typealias DetachAction = @MainActor (WebInspectorSession) async -> Void

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

    private let store: BrowserWindowStore
    private let inspectorSession: WebInspectorSession
    private let attachAction: AttachAction
    private let detachAction: DetachAction
    private var phase: AttachmentPhase = .detached
    private var lifecycleTask: Task<Void, Never>?
    private weak var attachedWebView: WKWebView?
    var onAttachForTesting: ((WKWebView) -> Void)?

    init(
        store: BrowserWindowStore,
        inspectorSession: WebInspectorSession,
        attachAction: @escaping AttachAction = { inspectorSession, webView in
            try await inspectorSession.attach(to: webView)
        },
        detachAction: @escaping DetachAction = { inspectorSession in
            await inspectorSession.detach()
        }
    ) {
        self.store = store
        self.inspectorSession = inspectorSession
        self.attachAction = attachAction
        self.detachAction = detachAction
    }

    func cancel() {
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
        let webView = store.webView
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
        guard lifecycleTask == nil else {
            return
        }

        let inspectorSession = inspectorSession
        let attachAction = attachAction
        let detachAction = detachAction
        lifecycleTask = Task { [weak self, inspectorSession, attachAction, detachAction] in
            guard let self else {
                return
            }
            while let effect = self.phase.currentEffect {
                let result: EffectResult
                switch effect {
                case let .attach(webView):
                    do {
                        self.onAttachForTesting?(webView)
                        try await attachAction(inspectorSession, webView)
                        result = .succeeded
                    } catch {
                        result = .failed
                    }
                case .detach:
                    await detachAction(inspectorSession)
                    result = .succeeded
                }
                self.finish(effect, result: result)
            }
            self.lifecycleTask = nil
        }
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
                phase = .attaching(store.webView, pending: nil)
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
            phase = .attaching(store.webView, pending: nil)
        case .detached, nil:
            phase = .detached
        }
    }

    private func requestAttachAfterCurrentEffect(completedWebView: WKWebView) {
        let latestWebView = store.webView
        if latestWebView === completedWebView {
            phase = .attached
        } else {
            phase = .attaching(latestWebView, pending: nil)
        }
    }
}
#endif
