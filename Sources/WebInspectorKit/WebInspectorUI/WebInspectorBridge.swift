//
//  WebInspectorBridge.swift
//  WebInspectorKit
//
//  Created by Kazuki Nakashima on 2025/11/20.
//

import SwiftUI
import WebKit
import Observation

enum WebInspectorConstants {
    static let defaultDepth = 4
    static let subtreeDepth = 3
    static let autoUpdateDebounce: TimeInterval = 0.6
}

@MainActor
@Observable
final class WebInspectorBridge {
    var isLoading = false
    var errorMessage: String?
    let contentModel = WebInspectorContentModel()
    let inspectorModel = WebInspectorInspectorModel()
    @ObservationIgnored private weak var lastPageWebView: WKWebView?

    init() {
        contentModel.bridge = self
        inspectorModel.bridge = self
    }

    func makeInspectorWebView() -> WKWebView {
        inspectorModel.makeInspectorWebView()
    }

    func teardownInspectorWebView(_ webView: WKWebView) {
        inspectorModel.teardownInspectorWebView(webView)
    }

    func enqueueMutationBundle(_ rawJSON: String, preserveState: Bool) {
        inspectorModel.enqueueMutationBundle(rawJSON, preserveState: preserveState)
    }

    func updateSearchTerm(_ term: String) {
        inspectorModel.updateSearchTerm(term)
    }

    func updatePreferredDepth(_ depth: Int) {
        inspectorModel.setPreferredDepth(depth)
    }

    func requestDocument(depth: Int, preserveState: Bool) {
        inspectorModel.requestDocument(depth: depth, preserveState: preserveState)
    }

    func attachPageWebView(_ webView: WKWebView?, requestedDepth: Int) {
        errorMessage = nil
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
        lastPageWebView = nil
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

    func handleSnapshotFromPage(_ package: WebInspectorSnapshotPackage) {
        isLoading = false
        enqueueMutationBundle(package.rawJSON, preserveState: true)
    }

    func handleDomUpdateFromPage(_ payload: WebInspectorDOMUpdatePayload) {
        isLoading = false
        enqueueMutationBundle(payload.rawJSON, preserveState: true)
    }
}
