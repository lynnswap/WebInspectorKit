//
//  WIBridgeModel.swift
//  WebInspectorKit
//
//  Created by Kazuki Nakashima on 2025/11/20.
//

import SwiftUI
import WebKit
import Observation

enum WIConstants {
    static let defaultDepth = 4
    static let subtreeDepth = 3
    static let autoUpdateDebounce: TimeInterval = 0.6
}

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
    let contentModel = WIContentModel()
    let inspectorModel = WIInspectorModel()
    @ObservationIgnored private weak var lastPageWebView: WKWebView?

    public init() {
        contentModel.bridge = self
        inspectorModel.bridge = self
    }

    func setLifecycle(_ state: WILifecycleState, requestedDepth: Int) {
        switch state {
        case .attach(let webView):
            handleAttach(webView: webView, requestedDepth: requestedDepth)
        case .suspend:
            handleSuspend(currentDepth: requestedDepth)
        case .detach:
            handleSuspend(currentDepth: requestedDepth)
            inspectorModel.detachInspectorWebView()
            lastPageWebView = nil
        }
    }

    private func handleAttach(webView: WKWebView?, requestedDepth: Int) {
        errorMessage = nil
        domSelection.clear()
        let previousWebView = lastPageWebView
        contentModel.webView = webView
        guard let webView else {
            errorMessage = "WebView is not available."
            return
        }
        let needsReload = previousWebView == nil || previousWebView != webView
        lastPageWebView = webView
        Task {
            if needsReload {
                await self.reloadInspector(depth: requestedDepth, preserveState: false)
            } else {
                await self.contentModel.setAutoUpdate(enabled: true, maxDepth: requestedDepth)
            }
        }
    }

    private func handleSuspend(currentDepth: Int) {
        contentModel.stopInspection(maxDepth: currentDepth)
        isLoading = false
        contentModel.webView = nil
        domSelection.clear()
    }

    func reloadInspector(depth: Int, preserveState: Bool) async {
        guard contentModel.webView != nil else {
            errorMessage = "WebView is not available."
            return
        }
        isLoading = true
        errorMessage = nil

        inspectorModel.setPreferredDepth(depth)
        isLoading = false
        inspectorModel.requestDocument(depth: depth, preserveState: preserveState)
        await contentModel.setAutoUpdate(enabled: true, maxDepth: depth)
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
