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

public enum WILifecycleState {
    case attach(WKWebView?)
    case suspend
    case detach
}

@MainActor
@Observable
public final class WIBridge {
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
        contentModel.errorMessage = nil
        clearDomSelection()
        let previousWebView = lastPageWebView
        contentModel.webView = webView
        guard let webView else {
            contentModel.errorMessage = "WebView is not available."
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

    private func handleSuspend(currentDepth: Int) {
        stopInspection(currentDepth: currentDepth)
        contentModel.isLoading = false
        contentModel.webView = nil
        clearDomSelection()
    }

    func reloadInspector(depth: Int, preserveState: Bool) async {
        guard contentModel.webView != nil else {
            contentModel.errorMessage = "WebView is not available."
            return
        }
        contentModel.isLoading = true
        contentModel.errorMessage = nil

        inspectorModel.setPreferredDepth(depth)
        contentModel.isLoading = false
        inspectorModel.requestDocument(depth: depth, preserveState: preserveState)
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

    func handleSnapshotFromPage(_ package: WISnapshotPackage) {
        contentModel.isLoading = false
        inspectorModel.enqueueMutationBundle(package.rawJSON, preserveState: true)
    }

    func handleDomUpdateFromPage(_ payload: WIDOMUpdatePayload) {
        contentModel.isLoading = false
        inspectorModel.enqueueMutationBundle(payload.rawJSON, preserveState: true)
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

    func removeAttribute(name: String) {
        guard let nodeId = domSelection.nodeId else { return }
        domSelection.removeAttribute(nodeId: nodeId, name: name)
        Task {
            await contentModel.removeAttribute(identifier: nodeId, name: name)
        }
    }
}
