//
//  WebInspectorViewModel.swift
//  WebInspectorKit
//
//  Created by Kazuki Nakashima on 2025/11/20.
//

import SwiftUI
import OSLog
import WebKit
import Observation

private let logger = Logger(subsystem: "WebInspectorKit", category: "WebInspectorViewModel")

@MainActor
@Observable
final class WebInspectorViewModel {
    @ObservationIgnored private weak var currentPageWebView: WKWebView?
    @ObservationIgnored private weak var lastWebView: WKWebView?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
#if canImport(UIKit)
    @ObservationIgnored private var scrollBackup: (isScrollEnabled: Bool, isPanEnabled: Bool)?
#endif

    var requestedDepth = WebInspectorConstants.defaultDepth
    var isSelectingElement = false
    var webBridge = WebInspectorBridge()

    var hasPageWebView: Bool {
        webBridge.contentModel.pageWebView != nil
    }

    func handleAppear(webView: WKWebView?) {
        webBridge.errorMessage = nil
        guard let webView else {
            currentPageWebView = nil
            webBridge.contentModel.pageWebView = nil
            webBridge.errorMessage = "WebView is not available."
            return
        }

        let previousWebView = lastWebView
        currentPageWebView = webView
        webBridge.contentModel.pageWebView = webView
        lastWebView = webView

        let needsReload = previousWebView == nil || previousWebView != webView
        if needsReload {
            Task { await reload() }
        } else {
            setAutoUpdateState(true)
        }
    }

    func handleDisappear() {
        webBridge.contentModel.clearWebInspectorHighlight()
        cancelSelectionMode()
        setAutoUpdateState(false)
#if canImport(UIKit)
        restorePageScrollingState()
#endif
        if let currentPageWebView {
            lastWebView = currentPageWebView
        }
        webBridge.contentModel.pageWebView = nil
        currentPageWebView = nil
    }

    func reload(maxDepth: Int? = nil) async {
        guard hasPageWebView else {
            webBridge.errorMessage = "WebView is not available."
            return
        }

        webBridge.isLoading = true
        webBridge.errorMessage = nil

        requestedDepth = maxDepth ?? requestedDepth
        webBridge.updatePreferredDepth(requestedDepth)
        webBridge.isLoading = false
        webBridge.requestDocument(depth: requestedDepth, preserveState: false)
        setAutoUpdateState(true)
    }

    func toggleSelectionMode() {
        if isSelectingElement {
            cancelSelectionMode()
        } else {
            startSelectionMode()
        }
    }

    func cancelSelectionMode() {
        guard isSelectingElement || selectionTask != nil else { return }
        selectionTask?.cancel()
        selectionTask = nil
#if canImport(UIKit)
        restorePageScrollingState()
#endif
        Task { @MainActor [webBridge] in
            await webBridge.contentModel.cancelSelectionMode()
        }
        isSelectingElement = false
    }

    private func startSelectionMode() {
        guard hasPageWebView else { return }
#if canImport(UIKit)
        disablePageScrollingForSelection()
#endif
        isSelectingElement = true
        webBridge.contentModel.clearWebInspectorHighlight()
        selectionTask?.cancel()
        selectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isSelectingElement = false
                self.selectionTask = nil
#if canImport(UIKit)
                self.restorePageScrollingState()
#endif
            }
            do {
                let result = try await self.webBridge.contentModel.beginSelectionMode()
                if Task.isCancelled || result.cancelled {
                    return
                }
                let depth = max(self.requestedDepth, result.requiredDepth + 1)
                await self.reload(maxDepth: depth)
            } catch is CancellationError {
                await self.webBridge.contentModel.cancelSelectionMode()
            } catch {
                logger.error("selection mode failed: \(error.localizedDescription, privacy: .public)")
                webBridge.errorMessage = error.localizedDescription
            }
        }
    }

    private func setAutoUpdateState(_ enabled: Bool) {
        guard webBridge.contentModel.pageWebView != nil else { return }
        let depth = requestedDepth
        Task { @MainActor [webBridge] in
            await webBridge.contentModel.setAutoUpdate(enabled: enabled, maxDepth: depth)
        }
    }

#if canImport(UIKit)
    private func disablePageScrollingForSelection() {
        guard let scrollView = currentPageWebView?.scrollView else { return }
        if scrollBackup == nil {
            scrollBackup = (scrollView.isScrollEnabled, scrollView.panGestureRecognizer.isEnabled)
        }
        scrollView.isScrollEnabled = false
        scrollView.panGestureRecognizer.isEnabled = false
    }

    private func restorePageScrollingState() {
        guard let scrollView = currentPageWebView?.scrollView else {
            scrollBackup = nil
            return
        }
        if let backup = scrollBackup {
            scrollView.isScrollEnabled = backup.isScrollEnabled
            scrollView.panGestureRecognizer.isEnabled = backup.isPanEnabled
        }
        scrollBackup = nil
    }
#endif
}
