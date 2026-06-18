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
            DOMTreeTextView.RenderedRowsBuildRequest(
                treeRevision: dom.treeRevision,
                expansionState: expansionState.snapshot,
                previousRowCapacity: previousRowCapacity,
                previousTextCapacity: previousTextCapacity,
                markupCache: markupCache
            )
        }

        func build(
            _ request: DOMTreeTextView.RenderedRowsBuildRequest
        ) async throws -> DOMTreeTextView.RenderedRowsBuildResult {
            try await DOMTreeTextView.RenderedRowsWorker(dom: dom, request: request).build()
        }

        func acceptCompletedBuild(_ result: DOMTreeTextView.RenderedRowsBuildResult) {
            markupCache = result.markupCache
        }
    }
}

extension DOMTreeTextView {
    struct RenderedRowsBuildRequest: Sendable {
        let treeRevision: UInt64
        let expansionState: [DOMNode.ID: Bool]
        let previousRowCapacity: Int
        let previousTextCapacity: Int
        let markupCache: [DOMNode.ID: DOMTreeTextView.CachedMarkup]

        init(
            treeRevision: UInt64,
            expansionState: [DOMNode.ID: Bool],
            previousRowCapacity: Int,
            previousTextCapacity: Int,
            markupCache: [DOMNode.ID: DOMTreeTextView.CachedMarkup]
        ) {
            self.treeRevision = treeRevision
            self.expansionState = expansionState
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
    @MainActor
    struct RenderedRowsWorker {
        private let dom: DOMSession
        private let request: DOMTreeTextView.RenderedRowsBuildRequest
        private var renderedLinePrefixCache: [Int: String] = [:]
        private var markupCache: [DOMNode.ID: DOMTreeTextView.CachedMarkup]
#if DEBUG
        private(set) static var lastVisitedNodeIDsForTesting: [DOMNode.ID] = []
#endif

        init(dom: DOMSession, request: DOMTreeTextView.RenderedRowsBuildRequest) {
            self.dom = dom
            self.request = request
            self.markupCache = request.markupCache
        }

        func build() async throws -> DOMTreeTextView.RenderedRowsBuildResult {
            var worker = self
            return try await worker.buildRows()
        }

        private mutating func buildRows() async throws -> DOMTreeTextView.RenderedRowsBuildResult {
            try Task.checkCancellation()
            guard let rootNode = currentPageRootNode() else {
#if DEBUG
                Self.lastVisitedNodeIDsForTesting = []
#endif
                return DOMTreeTextView.RenderedRowsBuildResult(
                    rows: [],
                    text: "",
                    maxLineDisplayColumnCount: 0,
                    markupCache: markupCache
                )
            }

            var nextRows: [DOMTreeTextView.Line] = []
            nextRows.reserveCapacity(request.previousRowCapacity)
            var nextText = ""
            nextText.reserveCapacity(request.previousTextCapacity)
            var utf16Location = 0
            var maxLineDisplayColumnCount = 0
            var visitedNodeIDs = Set<DOMNode.ID>()
#if DEBUG
            var visitedNodeIDsForTesting: [DOMNode.ID] = []
#endif

            func appendLine(
                _ node: DOMNode,
                depth: Int,
                isClosingTag: Bool
            ) async throws -> DOMTreeTextView.Line {
                try Task.checkCancellation()
                let rowIndex = nextRows.count
                if rowIndex > 0 && rowIndex.isMultiple(of: 128) {
                    await Task.yield()
                    try Task.checkCancellation()
                }
                let row = renderedRow(
                    for: node,
                    depth: depth,
                    rowIndex: rowIndex,
                    utf16Location: utf16Location,
                    isClosingTag: isClosingTag
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

            func append(_ node: DOMNode, depth: Int) async throws {
                try Task.checkCancellation()
                guard visitedNodeIDs.insert(node.id).inserted else {
                    return
                }
#if DEBUG
                visitedNodeIDsForTesting.append(node.id)
#endif
                let row = try await appendLine(node, depth: depth, isClosingTag: false)
                guard row.hasDisclosure, row.isOpen else {
                    return
                }
                for child in visibleChildren(of: node) {
                    try await append(child, depth: depth + 1)
                }
                if DOMTreeTextView.MarkupBuilder.rendersClosingTagRow(for: node) {
                    _ = try await appendLine(node, depth: depth, isClosingTag: true)
                }
            }

            let displayRoots = rootNode.nodeType == .document ? visibleChildren(of: rootNode) : [rootNode]
            for node in displayRoots {
                try await append(node, depth: 0)
            }

#if DEBUG
            Self.lastVisitedNodeIDsForTesting = visitedNodeIDsForTesting
#endif
            return DOMTreeTextView.RenderedRowsBuildResult(
                rows: nextRows,
                text: nextText,
                maxLineDisplayColumnCount: maxLineDisplayColumnCount,
                markupCache: markupCache
            )
        }

        private mutating func renderedRow(
            for node: DOMNode,
            depth: Int,
            rowIndex: Int,
            utf16Location: Int,
            isClosingTag: Bool = false
        ) -> DOMTreeTextView.Line {
            let hasDisclosure = !isClosingTag && nodeHasDisclosure(node)
            let isOpen = !isClosingTag && isNodeOpen(node)
            let markup = cachedMarkup(
                for: node,
                hasDisclosure: hasDisclosure,
                isOpen: isOpen,
                isClosingTag: isClosingTag
            )
            let prefix = renderedLinePrefix(depth: depth)
            let line = prefix + markup.text
            let prefixLength = depth * DOMTreeTextView.IndentMetrics.indentSpacesPerDepth + DOMTreeTextView.IndentMetrics.disclosureSlotSpaces
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
                nodeID: node.id,
                depth: depth,
                rowIndex: rowIndex,
                text: line,
                textRange: NSRange(location: utf16Location, length: lineLength),
                markupRange: NSRange(location: prefixLength, length: markup.utf16Length),
                tokens: tokens,
                displayColumnCount: prefixLength + markup.displayColumnCount,
                hasDisclosure: hasDisclosure,
                isOpen: isOpen,
                isClosingTag: isClosingTag
            )
        }

        private mutating func cachedMarkup(
            for node: DOMNode,
            hasDisclosure: Bool,
            isOpen: Bool,
            isClosingTag: Bool
        ) -> DOMTreeTextView.Markup {
            let isTemplateContent = isTemplateContent(node)
            let signature = DOMTreeTextView.MarkupSignature(
                nodeType: node.nodeType,
                nodeName: node.nodeName,
                localName: node.localName,
                nodeValue: node.nodeValue,
                pseudoType: node.pseudoType,
                shadowRootType: node.shadowRootType,
                isTemplateContent: isTemplateContent,
                attributes: node.attributes,
                childCount: node.regularChildren.knownCount,
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
                isTemplateContent: isTemplateContent
            )
            markupCache[node.id] = DOMTreeTextView.CachedMarkup(signature: signature, markup: markup)
            return markup
        }

        private func currentPageRootNode() -> DOMNode? {
            dom.currentPageRootNode
        }

        private func visibleChildren(of node: DOMNode) -> [DOMNode] {
            dom.visibleDOMTreeChildren(of: node)
        }

        private func nodeHasDisclosure(_ node: DOMNode) -> Bool {
            dom.hasVisibleDOMTreeChildren(node)
        }

        private func isNodeOpen(_ node: DOMNode) -> Bool {
            if let explicitState = request.expansionState[node.id] {
                return explicitState
            }
            let name = nodeName(for: node).lowercased()
            if name == "head" {
                return false
            }
            return name == "html" || name == "body"
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

        private func isTemplateContent(_ node: DOMNode) -> Bool {
            dom.isTemplateContent(node)
        }

        private func nodeName(for node: DOMNode) -> String {
            if !node.localName.isEmpty {
                return node.localName
            }
            if !node.nodeName.isEmpty {
                return node.nodeName
            }
            return node.nodeValue.isEmpty ? node.nodeName : node.nodeValue
        }
    }
}
#endif
