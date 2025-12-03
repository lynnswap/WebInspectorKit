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
    public struct Configuration {
        /// Maximum DOM depth captured in the initial/full document snapshot.
        public var snapshotDepth: Int
        /// Depth used when requesting child subtrees (DOM.requestChildNodes).
        public var subtreeDepth: Int
        /// Debounce window (seconds) for automatic DOM snapshot updates.
        public var autoUpdateDebounce: TimeInterval

        public init(
            snapshotDepth: Int = 4,
            subtreeDepth: Int = 3,
            autoUpdateDebounce: TimeInterval = 0.6
        ) {
            self.snapshotDepth = max(1, snapshotDepth)
            self.subtreeDepth = max(1, subtreeDepth)
            self.autoUpdateDebounce = max(0, autoUpdateDebounce)
        }
    }

    @ObservationIgnored private var selectionTask: Task<Void, Never>?
#if canImport(UIKit)
    @ObservationIgnored private var scrollBackup: (isScrollEnabled: Bool, isPanEnabled: Bool)?
#endif

    public private(set) var configuration: Configuration
    public var errorMessage: String?
    public private(set) var isSelectingElement = false
    public var selectedTab: WITab? = nil

    let domAgent: WIDOMAgentModel
    let networkAgent: WINetworkAgentModel
    let inspectorModel: WIInspectorModel

    @ObservationIgnored private weak var lastPageWebView: WKWebView?

    public var hasPageWebView: Bool {
        domAgent.webView != nil
    }

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        let domAgent = WIDOMAgentModel(configuration: configuration)
        let networkAgent = WINetworkAgentModel()
        let inspectorModel = WIInspectorModel(configuration: configuration)

        self.domAgent = domAgent
        self.networkAgent = networkAgent
        self.inspectorModel = inspectorModel

        domAgent.inspector = inspectorModel
        domAgent.owner = self
        inspectorModel.domAgent = domAgent
    }

    public func attach(webView: WKWebView?) {
        handleAttach(webView: webView)
    }

    public func suspend() {
        handleSuspend(detachInspector: false)
    }

    public func detach() {
        handleSuspend(detachInspector: true)
        inspectorModel.detachInspectorWebView()
        lastPageWebView = nil
    }

    public func copySelection(_ kind: WISelectionCopyKind) {
        performCopy(kind)
    }

    public func deleteSelectedNode() {
        guard let nodeId = domAgent.selection.nodeId else { return }
        Task {
            await domAgent.removeNode(identifier: nodeId)
        }
    }

    public func updateAttributeValue(name: String, value: String) {
        guard let nodeId = domAgent.selection.nodeId else { return }
        domAgent.selection.updateAttributeValue(nodeId: nodeId, name: name, value: value)
        Task {
            await domAgent.updateAttributeValue(identifier: nodeId, name: name, value: value)
        }
    }

    public func removeAttribute(name: String) {
        guard let nodeId = domAgent.selection.nodeId else { return }
        domAgent.selection.removeAttribute(nodeId: nodeId, name: name)
        Task {
            await domAgent.removeAttribute(identifier: nodeId, name: name)
        }
    }

    public func reload() async {
        guard hasPageWebView else {
            errorMessage = "WebView is not available."
            return
        }

        await reloadInspector(preserveState: false)
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
            await domAgent.cancelSelectionMode()
        }
        isSelectingElement = false
    }

    public func updateSnapshotDepth(_ depth: Int) {
        let clamped = max(1, depth)
        configuration.snapshotDepth = clamped
        domAgent.updateConfiguration(configuration)
        inspectorModel.updateConfiguration(configuration)
        inspectorModel.setPreferredDepth(clamped)
    }

    public func setNetworkRecording(_ enabled: Bool) {
        networkAgent.setRecording(enabled)
    }

    public func clearNetworkLogs() {
        networkAgent.clearNetworkLogs()
    }

    private func startSelectionMode() {
        guard hasPageWebView else { return }
#if canImport(UIKit)
        disablePageScrollingForSelection()
#endif
        isSelectingElement = true
        domAgent.clearWebInspectorHighlight()
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
                let result = try await self.domAgent.beginSelectionMode()
                guard !result.cancelled else { return }
                if Task.isCancelled { return }
                let requestedDepth = max(self.configuration.snapshotDepth, result.requiredDepth + 1)
                self.updateSnapshotDepth(requestedDepth)
                await self.reloadInspector(preserveState: true)
            } catch is CancellationError {
                await self.domAgent.cancelSelectionMode()
            } catch {
                logger.error("selection mode failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performCopy(_ kind: WISelectionCopyKind) {
        guard let nodeId = domAgent.selection.nodeId else { return }
        Task { @MainActor in
            do {
                let text = try await domAgent.selectionCopyText(for: nodeId, kind: kind)
                guard !text.isEmpty else { return }
                copyToPasteboard(text)
            } catch {
                logger.error("copy \(kind.logLabel, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func reloadInspector(preserveState: Bool) async {
        guard domAgent.webView != nil else {
            errorMessage = "WebView is not available."
            return
        }
        errorMessage = nil

        let depth = configuration.snapshotDepth
        inspectorModel.updateConfiguration(configuration)
        inspectorModel.setPreferredDepth(depth)
        inspectorModel.requestDocument(depth: depth, preserveState: preserveState)
    }

    private func handleAttach(webView: WKWebView?) {
        resetInteractionState()
        errorMessage = nil
        domAgent.selection.clear()
        networkAgent.store.reset()

        let previousWebView = lastPageWebView
        guard let webView else {
            errorMessage = "WebView is not available."
            domAgent.detachPageWebView()
            networkAgent.detachPageWebView(disableNetworkLogging: true)
            lastPageWebView = nil
            return
        }
        let shouldPreserveState = domAgent.webView == nil && previousWebView === webView
        let needsReload = shouldPreserveState || previousWebView !== webView
        domAgent.attachPageWebView(webView)
        networkAgent.attachPageWebView(webView)
        lastPageWebView = webView
        Task {
            if needsReload {
                await self.reloadInspector(preserveState: shouldPreserveState)
            }
        }
    }

    private func handleSuspend(detachInspector: Bool) {
        domAgent.detachPageWebView()
        networkAgent.store.reset()
        networkAgent.detachPageWebView(disableNetworkLogging: true)
        domAgent.selection.clear()
        if detachInspector {
            inspectorModel.detachInspectorWebView()
        }
    }

    private func resetInteractionState() {
        cancelSelectionMode()
#if canImport(UIKit)
        restorePageScrollingState()
#endif
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
        guard let scrollView = domAgent.webView?.scrollView else { return }
        if scrollBackup == nil {
            scrollBackup = (scrollView.isScrollEnabled, scrollView.panGestureRecognizer.isEnabled)
        }
        scrollView.isScrollEnabled = false
        scrollView.panGestureRecognizer.isEnabled = false
    }

    private func restorePageScrollingState() {
        guard let scrollView = domAgent.webView?.scrollView else {
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
