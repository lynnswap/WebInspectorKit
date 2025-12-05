//
//  WebInspectorModel.swift
//  WebInspectorKit
//
//  Created by Codex on 2025/03/06.
//

import SwiftUI
import WebKit
import Observation

@MainActor
@Observable
public final class WebInspectorModel {
    public var selectedTab: WITab? = nil

    public let dom: WIDOMViewModel
    public let network: WINetworkViewModel

    public init(configuration: WebInspectorConfiguration = .init()) {
        self.dom = WIDOMViewModel(session: WIDOMSession(configuration: configuration))
        self.network = WINetworkViewModel(session: WINetworkSession())
    }

    public func attach(webView: WKWebView?) {
        if let webView {
            dom.attach(to: webView)
            network.attach(to: webView)
        } else {
            dom.suspend()
            network.suspend()
        }
    }

    public func suspend() {
        dom.suspend()
        network.suspend()
    }

    public func detach() {
        dom.detach()
        network.detach()
    }
}
