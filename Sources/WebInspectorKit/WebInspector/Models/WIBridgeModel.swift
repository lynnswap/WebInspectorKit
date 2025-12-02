//
//  WIBridgeModel.swift
//  WebInspectorKit
//
//  Created by Kazuki Nakashima on 2025/11/20.
//

import SwiftUI
import WebKit
import Observation

public enum WILifecycleState {
    case attach(WKWebView?)
    case suspend
    case detach
}

@MainActor
@Observable
public final class WIBridgeModel {
    var isLoading = false
    var errorMessage: String?
    var domSelection = WIDOMSelection()
    private(set) var configuration: WebInspectorModel.Configuration
    let contentModel = WIContentModel()
    let inspectorModel = WIInspectorModel()
    @ObservationIgnored private weak var lastPageWebView: WKWebView?

    public init(configuration: WebInspectorModel.Configuration = .init()) {
        self.configuration = configuration
        contentModel.bridge = self
        inspectorModel.bridge = self
    }

    func setLifecycle(_ state: WILifecycleState) {
        switch state {
        case .attach(let webView):
            handleAttach(webView: webView)
        case .suspend:
            handleSuspend()
        case .detach:
            handleSuspend()
            inspectorModel.detachInspectorWebView()
            lastPageWebView = nil
        }
    }

    private func handleAttach(webView: WKWebView?) {
        errorMessage = nil
        domSelection.clear()
        let previousWebView = lastPageWebView
        guard let webView else {
            errorMessage = "WebView is not available."
            contentModel.detachPageWebView()
            lastPageWebView = nil
            return
        }
        let shouldPreserveState = contentModel.webView == nil && previousWebView === webView
        let needsReload = shouldPreserveState || previousWebView !== webView
        contentModel.attachPageWebView(webView)
        lastPageWebView = webView
        Task {
            if needsReload {
                await self.reloadInspector(preserveState: shouldPreserveState)
            }
        }
    }

    private func handleSuspend() {
        isLoading = false
        contentModel.detachPageWebView()
        domSelection.clear()
    }

    func updateSnapshotDepth(_ depth: Int) {
        let clamped = max(1, depth)
        configuration.snapshotDepth = clamped
        inspectorModel.setPreferredDepth(clamped)
    }

    func reloadInspector(preserveState: Bool) async {
        guard contentModel.webView != nil else {
            errorMessage = "WebView is not available."
            return
        }
        isLoading = true
        errorMessage = nil

        let depth = configuration.snapshotDepth
        inspectorModel.setPreferredDepth(depth)
        isLoading = false
        inspectorModel.requestDocument(depth: depth, preserveState: preserveState)
    }

    func handleSnapshotFromPage(_ package: WISnapshotPackage) {
        isLoading = false
        inspectorModel.enqueueMutationBundle(package.rawJSON, preserveState: true)
    }

    func handleDomUpdateFromPage(_ payload: WIDOMUpdatePayload) {
        isLoading = false
        inspectorModel.enqueueMutationBundle(payload.rawJSON, preserveState: true)
    }

    func updateAttributeValue(name: String, value: String) {
        guard let nodeId = domSelection.nodeId else { return }
        domSelection.updateAttributeValue(nodeId: nodeId, name: name, value: value)
        Task {
            await contentModel.setAttributeValue(identifier: nodeId, name: name, value: value)
        }
    }

    func removeAttribute(name: String) {
        guard let nodeId = domSelection.nodeId else { return }
        domSelection.removeAttribute(nodeId: nodeId, name: name)
        Task {
            await contentModel.removeAttribute(identifier: nodeId, name: name)
        }
    }
}
