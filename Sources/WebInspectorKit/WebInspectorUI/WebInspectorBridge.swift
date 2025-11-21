//
//  WebInspectorBridge.swift
//  WebInspectorKit
//
//  Created by Kazuki Nakashima on 2025/11/20.
//

import SwiftUI
import OSLog
import WebKit
import Observation

private let bridgeLogger = Logger(subsystem: "WebInspectorKit", category: "WebInspectorBridge")

enum WebInspectorConstants {
    static let defaultDepth = 4
    static let subtreeDepth = 3
    static let autoUpdateDebounce: TimeInterval = 0.6
}

@MainActor
@Observable
final class WebInspectorBridge {
    struct PendingBundle {
        let rawJSON: String
        let preserveState: Bool
    }

    var isLoading = false
    var errorMessage: String?
    let contentModel = WebInspectorContentModel()

    @ObservationIgnored private(set) var inspectorWebView: WKWebView?
    @ObservationIgnored private lazy var coordinator = WebInspectorCoordinator(bridge: self)

    init() {
        contentModel.bridge = self
    }

    func makeInspectorWebView() -> WKWebView {
        if let inspectorWebView {
            coordinator.attach(webView: inspectorWebView)
            return inspectorWebView
        }

        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)

#if DEBUG
        webView.isInspectable = true
#endif

#if canImport(UIKit)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.alwaysBounceVertical = true
#endif

        inspectorWebView = webView
        coordinator.attach(webView: webView)
        loadInspector(in: webView)
        return webView
    }

    func teardownInspectorWebView(_ webView: WKWebView) {
        coordinator.detach(webView: webView)
    }

    private func loadInspector(in webView: WKWebView) {
        guard
            let mainURL = WebInspectorAssets.mainFileURL,
            let baseURL = WebInspectorAssets.resourcesDirectory
        else {
            bridgeLogger.error("missing inspector resources")
            return
        }
        webView.loadFileURL(mainURL, allowingReadAccessTo: baseURL)
    }

    func enqueueMutationBundle(_ rawJSON: String, preserveState: Bool) {
        let payload = PendingBundle(rawJSON: rawJSON, preserveState: preserveState)
        coordinator.applyMutationBundle(payload)
    }

    func updateSearchTerm(_ term: String) {
        coordinator.updateSearchTerm(term)
    }

    func updatePreferredDepth(_ depth: Int) {
        coordinator.setPreferredDepth(depth)
    }

    func requestDocument(depth: Int, preserveState: Bool) {
        coordinator.requestDocument(depth: depth, preserveState: preserveState)
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
