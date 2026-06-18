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
#if DEBUG
            resumeSuspendedBuildForTesting()
#endif
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
        private var markupCache: [DOMNode.ID: DOMTreeTextView.CachedMarkup] = [:]

        init(dom: DOMSession, expansionState: DOMTreeTextView.ExpansionState) {
            self.dom = dom
            self.expansionState = expansionState
        }

        func removeCachedMarkup(keepingCapacity: Bool) {
            markupCache.removeAll(keepingCapacity: keepingCapacity)
        }

        func pruneCachedMarkup(keeping nodeIDs: Set<DOMNode.ID>) {
            markupCache = markupCache.filter { nodeIDs.contains($0.key) }
        }

        func makeBuildRequest(
            previousRowCapacity: Int,
            previousTextCapacity: Int
        ) -> DOMTreeTextView.RenderedRowsBuildRequest {
            let expansionSnapshot = expansionState.snapshot
            return DOMTreeTextView.RenderedRowsBuildRequest(
                treeRevision: dom.treeRevision,
                expansionState: expansionSnapshot,
                rows: collectVisibleRows(expansionState: expansionSnapshot),
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
        }

        private func collectVisibleRows(
            expansionState: [DOMNode.ID: Bool]
        ) -> [DOMTreeTextView.RenderedRowsBuildRow] {
            guard let rootNode = dom.currentPageRootNode else {
#if DEBUG
                Self.lastCollectedNodeIDsForTesting = []
#endif
                return []
            }

            var rows: [DOMTreeTextView.RenderedRowsBuildRow] = []
            rows.reserveCapacity(markupCache.count)
            var visitedNodeIDs = Set<DOMNode.ID>()
#if DEBUG
            var visitedNodeIDsForTesting: [DOMNode.ID] = []
#endif

            func collect(_ node: DOMNode, depth: Int) {
                guard visitedNodeIDs.insert(node.id).inserted else {
                    return
                }
                let renderNode = DOMTreeTextView.RenderedRowsBuildNode(
                    node: node,
                    isTemplateContent: dom.isTemplateContent(node)
                )
                let hasDisclosure = dom.hasVisibleDOMTreeChildren(node)
                let isOpen = Self.isNodeOpen(renderNode, expansionState: expansionState)
                rows.append(
                    DOMTreeTextView.RenderedRowsBuildRow(
                        node: renderNode,
                        depth: depth,
                        hasDisclosure: hasDisclosure,
                        isOpen: isOpen,
                        isClosingTag: false
                    )
                )
#if DEBUG
                visitedNodeIDsForTesting.append(node.id)
#endif

                guard hasDisclosure, isOpen else {
                    return
                }
                for child in dom.visibleDOMTreeChildren(of: node) {
                    collect(child, depth: depth + 1)
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

            let displayRoots = rootNode.nodeType == .document ? dom.visibleDOMTreeChildren(of: rootNode) : [rootNode]
            for node in displayRoots {
                collect(node, depth: 0)
            }
#if DEBUG
            Self.lastCollectedNodeIDsForTesting = visitedNodeIDsForTesting
#endif
            return rows
        }

        private static func isNodeOpen(
            _ node: DOMTreeTextView.RenderedRowsBuildNode,
            expansionState: [DOMNode.ID: Bool]
        ) -> Bool {
            if let explicitState = expansionState[node.id] {
                return explicitState
            }
            let name = node.displayName.lowercased()
            if name == "head" {
                return false
            }
            return name == "html" || name == "body"
        }

#if DEBUG
        private(set) static var lastCollectedNodeIDsForTesting: [DOMNode.ID] = []
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

        @MainActor
        init(node: DOMNode, isTemplateContent: Bool) {
            id = node.id
            nodeType = node.nodeType
            nodeName = node.nodeName
            localName = node.localName
            nodeValue = node.nodeValue
            attributes = node.attributes
            pseudoType = node.pseudoType
            shadowRootType = node.shadowRootType
            regularChildKnownCount = node.regularChildren.knownCount
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
        let treeRevision: UInt64
        let expansionState: [DOMNode.ID: Bool]
        let rows: [DOMTreeTextView.RenderedRowsBuildRow]
        let previousRowCapacity: Int
        let previousTextCapacity: Int
        let markupCache: [DOMNode.ID: DOMTreeTextView.CachedMarkup]

        init(
            treeRevision: UInt64,
            expansionState: [DOMNode.ID: Bool],
            rows: [DOMTreeTextView.RenderedRowsBuildRow],
            previousRowCapacity: Int,
            previousTextCapacity: Int,
            markupCache: [DOMNode.ID: DOMTreeTextView.CachedMarkup]
        ) {
            self.treeRevision = treeRevision
            self.expansionState = expansionState
            self.rows = rows
            self.previousRowCapacity = previousRowCapacity
            self.previousTextCapacity = previousTextCapacity
            self.markupCache = markupCache
        }
    }

    struct RenderedRowsBuildResult: Sendable {
        let rows: [DOMTreeTextView.Line]
        let text: String
        let maxLineDisplayColumnCount: Int
        let markupCache: [DOMNode.ID: DOMTreeTextView.CachedMarkup]

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
        private var markupCache: [DOMNode.ID: DOMTreeTextView.CachedMarkup]

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

            for rowInput in request.rows {
                _ = try await appendLine(rowInput)
            }

            return DOMTreeTextView.RenderedRowsBuildResult(
                rows: nextRows,
                text: nextText,
                maxLineDisplayColumnCount: maxLineDisplayColumnCount,
                markupCache: markupCache
            )
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
            if let cached = markupCache[node.id],
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
            markupCache[node.id] = DOMTreeTextView.CachedMarkup(signature: signature, markup: markup)
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
