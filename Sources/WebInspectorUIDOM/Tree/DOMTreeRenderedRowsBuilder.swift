#if canImport(UIKit)
import WebInspectorUIBase
import Foundation
import WebInspectorDataKit

extension DOMTreeTextView {
    @MainActor
    final class RowRenderBuildCoordinator {
        typealias IsCurrentBuild = @MainActor (
            DOMTreeTextView.RowRenderBuildRequest,
            DOMTreeTextView.RowRenderBuildResult
        ) -> Bool
        typealias ShouldApplyBuild = @MainActor (DOMTreeTextView.RowRenderBuildResult) -> Bool
        typealias ApplyBuild = @MainActor (DOMTreeTextView.RowRenderBuildResult) -> Void
        typealias FinishBuild = @MainActor () -> Void

        private let builder: DOMTreeTextView.RowRenderBuilder
        private var task: Task<Void, Never>?
        private var currentRequest: DOMTreeTextView.RowRenderBuildRequest?
        private var generation: UInt64 = 0
#if DEBUG
        private struct BuildCompletionWaiter {
            let continuation: CheckedContinuation<Bool, Never>
            let timeoutTask: Task<Void, Never>
        }

        private var shouldSuspendNextBuildForTesting = false
        private var suspendedBuildContinuationForTesting: CheckedContinuation<Void, Never>?
        private var buildSuspensionWaitersForTesting: [CheckedContinuation<Void, Never>] = []
        private var nextBuildCompletionWaiterID: UInt64 = 0
        private var buildCompletionWaiters: [UInt64: BuildCompletionWaiter] = [:]
        private var usesInlineBuildsForTesting = false
#endif

        init(builder: DOMTreeTextView.RowRenderBuilder) {
            self.builder = builder
        }

        var hasCurrentBuild: Bool {
            task != nil
        }

        func removeCachedMarkup(keepingCapacity: Bool) {
            builder.removeCachedMarkup(keepingCapacity: keepingCapacity)
        }

        func pruneCachedMarkup(keeping nodeIDs: Set<DOMNode.ID>) {
            builder.pruneCachedMarkup(keeping: nodeIDs)
        }

        func cancel() {
            generation &+= 1
            task?.cancel()
            task = nil
            currentRequest = nil
#if DEBUG
            resumeSuspendedBuildForTesting()
            resolveBuildCompletionWaiters(result: true)
#endif
        }

#if DEBUG
        func setUsesInlineBuildsForTesting(_ usesInlineBuilds: Bool) {
            usesInlineBuildsForTesting = usesInlineBuilds
        }

        func waitForCurrentBuild(timeout: Duration = .seconds(5)) async -> Bool {
            guard task != nil else {
                return true
            }

            return await withCheckedContinuation { continuation in
                let waiterID = nextBuildCompletionWaiterID
                nextBuildCompletionWaiterID &+= 1
                let timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.resolveBuildCompletionWaiter(id: waiterID, result: false)
                }
                buildCompletionWaiters[waiterID] = BuildCompletionWaiter(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        }
#endif

        func currentBuildMayRender(_ invalidation: DOMTreeRenderInvalidation) -> Bool {
            currentRequest?.mayRender(invalidation) == true
        }

        func startBuild(
            baseDocumentRevision: UInt64,
            previousRowCapacity: Int,
            previousTextCapacity: Int,
            isCurrentBuild: @escaping IsCurrentBuild,
            shouldApply: ShouldApplyBuild? = nil,
            apply: @escaping ApplyBuild,
            didFinish: FinishBuild? = nil
        ) {
            let request = builder.makeBuildRequest(
                baseDocumentRevision: baseDocumentRevision,
                previousRowCapacity: previousRowCapacity,
                previousTextCapacity: previousTextCapacity
            )
            generation &+= 1
            let buildGeneration = generation
            task?.cancel()
            currentRequest = request
#if DEBUG
            resumeSuspendedBuildForTesting()
#endif
            task = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                var shouldNotifyFinish = false
                defer {
                    if generation == buildGeneration {
                        task = nil
                        currentRequest = nil
#if DEBUG
                        resolveBuildCompletionWaiters(result: true)
#endif
                        if shouldNotifyFinish {
                            didFinish?()
                        }
                    }
                }
#if DEBUG
                await suspendBuildIfNeededForTesting()
#endif
                guard !Task.isCancelled else {
                    return
                }
                let buildResult: DOMTreeTextView.RowRenderBuildResult
                do {
#if DEBUG
                    if usesInlineBuildsForTesting {
                        buildResult = try await builder.buildInlineForTesting(request)
                    } else {
                        buildResult = try await builder.build(request)
                    }
#else
                    buildResult = try await builder.build(request)
#endif
                } catch is CancellationError {
                    return
                } catch {
                    assertionFailure("DOM tree row rendering failed: \(error)")
                    shouldNotifyFinish = true
                    return
                }
                guard !Task.isCancelled,
                      generation == buildGeneration,
                      isCurrentBuild(request, buildResult) else {
                    return
                }
                guard shouldApply?(buildResult) ?? true else {
                    shouldNotifyFinish = true
                    return
                }
                builder.acceptCompletedBuild(buildResult)
                apply(buildResult)
                shouldNotifyFinish = true
            }
        }

#if DEBUG
        func suspendNextBuildForTesting() {
            shouldSuspendNextBuildForTesting = true
        }

        func waitForBuildSuspensionForTesting() async {
            if suspendedBuildContinuationForTesting != nil {
                return
            }
            await withCheckedContinuation { continuation in
                buildSuspensionWaitersForTesting.append(continuation)
            }
        }

        func cachedMarkupKeysForTesting() -> Set<DOMTreeTextView.MarkupCacheKey> {
            builder.cachedMarkupKeysForTesting
        }

        private func resolveBuildCompletionWaiters(result: Bool) {
            let waiterIDs = Array(buildCompletionWaiters.keys)
            for waiterID in waiterIDs {
                resolveBuildCompletionWaiter(id: waiterID, result: result)
            }
        }

        private func resolveBuildCompletionWaiter(id: UInt64, result: Bool) {
            guard let waiter = buildCompletionWaiters.removeValue(forKey: id) else {
                return
            }
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: result)
        }

        func resumeSuspendedBuildForTesting() {
            guard let continuation = suspendedBuildContinuationForTesting else {
                return
            }
            suspendedBuildContinuationForTesting = nil
            continuation.resume()
        }

        private func suspendBuildIfNeededForTesting() async {
            guard shouldSuspendNextBuildForTesting else {
                return
            }
            shouldSuspendNextBuildForTesting = false
            await withCheckedContinuation { continuation in
                suspendedBuildContinuationForTesting = continuation
                let waiters = buildSuspensionWaitersForTesting
                buildSuspensionWaitersForTesting.removeAll(keepingCapacity: true)
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
#endif
    }
}

extension DOMTreeTextView {
    @MainActor
    final class RowRenderBuilder {
        private let snapshotProvider: @MainActor () -> DOMTreeRenderSnapshot
        private let expansionState: DOMTreeTextView.ExpansionState
        private var markupCache: [DOMTreeTextView.MarkupCacheKey: DOMTreeTextView.CachedMarkup] = [:]

        init(
            snapshotProvider: @escaping @MainActor () -> DOMTreeRenderSnapshot,
            expansionState: DOMTreeTextView.ExpansionState
        ) {
            self.snapshotProvider = snapshotProvider
            self.expansionState = expansionState
        }

        func removeCachedMarkup(keepingCapacity: Bool) {
            markupCache.removeAll(keepingCapacity: keepingCapacity)
        }

        func pruneCachedMarkup(keeping nodeIDs: Set<DOMNode.ID>) {
            markupCache = markupCache.filter { nodeIDs.contains($0.key.nodeID) }
        }

        func makeBuildRequest(
            baseDocumentRevision: UInt64,
            previousRowCapacity: Int,
            previousTextCapacity: Int
        ) -> DOMTreeTextView.RowRenderBuildRequest {
            let expansionSnapshot = expansionState.snapshot
            return DOMTreeTextView.RowRenderBuildRequest(
                snapshot: snapshotProvider(),
                expansionState: expansionSnapshot,
                baseDocumentRevision: baseDocumentRevision,
                previousRowCapacity: previousRowCapacity,
                previousTextCapacity: previousTextCapacity,
                markupCache: markupCache
            )
        }

        func build(
            _ request: DOMTreeTextView.RowRenderBuildRequest
        ) async throws -> DOMTreeTextView.RowRenderBuildResult {
            let task = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try await DOMTreeTextView.RowRenderWorker(request: request).build()
            }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }

#if DEBUG
        func buildInlineForTesting(
            _ request: DOMTreeTextView.RowRenderBuildRequest
        ) async throws -> DOMTreeTextView.RowRenderBuildResult {
            try Task.checkCancellation()
            return try await DOMTreeTextView.RowRenderWorker(request: request).build()
        }
#endif

        func acceptCompletedBuild(_ result: DOMTreeTextView.RowRenderBuildResult) {
            markupCache = result.markupCache
#if DEBUG
            Self.lastCollectedNodeIDsForTesting = result.collectedNodeIDsForTesting
#endif
        }

#if DEBUG
        private(set) static var lastCollectedNodeIDsForTesting: [DOMNode.ID] = []

        var cachedMarkupKeysForTesting: Set<DOMTreeTextView.MarkupCacheKey> {
            Set(markupCache.keys)
        }
#endif
    }
}

extension DOMTreeTextView {
    struct RowRenderNode: Sendable {
        let id: DOMNode.ID
        let nodeType: DOMNode.Kind
        let nodeName: String
        let localName: String
        let nodeValue: String
        let attributes: [DOMNode.Attribute]
        let pseudoType: String?
        let shadowRootType: String?
        let regularChildKnownCount: Int
        let isTemplateContent: Bool

        init(node: DOMTreeRenderSnapshot.Node, isTemplateContent: Bool) {
            id = node.id
            nodeType = node.kind
            nodeName = node.nodeName
            localName = node.localName
            nodeValue = node.nodeValue
            attributes = node.attributeList
            pseudoType = node.pseudoType?.domTreeDisplayName
            shadowRootType = node.shadowRootType?.domTreeDisplayName
            regularChildKnownCount = node.childNodeCount
            self.isTemplateContent = isTemplateContent
        }

        var displayName: String {
            if !localName.isEmpty {
                return localName
            }
            if !nodeName.isEmpty {
                return nodeName
            }
            return nodeValue.isEmpty ? nodeName : nodeValue
        }
    }

    struct RowRenderInput: Sendable {
        let node: DOMTreeTextView.RowRenderNode
        let depth: Int
        let hasDisclosure: Bool
        let isOpen: Bool
        let isClosingTag: Bool
    }

    struct RowRenderBuildRequest: Sendable {
        let snapshot: DOMTreeRenderSnapshot
        let expansionState: [DOMNode.ID: Bool]
        let baseDocumentRevision: UInt64
        let previousRowCapacity: Int
        let previousTextCapacity: Int
        let markupCache: [DOMTreeTextView.MarkupCacheKey: DOMTreeTextView.CachedMarkup]

        init(
            snapshot: DOMTreeRenderSnapshot,
            expansionState: [DOMNode.ID: Bool],
            baseDocumentRevision: UInt64,
            previousRowCapacity: Int,
            previousTextCapacity: Int,
            markupCache: [DOMTreeTextView.MarkupCacheKey: DOMTreeTextView.CachedMarkup]
        ) {
            self.snapshot = snapshot
            self.expansionState = expansionState
            self.baseDocumentRevision = baseDocumentRevision
            self.previousRowCapacity = previousRowCapacity
            self.previousTextCapacity = previousTextCapacity
            self.markupCache = markupCache
        }

        var treeRevision: UInt64 {
            snapshot.revision
        }

        func isNodeOpen(nodeID: DOMNode.ID, displayName: String) -> Bool {
            if let explicitState = expansionState[nodeID] {
                return explicitState
            }
            let name = displayName.lowercased()
            if name == "head" {
                return false
            }
            return name == "html" || name == "body"
        }

        func mayRender(_ invalidation: DOMTreeRenderInvalidation) -> Bool {
            switch invalidation.kind {
            case .root:
                return true
            case .content:
                guard !invalidation.affectedNodeIDs.isEmpty else {
                    return true
                }
                return mayRenderAny(nodeIDs: invalidation.affectedNodeIDs)
            case .structure:
                let scopedNodeIDs = invalidation.affectedNodeIDs.union(invalidation.parentNodeIDs)
                guard !scopedNodeIDs.isEmpty else {
                    return true
                }
                return mayRenderAny(nodeIDs: scopedNodeIDs)
            }
        }

        private func mayRenderAny(nodeIDs: Set<DOMNode.ID>) -> Bool {
            let displayRootIDs = Set(snapshot.displayRootIDs())
            for nodeID in nodeIDs where mayRenderNode(nodeID, displayRootIDs: displayRootIDs) {
                return true
            }
            return false
        }

        private func mayRenderNode(_ nodeID: DOMNode.ID, displayRootIDs: Set<DOMNode.ID>) -> Bool {
            guard snapshot.node(for: nodeID) != nil else {
                return false
            }
            if displayRootIDs.contains(nodeID) {
                return true
            }

            var visitedNodeIDs: Set<DOMNode.ID> = [nodeID]
            var parentID = snapshot.parent(of: nodeID)
            while let currentParentID = parentID {
                guard visitedNodeIDs.insert(currentParentID).inserted,
                      let parent = snapshot.node(for: currentParentID),
                      isNodeOpen(nodeID: currentParentID, displayName: parent.displayName) else {
                    return false
                }
                if displayRootIDs.contains(currentParentID) {
                    return true
                }
                parentID = snapshot.parent(of: currentParentID)
            }
            return false
        }
    }

    struct RowRenderBuildResult: Sendable {
        let rows: [DOMTreeRowRenderPlan]
        let text: String
        let maxLineDisplayColumnCount: Int
        let renderedNodeIDs: Set<DOMNode.ID>
        let markupCache: [DOMTreeTextView.MarkupCacheKey: DOMTreeTextView.CachedMarkup]
#if DEBUG
        let collectedNodeIDsForTesting: [DOMNode.ID]
#endif

        var observedContent: DOMTreeTextView.ObservedContent {
            DOMTreeTextView.ObservedContent((
                rows: rows,
                text: text,
                maxLineDisplayColumnCount: maxLineDisplayColumnCount
            ))
        }
    }
}

extension DOMTreeTextView {
    struct RowRenderWorker: Sendable {
        private let request: DOMTreeTextView.RowRenderBuildRequest
        private var renderedLinePrefixCache: [Int: String] = [:]
        private var markupCache: [DOMTreeTextView.MarkupCacheKey: DOMTreeTextView.CachedMarkup]

        init(request: DOMTreeTextView.RowRenderBuildRequest) {
            self.request = request
            self.markupCache = request.markupCache
        }

        func build() async throws -> DOMTreeTextView.RowRenderBuildResult {
            var worker = self
            return try await worker.buildRows()
        }

        private mutating func buildRows() async throws -> DOMTreeTextView.RowRenderBuildResult {
            try Task.checkCancellation()

            let buildRows = try await collectVisibleRows()
            var nextRows: [DOMTreeRowRenderPlan] = []
            nextRows.reserveCapacity(request.previousRowCapacity)
            var nextText = ""
            nextText.reserveCapacity(request.previousTextCapacity)
            var utf16Location = 0
            var maxLineDisplayColumnCount = 0

            func appendLine(
                _ rowInput: DOMTreeTextView.RowRenderInput
            ) async throws -> DOMTreeRowRenderPlan {
                try Task.checkCancellation()
                let rowIndex = nextRows.count
                if rowIndex > 0 && rowIndex.isMultiple(of: 128) {
                    await Task.yield()
                    try Task.checkCancellation()
                }
                let row = renderedRow(
                    for: rowInput,
                    rowIndex: rowIndex,
                    utf16Location: utf16Location
                )

                maxLineDisplayColumnCount = max(maxLineDisplayColumnCount, row.displayColumnCount)
                nextRows.append(row)
                if rowIndex > 0 {
                    nextText.append("\n")
                }
                nextText.append(row.text)
                utf16Location += row.documentRange.length + 1
                return row
            }

            for rowInput in buildRows.rows {
                _ = try await appendLine(rowInput)
            }

#if DEBUG
            return DOMTreeTextView.RowRenderBuildResult(
                rows: nextRows,
                text: nextText,
                maxLineDisplayColumnCount: maxLineDisplayColumnCount,
                renderedNodeIDs: Set(buildRows.renderedNodeIDs),
                markupCache: markupCache,
                collectedNodeIDsForTesting: buildRows.renderedNodeIDs
            )
#else
            return DOMTreeTextView.RowRenderBuildResult(
                rows: nextRows,
                text: nextText,
                maxLineDisplayColumnCount: maxLineDisplayColumnCount,
                renderedNodeIDs: Set(buildRows.renderedNodeIDs),
                markupCache: markupCache
            )
#endif
        }

        private func collectVisibleRows() async throws -> (
            rows: [DOMTreeTextView.RowRenderInput],
            renderedNodeIDs: [DOMNode.ID]
        ) {
            var rows: [DOMTreeTextView.RowRenderInput] = []
            rows.reserveCapacity(request.previousRowCapacity)
            var visitedNodeIDs = Set<DOMNode.ID>()
            var renderedNodeIDs: [DOMNode.ID] = []

            func collect(_ nodeID: DOMNode.ID, depth: Int) throws {
                try Task.checkCancellation()
                guard visitedNodeIDs.insert(nodeID).inserted,
                      let node = request.snapshot.node(for: nodeID) else {
                    return
                }
                let visibleChildren = request.snapshot.visibleChildren(of: nodeID)
                let renderNode = DOMTreeTextView.RowRenderNode(
                    node: node,
                    isTemplateContent: request.snapshot.isTemplateContent(nodeID)
                )
                let hasDisclosure = visibleChildren.hasRenderableChildren
                let isOpen = request.isNodeOpen(nodeID: renderNode.id, displayName: renderNode.displayName)
                rows.append(
                    DOMTreeTextView.RowRenderInput(
                        node: renderNode,
                        depth: depth,
                        hasDisclosure: hasDisclosure,
                        isOpen: isOpen,
                        isClosingTag: false
                    )
                )
                renderedNodeIDs.append(nodeID)

                guard hasDisclosure, isOpen else {
                    return
                }
                for childID in visibleChildren.nodeIDs {
                    try collect(childID, depth: depth + 1)
                }
                guard DOMTreeTextView.MarkupBuilder.rendersClosingTagRow(for: renderNode) else {
                    return
                }
                rows.append(
                    DOMTreeTextView.RowRenderInput(
                        node: renderNode,
                        depth: depth,
                        hasDisclosure: false,
                        isOpen: false,
                        isClosingTag: true
                    )
                )
            }

            for nodeID in request.snapshot.displayRootIDs() {
                if rows.count > 0, rows.count.isMultiple(of: 128) {
                    await Task.yield()
                }
                try collect(nodeID, depth: 0)
            }
            return (rows, renderedNodeIDs)
        }

        private mutating func renderedRow(
            for rowInput: DOMTreeTextView.RowRenderInput,
            rowIndex: Int,
            utf16Location: Int
        ) -> DOMTreeRowRenderPlan {
            let markup = cachedMarkup(
                for: rowInput.node,
                hasDisclosure: rowInput.hasDisclosure,
                isOpen: rowInput.isOpen,
                isClosingTag: rowInput.isClosingTag
            )
            let prefix = renderedLinePrefix(depth: rowInput.depth)
            let line = prefix + markup.text
            let prefixLength = rowInput.depth * DOMTreeTextView.IndentMetrics.indentSpacesPerDepth + DOMTreeTextView.IndentMetrics.disclosureSlotSpaces
            let lineLength = prefixLength + markup.utf16Length
            var tokens: [DOMTreeTextView.Token] = []
            tokens.reserveCapacity(markup.tokens.count)
            for token in markup.tokens {
                tokens.append(
                    DOMTreeTextView.Token(
                        kind: token.kind,
                        range: NSRange(location: prefixLength + token.range.location, length: token.range.length)
                    )
                )
            }

            return DOMTreeRowRenderPlan(
                identity: DOMTreeRowIdentity(
                    nodeID: rowInput.node.id,
                    kind: rowInput.isClosingTag ? .closingTag : .opening
                ),
                depth: rowInput.depth,
                rowIndex: rowIndex,
                text: line,
                documentRange: NSRange(location: utf16Location, length: lineLength),
                markupRange: NSRange(location: prefixLength, length: markup.utf16Length),
                tokens: tokens,
                displayColumnCount: prefixLength + markup.displayColumnCount,
                hasDisclosure: rowInput.hasDisclosure,
                isOpen: rowInput.isOpen
            )
        }

        private mutating func cachedMarkup(
            for node: DOMTreeTextView.RowRenderNode,
            hasDisclosure: Bool,
            isOpen: Bool,
            isClosingTag: Bool
        ) -> DOMTreeTextView.Markup {
            let signature = DOMTreeTextView.MarkupSignature(
                nodeType: node.nodeType,
                nodeName: node.nodeName,
                localName: node.localName,
                nodeValue: node.nodeValue,
                pseudoType: node.pseudoType,
                shadowRootType: node.shadowRootType,
                isTemplateContent: node.isTemplateContent,
                attributes: node.attributes,
                childCount: node.regularChildKnownCount,
                hasDisclosure: hasDisclosure,
                isOpen: isOpen,
                isClosingTag: isClosingTag
            )
            let cacheKey = DOMTreeTextView.MarkupCacheKey(
                nodeID: node.id,
                isClosingTag: isClosingTag
            )
            if let cached = markupCache[cacheKey],
               cached.signature == signature {
                return cached.markup
            }
            let markup = DOMTreeTextView.MarkupBuilder.markup(
                for: node,
                hasDisclosure: hasDisclosure,
                isOpen: isOpen,
                isClosingTag: isClosingTag,
                isTemplateContent: node.isTemplateContent
            )
            markupCache[cacheKey] = DOMTreeTextView.CachedMarkup(signature: signature, markup: markup)
            return markup
        }

        private mutating func renderedLinePrefix(depth: Int) -> String {
            if let cached = renderedLinePrefixCache[depth] {
                return cached
            }
            let prefix = String(
                repeating: " ",
                count: depth * DOMTreeTextView.IndentMetrics.indentSpacesPerDepth + DOMTreeTextView.IndentMetrics.disclosureSlotSpaces
            )
            renderedLinePrefixCache[depth] = prefix
            return prefix
        }
    }
}

private extension DOMPseudoElementKind {
    var domTreeDisplayName: String {
        rawValue
    }
}

private extension DOMShadowRootKind {
    var domTreeDisplayName: String {
        rawValue
    }
}
#endif
