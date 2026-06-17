#if canImport(UIKit)
import WebInspectorCore
import Observation
import UIKit

extension DOMTreeTextView {
    enum IndentMetrics {
        static let indentSpacesPerDepth = 2
        static let disclosureSlotSpaces = 2
    }
}

extension DOMTreeTextView {
    @MainActor
    @Observable
    final class ExpansionState {
        private var states: [DOMNode.ID: Bool] = [:]

        var snapshot: [DOMNode.ID: Bool] {
            states
        }

        func isOpen(_ nodeID: DOMNode.ID) -> Bool? {
            states[nodeID]
        }

        func setIsOpen(_ isOpen: Bool, for nodeID: DOMNode.ID) {
            states[nodeID] = isOpen
        }

        func removeAll() {
            guard !states.isEmpty else {
                return
            }
            states.removeAll(keepingCapacity: true)
        }
    }
}

extension DOMTreeTextView {
    struct ObservedLine: Equatable, Sendable {
        var nodeID: DOMNode.ID
        var depth: Int
        var text: String
        var tokens: [DOMTreeTextView.Token]
        var displayColumnCount: Int
        var hasDisclosure: Bool
        var isOpen: Bool
        var isClosingTag: Bool

        init(_ line: DOMTreeTextView.Line) {
            nodeID = line.nodeID
            depth = line.depth
            text = line.text
            tokens = line.tokens
            displayColumnCount = line.displayColumnCount
            hasDisclosure = line.hasDisclosure
            isOpen = line.isOpen
            isClosingTag = line.isClosingTag
        }
    }
}

extension DOMTreeTextView {
    struct ObservedContent: Equatable, Sendable {
        var lines: [DOMTreeTextView.ObservedLine]
        var text: String
        var maxLineDisplayColumnCount: Int

        init(_ buildResult: (rows: [DOMTreeTextView.Line], text: String, maxLineDisplayColumnCount: Int)) {
            lines = buildResult.rows.map(DOMTreeTextView.ObservedLine.init)
            text = buildResult.text
            maxLineDisplayColumnCount = buildResult.maxLineDisplayColumnCount
        }
    }
}

extension DOMTreeTextView {
    @MainActor
    struct RenderedRows {
        private(set) var rows: [DOMTreeTextView.Line]
        private(set) var visibleNodeIDs: Set<DOMNode.ID>
        private var rowIndexByNodeID: [DOMNode.ID: Int]

        init(rows: [DOMTreeTextView.Line] = []) {
            self.rows = rows
            visibleNodeIDs = []
            rowIndexByNodeID = [:]
            rebuildIndex()
        }

        mutating func replaceRows(_ rows: [DOMTreeTextView.Line]) {
            self.rows = rows
            rebuildIndex()
        }

        func rowIndex(for nodeID: DOMNode.ID) -> Int? {
            rowIndexByNodeID[nodeID]
        }

        func contains(nodeID: DOMNode.ID) -> Bool {
            rowIndexByNodeID[nodeID] != nil
        }

        func row(for nodeID: DOMNode.ID) -> DOMTreeTextView.Line? {
            guard let rowIndex = rowIndexByNodeID[nodeID],
                  rows.indices.contains(rowIndex) else {
                return nil
            }
            return rows[rowIndex]
        }

        func rowsBetween(_ firstNodeID: DOMNode.ID, _ secondNodeID: DOMNode.ID) -> ArraySlice<DOMTreeTextView.Line> {
            guard let firstIndex = rowIndexByNodeID[firstNodeID],
                  let secondIndex = rowIndexByNodeID[secondNodeID]
            else {
                return []
            }
            let lowerBound = min(firstIndex, secondIndex)
            let upperBound = max(firstIndex, secondIndex)
            return rows[lowerBound...upperBound]
        }

    #if DEBUG
        mutating func removeRowIndex(for nodeID: DOMNode.ID) {
            rowIndexByNodeID.removeValue(forKey: nodeID)
        }
    #endif

        private mutating func rebuildIndex() {
            var nextRowIndexByNodeID: [DOMNode.ID: Int] = [:]
            nextRowIndexByNodeID.reserveCapacity(rows.count)
            var nextVisibleNodeIDs = Set<DOMNode.ID>()
            nextVisibleNodeIDs.reserveCapacity(rows.count)
            for row in rows {
                if !row.isClosingTag, nextRowIndexByNodeID[row.nodeID] == nil {
                    nextRowIndexByNodeID[row.nodeID] = row.rowIndex
                }
                nextVisibleNodeIDs.insert(row.nodeID)
            }
            rowIndexByNodeID = nextRowIndexByNodeID
            visibleNodeIDs = nextVisibleNodeIDs
        }
    }
}

extension DOMTreeTextView {
    @MainActor
    struct SelectionController {
        private(set) var selectedNodeIDs: Set<DOMNode.ID> = []
        private(set) var lastNodeID: DOMNode.ID?
        private var shiftAnchorNodeID: DOMNode.ID?
        private var shiftRangeNodeIDs: Set<DOMNode.ID> = []

        var hasExplicitSelection: Bool {
            !selectedNodeIDs.isEmpty
        }

        var selectedCount: Int {
            selectedNodeIDs.count
        }

        var hasState: Bool {
            !selectedNodeIDs.isEmpty
                || lastNodeID != nil
                || shiftAnchorNodeID != nil
                || !shiftRangeNodeIDs.isEmpty
        }

        func contains(_ nodeID: DOMNode.ID) -> Bool {
            selectedNodeIDs.contains(nodeID)
        }

        mutating func notePrimarySelection(_ nodeID: DOMNode.ID) {
            lastNodeID = nodeID
        }

        mutating func clear(keepingLast nodeID: DOMNode.ID?) {
            selectedNodeIDs.removeAll(keepingCapacity: true)
            lastNodeID = nodeID
            shiftAnchorNodeID = nil
            shiftRangeNodeIDs.removeAll(keepingCapacity: true)
        }

        mutating func reset() {
            clear(keepingLast: nil)
        }

        mutating func selectAll(rows: [DOMTreeTextView.Line]) {
            guard !rows.isEmpty else {
                clear(keepingLast: nil)
                return
            }
            selectedNodeIDs = Set(rows.map(\.nodeID))
            lastNodeID = rows.last?.nodeID
            shiftAnchorNodeID = rows.first?.nodeID
            shiftRangeNodeIDs = selectedNodeIDs
        }

        mutating func toggle(
            row: DOMTreeTextView.Line,
            renderedRows: DOMTreeTextView.RenderedRows,
            selectedNodeID: DOMNode.ID?
        ) {
            var nextSelectedNodeIDs = selectedNodeIDs
            if nextSelectedNodeIDs.isEmpty {
                if let lastNodeID, renderedRows.contains(nodeID: lastNodeID) {
                    nextSelectedNodeIDs.insert(lastNodeID)
                } else if let selectedNodeID, renderedRows.contains(nodeID: selectedNodeID) {
                    nextSelectedNodeIDs.insert(selectedNodeID)
                }
            }

            if nextSelectedNodeIDs.contains(row.nodeID) {
                nextSelectedNodeIDs.remove(row.nodeID)
            } else {
                nextSelectedNodeIDs.insert(row.nodeID)
            }
            if nextSelectedNodeIDs.isEmpty {
                nextSelectedNodeIDs.insert(row.nodeID)
            }

            selectedNodeIDs = nextSelectedNodeIDs
            lastNodeID = row.nodeID
            shiftAnchorNodeID = nil
            shiftRangeNodeIDs.removeAll(keepingCapacity: true)
        }

        mutating func extend(
            to row: DOMTreeTextView.Line,
            renderedRows: DOMTreeTextView.RenderedRows,
            selectedNodeID: DOMNode.ID?
        ) -> Bool {
            guard let anchorNodeID = anchorNodeID(
                renderedRows: renderedRows,
                selectedNodeID: selectedNodeID
            ) else {
                return false
            }
            let rangeRows = renderedRows.rowsBetween(anchorNodeID, row.nodeID)
            let rangeNodeIDs = Set(rangeRows.map(\.nodeID))
            guard !rangeNodeIDs.isEmpty else {
                return false
            }

            var nextSelectedNodeIDs = selectedNodeIDs
            if nextSelectedNodeIDs.isEmpty,
               let selectedNodeID,
               renderedRows.contains(nodeID: selectedNodeID) {
                nextSelectedNodeIDs.insert(selectedNodeID)
            }
            nextSelectedNodeIDs.subtract(shiftRangeNodeIDs)
            nextSelectedNodeIDs.formUnion(rangeNodeIDs)

            selectedNodeIDs = nextSelectedNodeIDs
            shiftAnchorNodeID = anchorNodeID
            shiftRangeNodeIDs = rangeNodeIDs
            lastNodeID = row.nodeID
            return true
        }

        func focusedNodeID(selectedNodeID: DOMNode.ID?, fallbackNodeID: DOMNode.ID?) -> DOMNode.ID? {
            lastNodeID ?? selectedNodeID ?? fallbackNodeID
        }

        mutating func reconcileAfterReload(visibleNodeIDs: Set<DOMNode.ID>) {
            selectedNodeIDs.formIntersection(visibleNodeIDs)
            shiftRangeNodeIDs.formIntersection(visibleNodeIDs)
            if let nodeID = lastNodeID, !visibleNodeIDs.contains(nodeID) {
                lastNodeID = nil
            }
            if let nodeID = shiftAnchorNodeID, !visibleNodeIDs.contains(nodeID) {
                shiftAnchorNodeID = nil
                shiftRangeNodeIDs.removeAll(keepingCapacity: true)
            }
            if selectedNodeIDs.isEmpty {
                shiftRangeNodeIDs.removeAll(keepingCapacity: true)
            }
        }

        mutating func reconcileRenderedSelection(
            selectedNodeID: DOMNode.ID?,
            selectedNodeIDChanged: Bool,
            clearsMultiSelectionForDocumentSelection: Bool
        ) -> Bool {
            if clearsMultiSelectionForDocumentSelection {
                if let selectedNodeID {
                    guard hasStateForClearing(keepingLast: selectedNodeID) else {
                        return false
                    }
                    clear(keepingLast: selectedNodeID)
                    return true
                }

                guard hasState else {
                    return false
                }
                clear(keepingLast: nil)
                return true
            }

            guard selectedNodeIDChanged else {
                return false
            }
            if let selectedNodeID, !selectedNodeIDs.contains(selectedNodeID) {
                clear(keepingLast: selectedNodeID)
                return true
            }
            if selectedNodeID == nil {
                clear(keepingLast: nil)
                return true
            }
            return false
        }

        func selectedNodeIDsInDisplayOrder(rows: [DOMTreeTextView.Line]) -> [DOMNode.ID] {
            rows.compactMap { row in
                !row.isClosingTag && selectedNodeIDs.contains(row.nodeID) ? row.nodeID : nil
            }
        }

        private func anchorNodeID(
            renderedRows: DOMTreeTextView.RenderedRows,
            selectedNodeID: DOMNode.ID?
        ) -> DOMNode.ID? {
            if let shiftAnchorNodeID,
               renderedRows.contains(nodeID: shiftAnchorNodeID) {
                return shiftAnchorNodeID
            }
            if let lastNodeID,
               renderedRows.contains(nodeID: lastNodeID) {
                return lastNodeID
            }
            if let selectedNodeID,
               renderedRows.contains(nodeID: selectedNodeID) {
                return selectedNodeID
            }
            return renderedRows.rows.first?.nodeID
        }

        private func hasStateForClearing(keepingLast nodeID: DOMNode.ID) -> Bool {
            !selectedNodeIDs.isEmpty
                || lastNodeID != nodeID
                || shiftAnchorNodeID != nil
                || !shiftRangeNodeIDs.isEmpty
        }
    }
}

extension DOMTreeTextView {
    struct Line: Sendable {
        let nodeID: DOMNode.ID
        let depth: Int
        let rowIndex: Int
        let text: String
        let textRange: NSRange
        let markupRange: NSRange
        let tokens: [DOMTreeTextView.Token]
        let displayColumnCount: Int
        let hasDisclosure: Bool
        let isOpen: Bool
        let isClosingTag: Bool

        func hasSameRenderedContent(as other: DOMTreeTextView.Line) -> Bool {
            nodeID == other.nodeID
                && depth == other.depth
                && text == other.text
                && tokens == other.tokens
                && displayColumnCount == other.displayColumnCount
                && hasDisclosure == other.hasDisclosure
                && isOpen == other.isOpen
                && isClosingTag == other.isClosingTag
        }
    }
}

extension DOMTreeTextView {
    struct Token: Equatable, Sendable {
        let kind: DOMTreeTextView.Token.Kind
        let range: NSRange
    }
}

extension DOMTreeTextView {
    struct RowDiff: Sendable {
        let previousStart: Int
        let previousEnd: Int
        let nextStart: Int
        let nextEnd: Int
    }
}

extension DOMTreeTextView {
    struct MarkupSignature: Hashable, Sendable {
        let nodeType: DOMNode.Kind
        let nodeName: String
        let localName: String
        let nodeValue: String
        let pseudoType: String?
        let shadowRootType: String?
        let isTemplateContent: Bool
        let attributes: [DOMNode.Attribute]
        let childCount: Int
        let hasDisclosure: Bool
        let isOpen: Bool
        let isClosingTag: Bool
    }
}

extension DOMTreeTextView {
    struct CachedMarkup: Sendable {
        let signature: DOMTreeTextView.MarkupSignature
        let markup: DOMTreeTextView.Markup
    }
}

extension DOMTreeTextView.Token {
    enum Kind: String, Sendable {
        case punctuation
        case tagName
        case attributeName
        case attributeValue
        case text
        case comment
        case doctype
        case fallback

        @MainActor
        func color(resolvedFor traitCollection: UITraitCollection) -> UIColor {
            let theme = DOMTreeTextView.HighlightTheme.webInspector
            let dynamicColor = switch self {
            case .punctuation:
                theme.tagPunctuation
            case .tagName:
                theme.nodeName
            case .attributeName:
                theme.nodeAttribute
            case .attributeValue:
                theme.nodeValue
            case .text:
                theme.textSecondary
            case .comment:
                theme.textSecondary
            case .doctype:
                theme.nodeAttribute
            case .fallback:
                theme.textSecondary
            }
            return dynamicColor.resolvedColor(with: traitCollection)
        }
    }
}

extension DOMTreeTextView {
    @MainActor
    struct ResolvedTextAttributes {
        let userInterfaceStyle: UIUserInterfaceStyle
        let base: [NSAttributedString.Key: Any]
        let tokenColors: [DOMTreeTextView.Token.Kind: UIColor]

        init(traitCollection: UITraitCollection) {
            userInterfaceStyle = traitCollection.userInterfaceStyle
            let theme = DOMTreeTextView.HighlightTheme.webInspector
            base = [
                .font: DOMTreeTextView.font,
                .paragraphStyle: DOMTreeTextView.paragraphStyle,
                .baselineOffset: DOMTreeTextView.textBaselineOffset,
                .foregroundColor: theme.baseForeground.resolvedColor(with: traitCollection)
            ]
            tokenColors = [
                .punctuation: theme.tagPunctuation.resolvedColor(with: traitCollection),
                .tagName: theme.nodeName.resolvedColor(with: traitCollection),
                .attributeName: theme.nodeAttribute.resolvedColor(with: traitCollection),
                .attributeValue: theme.nodeValue.resolvedColor(with: traitCollection),
                .text: theme.textSecondary.resolvedColor(with: traitCollection),
                .comment: theme.textSecondary.resolvedColor(with: traitCollection),
                .doctype: theme.nodeAttribute.resolvedColor(with: traitCollection),
                .fallback: theme.textSecondary.resolvedColor(with: traitCollection)
            ]
        }
    }
}

extension DOMTreeTextView {
    struct HighlightTheme {
        let baseForeground: UIColor
        let textSecondary: UIColor
        let textTertiary: UIColor
        let nodeName: UIColor
        let nodeAttribute: UIColor
        let nodeValue: UIColor
        let tagPunctuation: UIColor
        let disclosure: UIColor
        let selectedRowBackground: UIColor
        let hoverRowBackground: UIColor
        let findBackground: UIColor
        let currentFindBackground: UIColor

        static let webInspector = DOMTreeTextView.HighlightTheme(
            baseForeground: .domTreeDynamic(light: 0x111827, dark: 0xF7F9FC),
            textSecondary: .domTreeDynamic(light: 0x475569, dark: 0xA0AFC1),
            textTertiary: .domTreeDynamic(light: 0x6B7280, dark: 0x6E7A88),
            nodeName: .domTreeDynamic(light: 0x0F6BDC, dark: 0x32D4FF),
            nodeAttribute: .domTreeDynamic(light: 0x8A2EC3, dark: 0xEC9EFF),
            nodeValue: .domTreeDynamic(light: 0xB35C00, dark: 0xFFD479),
            tagPunctuation: .domTreeDynamic(light: 0x0F6BDC, dark: 0x32D4FF),
            disclosure: .systemGray,
            selectedRowBackground: .domTreeDynamic(light: 0x0A84FF, dark: 0x0A84FF, lightAlpha: 0.18, darkAlpha: 0.35),
            hoverRowBackground: .domTreeDynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.04, darkAlpha: 0.05),
            findBackground: .domTreeDynamic(light: 0xFFC947, dark: 0xFFDB73, lightAlpha: 0.42, darkAlpha: 0.35),
            currentFindBackground: .domTreeDynamic(light: 0xFFC947, dark: 0xFFDB73, lightAlpha: 0.62, darkAlpha: 0.52)
        )
    }
}

struct DisclosureSymbolImageCacheKey: Hashable {
    let userInterfaceStyle: UIUserInterfaceStyle
    let isOpen: Bool
}

extension CGRect {
    func wiIsNearlyEqual(to other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        origin.x.wiIsNearlyEqual(to: other.origin.x, tolerance: tolerance)
            && origin.y.wiIsNearlyEqual(to: other.origin.y, tolerance: tolerance)
            && size.wiIsNearlyEqual(to: other.size, tolerance: tolerance)
    }
}

extension CGSize {
    func wiIsNearlyEqual(to other: CGSize, tolerance: CGFloat = 0.5) -> Bool {
        width.wiIsNearlyEqual(to: other.width, tolerance: tolerance)
            && height.wiIsNearlyEqual(to: other.height, tolerance: tolerance)
    }
}

extension CGFloat {
    func wiIsNearlyEqual(to other: CGFloat, tolerance: CGFloat = 0.5) -> Bool {
        abs(self - other) <= tolerance
    }
}

private extension UIColor {
    static func domTreeDynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1.0, darkAlpha: CGFloat = 1.0) -> UIColor {
        UIColor { traitCollection in
            let isDark = traitCollection.userInterfaceStyle == .dark
            return domTreeColor(
                hex: isDark ? dark : light,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        }
    }

    static func domTreeColor(hex: UInt32, alpha: CGFloat = 1.0) -> UIColor {
        let red = CGFloat((hex >> 16) & 0xFF) / 255.0
        let green = CGFloat((hex >> 8) & 0xFF) / 255.0
        let blue = CGFloat(hex & 0xFF) / 255.0
        return UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
#endif
