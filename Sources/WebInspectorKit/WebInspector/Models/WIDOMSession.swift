//
//  WIDOMSession.swift
//  WebInspectorKit
//
//  Created by Codex on 2025/03/06.
//

import WebKit

@MainActor
public final class WIDOMSession {
    public private(set) var configuration: WebInspectorConfiguration

    let domAgent: WIDOMAgentModel

    private weak var lastPageWebView: WKWebView?

    public var hasPageWebView: Bool {
        domAgent.webView != nil
    }

    public init(configuration: WebInspectorConfiguration = .init()) {
        self.configuration = configuration
        let domAgent = WIDOMAgentModel(configuration: configuration)
        self.domAgent = domAgent
    }

    public func updateConfiguration(_ configuration: WebInspectorConfiguration) {
        self.configuration = configuration
        domAgent.updateConfiguration(configuration)
    }

    public func attach(
        pageWebView webView: WKWebView
    ) -> (shouldReload: Bool, preserveState: Bool) {
        domAgent.selection.clear()

        let previousWebView = lastPageWebView
        let shouldPreserveState = domAgent.webView == nil && previousWebView === webView
        let needsReload = shouldPreserveState || previousWebView !== webView
        domAgent.attachPageWebView(webView)
        lastPageWebView = webView

        return (needsReload, shouldPreserveState)
    }

    public func suspend() {
        domAgent.detachPageWebView()
        domAgent.selection.clear()
    }

    public func detach() {
        suspend()
        lastPageWebView = nil
    }
}
