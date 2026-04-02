import WebKit

package struct DOMPageContext: Equatable, Sendable {
    package let pageEpoch: Int
    package let documentScopeID: DOMDocumentScopeID
}

package enum DOMMutationExecutionResult<Payload: Sendable>: Sendable {
    case applied(Payload)
    case ignoredStaleContext
    case failed
}

@MainActor
package final class DOMSession {
    package typealias AttachmentResult = (
        shouldReload: Bool,
        shouldPreserveInspectorState: Bool,
        observedPageContext: DOMPageContext?
    )

    package private(set) var configuration: DOMConfiguration

    package private(set) weak var lastPageWebView: WKWebView?
    private let pageAgent: DOMPageAgent
    private var autoSnapshotEnabled = false
    private var preparedPageEpoch = 0
    private var preparedDocumentScopeID: DOMDocumentScopeID = 0

#if DEBUG
    package var testRemoveNodeOverride: (@MainActor (
        _ nodeId: Int,
        _ expectedPageEpoch: Int?,
        _ expectedDocumentScopeID: DOMDocumentScopeID?
    ) async -> DOMMutationExecutionResult<Void>)?
    package var testUndoRemoveNodeInterposer: (@MainActor (
        _ undoToken: Int,
        _ expectedPageEpoch: Int?,
        _ expectedDocumentScopeID: DOMDocumentScopeID?,
        _ perform: @escaping @MainActor @Sendable () async -> DOMMutationExecutionResult<Void>
    ) async -> DOMMutationExecutionResult<Void>)?
    package var testRedoRemoveNodeInterposer: (@MainActor (
        _ undoToken: Int,
        _ nodeId: Int?,
        _ expectedPageEpoch: Int?,
        _ expectedDocumentScopeID: DOMDocumentScopeID?,
        _ perform: @escaping @MainActor @Sendable () async -> DOMMutationExecutionResult<Void>
    ) async -> DOMMutationExecutionResult<Void>)?
    package var testHighlightOverride: (@MainActor (Int) async -> Void)?
    package var testHideHighlightOverride: (@MainActor () async -> Void)?
#endif

    var isAutoSnapshotEnabled: Bool {
        autoSnapshotEnabled
    }

    package var bridgeMode: WIBridgeMode {
        pageAgent.currentBridgeMode
    }

    package weak var bundleSink: (any DOMBundleSink)? {
        didSet {
            pageAgent.sink = bundleSink
        }
    }

    package init(configuration: DOMConfiguration = .init()) {
        self.configuration = configuration
        pageAgent = DOMPageAgent(configuration: configuration)
    }

    package func updateConfiguration(_ configuration: DOMConfiguration) async {
        self.configuration = configuration
        pageAgent.updateConfiguration(configuration)
        if autoSnapshotEnabled {
            await pageAgent.setAutoSnapshot(enabled: true)
        }
    }

    package var pageWebView: WKWebView? {
        pageAgent.webView
    }

    package var hasPageWebView: Bool {
        pageAgent.webView != nil
    }

    @discardableResult
    package func attach(to webView: WKWebView) async -> AttachmentResult {
        if pageAgent.webView === webView {
            lastPageWebView = webView
            let observedPageContext = await readObservedPageContextIfNewer(on: webView)
            if autoSnapshotEnabled {
                await pageAgent.setAutoSnapshot(enabled: true)
            }
            return (false, false, observedPageContext)
        }

        if let attachedWebView = pageAgent.webView, attachedWebView !== webView {
            await pageAgent.detachPageWebViewAndWaitForCleanup()
        }

        let previousWebView = lastPageWebView
        let shouldPreserveState = pageAgent.webView == nil && previousWebView === webView
        let shouldReload = shouldPreserveState || previousWebView !== webView
        pageAgent.attachPageWebView(webView)
        await pageAgent.ensureDOMAgentScriptInstalled(
            on: webView,
            pageEpoch: preparedPageEpoch,
            documentScopeID: preparedDocumentScopeID
        )
        let observedPageContext = await readObservedPageContextIfNewer(on: webView)
        lastPageWebView = webView

        if autoSnapshotEnabled {
            await pageAgent.setAutoSnapshot(enabled: true)
        }

        return (shouldReload, shouldPreserveState, observedPageContext)
    }

    private func readObservedPageContextIfNewer(on webView: WKWebView) async -> DOMPageContext? {
        guard let refreshedPageContext = await pageAgent.readPageContext(on: webView),
              shouldAdoptObservedPageContext(refreshedPageContext),
              pageAgent.webView === webView
        else {
            return nil
        }
        pageAgent.commitPageContext(refreshedPageContext, on: webView)
        pageAgent.cancelPreparedPageContextSync()
        preparedPageEpoch = refreshedPageContext.pageEpoch
        preparedDocumentScopeID = refreshedPageContext.documentScopeID
        return refreshedPageContext
    }

    private func shouldAdoptObservedPageContext(_ pageContext: DOMPageContext) -> Bool {
        if pageContext.pageEpoch > preparedPageEpoch {
            return true
        }
        if pageContext.pageEpoch < preparedPageEpoch {
            return false
        }
        return pageContext.documentScopeID > preparedDocumentScopeID
    }

    package func suspend() async {
        await pageAgent.detachPageWebViewAndWaitForCleanup()
    }

    package func detach() async {
        await suspend()
        lastPageWebView = nil
    }

    package func reloadPage() {
        pageAgent.reloadPage()
    }

    package func reloadPageAndWaitForPreparedPageEpochSync() async {
        await pageAgent.reloadPageAndWaitForPreparedPageEpochSync(
            preparedPageEpoch,
            documentScopeID: preparedDocumentScopeID
        )
        if autoSnapshotEnabled, pageAgent.webView != nil {
            await pageAgent.setAutoSnapshot(enabled: true)
        }
    }

    package func setAutoSnapshot(enabled: Bool) async {
        autoSnapshotEnabled = enabled
        guard pageAgent.webView != nil else {
            return
        }
        await pageAgent.setAutoSnapshot(enabled: enabled)
    }

    package func preparePageEpoch(_ epoch: Int) {
        preparedPageEpoch = epoch
    }

    package func prepareDocumentScopeID(_ scopeID: DOMDocumentScopeID) {
        preparedDocumentScopeID = scopeID
    }

    package func syncCurrentDocumentScopeIDIfNeeded(
        _ scopeID: DOMDocumentScopeID,
        expectedPageEpoch: Int? = nil
    ) async -> Bool {
        preparedDocumentScopeID = scopeID
        guard let webView = pageAgent.webView else {
            return false
        }
        await pageAgent.ensureDOMAgentScriptInstalled(on: webView)
        return await pageAgent.syncDocumentScopeIDIfNeeded(
            scopeID,
            on: webView,
            expectedPageEpoch: expectedPageEpoch
        )
    }

    package func tearDownForDeinit() {
        pageAgent.tearDownForDeinit()
        lastPageWebView = nil
        autoSnapshotEnabled = false
    }

    package var currentPageContext: DOMPageContext {
        pageAgent.currentPageContext
    }
}

// MARK: - Snapshot API (for DOMTreeView)

extension DOMSession {
    package func captureSnapshot(maxDepth: Int) async throws -> String {
        try await pageAgent.captureSnapshot(maxDepth: maxDepth)
    }

    package func captureSubtree(nodeId: Int, maxDepth: Int) async throws -> String {
        try await pageAgent.captureSubtree(nodeId: nodeId, maxDepth: maxDepth)
    }

    package func matchedStyles(nodeId: Int, maxRules: Int = 0) async throws -> DOMMatchedStylesPayload {
        try await pageAgent.matchedStyles(nodeId: nodeId, maxRules: maxRules)
    }
}

// MARK: - Snapshot API (bridge/object)

extension DOMSession {
    package func captureSnapshotPayload(maxDepth: Int) async throws -> Any {
        try await pageAgent.captureSnapshotEnvelope(maxDepth: maxDepth)
    }

    package func captureSubtreePayload(nodeId: Int, maxDepth: Int) async throws -> Any {
        try await pageAgent.captureSubtreeEnvelope(nodeId: nodeId, maxDepth: maxDepth)
    }
}

// MARK: - Selection / Highlight

extension DOMSession {
    package func beginSelectionMode() async throws -> DOMPageAgent.SelectionModeResult {
        try await pageAgent.beginSelectionMode()
    }

    package func cancelSelectionMode() async {
        await pageAgent.cancelSelectionMode()
    }

    package func highlight(nodeId: Int) async {
#if DEBUG
        if let testHighlightOverride {
            await testHighlightOverride(nodeId)
            return
        }
#endif
        await pageAgent.highlight(nodeId: nodeId)
    }

    package func hideHighlight() async {
#if DEBUG
        if let testHideHighlightOverride {
            await testHideHighlightOverride()
            return
        }
#endif
        await pageAgent.hideHighlight()
    }
}

// MARK: - DOM Mutations

extension DOMSession {
    package func removeNode(
        nodeId: Int,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: DOMDocumentScopeID? = nil
    ) async -> DOMMutationExecutionResult<Void> {
#if DEBUG
        if let testRemoveNodeOverride {
            return await testRemoveNodeOverride(nodeId, expectedPageEpoch, expectedDocumentScopeID)
        }
#endif
        return await pageAgent.removeNode(
            nodeId: nodeId,
            expectedPageEpoch: expectedPageEpoch,
            expectedDocumentScopeID: expectedDocumentScopeID
        )
    }

    package func removeNodeWithUndo(
        nodeId: Int,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: DOMDocumentScopeID? = nil
    ) async -> DOMMutationExecutionResult<Int> {
        await pageAgent.removeNodeWithUndo(
            nodeId: nodeId,
            expectedPageEpoch: expectedPageEpoch,
            expectedDocumentScopeID: expectedDocumentScopeID
        )
    }

    package func undoRemoveNode(
        undoToken: Int,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: DOMDocumentScopeID? = nil
    ) async -> DOMMutationExecutionResult<Void> {
        let perform = { @MainActor @Sendable [pageAgent] in
            await pageAgent.undoRemoveNode(
                undoToken: undoToken,
                expectedPageEpoch: expectedPageEpoch,
                expectedDocumentScopeID: expectedDocumentScopeID
            )
        }
#if DEBUG
        if let testUndoRemoveNodeInterposer {
            return await testUndoRemoveNodeInterposer(
                undoToken,
                expectedPageEpoch,
                expectedDocumentScopeID,
                perform
            )
        }
#endif
        return await perform()
    }

    package func redoRemoveNode(
        undoToken: Int,
        nodeId: Int? = nil,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: DOMDocumentScopeID? = nil
    ) async -> DOMMutationExecutionResult<Void> {
        let perform = { @MainActor @Sendable [pageAgent] in
            await pageAgent.redoRemoveNode(
                undoToken: undoToken,
                nodeId: nodeId,
                expectedPageEpoch: expectedPageEpoch,
                expectedDocumentScopeID: expectedDocumentScopeID
            )
        }
#if DEBUG
        if let testRedoRemoveNodeInterposer {
            return await testRedoRemoveNodeInterposer(
                undoToken,
                nodeId,
                expectedPageEpoch,
                expectedDocumentScopeID,
                perform
            )
        }
#endif
        return await perform()
    }

    package func setAttribute(
        nodeId: Int,
        name: String,
        value: String,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: DOMDocumentScopeID? = nil
    ) async -> DOMMutationExecutionResult<Void> {
        await pageAgent.setAttribute(
            nodeId: nodeId,
            name: name,
            value: value,
            expectedPageEpoch: expectedPageEpoch,
            expectedDocumentScopeID: expectedDocumentScopeID
        )
    }

    package func removeAttribute(
        nodeId: Int,
        name: String,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: DOMDocumentScopeID? = nil
    ) async -> DOMMutationExecutionResult<Void> {
        await pageAgent.removeAttribute(
            nodeId: nodeId,
            name: name,
            expectedPageEpoch: expectedPageEpoch,
            expectedDocumentScopeID: expectedDocumentScopeID
        )
    }
}

#if DEBUG
extension DOMSession {
    package var testHasPreparedPageContextSyncTask: Bool {
        pageAgent.testHasPreparedPageContextSyncTask
    }

    package var testCachedPageEpoch: Int {
        pageAgent.testCachedPageEpoch
    }

    package var testCachedDocumentScopeID: DOMDocumentScopeID {
        pageAgent.testCachedDocumentScopeID
    }

    package var testSetAttributeInterposer: (@MainActor (
        Int,
        String,
        String,
        Int?,
        DOMDocumentScopeID?,
        @escaping @MainActor @Sendable () async -> DOMMutationExecutionResult<Void>
    ) async -> DOMMutationExecutionResult<Void>)? {
        get { pageAgent.testSetAttributeInterposer }
        set { pageAgent.testSetAttributeInterposer = newValue }
    }
}
#endif

// MARK: - Copy Helpers

extension DOMSession {
    package func selectionCopyText(nodeId: Int, kind: DOMSelectionCopyKind) async throws -> String {
        try await pageAgent.selectionCopyText(nodeId: nodeId, kind: kind)
    }

    package func selectorPath(nodeId: Int) async throws -> String {
        try await selectionCopyText(nodeId: nodeId, kind: .selectorPath)
    }
}
