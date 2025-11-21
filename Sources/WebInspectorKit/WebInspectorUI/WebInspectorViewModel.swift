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
public final class WebInspectorViewModel {
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
#if canImport(UIKit)
    @ObservationIgnored private var scrollBackup: (isScrollEnabled: Bool, isPanEnabled: Bool)?
#endif

    public private(set) var requestedDepth = WebInspectorConstants.defaultDepth
    public private(set) var isSelectingElement = false
    public let webBridge = WebInspectorBridge()

    public var hasPageWebView: Bool {
        webBridge.contentModel.webView != nil
    }

    public init() {}

    public func handleAppear(webView: WKWebView?) {
        webBridge.attachPageWebView(webView, requestedDepth: requestedDepth)
    }

    public func handleDisappear() {
        cancelSelectionMode()
#if canImport(UIKit)
        restorePageScrollingState()
#endif
        webBridge.detachPageWebView(currentDepth: requestedDepth)
    }

    public func reload(maxDepth: Int? = nil) async {
        guard hasPageWebView else {
            webBridge.errorMessage = "WebView is not available."
            return
        }

        requestedDepth = maxDepth ?? requestedDepth
        await webBridge.reloadInspector(depth: requestedDepth, preserveState: false)
    }

    public func toggleSelectionMode() {
        if isSelectingElement {
            cancelSelectionMode()
        } else {
            startSelectionMode()
        }
    }

    public func cancelSelectionMode() {
        guard isSelectingElement || selectionTask != nil else { return }
        selectionTask?.cancel()
        selectionTask = nil
#if canImport(UIKit)
        restorePageScrollingState()
#endif
        Task {
            await webBridge.cancelSelectionMode()
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
        selectionTask = Task {
            defer {
                self.isSelectingElement = false
                self.selectionTask = nil
#if canImport(UIKit)
                self.restorePageScrollingState()
#endif
            }
            do {
                if let targetDepth = try await self.webBridge.beginSelectionMode(currentDepth: self.requestedDepth) {
                    if Task.isCancelled { return }
                    self.requestedDepth = targetDepth
                    await self.webBridge.reloadInspector(depth: targetDepth, preserveState: false)
                }
            } catch is CancellationError {
                await self.webBridge.cancelSelectionMode()
            } catch {
                logger.error("selection mode failed: \(error.localizedDescription, privacy: .public)")
                webBridge.errorMessage = error.localizedDescription
            }
        }
    }

#if canImport(UIKit)
    private func disablePageScrollingForSelection() {
        guard let scrollView = webBridge.contentModel.webView?.scrollView else { return }
        if scrollBackup == nil {
            scrollBackup = (scrollView.isScrollEnabled, scrollView.panGestureRecognizer.isEnabled)
        }
        scrollView.isScrollEnabled = false
        scrollView.panGestureRecognizer.isEnabled = false
    }

    private func restorePageScrollingState() {
        guard let scrollView = webBridge.contentModel.webView?.scrollView else {
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
