import WebKit

package struct DOMPageContext: Equatable, Sendable {
    package let pageEpoch: Int
    package let documentScopeID: DOMDocumentScopeID
    package let documentURL: String?

    package init(
        pageEpoch: Int,
        documentScopeID: DOMDocumentScopeID,
        documentURL: String? = nil
    ) {
        self.pageEpoch = pageEpoch
        self.documentScopeID = documentScopeID
        self.documentURL = documentURL
    }
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
    private var preparedDocumentURL: String?
    private var hasPreparedPageContext = false
    private var hasPreparedDocumentScope = false

#if DEBUG
    package var testRemoveNodeOverride: (@MainActor (
        _ nodeId: Int,
        _ expectedPageEpoch: Int?,
        _ expectedDocumentScopeID: DOMDocumentScopeID?
    ) async -> DOMMutationExecutionResult<Void>)?
    package var testRemoveNodeWithUndoOverride: (@MainActor (
        _ target: DOMRequestNodeTarget,
        _ expectedPageEpoch: Int?,
        _ expectedDocumentScopeID: DOMDocumentScopeID?
    ) async -> DOMMutationExecutionResult<Int>)?
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
    package var testSelectionCopyTextOverride: (@MainActor (
        _ nodeId: Int,
        _ kind: DOMSelectionCopyKind
    ) async throws -> String)?
    package var testHighlightOverride: (@MainActor (Int, Bool) async -> Void)?
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
        var existingPageContext = await pageAgent.readPageContext(on: webView)
        if existingPageContext == nil {
            await pageAgent.ensureDOMAgentScriptInstalled(on: webView)
            existingPageContext = await pageAgent.readPageContext(on: webView)
        }
        if !hasPreparedPageContext,
           hasPreparedDocumentScope,
           let pageEpochToApply = pageEpochToApplyForPreparedDocumentScopeAttach(
                existingPageContext: existingPageContext
           ) {
            await pageAgent.ensureDOMAgentScriptInstalled(on: webView)
            await pageAgent.ensureDOMAgentScriptInstalled(
                on: webView,
                pageEpoch: pageEpochToApply,
                documentScopeID: preparedDocumentScopeID
            )
            existingPageContext = await pageAgent.readPageContext(on: webView) ?? existingPageContext
        } else if !shouldPreferObservedPageContextDuringAttach(existingPageContext) {
            await pageAgent.ensureDOMAgentScriptInstalled(on: webView)
            await pageAgent.ensureDOMAgentScriptInstalled(
                on: webView,
                pageEpoch: preparedPageEpoch,
                documentScopeID: preparedDocumentScopeID
            )
        }
        let observedPageContext = await readObservedPageContextIfNewer(on: webView)
        lastPageWebView = webView

        if autoSnapshotEnabled {
            await pageAgent.setAutoSnapshot(enabled: true)
        }

        return (shouldReload, shouldPreserveState, observedPageContext)
    }

    private func pageEpochToApplyForPreparedDocumentScopeAttach(
        existingPageContext: DOMPageContext?
    ) -> Int? {
        if let existingPageContext,
           existingPageContext.pageEpoch != 0 {
            return existingPageContext.pageEpoch
        }
        let cachedPageEpoch = pageAgent.currentPageContext.pageEpoch
        if cachedPageEpoch != 0 {
            return cachedPageEpoch
        }
        if preparedPageEpoch != 0 {
            return preparedPageEpoch
        }
        return nil
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
        preparedDocumentURL = normalizedDocumentURL(refreshedPageContext.documentURL)
        hasPreparedPageContext = true
        hasPreparedDocumentScope = true
        return refreshedPageContext
    }

    private func shouldAdoptObservedPageContext(_ pageContext: DOMPageContext) -> Bool {
        let observedDocumentURL = normalizedDocumentURL(pageContext.documentURL)
        if let observedDocumentURL,
           observedDocumentURL != preparedDocumentURL {
            return true
        }
        return pageContext.pageEpoch != preparedPageEpoch
            || pageContext.documentScopeID != preparedDocumentScopeID
    }

    private func shouldPreferObservedPageContextDuringAttach(_ pageContext: DOMPageContext?) -> Bool {
        guard let pageContext else {
            return false
        }
        if hasPreparedDocumentScope,
           pageContext.documentScopeID != preparedDocumentScopeID {
            return false
        }
        guard hasPreparedPageContext else {
            return true
        }
        return pageContext.pageEpoch == preparedPageEpoch
            && pageContext.documentScopeID == preparedDocumentScopeID
            && (
                preparedDocumentURL == nil
                || normalizedDocumentURL(pageContext.documentURL) == preparedDocumentURL
            )
    }

    package func suspend() async {
        await pageAgent.detachPageWebViewAndWaitForCleanup()
        hasPreparedPageContext = false
        hasPreparedDocumentScope = false
    }

    package func detach() async {
        await suspend()
        lastPageWebView = nil
        preparedDocumentURL = nil
        hasPreparedPageContext = false
        hasPreparedDocumentScope = false
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
        await pageAgent.setAutoSnapshot(enabled: enabled)
    }

    package func preparePageEpoch(_ epoch: Int) {
        preparedPageEpoch = epoch
        hasPreparedPageContext = true
        pageAgent.preparePageEpoch(epoch)
    }

    package func prepareDocumentScopeID(_ scopeID: DOMDocumentScopeID) {
        preparedDocumentScopeID = scopeID
        hasPreparedDocumentScope = true
        pageAgent.prepareDocumentScopeID(scopeID)
    }

    package func syncCurrentDocumentScopeIDIfNeeded(
        _ scopeID: DOMDocumentScopeID,
        expectedPageEpoch: Int? = nil
    ) async -> Bool {
        preparedDocumentScopeID = scopeID
        hasPreparedDocumentScope = true
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
        preparedDocumentURL = nil
        hasPreparedPageContext = false
        hasPreparedDocumentScope = false
    }

    package var currentPageContext: DOMPageContext {
        pageAgent.currentPageContext
    }
}

private func normalizedDocumentURL(_ documentURL: String?) -> String? {
    guard let documentURL, !documentURL.isEmpty else {
        return nil
    }
    guard var components = URLComponents(string: documentURL) else {
        return documentURL
    }
    components.fragment = nil
    return components.string ?? documentURL
}

// MARK: - Snapshot API (for DOMTreeView)

extension DOMSession {
    package func captureSnapshot(
        maxDepth: Int,
        initialModeOwnership: DOMSnapshotInitialModeOwnership = .preservePendingInitialMode
    ) async throws -> String {
        try await pageAgent.captureSnapshot(
            maxDepth: maxDepth,
            initialModeOwnership: initialModeOwnership
        )
    }

    package func captureSubtree(nodeId: Int, maxDepth: Int) async throws -> String {
        try await pageAgent.captureSubtree(nodeId: nodeId, maxDepth: maxDepth)
    }

}

// MARK: - Snapshot API (bridge/object)

extension DOMSession {
    package func captureSnapshotPayload(
        maxDepth: Int,
        initialModeOwnership: DOMSnapshotInitialModeOwnership = .preservePendingInitialMode
    ) async throws -> Any {
        try await pageAgent.captureSnapshotEnvelope(
            maxDepth: maxDepth,
            initialModeOwnership: initialModeOwnership
        )
    }

    package func consumePendingInitialSnapshotMode(
        expectedPageEpoch: Int,
        expectedDocumentScopeID: DOMDocumentScopeID
    ) async {
        await pageAgent.consumePendingInitialSnapshotMode(
            expectedPageEpoch: expectedPageEpoch,
            expectedDocumentScopeID: expectedDocumentScopeID
        )
    }

    package func captureSubtreePayload(target: DOMRequestNodeTarget, maxDepth: Int) async throws -> Any {
        try await pageAgent.captureSubtreeEnvelope(target: target, maxDepth: maxDepth)
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

    package func setPendingSelectionPath(_ path: [Int]?) async {
        await pageAgent.setPendingSelectionPath(path)
    }

    package func highlight(nodeId: Int, reveal: Bool = true) async {
#if DEBUG
        if let testHighlightOverride {
            await testHighlightOverride(nodeId, reveal)
            return
        }
#endif
        await pageAgent.highlight(nodeId: nodeId, reveal: reveal)
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
        target: DOMRequestNodeTarget,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: DOMDocumentScopeID? = nil
    ) async -> DOMMutationExecutionResult<Void> {
#if DEBUG
        if let testRemoveNodeOverride {
            return await testRemoveNodeOverride(target.jsIdentifier ?? -1, expectedPageEpoch, expectedDocumentScopeID)
        }
#endif
        return await pageAgent.removeNode(
            target: target,
            expectedPageEpoch: expectedPageEpoch,
            expectedDocumentScopeID: expectedDocumentScopeID
        )
    }

    package func removeNodeWithUndo(
        target: DOMRequestNodeTarget,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: DOMDocumentScopeID? = nil
    ) async -> DOMMutationExecutionResult<Int> {
#if DEBUG
        if let testRemoveNodeWithUndoOverride {
            return await testRemoveNodeWithUndoOverride(target, expectedPageEpoch, expectedDocumentScopeID)
        }
#endif
        return await pageAgent.removeNodeWithUndo(
            target: target,
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
        target: DOMRequestNodeTarget,
        name: String,
        value: String,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: DOMDocumentScopeID? = nil
    ) async -> DOMMutationExecutionResult<Void> {
        await pageAgent.setAttribute(
            target: target,
            name: name,
            value: value,
            expectedPageEpoch: expectedPageEpoch,
            expectedDocumentScopeID: expectedDocumentScopeID
        )
    }

    package func removeAttribute(
        target: DOMRequestNodeTarget,
        name: String,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: DOMDocumentScopeID? = nil
    ) async -> DOMMutationExecutionResult<Void> {
        await pageAgent.removeAttribute(
            target: target,
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
    package func selectionCopyText(target: DOMRequestNodeTarget, kind: DOMSelectionCopyKind) async throws -> String {
#if DEBUG
        if let testSelectionCopyTextOverride {
            return try await testSelectionCopyTextOverride(target.jsIdentifier ?? -1, kind)
        }
#endif
        return try await pageAgent.selectionCopyText(target: target, kind: kind)
    }

    package func selectorPath(target: DOMRequestNodeTarget) async throws -> String {
        try await selectionCopyText(target: target, kind: .selectorPath)
    }
}
