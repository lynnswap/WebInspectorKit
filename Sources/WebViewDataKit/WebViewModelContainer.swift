import Foundation
import WebKit
import WebViewProxyKit

public final class WebViewModelContainer: @unchecked Sendable {
    public let proxy: WebViewProxy

    @MainActor private let context: WebViewModelContext

    @MainActor public var mainContext: WebViewModelContext {
        context
    }

    @MainActor
    public init(proxy: WebViewProxy) {
        self.proxy = proxy
        context = WebViewModelContext(proxy: proxy)
        context.start()
    }

    @MainActor
    public convenience init(
        attachingTo webView: WKWebView,
        configuration: WebViewProxy.Configuration = .init()
    ) async throws {
        let proxy = try await WebViewProxy(attachingTo: webView, configuration: configuration)
        self.init(proxy: proxy)
    }

    public func close() async {
        await context.detach()
        await proxy.close()
    }
}
