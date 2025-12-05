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

    public var hasPageWebView: Bool {
        dom.hasPageWebView
    }

    public var isSelectingElement: Bool {
        dom.isSelectingElement
    }

    public var errorMessage: String? {
        dom.errorMessage
    }

    public var selection: WIDOMSelection {
        dom.selection
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

    public func reloadInspector() async {
        await dom.reloadInspector()
    }

    public func updateSnapshotDepth(_ depth: Int) {
        dom.updateSnapshotDepth(depth)
    }

    public func toggleSelectionMode() {
        dom.toggleSelectionMode()
    }

    public func cancelSelectionMode() {
        dom.cancelSelectionMode()
    }

    public func copySelection(_ kind: WISelectionCopyKind) {
        dom.copySelection(kind)
    }

    public func deleteSelectedNode() {
        dom.deleteSelectedNode()
    }

    public func updateAttributeValue(name: String, value: String) {
        dom.updateAttributeValue(name: name, value: value)
    }

    public func removeAttribute(name: String) {
        dom.removeAttribute(name: name)
    }

    public func setNetworkRecording(_ enabled: Bool) {
        network.setRecording(enabled)
    }

    public func clearNetworkLogs() {
        network.clearNetworkLogs()
    }
}
