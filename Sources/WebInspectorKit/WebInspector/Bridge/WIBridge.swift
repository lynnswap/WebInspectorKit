//
//  WebInspectorBridge.swift
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

@MainActor
@Observable
public final class WIBridge {
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

    func makeInspectorWebView() -> WIWebView {
        inspectorModel.makeInspectorWebView()
    }

    func teardownInspectorWebView(_ webView: WIWebView) {
        inspectorModel.teardownInspectorWebView(webView)
    }

    func enqueueMutationBundle(_ rawJSON: String, preserveState: Bool) {
        inspectorModel.enqueueMutationBundle(rawJSON, preserveState: preserveState)
    }

    func updatePreferredDepth(_ depth: Int) {
        inspectorModel.setPreferredDepth(depth)
    }

    func requestDocument(depth: Int, preserveState: Bool) {
        inspectorModel.requestDocument(depth: depth, preserveState: preserveState)
    }

    func attachPageWebView(_ webView: WKWebView?, requestedDepth: Int) {
        errorMessage = nil
        clearDomSelection()
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
                await self.configureAutoUpdate(enabled: true, depth: requestedDepth)
            }
        }
    }

    func detachPageWebView(currentDepth: Int) {
        stopInspection(currentDepth: currentDepth)
        contentModel.webView = nil
        clearDomSelection()
    }

    func reloadInspector(depth: Int, preserveState: Bool) async {
        guard contentModel.webView != nil else {
            errorMessage = "WebView is not available."
            return
        }
        isLoading = true
        errorMessage = nil

        updatePreferredDepth(depth)
        isLoading = false
        requestDocument(depth: depth, preserveState: preserveState)
        await configureAutoUpdate(enabled: true, depth: depth)
    }

    func configureAutoUpdate(enabled: Bool, depth: Int) async {
        await contentModel.setAutoUpdate(enabled: enabled, maxDepth: depth)
    }

    func stopInspection(currentDepth: Int) {
        contentModel.clearWebInspectorHighlight()
        Task {
            await contentModel.cancelSelectionMode()
            await contentModel.setAutoUpdate(enabled: false, maxDepth: currentDepth)
        }
    }

    func beginSelectionMode(currentDepth: Int) async throws -> Int? {
        let result = try await contentModel.beginSelectionMode()
        if result.cancelled {
            return nil
        }
        return max(currentDepth, result.requiredDepth + 1)
    }

    func cancelSelectionMode() async {
        await contentModel.cancelSelectionMode()
    }

    func deleteNode(identifier: Int) async {
        await contentModel.removeNode(identifier: identifier)
    }

    func handleSnapshotFromPage(_ package: WISnapshotPackage) {
        isLoading = false
        enqueueMutationBundle(package.rawJSON, preserveState: true)
    }

    func handleDomUpdateFromPage(_ payload: WIDOMUpdatePayload) {
        isLoading = false
        enqueueMutationBundle(payload.rawJSON, preserveState: true)
    }

    func updateDomSelection(with dictionary: [String: Any]) {
        domSelection.applySnapshot(from: dictionary)
    }

    func clearDomSelection() {
        domSelection.clear()
    }

    func updateDomSelectorPath(nodeId: Int?, selectorPath: String) {
        guard
            let nodeId,
            domSelection.nodeId == nodeId
        else { return }
        domSelection.selectorPath = selectorPath
    }

    func updateAttributeValue(name: String, value: String) {
        guard let nodeId = domSelection.nodeId else { return }
        domSelection.updateAttributeValue(nodeId: nodeId, name: name, value: value)
        Task {
            await contentModel.setAttributeValue(identifier: nodeId, name: name, value: value)
        }
    }
}
