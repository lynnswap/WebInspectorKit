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

    func handleSnapshotFromPage(_ package: WebInspectorSnapshotPackage) {
        isLoading = false
        enqueueMutationBundle(package.rawJSON, preserveState: true)
    }

    func handleDomUpdateFromPage(_ payload: WebInspectorDOMUpdatePayload) {
        isLoading = false
        enqueueMutationBundle(payload.rawJSON, preserveState: true)
    }
}
