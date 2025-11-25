//
//  WebInspectorModel.swift
//  WebInspectorKit
//
//  Created by Kazuki Nakashima on 2025/11/20.
//

import SwiftUI
import OSLog
import WebKit
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private let logger = Logger(subsystem: "WebInspectorKit", category: "WebInspectorModel")

@MainActor
@Observable
public final class WebInspectorModel {
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
#if canImport(UIKit)
    @ObservationIgnored private var scrollBackup: (isScrollEnabled: Bool, isPanEnabled: Bool)?
#endif

    public private(set) var requestedDepth = WIConstants.defaultDepth
    public private(set) var isSelectingElement = false
    public let webBridge = WIBridgeModel()
    public var selectedTabIdentifier: String? = nil

    public var hasPageWebView: Bool {
        webBridge.contentModel.webView != nil
    }

    public init() {}

    public func attach(webView: WKWebView?) {
        updateLifecycle(.attach(webView))
    }

    public func suspend() {
        updateLifecycle(.suspend)
    }

    public func detach() {
        updateLifecycle(.detach)
    }
    
    public func updateLifecycle(_ state: WILifecycleState) {
        switch state {
        case .attach(let webView):
            webBridge.setLifecycle(.attach(webView), requestedDepth: requestedDepth)
        case .suspend:
            resetInteractionState()
            webBridge.setLifecycle(.suspend, requestedDepth: requestedDepth)
        case .detach:
            resetInteractionState()
            webBridge.setLifecycle(.detach, requestedDepth: requestedDepth)
        }
    }

    private func resetInteractionState() {
        cancelSelectionMode()
#if canImport(UIKit)
        restorePageScrollingState()
#endif
    }

    public func copySelection(_ kind: WISelectionCopyKind) {
        performCopy(kind)
    }

    public func deleteSelectedNode() {
        guard let nodeId = webBridge.domSelection.nodeId else { return }
        Task {
            await webBridge.contentModel.removeNode(identifier: nodeId)
        }
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
        selectionTask = Task {
            defer {
                self.isSelectingElement = false
                self.selectionTask = nil
#if canImport(UIKit)
                self.restorePageScrollingState()
#endif
            }
            do {
                let result = try await self.webBridge.contentModel.beginSelectionMode()
                guard !result.cancelled else { return }
                if Task.isCancelled { return }
                let targetDepth = max(self.requestedDepth, result.requiredDepth + 1)
                self.requestedDepth = targetDepth
                await self.webBridge.reloadInspector(depth: targetDepth, preserveState: true)
            } catch is CancellationError {
                await self.webBridge.contentModel.cancelSelectionMode()
            } catch {
                logger.error("selection mode failed: \(error.localizedDescription, privacy: .public)")
                webBridge.errorMessage = error.localizedDescription
            }
        }
    }

    private func performCopy(_ kind: WISelectionCopyKind) {
        guard let nodeId = webBridge.domSelection.nodeId else { return }
        Task { @MainActor in
            do {
                let text = try await webBridge.contentModel.selectionCopyText(for: nodeId, kind: kind)
                guard !text.isEmpty else { return }
                copyToPasteboard(text)
            } catch {
                logger.error("copy \(kind.logLabel, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
#if canImport(UIKit)
        UIPasteboard.general.string = text
#elseif canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
#endif
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
