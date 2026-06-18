#if canImport(UIKit)
import Foundation
import WebInspectorCore

extension DOMTreeTextView {
    @MainActor
    final class RenderedRowsBuildCoordinator {
        typealias IsCurrentBuild = @MainActor (DOMTreeTextView.RenderedRowsBuildRequest) -> Bool
        typealias ShouldApplyBuild = @MainActor (DOMTreeTextView.RenderedRowsBuildResult) -> Bool
        typealias ApplyBuild = @MainActor (DOMTreeTextView.RenderedRowsBuildResult) -> Void
        typealias FinishBuild = @MainActor () -> Void

        private let builder: DOMTreeTextView.RenderedRowsBuilder
        private var task: Task<Void, Never>?
        private var currentRequest: DOMTreeTextView.RenderedRowsBuildRequest?
        private var generation: UInt64 = 0
#if DEBUG
        private var shouldSuspendNextBuildForTesting = false
        private var suspendedBuildContinuationForTesting: CheckedContinuation<Void, Never>?
        private var buildSuspensionWaitersForTesting: [CheckedContinuation<Void, Never>] = []
#endif

        init(builder: DOMTreeTextView.RenderedRowsBuilder) {
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
            task?.cancel()
            task = nil
            currentRequest = nil
#if DEBUG
            resumeSuspendedBuildForTesting()
#endif
        }

        func currentBuildRenders(nodeID: DOMNode.ID) -> Bool {
            currentRequest?.rendersNode(nodeID) ?? false
        }

        func waitForCurrentBuild() async {
            while true {
                await Task.yield()
                guard let task else {
                    return
                }
                await task.value
            }
        }

        func startBuild(
            previousRowCapacity: Int,
            previousTextCapacity: Int,
            isCurrentBuild: @escaping IsCurrentBuild,
            shouldApply: ShouldApplyBuild? = nil,
            apply: @escaping ApplyBuild,
            didFinish: FinishBuild? = nil
        ) {
            let request = builder.makeBuildRequest(
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
                let buildResult: DOMTreeTextView.RenderedRowsBuildResult
                do {
                    buildResult = try await builder.build(request)
                } catch is CancellationError {
                    return
                } catch {
                    assertionFailure("DOM tree row rendering failed: \(error)")
                    shouldNotifyFinish = true
                    return
                }
                guard !Task.isCancelled,
                      generation == buildGeneration,
                      isCurrentBuild(request) else {
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
    final class RenderedRowsBuilder {
        private let dom: DOMSession
        private let expansionState: DOMTreeTextView.ExpansionState
        private var markupCache: [DOMTreeTextView.MarkupCacheKey: DOMTreeTextView.CachedMarkup] = [:]

        init(dom: DOMSession, expansionState: DOMTreeTextView.ExpansionState) {
            self.dom = dom
            self.expansionState = expansionState
        }

        func removeCachedMarkup(keepingCapacity: Bool) {
            markupCache.removeAll(keepingCapacity: keepingCapacity)
        }

        func pruneCachedMarkup(keeping nodeIDs: Set<DOMNode.ID>) {
            markupCache = markupCache.filter { nodeIDs.contains($0.key.nodeID) }
        }

        func makeBuildRequest(
            previousRowCapacity: Int,
            previousTextCapacity: Int
        ) -> DOMTreeTextView.RenderedRowsBuildRequest {
            let expansionSnapshot = expansionState.snapshot
            return DOMTreeTextView.RenderedRowsBuildRequest(
                snapshot: dom.domTreeRenderSnapshot(),
                expansionState: expansionSnapshot,
                previousRowCapacity: previousRowCapacity,
                previousTextCapacity: previousTextCapacity,
                markupCache: markupCache
            )
        }

        func build(
            _ request: DOMTreeTextView.RenderedRowsBuildRequest
        ) async throws -> DOMTreeTextView.RenderedRowsBuildResult {
            let task = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try await DOMTreeTextView.RenderedRowsWorker(request: request).build()
            }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }

        func acceptCompletedBuild(_ result: DOMTreeTextView.RenderedRowsBuildResult) {
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
    struct RenderedRowsBuildNode: Sendable {
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

        init(node: DOMTreeRenderNodeSnapshot, isTemplateContent: Bool) {
            id = node.id
            nodeType = node.nodeType
            nodeName = node.nodeName
            localName = node.localName
            nodeValue = node.nodeValue
            attributes = node.attributes
            pseudoType = node.pseudoType
            shadowRootType = node.shadowRootType
            regularChildKnownCount = node.regularChildKnownCount
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

    struct RenderedRowsBuildRow: Sendable {
        let node: DOMTreeTextView.RenderedRowsBuildNode
        let depth: Int
        let hasDisclosure: Bool
        let isOpen: Bool
        let isClosingTag: Bool
    }

    struct RenderedRowsBuildRequest: Sendable {
        let snapshot: DOMTreeRenderSnapshot
        let expansionState: [DOMNode.ID: Bool]
        let previousRowCapacity: Int
        let previousTextCapacity: Int
        let markupCache: [DOMTreeTextView.MarkupCacheKey: DOMTreeTextView.CachedMarkup]

        init(
            snapshot: DOMTreeRenderSnapshot,
            expansionState: [DOMNode.ID: Bool],
            previousRowCapacity: Int,
            previousTextCapacity: Int,
            markupCache: [DOMTreeTextView.MarkupCacheKey: DOMTreeTextView.CachedMarkup]
        ) {
            self.snapshot = snapshot
            self.expansionState = expansionState
            self.previousRowCapacity = previousRowCapacity
            self.previousTextCapacity = previousTextCapacity
            self.markupCache = markupCache
        }

        var treeRevision: UInt64 {
            snapshot.treeRevision
        }

        func rendersNode(_ targetNodeID: DOMNode.ID) -> Bool {
            var visitedNodeIDs = Set<DOMNode.ID>()

            func renders(_ nodeID: DOMNode.ID) -> Bool {
                guard visitedNodeIDs.insert(nodeID).inserted,
                      let node = snapshot.node(for: nodeID) else {
                    return false
                }
                if nodeID == targetNodeID {
                    return true
                }
                let visibleChildren = snapshot.visibleChildrenProjection(of: nodeID)
                guard visibleChildren.hasRenderableChildren,
                      isNodeOpen(nodeID: node.id, displayName: node.displayName) else {
                    return false
                }
                for childID in visibleChildren.children where renders(childID) {
                    return true
                }
                return false
            }

            for rootNodeID in snapshot.displayRootIDs() where renders(rootNodeID) {
                return true
            }
            return false
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
    }

    struct RenderedRowsBuildResult: Sendable {
        let rows: [DOMTreeTextView.Line]
        let text: String
        let maxLineDisplayColumnCount: Int
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
    struct RenderedRowsWorker: Sendable {
        private let request: DOMTreeTextView.RenderedRowsBuildRequest
        private var renderedLinePrefixCache: [Int: String] = [:]
        private var markupCache: [DOMTreeTextView.MarkupCacheKey: DOMTreeTextView.CachedMarkup]

        init(request: DOMTreeTextView.RenderedRowsBuildRequest) {
            self.request = request
            self.markupCache = request.markupCache
        }

        func build() async throws -> DOMTreeTextView.RenderedRowsBuildResult {
            var worker = self
            return try await worker.buildRows()
        }

        private mutating func buildRows() async throws -> DOMTreeTextView.RenderedRowsBuildResult {
            try Task.checkCancellation()

            let buildRows = try await collectVisibleRows()
            var nextRows: [DOMTreeTextView.Line] = []
            nextRows.reserveCapacity(request.previousRowCapacity)
            var nextText = ""
            nextText.reserveCapacity(request.previousTextCapacity)
            var utf16Location = 0
            var maxLineDisplayColumnCount = 0

            func appendLine(
                _ rowInput: DOMTreeTextView.RenderedRowsBuildRow
            ) async throws -> DOMTreeTextView.Line {
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
                utf16Location += row.textRange.length + 1
                return row
            }

            for rowInput in buildRows.rows {
                _ = try await appendLine(rowInput)
            }

#if DEBUG
            return DOMTreeTextView.RenderedRowsBuildResult(
                rows: nextRows,
                text: nextText,
                maxLineDisplayColumnCount: maxLineDisplayColumnCount,
                markupCache: markupCache,
                collectedNodeIDsForTesting: buildRows.collectedNodeIDsForTesting
            )
#else
            return DOMTreeTextView.RenderedRowsBuildResult(
                rows: nextRows,
                text: nextText,
                maxLineDisplayColumnCount: maxLineDisplayColumnCount,
                markupCache: markupCache
            )
#endif
        }

        private func collectVisibleRows() async throws -> (
            rows: [DOMTreeTextView.RenderedRowsBuildRow],
            collectedNodeIDsForTesting: [DOMNode.ID]
        ) {
            var rows: [DOMTreeTextView.RenderedRowsBuildRow] = []
            rows.reserveCapacity(request.previousRowCapacity)
            var visitedNodeIDs = Set<DOMNode.ID>()
            var visitedNodeIDsForTesting: [DOMNode.ID] = []

            func collect(_ nodeID: DOMNode.ID, depth: Int) throws {
                try Task.checkCancellation()
                guard visitedNodeIDs.insert(nodeID).inserted,
                      let node = request.snapshot.node(for: nodeID) else {
                    return
                }
                let visibleChildren = request.snapshot.visibleChildrenProjection(of: nodeID)
                let renderNode = DOMTreeTextView.RenderedRowsBuildNode(
                    node: node,
                    isTemplateContent: request.snapshot.isTemplateContent(nodeID)
                )
                let hasDisclosure = visibleChildren.hasRenderableChildren
                let isOpen = request.isNodeOpen(nodeID: renderNode.id, displayName: renderNode.displayName)
                rows.append(
                    DOMTreeTextView.RenderedRowsBuildRow(
                        node: renderNode,
                        depth: depth,
                        hasDisclosure: hasDisclosure,
                        isOpen: isOpen,
                        isClosingTag: false
                    )
                )
                visitedNodeIDsForTesting.append(nodeID)

                guard hasDisclosure, isOpen else {
                    return
                }
                for childID in visibleChildren.children {
                    try collect(childID, depth: depth + 1)
                }
                guard DOMTreeTextView.MarkupBuilder.rendersClosingTagRow(for: renderNode) else {
                    return
                }
                rows.append(
                    DOMTreeTextView.RenderedRowsBuildRow(
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
            return (rows, visitedNodeIDsForTesting)
        }

        private mutating func renderedRow(
            for rowInput: DOMTreeTextView.RenderedRowsBuildRow,
            rowIndex: Int,
            utf16Location: Int
        ) -> DOMTreeTextView.Line {
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

            return DOMTreeTextView.Line(
                nodeID: rowInput.node.id,
                depth: rowInput.depth,
                rowIndex: rowIndex,
                text: line,
                textRange: NSRange(location: utf16Location, length: lineLength),
                markupRange: NSRange(location: prefixLength, length: markup.utf16Length),
                tokens: tokens,
                displayColumnCount: prefixLength + markup.displayColumnCount,
                hasDisclosure: rowInput.hasDisclosure,
                isOpen: rowInput.isOpen,
                isClosingTag: rowInput.isClosingTag
            )
        }

        private mutating func cachedMarkup(
            for node: DOMTreeTextView.RenderedRowsBuildNode,
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
#endif
