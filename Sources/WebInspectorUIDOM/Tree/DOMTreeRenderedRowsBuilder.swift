#if canImport(UIKit)
import Foundation
import WebInspectorDataKit
import WebInspectorUIBase

extension DOMTreeTextView {
    @MainActor
    final class RowRenderBuildCoordinator {
        struct SemanticUpdate: Equatable {
            fileprivate let token: UInt64
            fileprivate let sourceRevision: UInt64
            fileprivate let cancelledBuild: Bool
        }

        struct PendingInvalidation {
            let invalidation: DOMTreeRenderInvalidation
            let isInitial: Bool
            let requiresRoute: Bool
        }

        struct SemanticUpdateAcceptance {
            let isInitial: Bool
            let requiresRoute: Bool
        }

        typealias CanCommitBuild = @MainActor (
            DOMTreeTextView.RowRenderBuildRequest
        ) -> Bool
        typealias ApplyBuild = @MainActor (DOMTreeTextView.RowRenderBuildResult) -> Void
        typealias FinishBuild = @MainActor () -> Void

        private let projector: DOMTreeRenderProjector
        private let expansionState = DOMTreeTextView.ExpansionState()
        private var task: Task<Void, Never>?
        private var currentRequest: DOMTreeTextView.RowRenderBuildRequest?
        private var nextRequestToken: UInt64 = 0
        private var nextSemanticUpdateToken: UInt64 = 0
        private var pendingSemanticUpdate: SemanticUpdate?
        private(set) var currentMetadata: DOMTreeRenderMetadata = .empty
        private var lastRoutedSourceRevision: UInt64?
        private var pendingInvalidation: DOMTreeRenderInvalidation?
        private var pendingInvalidationIsInitial = false
        private var pendingInvalidationRequiresRoute = false
#if DEBUG
        private struct BuildCompletionWaiter {
            let continuation: CheckedContinuation<Bool, Never>
            let timeoutTask: Task<Void, Never>
        }

        private var shouldSuspendNextBuildForTesting = false
        private var suspendedBuildContinuationForTesting: CheckedContinuation<Void, Never>?
        private var buildSuspensionWaitersForTesting: [CheckedContinuation<Void, Never>] = []
        private var shouldSuspendNextCompletedBuildForTesting = false
        private var suspendedCompletedBuildContinuationForTesting: CheckedContinuation<Void, Never>?
        private var completedBuildSuspensionWaitersForTesting: [CheckedContinuation<Void, Never>] = []
        private var nextBuildCompletionWaiterID: UInt64 = 0
        private var buildCompletionWaiters: [UInt64: BuildCompletionWaiter] = [:]
        private(set) var semanticInputCancellationCountForTesting = 0
        private(set) var lastCommittedRequestIdentityForTesting:
            DOMTreeTextView.RowRenderRequestIdentity?
#endif

        init(projector: DOMTreeRenderProjector) {
            self.projector = projector
        }

        var hasCurrentBuild: Bool {
            task != nil
        }

        var expansionSnapshot: DOMTreeTextView.ExpansionState.Snapshot {
            expansionState.snapshot
        }

        var pendingInvalidationRevision: UInt64? {
            pendingInvalidation?.revision
        }

        func isNodeOpen(_ nodeID: DOMNode.ID) -> Bool? {
            expansionState.isOpen(nodeID)
        }

        @discardableResult
        func setIsNodeOpen(_ isOpen: Bool, for nodeID: DOMNode.ID) -> Bool {
            guard expansionState.setIsOpen(isOpen, for: nodeID) else {
                return false
            }
            supersedeCurrentBuild()
            return true
        }

        @discardableResult
        func removeAllExpansion() -> Bool {
            guard expansionState.removeAll() else {
                return false
            }
            supersedeCurrentBuild()
            return true
        }

        func beginSemanticUpdate(sourceRevision: UInt64) -> SemanticUpdate {
            precondition(
                pendingSemanticUpdate == nil,
                "DOM render coordinator accepts one ordered semantic update at a time."
            )
            nextSemanticUpdateToken &+= 1
            let cancelledBuild = supersedeCurrentBuild()
#if DEBUG
            if cancelledBuild {
                semanticInputCancellationCountForTesting += 1
            }
#endif
            let update = SemanticUpdate(
                token: nextSemanticUpdateToken,
                sourceRevision: sourceRevision,
                cancelledBuild: cancelledBuild
            )
            pendingSemanticUpdate = update
            return update
        }

        func acceptSemanticUpdate(
            _ update: SemanticUpdate,
            metadata: DOMTreeRenderMetadata
        ) -> SemanticUpdateAcceptance {
            precondition(
                pendingSemanticUpdate == update,
                "DOM render semantic updates must complete in accepted source order."
            )
            precondition(
                metadata.revision == update.sourceRevision,
                "DOM render projection returned a different source revision."
            )
            pendingSemanticUpdate = nil
            currentMetadata = metadata
            return SemanticUpdateAcceptance(
                isInitial: lastRoutedSourceRevision == nil,
                requiresRoute: update.cancelledBuild
            )
        }

        @discardableResult
        func rejectSemanticUpdate(_ update: SemanticUpdate) -> Bool {
            precondition(
                pendingSemanticUpdate == update,
                "DOM render semantic updates must fail in accepted source order."
            )
            pendingSemanticUpdate = nil
            guard update.cancelledBuild else {
                return false
            }
            enqueueCurrentInvalidation(forceRoute: true)
            return true
        }

        @discardableResult
        func enqueueInvalidation(
            _ invalidation: DOMTreeRenderInvalidation,
            isInitial: Bool,
            requiresRoute: Bool
        ) -> UInt64 {
            pendingInvalidation = pendingInvalidation?.merging(with: invalidation) ?? invalidation
            pendingInvalidationIsInitial = pendingInvalidationIsInitial || isInitial
            pendingInvalidationRequiresRoute = self.pendingInvalidationRequiresRoute
                || requiresRoute
                || currentBuildMayRender(invalidation)
            return pendingInvalidation?.revision ?? invalidation.revision
        }

        func takePendingInvalidation() -> PendingInvalidation? {
            guard let pendingInvalidation else {
                return nil
            }
            let result = PendingInvalidation(
                invalidation: pendingInvalidation,
                isInitial: pendingInvalidationIsInitial,
                requiresRoute: pendingInvalidationRequiresRoute
            )
            self.pendingInvalidation = nil
            pendingInvalidationIsInitial = false
            pendingInvalidationRequiresRoute = false
            lastRoutedSourceRevision = result.invalidation.revision
            return result
        }

        @discardableResult
        func enqueueCurrentInvalidationIfNeeded() -> Bool {
            guard lastRoutedSourceRevision != currentMetadata.revision else {
                return false
            }
            enqueueCurrentInvalidation(forceRoute: true)
            return true
        }

        @discardableResult
        func suspendRendering() -> Bool {
            guard supersedeCurrentBuild() else {
                return false
            }
            enqueueCurrentInvalidation(forceRoute: true)
            return true
        }

        func cancel() {
            pendingSemanticUpdate = nil
            supersedeCurrentBuild()
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

        var currentRequestIdentityForTesting:
            DOMTreeTextView.RowRenderRequestIdentity? {
            currentRequest?.identity
        }
#endif

        func currentBuildMayRender(_ invalidation: DOMTreeRenderInvalidation) -> Bool {
            currentRequest?.mayRender(invalidation) == true
        }

        func startBuild(
            baseDocumentRevision: UInt64,
            visibleNodeIDs: Set<DOMNode.ID>,
            previousRows: [DOMTreeRowRenderPlan],
            previousTextUTF16Length: Int,
            resetMarkupCache: Bool,
            canCommit: @escaping CanCommitBuild,
            apply: @escaping ApplyBuild,
            didQueueInvalidation: FinishBuild? = nil,
            didFinish: FinishBuild? = nil
        ) {
            supersedeCurrentBuild()
            nextRequestToken &+= 1
            let expansionSnapshot = expansionState.snapshot
            let request = DOMTreeTextView.RowRenderBuildRequest(
                identity: DOMTreeTextView.RowRenderRequestIdentity(
                    token: nextRequestToken,
                    documentRootNodeID: currentMetadata.rootNodeID,
                    sourceRevision: currentMetadata.revision,
                    expansionRevision: expansionSnapshot.revision
                ),
                visibleNodeIDs: visibleNodeIDs,
                expansionState: expansionSnapshot.states,
                baseDocumentRevision: baseDocumentRevision,
                previousRows: previousRows,
                previousTextUTF16Length: previousTextUTF16Length,
                resetMarkupCache: resetMarkupCache
            )
            currentRequest = request
            task = Task { @MainActor [weak self, projector] in
                guard let self else {
                    return
                }
                var shouldNotifyFinish = false
                defer {
                    if currentRequest?.identity.token == request.identity.token {
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
#if DEBUG
                await suspendCompletedBuildIfNeededForTesting()
#endif
                guard !Task.isCancelled,
                      currentRequest?.identity == request.identity,
                      request.identity.documentRootNodeID == currentMetadata.rootNodeID,
                      request.identity.sourceRevision == currentMetadata.revision,
                      request.identity.expansionRevision == expansionState.snapshot.revision,
                      request.identity.documentRootNodeID == buildResult.rootNodeID,
                      request.identity.sourceRevision == buildResult.treeRevision else {
                    return
                }
                guard canCommit(request) else {
                    enqueueCurrentInvalidation(forceRoute: true)
                    didQueueInvalidation?()
                    return
                }
#if DEBUG
                lastCommittedRequestIdentityForTesting = request.identity
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

        func suspendNextCompletedBuildForTesting() {
            shouldSuspendNextCompletedBuildForTesting = true
        }

        func waitForCompletedBuildSuspensionForTesting() async {
            if suspendedCompletedBuildContinuationForTesting != nil {
                return
            }
            await withCheckedContinuation { continuation in
                completedBuildSuspensionWaitersForTesting.append(continuation)
            }
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

        func resumeSuspendedCompletedBuildForTesting() {
            guard let continuation = suspendedCompletedBuildContinuationForTesting else {
                return
            }
            suspendedCompletedBuildContinuationForTesting = nil
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

        private func suspendCompletedBuildIfNeededForTesting() async {
            guard shouldSuspendNextCompletedBuildForTesting else {
                return
            }
            shouldSuspendNextCompletedBuildForTesting = false
            await withCheckedContinuation { continuation in
                suspendedCompletedBuildContinuationForTesting = continuation
                let waiters = completedBuildSuspensionWaitersForTesting
                completedBuildSuspensionWaitersForTesting.removeAll(keepingCapacity: true)
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
#endif

        @discardableResult
        private func supersedeCurrentBuild() -> Bool {
            nextRequestToken &+= 1
            let hadCurrentBuild = task != nil
            task?.cancel()
            task = nil
            currentRequest = nil
#if DEBUG
            resumeSuspendedBuildForTesting()
            resumeSuspendedCompletedBuildForTesting()
            resolveBuildCompletionWaiters(result: true)
#endif
            return hadCurrentBuild
        }

        private func enqueueCurrentInvalidation(forceRoute: Bool) {
            enqueueInvalidation(
                .initial(metadata: currentMetadata),
                isInitial: false,
                requiresRoute: forceRoute
            )
        }
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

    struct RowRenderRequestIdentity: Equatable, Sendable {
        let token: UInt64
        let documentRootNodeID: DOMNode.ID?
        let sourceRevision: UInt64
        let expansionRevision: UInt64
    }

    struct RowRenderBuildRequest: Sendable {
        let identity: DOMTreeTextView.RowRenderRequestIdentity
        let visibleNodeIDs: Set<DOMNode.ID>
        let expansionState: [DOMNode.ID: Bool]
        let baseDocumentRevision: UInt64
        let previousRows: [DOMTreeRowRenderPlan]
        let previousTextUTF16Length: Int
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
                if let rootNodeID = identity.documentRootNodeID,
                   invalidation.affectedNodeIDs.contains(rootNodeID)
                    || invalidation.parentNodeIDs.contains(rootNodeID) {
                    return true
                }
                return invalidation.intersects(nodeIDs: visibleNodeIDs)
                    || !invalidation.hasScopedNodes
            }
        }
    }

    enum RowRenderDifference: Equatable, Sendable {
        case noChange
        case replaceDocument(resetTextFragments: Bool)
        case replaceCharacters(RowRenderTextEdit)
    }

    struct RowRenderTextEdit: Equatable, Sendable {
        let previousRange: NSRange
        let nextRowsRange: Range<Int>
    }

    struct RowRenderBuildResult: Sendable {
        let treeRevision: UInt64
        let rootNodeID: DOMNode.ID?
        let rowIndex: DOMTreeRowIndex
        let maxLineDisplayColumnCount: Int
        let difference: DOMTreeTextView.RowRenderDifference

        var rows: [DOMTreeRowRenderPlan] {
            rowIndex.rows
        }
    }

    struct RowRenderWorkerOutput {
        let rowIndex: DOMTreeRowIndex
        let maxLineDisplayColumnCount: Int
        let difference: DOMTreeTextView.RowRenderDifference
    }

    struct RowRenderDifferenceBuilder {
        let previousRows: [DOMTreeRowRenderPlan]
        let previousTextUTF16Length: Int
        let nextRows: [DOMTreeRowRenderPlan]
        let resetMarkupCache: Bool

        func build() throws -> DOMTreeTextView.RowRenderDifference {
            try Task.checkCancellation()
            if resetMarkupCache {
                return .replaceDocument(resetTextFragments: true)
            }
            if previousRows.isEmpty || nextRows.isEmpty {
                return previousRows.isEmpty && nextRows.isEmpty
                    ? .noChange
                    : .replaceDocument(resetTextFragments: false)
            }

            var prefix = 0
            while prefix < previousRows.count,
                  prefix < nextRows.count,
                  previousRows[prefix].hasSameRenderedContent(as: nextRows[prefix]) {
                if prefix.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                prefix += 1
            }

            guard prefix != previousRows.count || prefix != nextRows.count else {
                return .noChange
            }

            var previousSuffix = previousRows.count
            var nextSuffix = nextRows.count
            var comparedSuffixCount = 0
            while previousSuffix > prefix,
                  nextSuffix > prefix,
                  previousRows[previousSuffix - 1].hasSameRenderedContent(
                    as: nextRows[nextSuffix - 1]
                  ) {
                if comparedSuffixCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                previousSuffix -= 1
                nextSuffix -= 1
                comparedSuffixCount += 1
            }

            return .replaceCharacters(
                DOMTreeTextView.RowRenderTextEdit(
                    previousRange: textEditRange(
                        previousStart: prefix,
                        previousEnd: previousSuffix
                    ),
                    nextRowsRange: prefix..<nextSuffix
                )
            )
        }

        private func textEditRange(
            previousStart: Int,
            previousEnd: Int
        ) -> NSRange {
            let location: Int
            let length: Int
            if previousStart == 0 {
                location = 0
                if previousEnd == previousRows.count {
                    length = previousTextUTF16Length
                } else {
                    length = previousRows[previousEnd].documentRange.location
                }
            } else {
                let precedingRow = previousRows[previousStart - 1]
                location = NSMaxRange(precedingRow.documentRange)
                if previousEnd == previousRows.count {
                    length = previousTextUTF16Length - location
                } else {
                    length = previousRows[previousEnd].documentRange.location - location
                }
            }
            return NSRange(location: location, length: length)
        }
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
            !output.rowIndex.visibleNodeIDs.contains($0.nodeID)
        }
        for key in staleCacheKeys {
            markupCache.removeValue(forKey: key)
        }

        return DOMTreeTextView.RowRenderBuildResult(
            treeRevision: revision,
            rootNodeID: rootNodeID,
            rowIndex: output.rowIndex,
            maxLineDisplayColumnCount: output.maxLineDisplayColumnCount,
            difference: output.difference
        )
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
            nextRows.reserveCapacity(request.previousRows.count)
            var utf16Location = 0
            var maxLineDisplayColumnCount = 0
            var visitedNodeIDs = Set<DOMNode.ID>()

            for nodeID in displayRootIDs() {
                try append(
                    nodeID,
                    depth: 0,
                    visitedNodeIDs: &visitedNodeIDs,
                    rows: &nextRows,
                    utf16Location: &utf16Location,
                    maxLineDisplayColumnCount: &maxLineDisplayColumnCount
                )
            }

            let difference = try DOMTreeTextView.RowRenderDifferenceBuilder(
                previousRows: request.previousRows,
                previousTextUTF16Length: request.previousTextUTF16Length,
                nextRows: nextRows,
                resetMarkupCache: request.resetMarkupCache
            ).build()
            let rowIndex = try DOMTreeRowIndex(cancellableRows: nextRows)
            return DOMTreeTextView.RowRenderWorkerOutput(
                rowIndex: rowIndex,
                maxLineDisplayColumnCount: maxLineDisplayColumnCount,
                difference: difference
            )
        }

        private mutating func append(
            _ nodeID: DOMNode.ID,
            depth: Int,
            visitedNodeIDs: inout Set<DOMNode.ID>,
            rows: inout [DOMTreeRowRenderPlan],
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
                utf16Location: &utf16Location,
                maxLineDisplayColumnCount: &maxLineDisplayColumnCount
            )

            guard hasDisclosure, isOpen else {
                return
            }
            for childID in visibleChildren.nodeIDs {
                try append(
                    childID,
                    depth: depth + 1,
                    visitedNodeIDs: &visitedNodeIDs,
                    rows: &rows,
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
                utf16Location: &utf16Location,
                maxLineDisplayColumnCount: &maxLineDisplayColumnCount
            )
        }

        private mutating func appendLine(
            _ rowInput: DOMTreeTextView.RowRenderInput,
            rows: inout [DOMTreeRowRenderPlan],
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
