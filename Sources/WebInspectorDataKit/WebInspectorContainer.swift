import Foundation
import WebKit
import WebInspectorProxyKit

/// A DataKit inspection container attached to one proxy connection.
///
/// `WebInspectorContainer` owns the underlying `WebInspectorProxy` and vends
/// context objects that preserve DOM, Network, Console, Runtime, and CSS model
/// identity.
///
/// Example:
///
/// ```swift
/// let container = try await WebInspectorContainer(attachingTo: webView)
/// let context = container.mainContext
///
/// let tree = context.dom.treeController()
/// render(tree.snapshot)
///
/// await container.close()
/// ```
public final class WebInspectorContainer: @unchecked Sendable {
    let proxy: WebInspectorProxy
    let domainEnablement: WebInspectorDomainEnablementRegistry

    @MainActor private var _mainContext: WebInspectorContext?

    /// The main-actor context for UIKit/AppKit clients.
    ///
    /// The context is created lazily and starts observing the inspected page
    /// when first accessed.
    @MainActor public var mainContext: WebInspectorContext {
        if let context = _mainContext {
            return context
        }
        let context = WebInspectorContext(self, isolation: MainActor.shared)
        _mainContext = context
        context.start()
        return context
    }

    /// Creates a container from an existing proxy connection.
    public init(proxy: WebInspectorProxy) {
        self.proxy = proxy
        domainEnablement = WebInspectorDomainEnablementRegistry()
    }

    /// Attaches to a web view and creates a container for the resulting proxy.
    @MainActor
    public convenience init(
        attachingTo webView: WKWebView,
        configuration: WebInspectorProxy.Configuration = .init()
    ) async throws {
        let proxy = try await WebInspectorProxy(attachingTo: webView, configuration: configuration)
        self.init(proxy: proxy)
    }

    /// Stops the main context and closes the underlying proxy connection.
    public func close() async {
        await stopMainContext()
        await proxy.close()
    }

    @MainActor
    private func stopMainContext() async {
        await _mainContext?.stop()
    }
}
