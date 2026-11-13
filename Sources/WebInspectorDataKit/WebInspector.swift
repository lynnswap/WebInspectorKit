import Foundation
import Observation
import WebInspectorProxyKit
import WebKit

/// The inspector of a web view.
///
/// A `WebInspector` attaches to a `WKWebView` and publishes what it finds as
/// observable models: the DOM tree, the network requests, the console
/// messages, and the JavaScript execution contexts. Each domain also carries
/// the commands that act on its models.
///
/// ```swift
/// let inspector = WebInspector()
/// inspector.attach(to: webView)
///
/// for request in inspector.network.requests {
///     print(request.url)
/// }
/// ```
///
/// `attach(to:)` and `detach()` return immediately, and ``state`` reports
/// their progress. Calling either again replaces what was asked before: the
/// inspector applies one call at a time, ends an attachment that was
/// superseded while it was starting, and settles on the latest call.
///
/// The domain objects are the same for the lifetime of the inspector. Their
/// models belong to one attachment and are replaced by the next.
@MainActor
@Observable
public final class WebInspector {
    /// The progress of an attachment.
    public enum State: Equatable, Sendable {
        /// The inspector is connecting to the web view and loading the
        /// initial state of the page.
        case attaching

        /// The inspector is attached and observing the page.
        case attached

        /// The inspector is not attached.
        case detached

        /// The attachment failed or ended with an inspector error.
        case failed(WebInspectorProxyError)
    }

    private struct Request {
        enum Kind {
            case attach(@MainActor () async throws -> WebInspectorContainer)
            case detach
        }

        let id: UInt64
        let kind: Kind
    }

    /// The DOM of the inspected page.
    public let dom: DOMInspector

    /// The CSS styles of the inspected page's elements.
    public let css: CSSInspector

    /// The network requests of the inspected page.
    public let network: NetworkInspector

    /// The console messages of the inspected page.
    public let console: ConsoleInspector

    /// The JavaScript execution contexts of the inspected page.
    public let runtime: RuntimeInspector

    /// Page-level commands.
    public let page: PageInspector

    @ObservationIgnored private let attachment: WebInspectorAttachment
    @ObservationIgnored private var container: WebInspectorContainer?
    @ObservationIgnored private var pendingRequest: Request?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var runningAttach: Task<WebInspectorContainer, any Error>?
    @ObservationIgnored private var lastRequestID: UInt64 = 0
    @ObservationIgnored private var lastAppliedRequestID: UInt64 = 0
    @ObservationIgnored private var lastAttachError: (any Error)?
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// What the latest call asked for, until that call has been applied.
    private var requestedState: State?
    private var attachFailure: WebInspectorProxyError?

    /// Creates a detached inspector.
    public convenience init() {
        self.init(context: .detached())
    }

    package init(context: WebInspectorContext) {
        let attachment = WebInspectorAttachment(following: context)
        self.attachment = attachment
        dom = DOMInspector(attachment: attachment)
        css = CSSInspector(attachment: attachment)
        network = NetworkInspector(attachment: attachment)
        console = ConsoleInspector(attachment: attachment)
        runtime = RuntimeInspector(attachment: attachment)
        page = PageInspector(attachment: attachment)
    }

    /// The progress of the latest ``attach(to:configuration:)`` or
    /// ``detach()`` call.
    public var state: State {
        if let requestedState {
            return requestedState
        }
        if let attachFailure {
            return .failed(attachFailure)
        }
        return attachment.context.state
    }

    /// Starts inspecting a web view, replacing the current attachment.
    ///
    /// The call returns immediately. ``state`` is ``State/attaching`` until
    /// the page's initial state is loaded, and ``State/failed(_:)`` if the
    /// connection cannot be made.
    public func attach(
        to webView: WKWebView,
        configuration: WebInspectorProxy.Configuration = .init()
    ) {
        submit(.attach {
            try await WebInspectorContainer(attachingTo: webView, configuration: configuration)
        })
    }

    /// Stops inspecting.
    ///
    /// The call returns immediately. The models of the ended attachment keep
    /// their last state, and the domain collections become empty.
    public func detach() {
        submit(.detach)
    }

    /// The context of the current attachment. It is replaced whenever an
    /// attachment starts or ends.
    package var context: WebInspectorContext {
        attachment.context
    }

    /// Replaces the current context with one that is managed elsewhere, such
    /// as a preview or a test fixture.
    package func install(_ context: WebInspectorContext) {
        attachment.replaceContext(context)
    }

    /// Attaches with `makeContainer` and waits until the call is applied.
    ///
    /// Cancelling the calling task abandons the attachment.
    /// - Returns: `false` when a later call replaced this one.
    /// - Throws: The attachment failure.
    @discardableResult
    package func attach(
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
        guard lastAppliedRequestID == id else {
            return false
        }
        if let lastAttachError {
            throw lastAttachError
        }
        return true
    }

    /// Detaches and waits until the call is applied.
    package func detachAndWait() async {
        submit(.detach)
        await waitUntilIdle()
    }

    /// Suspends until every submitted call has been applied.
    package func waitUntilIdle() async {
        guard worker != nil else {
            return
        }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    @discardableResult
    private func submit(_ kind: Request.Kind) -> UInt64 {
        lastRequestID += 1
        pendingRequest = Request(id: lastRequestID, kind: kind)
        attachFailure = nil
        lastAttachError = nil
        switch kind {
        case .attach:
            requestedState = .attaching
        case .detach:
            requestedState = .detached
        }
        // An attachment that is still starting has been superseded.
        runningAttach?.cancel()
        if worker == nil {
            worker = Task { [weak self] in
                await self?.applyRequests()
            }
        }
        return lastRequestID
    }

    private func abandonRequest(_ id: UInt64) {
        guard lastRequestID == id, lastAppliedRequestID != id else {
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
                attachment.replaceContext(.detached())
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
                    attachment.replaceContext(container.mainContext)
                case let .failure(error):
                    guard pendingRequest == nil else {
                        continue
                    }
                    attachment.replaceContext(.detached())
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
        if let container {
            self.container = nil
            await container.close()
        } else {
            await attachment.context.stop()
        }
    }
}
