//
//  WINetworkViewModel.swift
//  WebInspectorKit
//
//  Created by Codex on 2025/03/06.
//

import WebKit
import Observation

@MainActor
@Observable
public final class WINetworkViewModel {
    public let session: WINetworkSession
    public var selectedEntryID: String?
    public var store: WINetworkStore {
        session.store
    }

    public init(session: WINetworkSession = WINetworkSession()) {
        self.session = session
    }

    public func attach(to webView: WKWebView) {
        session.attach(pageWebView: webView)
    }

    public func setRecording(_ enabled: Bool) {
        session.setRecording(enabled)
    }

    public func clearNetworkLogs() {
        selectedEntryID = nil
        session.clearNetworkLogs()
    }

    public func suspend() {
        session.suspend()
    }

    public func detach() {
        session.detach()
    }
}
