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
/// Releasing the inspector ends its attachment.
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

        /// The inspector is ending its attachment and closing the
        /// connection.
        case detaching

        /// The inspector is not attached.
        case detached

        /// The attachment failed or ended with an inspector error.
        case failed(WebInspectorProxyError)
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

    isolated deinit {
        attachment.endForReleasedInspector()
    }

    /// The progress of the latest ``attach(to:configuration:)`` or
    /// ``detach()`` call.
    public var state: State {
        attachment.state
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
        attachment.attach(webView: webView) {
            try await WebInspectorContainer(attachingTo: webView, configuration: configuration)
        }
    }

    /// Stops inspecting.
    ///
    /// The call returns immediately. ``state`` is ``State/detaching`` until
    /// the connection is closed, and then ``State/detached``. The models of
    /// the ended attachment keep their last state, and the domain collections
    /// become empty.
    public func detach() {
        attachment.detach()
    }

    /// The context of the current attachment. It is replaced whenever an
    /// attachment starts or ends.
    package var context: WebInspectorContext {
        attachment.context
    }

    /// The web view of the current attachment, when it was made to one.
    package var inspectedWebView: WKWebView? {
        attachment.inspectedWebView
    }

    /// The number of attach and detach calls made so far.
    package var requestCount: UInt64 {
        attachment.requestCount
    }

    /// Called after ``context`` was replaced, in the same step.
    package var contextDidChange: (@MainActor () -> Void)? {
        get { attachment.contextDidChange }
        set { attachment.contextDidChange = newValue }
    }

    /// State that the presentation layer keeps for as long as the inspector
    /// lives, such as the selected tab.
    @ObservationIgnored package var presentationStorage: AnyObject?

    /// Replaces the current context with one that is managed elsewhere, such
    /// as a preview or a test fixture.
    package func install(_ context: WebInspectorContext) {
        attachment.replaceContext(context)
    }

    /// Starts an attachment whose connection `makeContainer` provides.
    package func attach(
        makeContainer: @escaping @MainActor () async throws -> WebInspectorContainer
    ) {
        attachment.attach(makeContainer: makeContainer)
    }

    /// Attaches with `makeContainer` and waits until the call is applied.
    ///
    /// Cancelling the calling task abandons the attachment.
    /// - Returns: `false` when a later call replaced this one.
    /// - Throws: The attachment failure.
    @discardableResult
    package func attachAndWait(
        makeContainer: @escaping @MainActor () async throws -> WebInspectorContainer
    ) async throws -> Bool {
        try await attachment.attachAndWait(makeContainer: makeContainer)
    }

    /// Detaches and waits until the call is applied.
    package func detachAndWait() async {
        await attachment.detachAndWait()
    }

    /// Suspends until every submitted call has been applied.
    package func waitUntilIdle() async {
        await attachment.waitUntilIdle()
    }
}
