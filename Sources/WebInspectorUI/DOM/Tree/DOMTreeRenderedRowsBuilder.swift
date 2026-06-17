#if canImport(UIKit)
import Foundation
import WebInspectorCore

extension DOMTreeTextView {
    @MainActor
    final class RenderedRowsBuildCoordinator {
        typealias IsCurrentBuild = @MainActor (DOMTreeTextView.RenderedRowsBuildRequest) -> Bool
        typealias ShouldApplyBuild = @MainActor (DOMTreeTextView.RenderedRowsBuildResult) -> Bool
        typealias ApplyBuild = @MainActor (DOMTreeTextView.RenderedRowsBuildResult) -> Void

        private let builder: DOMTreeTextView.RenderedRowsBuilder
        private var task: Task<Void, Never>?
        private var generation: UInt64 = 0

        init(builder: DOMTreeTextView.RenderedRowsBuilder) {
            self.builder = builder
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
            apply: @escaping ApplyBuild
        ) {
            let request = builder.makeBuildRequest(
                previousRowCapacity: previousRowCapacity,
                previousTextCapacity: previousTextCapacity
            )
            generation &+= 1
            let buildGeneration = generation
            task?.cancel()
            task = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                defer {
                    if generation == buildGeneration {
                        task = nil
                    }
                }
                let buildResult: DOMTreeTextView.RenderedRowsBuildResult
                do {
                    buildResult = try await builder.build(request)
                } catch is CancellationError {
                    return
                } catch {
                    assertionFailure("DOM tree row rendering failed: \(error)")
                    return
                }
                guard !Task.isCancelled,
                      generation == buildGeneration,
                      isCurrentBuild(request),
                      shouldApply?(buildResult) ?? true else {
                    return
                }
                builder.acceptCompletedBuild(buildResult)
                apply(buildResult)
            }
        }
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
                domSnapshot: dom.snapshot(),
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
            let task = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try DOMTreeTextView.RenderedRowsWorker(request: request).build()
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
    }
}

extension DOMTreeTextView {
    struct RenderedRowsBuildRequest: Sendable {
        let domSnapshot: DOMSession.Snapshot
        let treeRevision: UInt64
        let expansionState: [DOMNode.ID: Bool]
        let previousRowCapacity: Int
        let previousTextCapacity: Int
        let markupCache: [DOMNode.ID: DOMTreeTextView.CachedMarkup]
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

        func build() throws -> DOMTreeTextView.RenderedRowsBuildResult {
            var worker = self
            return try worker.buildRows()
        }

        private mutating func buildRows() throws -> DOMTreeTextView.RenderedRowsBuildResult {
            try Task.checkCancellation()
            guard let rootNode = currentPageRootNode() else {
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

            func appendLine(
                _ node: DOMNode.Snapshot,
                depth: Int,
                isClosingTag: Bool
            ) throws -> DOMTreeTextView.Line {
                try Task.checkCancellation()
                let rowIndex = nextRows.count
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

            func append(_ node: DOMNode.Snapshot, depth: Int) throws {
                try Task.checkCancellation()
                guard visitedNodeIDs.insert(node.id).inserted else {
                    return
                }
                let row = try appendLine(node, depth: depth, isClosingTag: false)
                guard row.hasDisclosure, row.isOpen else {
                    return
                }
                for childID in visibleChildIDs(of: node) {
                    guard let child = request.domSnapshot.nodesByID[childID] else {
                        continue
                    }
                    try append(child, depth: depth + 1)
                }
                if DOMTreeTextView.MarkupBuilder.rendersClosingTagRow(for: node) {
                    _ = try appendLine(node, depth: depth, isClosingTag: true)
                }
            }

            let displayRootIDs = rootNode.nodeType == .document ? visibleChildIDs(of: rootNode) : [rootNode.id]
            for nodeID in displayRootIDs {
                guard let node = request.domSnapshot.nodesByID[nodeID] else {
                    continue
                }
                try append(node, depth: 0)
            }

            return DOMTreeTextView.RenderedRowsBuildResult(
                rows: nextRows,
                text: nextText,
                maxLineDisplayColumnCount: maxLineDisplayColumnCount,
                markupCache: markupCache
            )
        }

        private mutating func renderedRow(
            for node: DOMNode.Snapshot,
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
            for node: DOMNode.Snapshot,
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

        private func currentPageRootNode() -> DOMNode.Snapshot? {
            guard let targetID = request.domSnapshot.currentPageTargetID else {
                return nil
            }
            let documentID = request.domSnapshot.targetStatesByID[targetID]?.currentDocumentID
                ?? request.domSnapshot.targetsByID[targetID]?.currentDocumentID
            guard let documentID,
                  let document = request.domSnapshot.documentsByID[documentID],
                  document.lifecycle == .loaded else {
                return nil
            }
            return request.domSnapshot.nodesByID[document.rootNodeID]
        }

        private func visibleChildIDs(of node: DOMNode.Snapshot) -> [DOMNode.ID] {
            guard isCurrentDocument(node.id.documentID) else {
                return []
            }

            var children: [DOMNode.ID] = []
            if let templateContentID = node.templateContentID {
                children.append(templateContentID)
            }
            if let beforePseudoElementID = node.beforePseudoElementID {
                children.append(beforePseudoElementID)
            }
            children.append(contentsOf: node.otherPseudoElementIDs)
            children.append(contentsOf: effectiveChildIDs(of: node))
            if let afterPseudoElementID = node.afterPseudoElementID {
                children.append(afterPseudoElementID)
            }
            return children
        }

        private func effectiveChildIDs(of node: DOMNode.Snapshot) -> [DOMNode.ID] {
            if nodeName(for: node).lowercased() == "iframe" || nodeName(for: node).lowercased() == "frame",
               let rootNodeID = projectedFrameDocumentRootID(forOwnerNodeID: node.id) {
                return [rootNodeID]
            }
            if let contentDocumentID = node.contentDocumentID,
               isCurrentDocument(contentDocumentID.documentID) {
                return [contentDocumentID]
            }
            return node.shadowRootIDs + node.regularChildren.loadedChildren
        }

        private func projectedFrameDocumentRootID(forOwnerNodeID ownerNodeID: DOMNode.ID) -> DOMNode.ID? {
            for projection in request.domSnapshot.frameDocumentProjections.values
                where projection.ownerNodeID == ownerNodeID && projection.state == .attached {
                guard let document = request.domSnapshot.documentsByID[projection.frameDocumentID],
                      document.lifecycle == .loaded else {
                    continue
                }
                return document.rootNodeID
            }
            return nil
        }

        private func nodeHasDisclosure(_ node: DOMNode.Snapshot) -> Bool {
            guard isCurrentDocument(node.id.documentID) else {
                return node.regularChildren.knownCount > 0
            }
            return !visibleChildIDs(of: node).isEmpty || node.regularChildren.knownCount > 0
        }

        private func isNodeOpen(_ node: DOMNode.Snapshot) -> Bool {
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

        private func isCurrentDocument(_ documentID: DOMDocument.ID) -> Bool {
            guard let document = request.domSnapshot.documentsByID[documentID] else {
                return false
            }
            return document.lifecycle == .loaded
        }

        private func isTemplateContent(_ node: DOMNode.Snapshot) -> Bool {
            guard let parentID = node.parentID,
                  let parent = request.domSnapshot.nodesByID[parentID] else {
                return false
            }
            return parent.templateContentID == node.id
        }

        private func nodeName(for node: DOMNode.Snapshot) -> String {
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
