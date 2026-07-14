#if canImport(UIKit)
import Foundation
import WebInspectorDataKit
import WebInspectorUIBase

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

        private let projector: DOMTreeRenderProjector
        private let expansionState: DOMTreeTextView.ExpansionState
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
        private var cachedMarkupKeysForTestingStorage: Set<DOMTreeTextView.MarkupCacheKey> = []
#endif

        init(
            projector: DOMTreeRenderProjector,
            expansionState: DOMTreeTextView.ExpansionState
        ) {
            self.projector = projector
            self.expansionState = expansionState
        }

        var hasCurrentBuild: Bool {
            task != nil
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
            rootNodeID: DOMNode.ID?,
            visibleNodeIDs: Set<DOMNode.ID>,
            previousRowCapacity: Int,
            previousTextCapacity: Int,
            resetMarkupCache: Bool,
            isCurrentBuild: @escaping IsCurrentBuild,
            shouldApply: ShouldApplyBuild? = nil,
            apply: @escaping ApplyBuild,
            didFinish: FinishBuild? = nil
        ) {
            let request = DOMTreeTextView.RowRenderBuildRequest(
                rootNodeID: rootNodeID,
                visibleNodeIDs: visibleNodeIDs,
                expansionState: expansionState.snapshot,
                baseDocumentRevision: baseDocumentRevision,
                previousRowCapacity: previousRowCapacity,
                previousTextCapacity: previousTextCapacity,
                resetMarkupCache: resetMarkupCache
            )
            generation &+= 1
            let buildGeneration = generation
            task?.cancel()
            currentRequest = request
#if DEBUG
            resumeSuspendedBuildForTesting()
#endif
            task = Task { @MainActor [weak self, projector] in
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
                    buildResult = try await projector.buildRows(request)
                } catch is CancellationError {
                    return
                } catch {
                    WebInspectorUIDOMLog.error(
                        "DOM tree row projection failed: \(String(describing: error))"
                    )
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
#if DEBUG
                cachedMarkupKeysForTestingStorage = buildResult.cachedMarkupKeysForTesting
#endif
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
            cachedMarkupKeysForTestingStorage
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
        let hasUnloadedRegularChildren: Bool
        let isTemplateContent: Bool

        init(node: DOMTreeRenderProjector.Node, isTemplateContent: Bool) {
            id = node.id
            nodeType = node.kind
            nodeName = node.nodeName
            localName = node.localName
            nodeValue = node.nodeValue
            attributes = node.attributeList
            pseudoType = node.pseudoType?.domTreeDisplayName
            shadowRootType = node.shadowRootType?.domTreeDisplayName
            regularChildKnownCount = node.childNodeCount
            hasUnloadedRegularChildren = node.hasUnloadedRegularChildren
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
        let rootNodeID: DOMNode.ID?
        let visibleNodeIDs: Set<DOMNode.ID>
        let expansionState: [DOMNode.ID: Bool]
        let baseDocumentRevision: UInt64
        let previousRowCapacity: Int
        let previousTextCapacity: Int
        let resetMarkupCache: Bool

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
                return !invalidation.affectedNodeIDs.isDisjoint(with: visibleNodeIDs)
            case .structure:
                if let rootNodeID,
                   invalidation.affectedNodeIDs.contains(rootNodeID)
                    || invalidation.parentNodeIDs.contains(rootNodeID) {
                    return true
                }
                return invalidation.intersects(nodeIDs: visibleNodeIDs)
                    || !invalidation.hasScopedNodes
            }
        }
    }

    struct RowRenderBuildResult: Sendable {
        let treeRevision: UInt64
        let rootNodeID: DOMNode.ID?
        let rows: [DOMTreeRowRenderPlan]
        let text: String
        let maxLineDisplayColumnCount: Int
        let renderedNodeIDs: Set<DOMNode.ID>
#if DEBUG
        let collectedNodeIDsForTesting: [DOMNode.ID]
        let cachedMarkupKeysForTesting: Set<DOMTreeTextView.MarkupCacheKey>
#endif

        var observedContent: DOMTreeTextView.ObservedContent {
            DOMTreeTextView.ObservedContent((
                rows: rows,
                text: text,
                maxLineDisplayColumnCount: maxLineDisplayColumnCount
            ))
        }
    }

    struct RowRenderWorkerOutput {
        let rows: [DOMTreeRowRenderPlan]
        let text: String
        let maxLineDisplayColumnCount: Int
        let renderedNodeIDs: Set<DOMNode.ID>
#if DEBUG
        let collectedNodeIDsForTesting: [DOMNode.ID]
#endif
    }
}

extension DOMTreeRenderProjector {
    func buildRows(
        _ request: DOMTreeTextView.RowRenderBuildRequest
    ) throws -> DOMTreeTextView.RowRenderBuildResult {
        try Task.checkCancellation()
        if request.resetMarkupCache {
            markupCache.removeAll(keepingCapacity: true)
        }

        var movedMarkupCache: [DOMTreeTextView.MarkupCacheKey: DOMTreeTextView.CachedMarkup] = [:]
        swap(&movedMarkupCache, &markupCache)
        var worker = DOMTreeTextView.RowRenderWorker(
            request: request,
            rootNodeID: rootNodeID,
            nodesByID: nodesByID,
            parentByNodeID: parentByNodeID,
            markupCache: movedMarkupCache
        )

        let output: DOMTreeTextView.RowRenderWorkerOutput
        do {
            output = try worker.build()
        } catch {
            markupCache = worker.takeMarkupCache()
            throw error
        }
        markupCache = worker.takeMarkupCache()
        let staleCacheKeys = markupCache.keys.filter {
            !output.renderedNodeIDs.contains($0.nodeID)
        }
        for key in staleCacheKeys {
            markupCache.removeValue(forKey: key)
        }

#if DEBUG
        return DOMTreeTextView.RowRenderBuildResult(
            treeRevision: revision,
            rootNodeID: rootNodeID,
            rows: output.rows,
            text: output.text,
            maxLineDisplayColumnCount: output.maxLineDisplayColumnCount,
            renderedNodeIDs: output.renderedNodeIDs,
            collectedNodeIDsForTesting: output.collectedNodeIDsForTesting,
            cachedMarkupKeysForTesting: Set(markupCache.keys)
        )
#else
        return DOMTreeTextView.RowRenderBuildResult(
            treeRevision: revision,
            rootNodeID: rootNodeID,
            rows: output.rows,
            text: output.text,
            maxLineDisplayColumnCount: output.maxLineDisplayColumnCount,
            renderedNodeIDs: output.renderedNodeIDs
        )
#endif
    }
}

extension DOMTreeTextView {
    struct RowRenderWorker {
        private let request: DOMTreeTextView.RowRenderBuildRequest
        private let rootNodeID: DOMNode.ID?
        private let nodesByID: [DOMNode.ID: DOMTreeRenderProjector.Node]
        private let parentByNodeID: [DOMNode.ID: DOMNode.ID]
        private var renderedLinePrefixCache: [Int: String] = [:]
        private var markupCache: [DOMTreeTextView.MarkupCacheKey: DOMTreeTextView.CachedMarkup]

        init(
            request: DOMTreeTextView.RowRenderBuildRequest,
            rootNodeID: DOMNode.ID?,
            nodesByID: [DOMNode.ID: DOMTreeRenderProjector.Node],
            parentByNodeID: [DOMNode.ID: DOMNode.ID],
            markupCache: [DOMTreeTextView.MarkupCacheKey: DOMTreeTextView.CachedMarkup]
        ) {
            self.request = request
            self.rootNodeID = rootNodeID
            self.nodesByID = nodesByID
            self.parentByNodeID = parentByNodeID
            self.markupCache = markupCache
        }

        mutating func takeMarkupCache() -> [DOMTreeTextView.MarkupCacheKey: DOMTreeTextView.CachedMarkup] {
            var result: [DOMTreeTextView.MarkupCacheKey: DOMTreeTextView.CachedMarkup] = [:]
            swap(&result, &markupCache)
            return result
        }

        mutating func build() throws -> DOMTreeTextView.RowRenderWorkerOutput {
            try Task.checkCancellation()
            var nextRows: [DOMTreeRowRenderPlan] = []
            nextRows.reserveCapacity(request.previousRowCapacity)
            var nextText = ""
            nextText.reserveCapacity(request.previousTextCapacity)
            var utf16Location = 0
            var maxLineDisplayColumnCount = 0
            var visitedNodeIDs = Set<DOMNode.ID>()
            var renderedNodeIDs: [DOMNode.ID] = []

            for nodeID in displayRootIDs() {
                try append(
                    nodeID,
                    depth: 0,
                    visitedNodeIDs: &visitedNodeIDs,
                    renderedNodeIDs: &renderedNodeIDs,
                    rows: &nextRows,
                    text: &nextText,
                    utf16Location: &utf16Location,
                    maxLineDisplayColumnCount: &maxLineDisplayColumnCount
                )
            }

#if DEBUG
            return DOMTreeTextView.RowRenderWorkerOutput(
                rows: nextRows,
                text: nextText,
                maxLineDisplayColumnCount: maxLineDisplayColumnCount,
                renderedNodeIDs: Set(renderedNodeIDs),
                collectedNodeIDsForTesting: renderedNodeIDs
            )
#else
            return DOMTreeTextView.RowRenderWorkerOutput(
                rows: nextRows,
                text: nextText,
                maxLineDisplayColumnCount: maxLineDisplayColumnCount,
                renderedNodeIDs: Set(renderedNodeIDs)
            )
#endif
        }

        private mutating func append(
            _ nodeID: DOMNode.ID,
            depth: Int,
            visitedNodeIDs: inout Set<DOMNode.ID>,
            renderedNodeIDs: inout [DOMNode.ID],
            rows: inout [DOMTreeRowRenderPlan],
            text: inout String,
            utf16Location: inout Int,
            maxLineDisplayColumnCount: inout Int
        ) throws {
            try Task.checkCancellation()
            guard visitedNodeIDs.insert(nodeID).inserted,
                  let node = nodesByID[nodeID] else {
                return
            }
            let visibleChildren = visibleChildren(of: node)
            let renderNode = DOMTreeTextView.RowRenderNode(
                node: node,
                isTemplateContent: isTemplateContent(nodeID)
            )
            let hasDisclosure = visibleChildren.hasRenderableChildren
            let isOpen = request.isNodeOpen(
                nodeID: renderNode.id,
                displayName: renderNode.displayName
            )
            try appendLine(
                DOMTreeTextView.RowRenderInput(
                    node: renderNode,
                    depth: depth,
                    hasDisclosure: hasDisclosure,
                    isOpen: isOpen,
                    isClosingTag: false
                ),
                rows: &rows,
                text: &text,
                utf16Location: &utf16Location,
                maxLineDisplayColumnCount: &maxLineDisplayColumnCount
            )
            renderedNodeIDs.append(nodeID)

            guard hasDisclosure, isOpen else {
                return
            }
            for childID in visibleChildren.nodeIDs {
                try append(
                    childID,
                    depth: depth + 1,
                    visitedNodeIDs: &visitedNodeIDs,
                    renderedNodeIDs: &renderedNodeIDs,
                    rows: &rows,
                    text: &text,
                    utf16Location: &utf16Location,
                    maxLineDisplayColumnCount: &maxLineDisplayColumnCount
                )
            }
            guard DOMTreeTextView.MarkupBuilder.rendersClosingTagRow(for: renderNode) else {
                return
            }
            try appendLine(
                DOMTreeTextView.RowRenderInput(
                    node: renderNode,
                    depth: depth,
                    hasDisclosure: false,
                    isOpen: false,
                    isClosingTag: true
                ),
                rows: &rows,
                text: &text,
                utf16Location: &utf16Location,
                maxLineDisplayColumnCount: &maxLineDisplayColumnCount
            )
        }

        private mutating func appendLine(
            _ rowInput: DOMTreeTextView.RowRenderInput,
            rows: inout [DOMTreeRowRenderPlan],
            text: inout String,
            utf16Location: inout Int,
            maxLineDisplayColumnCount: inout Int
        ) throws {
            try Task.checkCancellation()
            let rowIndex = rows.count
            let row = renderedRow(
                for: rowInput,
                rowIndex: rowIndex,
                utf16Location: utf16Location
            )
            maxLineDisplayColumnCount = max(
                maxLineDisplayColumnCount,
                row.displayColumnCount
            )
            rows.append(row)
            if rowIndex > 0 {
                text.append("\n")
            }
            text.append(row.text)
            utf16Location += row.documentRange.length + 1
        }

        private func displayRootIDs() -> [DOMNode.ID] {
            guard let rootNodeID,
                  let root = nodesByID[rootNodeID] else {
                return []
            }
            return root.kind == .document
                ? visibleChildren(of: root).nodeIDs
                : [rootNodeID]
        }

        private func visibleChildren(
            of node: DOMTreeRenderProjector.Node
        ) -> DOMTreeRenderProjector.VisibleChildren {
            var nodeIDs: [DOMNode.ID] = []
            if let templateContentID = node.templateContentID {
                nodeIDs.append(templateContentID)
            }
            if let beforePseudoElementID = node.beforePseudoElementID {
                nodeIDs.append(beforePseudoElementID)
            }
            nodeIDs.append(contentsOf: node.otherPseudoElementIDs)
            if let contentDocumentID = node.contentDocumentID {
                nodeIDs.append(contentDocumentID)
            } else {
                nodeIDs.append(contentsOf: node.shadowRootIDs)
                if case let .loaded(childIDs) = node.children {
                    nodeIDs.append(contentsOf: childIDs)
                }
            }
            if let afterPseudoElementID = node.afterPseudoElementID {
                nodeIDs.append(afterPseudoElementID)
            }
            return DOMTreeRenderProjector.VisibleChildren(
                nodeIDs: nodeIDs,
                hasRenderableChildren: nodeIDs.isEmpty == false || node.childNodeCount > 0
            )
        }

        private func isTemplateContent(_ id: DOMNode.ID) -> Bool {
            guard let parentID = parentByNodeID[id],
                  let parent = nodesByID[parentID] else {
                return false
            }
            return parent.templateContentID == id
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
            let prefixLength = rowInput.depth * DOMTreeTextView.IndentMetrics.indentSpacesPerDepth
                + DOMTreeTextView.IndentMetrics.disclosureSlotSpaces
            let lineLength = prefixLength + markup.utf16Length
            var tokens: [DOMTreeTextView.Token] = []
            tokens.reserveCapacity(markup.tokens.count)
            for token in markup.tokens {
                tokens.append(
                    DOMTreeTextView.Token(
                        kind: token.kind,
                        range: NSRange(
                            location: prefixLength + token.range.location,
                            length: token.range.length
                        )
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
                isOpen: rowInput.isOpen,
                hasUnloadedRegularChildren: rowInput.node.hasUnloadedRegularChildren
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
            markupCache[cacheKey] = DOMTreeTextView.CachedMarkup(
                signature: signature,
                markup: markup
            )
            return markup
        }

        private mutating func renderedLinePrefix(depth: Int) -> String {
            if let cached = renderedLinePrefixCache[depth] {
                return cached
            }
            let prefix = String(
                repeating: " ",
                count: depth * DOMTreeTextView.IndentMetrics.indentSpacesPerDepth
                    + DOMTreeTextView.IndentMetrics.disclosureSlotSpaces
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
