import Foundation
import Observation
import WebInspectorProxyKit
import WebKit

/// The attachment of a ``WebInspector``: its current context and the calls
/// that replace it.
///
/// The domain objects read their context through this object, so they follow
/// the inspector from one attachment to the next. The worker that applies
/// attach and detach calls retains this object and not the inspector, so an
/// inspector can be released while a call is still being applied.
@MainActor
@Observable
final class WebInspectorAttachment {
    private struct Request {
        enum Kind {
            case attach(@MainActor () async throws -> WebInspectorContainer)
            case detach
        }

        let id: UInt64
        let kind: Kind
    }

    private(set) var context: WebInspectorContext
    /// The web view of the latest attach call, until a detach call.
    private(set) weak var inspectedWebView: WKWebView?
    /// The number of attach and detach calls made so far.
    @ObservationIgnored private(set) var requestCount: UInt64 = 0
    /// Called when an attach or detach call is made, before it is applied.
    @ObservationIgnored var attachmentWillChange: (@MainActor () -> Void)?
    /// Called after the context was replaced.
    @ObservationIgnored var contextDidChange: (@MainActor () -> Void)?
    /// What the latest call asked for, until that call has been applied.
    private var requestedState: WebInspector.State?
    private var attachFailure: WebInspectorProxyError?

    /// The relays that carry collection changes across attachments, or `nil`
    /// for an attachment that stays with one context.
    @ObservationIgnored private let spanningChanges: (
        requests: WebInspectorAsyncStreamRelay<WebInspectorCollectionChange<NetworkRequest>>,
        messages: WebInspectorAsyncStreamRelay<WebInspectorCollectionChange<ConsoleMessage>>
    )?
    @ObservationIgnored private var container: WebInspectorContainer?
    @ObservationIgnored private var pendingRequest: Request?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var runningAttach: Task<WebInspectorContainer, any Error>?
    @ObservationIgnored private var lastAppliedRequestID: UInt64 = 0
    @ObservationIgnored private var lastAttachError: (any Error)?
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates an attachment that stays with `context`, for the domain
    /// objects of a context that no inspector owns.
    init(context: WebInspectorContext) {
        self.context = context
        spanningChanges = nil
    }

    /// Creates the attachment of an inspector.
    init(following context: WebInspectorContext) {
        self.context = context
        spanningChanges = (WebInspectorAsyncStreamRelay(), WebInspectorAsyncStreamRelay())
        mirrorCollectionChanges(of: context)
    }

    var state: WebInspector.State {
        if let requestedState {
            return requestedState
        }
        if let attachFailure {
            return .failed(attachFailure)
        }
        switch context.state {
        case .attaching:
            return .attaching
        case .attached:
            return .attached
        case .detached:
            return .detached
        case let .failed(error):
            return .failed(error)
        }
    }

    var requestChanges: AsyncStream<WebInspectorCollectionChange<NetworkRequest>> {
        spanningChanges?.requests.makeStream() ?? context.networkRequestChanges
    }

    var messageChanges: AsyncStream<WebInspectorCollectionChange<ConsoleMessage>> {
        spanningChanges?.messages.makeStream() ?? context.consoleMessageChanges
    }

    // MARK: Calls

    /// Starts an attachment, unless the inspector is already attaching or
    /// attached to `webView`.
    func attach(
        webView: WKWebView? = nil,
        makeContainer: @escaping @MainActor () async throws -> WebInspectorContainer
    ) {
        if let webView, webView === inspectedWebView {
            switch state {
            case .attaching, .attached:
                return
            case .detaching, .detached, .failed:
                break
            }
        }
        submit(.attach(makeContainer), webView: webView)
    }

    func detach() {
        submit(.detach)
    }

    /// Ends what the released inspector left behind: a connection, or a call
    /// that is still being applied.
    func endForReleasedInspector() {
        guard container != nil || worker != nil else {
            return
        }
        submit(.detach)
    }

    /// Attaches with `makeContainer` and waits until the call is applied.
    ///
    /// Cancelling the calling task abandons the attachment.
    /// - Returns: `false` when a later call replaced this one.
    /// - Throws: The attachment failure.
    func attachAndWait(
        makeContainer: @escaping @MainActor () async throws -> WebInspectorContainer
    ) async throws -> Bool {
        let id = submit(.attach(makeContainer))
        await withTaskCancellationHandler {
            await waitUntilIdle()
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.abandonRequest(id)
            }
        }
        if Task.isCancelled, requestCount == id {
            // The attachment finished before the cancellation reached it.
            await detachAndWait()
        }
        guard requestCount == id, lastAppliedRequestID == id else {
            return false
        }
        if let lastAttachError {
            throw lastAttachError
        }
        return true
    }

    func detachAndWait() async {
        submit(.detach)
        await waitUntilIdle()
    }

    func waitUntilIdle() async {
        guard worker != nil else {
            return
        }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    @discardableResult
    private func submit(_ kind: Request.Kind, webView: WKWebView? = nil) -> UInt64 {
        requestCount += 1
        pendingRequest = Request(id: requestCount, kind: kind)
        inspectedWebView = webView
        attachFailure = nil
        lastAttachError = nil
        switch kind {
        case .attach:
            requestedState = .attaching
        case .detach:
            requestedState = .detaching
        }
        // An attachment that is still starting has been superseded.
        runningAttach?.cancel()
        attachmentWillChange?()
        if worker == nil {
            worker = Task {
                await self.applyRequests()
            }
        }
        return requestCount
    }

    private func abandonRequest(_ id: UInt64) {
        guard requestCount == id, lastAppliedRequestID != id else {
            return
        }
        submit(.detach)
    }

    private func applyRequests() async {
        while let request = pendingRequest {
            pendingRequest = nil
            await closeCurrentAttachment()
            switch request.kind {
            case .detach:
                replaceContext(.detached())
            case let .attach(makeContainer):
                guard pendingRequest == nil else {
                    continue
                }
                let attach = Task {
                    try await makeContainer()
                }
                runningAttach = attach
                let result = await attach.result
                runningAttach = nil
                switch result {
                case let .success(container):
                    guard pendingRequest == nil else {
                        await container.close()
                        continue
                    }
                    self.container = container
                    replaceContext(container.mainContext)
                case let .failure(error):
                    guard pendingRequest == nil else {
                        continue
                    }
                    replaceContext(.detached())
                    WebInspectorDataKitLog.error("Attaching failed: \(String(describing: error))")
                    lastAttachError = error
                    attachFailure = (error as? WebInspectorProxyError)
                        ?? .disconnected(String(describing: error))
                }
            }
            lastAppliedRequestID = request.id
        }
        requestedState = nil
        worker = nil
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func closeCurrentAttachment() async {
        let context = context
        if let container {
            self.container = nil
            await container.close()
        } else {
            await context.stop()
        }
        // The connection is closed either way, so a domain that could not be
        // disabled leaves nothing for the caller to recover.
        if let teardownError = context.teardownError {
            WebInspectorDataKitLog.error(
                "Ending the attachment reported an error: \(String(describing: teardownError))"
            )
        }
    }

    // MARK: Context

    /// Replaces the context.
    ///
    /// The replacement is one synchronous step. The change streams report
    /// that everything was removed and then that the new context's models
    /// were inserted, so a consumer that applies every change stays in step
    /// with the collections. Live DOM tree controllers move to the new
    /// context and show its document.
    func replaceContext(_ newContext: WebInspectorContext) {
        guard newContext !== context else {
            return
        }
        let previousContext = context
        previousContext.setCollectionChangeMirrors(requests: nil, messages: nil)
        context = newContext
        previousContext.transferTreeStates(to: newContext)
        if let spanningChanges {
            spanningChanges.requests.yield(.removedAll)
            spanningChanges.messages.yield(.removedAll)
            mirrorCollectionChanges(of: newContext)
            let requests = newContext.networkRequests
            if requests.isEmpty == false {
                spanningChanges.requests.yield(.inserted(requests))
            }
            let messages = newContext.consoleMessages
            if messages.isEmpty == false {
                spanningChanges.messages.yield(.inserted(messages))
            }
        }
        contextDidChange?()
    }

    private func mirrorCollectionChanges(of context: WebInspectorContext) {
        context.setCollectionChangeMirrors(
            requests: spanningChanges?.requests,
            messages: spanningChanges?.messages
        )
    }
}
