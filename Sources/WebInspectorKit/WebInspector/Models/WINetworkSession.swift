//
//  WINetworkSession.swift
//  WebInspectorKit
//
//  Created by Codex on 2025/03/06.
//

import WebKit

@MainActor
public final class WINetworkSession {
    let networkAgent: WINetworkAgentModel
    private weak var lastPageWebView: WKWebView?

    public init() {
        self.networkAgent = WINetworkAgentModel()
    }

    public func attach(pageWebView webView: WKWebView) {
        let previousWebView = lastPageWebView
        if previousWebView !== webView {
            networkAgent.store.reset()
        }
        networkAgent.attachPageWebView(webView)
        lastPageWebView = webView
    }

    public func suspend() {
        networkAgent.store.reset()
        networkAgent.detachPageWebView(disableNetworkLogging: true)
    }

    public func detach() {
        suspend()
        lastPageWebView = nil
    }
}
