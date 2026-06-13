#if canImport(UIKit)
import WebInspectorCore
import UIKit

@MainActor
final class DOMTreeRenderedRowsBuilder {
    private let dom: DOMSession
    private let expansionState: DOMTreeExpansionState
    private var renderedLinePrefixCache: [Int: String] = [:]
    private var markupCache: [DOMNode.ID: DOMTreeCachedMarkup] = [:]

    init(dom: DOMSession, expansionState: DOMTreeExpansionState) {
        self.dom = dom
        self.expansionState = expansionState
    }

    func removeCachedMarkup(keepingCapacity: Bool) {
        markupCache.removeAll(keepingCapacity: keepingCapacity)
    }

    func pruneCachedMarkup(keeping nodeIDs: Set<DOMNode.ID>) {
        markupCache = markupCache.filter { nodeIDs.contains($0.key) }
    }

    func build(
        previousRowCapacity: Int,
        previousTextCapacity: Int
    ) -> (rows: [DOMTreeLine], text: String, maxLineDisplayColumnCount: Int) {
        guard let rootNode = dom.currentPageRootNode else {
            return ([], "", 0)
        }

        var nextRows: [DOMTreeLine] = []
        nextRows.reserveCapacity(previousRowCapacity)
        var nextText = ""
        nextText.reserveCapacity(previousTextCapacity)
        var utf16Location = 0
        var maxLineDisplayColumnCount = 0

        func appendLine(_ node: DOMNode, depth: Int, isClosingTag: Bool) -> DOMTreeLine {
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

        func append(_ node: DOMNode, depth: Int) {
            let row = appendLine(node, depth: depth, isClosingTag: false)
            guard row.hasDisclosure, row.isOpen else {
                return
            }
            for child in dom.visibleDOMTreeChildren(of: node) {
                append(child, depth: depth + 1)
            }
            if DOMTreeMarkupBuilder.rendersClosingTagRow(for: node) {
                _ = appendLine(node, depth: depth, isClosingTag: true)
            }
        }

        let displayRoots = rootNode.nodeType == .document ? dom.visibleDOMTreeChildren(of: rootNode) : [rootNode]
        for node in displayRoots {
            append(node, depth: 0)
        }

        return (nextRows, nextText, maxLineDisplayColumnCount)
    }

    func rebuildRow(_ previousRow: DOMTreeLine, rowIndex: Int) -> DOMTreeLine {
        renderedRow(
            for: previousRow.node,
            depth: previousRow.depth,
            rowIndex: rowIndex,
            utf16Location: previousRow.textRange.location,
            isClosingTag: previousRow.isClosingTag
        )
    }

    private func renderedRow(
        for node: DOMNode,
        depth: Int,
        rowIndex: Int,
        utf16Location: Int,
        isClosingTag: Bool = false
    ) -> DOMTreeLine {
        let hasDisclosure = !isClosingTag && nodeHasDisclosure(node)
        let isOpen = !isClosingTag && isNodeOpen(node, depth: depth)
        let markup = cachedMarkup(
            for: node,
            hasDisclosure: hasDisclosure,
            isOpen: isOpen,
            isClosingTag: isClosingTag
        )
        let prefix = renderedLinePrefix(depth: depth)
        let line = prefix + markup.text
        let prefixLength = depth * DOMTreeTextIndentMetrics.indentSpacesPerDepth + DOMTreeTextIndentMetrics.disclosureSlotSpaces
        let lineLength = prefixLength + markup.utf16Length
        var tokens: [DOMTreeToken] = []
        tokens.reserveCapacity(markup.tokens.count)
        for token in markup.tokens {
            tokens.append(
                DOMTreeToken(
                    kind: token.kind,
                    range: NSRange(location: prefixLength + token.range.location, length: token.range.length)
                )
            )
        }

        return DOMTreeLine(
            node: node,
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

    private func cachedMarkup(
        for node: DOMNode,
        hasDisclosure: Bool,
        isOpen: Bool,
        isClosingTag: Bool
    ) -> DOMTreeMarkup {
        let signature = DOMTreeMarkupSignature(
            nodeType: node.nodeType,
            nodeName: node.nodeName,
            localName: node.localName,
            nodeValue: node.nodeValue,
            pseudoType: node.pseudoType,
            shadowRootType: node.shadowRootType,
            isTemplateContent: dom.isTemplateContent(node),
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
        let markup = DOMTreeMarkupBuilder.markup(
            for: node,
            hasDisclosure: hasDisclosure,
            isOpen: isOpen,
            isClosingTag: isClosingTag,
            isTemplateContent: dom.isTemplateContent(node)
        )
        markupCache[node.id] = DOMTreeCachedMarkup(signature: signature, markup: markup)
        return markup
    }

    private func nodeHasDisclosure(_ node: DOMNode) -> Bool {
        dom.hasVisibleDOMTreeChildren(node)
    }

    private func isNodeOpen(_ node: DOMNode, depth: Int) -> Bool {
        if let explicitState = expansionState.isOpen(node.id) {
            return explicitState
        }
        if nodeName(for: node).lowercased() == "head" {
            return false
        }
        let name = nodeName(for: node).lowercased()
        return name == "html" || name == "body"
    }

    private func renderedLinePrefix(depth: Int) -> String {
        if let cached = renderedLinePrefixCache[depth] {
            return cached
        }
        let prefix = String(
            repeating: " ",
            count: depth * DOMTreeTextIndentMetrics.indentSpacesPerDepth + DOMTreeTextIndentMetrics.disclosureSlotSpaces
        )
        renderedLinePrefixCache[depth] = prefix
        return prefix
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
#endif
