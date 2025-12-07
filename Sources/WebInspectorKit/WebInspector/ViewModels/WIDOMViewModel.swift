//
//  WIDOMViewModel.swift
//  WebInspectorKit
//
//  Created by Codex on 2025/03/06.
//

import SwiftUI
import OSLog
import WebKit
import Observation

private let domViewLogger = Logger(subsystem: "WebInspectorKit", category: "WIDOMViewModel")

@MainActor
@Observable
public final class WIDOMViewModel {
    public let session: WIDOMSession
    public let selection: WIDOMSelection
    let inspectorModel: WIInspectorModel

    public private(set) var errorMessage: String?
    public private(set) var isSelectingElement = false

    @ObservationIgnored private var selectionTask: Task<Void, Never>?
#if canImport(UIKit)
    @ObservationIgnored private var scrollBackup: (isScrollEnabled: Bool, isPanEnabled: Bool)?
#endif

    public init(session: WIDOMSession = WIDOMSession()) {
        self.session = session
        self.selection = session.selection
        self.inspectorModel = session.inspectorModel
    }

    public var hasPageWebView: Bool {
        session.hasPageWebView
    }

    public func attach(to webView: WKWebView) {
        resetInteractionState()
        let outcome = session.attach(pageWebView: webView)
        if outcome.shouldReload {
            Task {
                await self.reloadInspector(preserveState: outcome.preserveState)
            }
        }
    }

    public func suspend() {
        resetInteractionState()
        session.suspend()
    }

    public func detach() {
        resetInteractionState()
        session.detach()
        inspectorModel.detachInspectorWebView()
        errorMessage = nil
    }

    public func reloadInspector(preserveState: Bool = false) async {
        guard session.hasPageWebView else {
            errorMessage = String(localized: "dom.error.webview_unavailable", bundle: .module)
            return
        }
        errorMessage = nil

        let depth = session.configuration.snapshotDepth
        inspectorModel.updateConfiguration(session.configuration)
        inspectorModel.setPreferredDepth(depth)
        inspectorModel.requestDocument(depth: depth, preserveState: preserveState)
    }

    public func updateSnapshotDepth(_ depth: Int) {
        let clamped = max(1, depth)
        var configuration = session.configuration
        configuration.snapshotDepth = clamped
        session.updateConfiguration(configuration)
        inspectorModel.updateConfiguration(configuration)
        inspectorModel.setPreferredDepth(clamped)
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
            await session.cancelSelectionMode()
        }
        isSelectingElement = false
    }

    public func copySelection(_ kind: WISelectionCopyKind) {
        guard let nodeId = selection.nodeId else { return }
        Task {
            do {
                let text = try await session.selectionCopyText(
                    for: nodeId,
                    kind: kind
                )
                guard !text.isEmpty else { return }
                copyToPasteboard(text)
            } catch {
                domViewLogger.error("copy \(kind.logLabel, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func deleteSelectedNode() {
        guard let nodeId = selection.nodeId else { return }
        Task {
            await session.removeNode(identifier: nodeId)
        }
    }

    public func updateAttributeValue(name: String, value: String) {
        guard let nodeId = selection.nodeId else { return }
        selection.updateAttributeValue(nodeId: nodeId, name: name, value: value)
        Task {
            await session.updateAttributeValue(identifier: nodeId, name: name, value: value)
        }
    }

    public func removeAttribute(name: String) {
        guard let nodeId = selection.nodeId else { return }
        selection.removeAttribute(nodeId: nodeId, name: name)
        Task {
            await session.removeAttribute(identifier: nodeId, name: name)
        }
    }
}

private extension WIDOMViewModel {
    func startSelectionMode() {
        guard session.hasPageWebView else { return }
#if canImport(UIKit)
        disablePageScrollingForSelection()
#endif
        isSelectingElement = true
        session.clearHighlight()
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
                let result = try await self.session.beginSelectionMode()
                guard !result.cancelled else { return }
                if Task.isCancelled { return }
                let requestedDepth = max(self.session.configuration.snapshotDepth, result.requiredDepth + 1)
                self.updateSnapshotDepth(requestedDepth)
                await self.reloadInspector(preserveState: true)
            } catch is CancellationError {
                await self.session.cancelSelectionMode()
            } catch {
                domViewLogger.error("selection mode failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        }
    }

    func resetInteractionState() {
        cancelSelectionMode()
#if canImport(UIKit)
        restorePageScrollingState()
#endif
    }

    func copyToPasteboard(_ text: String) {
#if canImport(UIKit)
        UIPasteboard.general.string = text
#elseif canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
#endif
    }

#if canImport(UIKit)
    func disablePageScrollingForSelection() {
        guard let scrollView = session.pageWebView?.scrollView else { return }
        if scrollBackup == nil {
            scrollBackup = (scrollView.isScrollEnabled, scrollView.panGestureRecognizer.isEnabled)
        }
        scrollView.isScrollEnabled = false
        scrollView.panGestureRecognizer.isEnabled = false
    }

    func restorePageScrollingState() {
        guard let scrollView = session.pageWebView?.scrollView else {
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
