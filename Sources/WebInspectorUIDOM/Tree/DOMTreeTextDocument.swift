#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorCore
import UIKit

final class DOMTreeTextDocument: NSObject, NSTextContentStorageDelegate {
    static let rowIdentityAttribute = NSAttributedString.Key("WebInspectorKit.DOMTree.rowIdentity")

    let textContentStorage: NSTextContentStorage
    let layoutManager: NSTextLayoutManager
    let textContainer: NSTextContainer

    private(set) var rowIndex = DOMTreeRowIndex()
    private var rowIdentityByParagraphLocation: [Int: DOMTreeRowIdentity] = [:]

    override init() {
        textContentStorage = NSTextContentStorage()
        layoutManager = NSTextLayoutManager()
        textContainer = NSTextContainer()
        super.init()

        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byClipping
        layoutManager.textContainer = textContainer
        textContentStorage.delegate = self
        textContentStorage.addTextLayoutManager(layoutManager)
        textContentStorage.primaryTextLayoutManager = layoutManager
    }

    private var backingTextStorage: NSTextStorage {
        guard let storage = textContentStorage.textStorage else {
            fatalError("DOMTreeTextDocument requires NSTextContentStorage-backed NSTextStorage")
        }
        return storage
    }

    var string: String {
        let text = backingTextStorage.string
        return text == "\n" ? "" : text
    }

    var utf16Length: Int {
        (string as NSString).length
    }

    func replaceDocument(
        with attributedString: NSAttributedString,
        rows: [DOMTreeRowRenderPlan]
    ) {
        rowIndex = DOMTreeRowIndex(rows: rows)
        rebuildParagraphLocationIndex(rows: rows)
        textContentStorage.performEditingTransaction {
            backingTextStorage.setAttributedString(attributedString)
        }
    }

    func replaceCharacters(
        in range: NSRange,
        with attributedString: NSAttributedString,
        rows: [DOMTreeRowRenderPlan]
    ) {
        rowIndex = DOMTreeRowIndex(rows: rows)
        rebuildParagraphLocationIndex(rows: rows)
        textContentStorage.performEditingTransaction {
            backingTextStorage.replaceCharacters(in: range, with: attributedString)
        }
    }

    func rowIdentity(for textLayoutFragment: NSTextLayoutFragment) -> DOMTreeRowIdentity? {
        (textLayoutFragment.textElement as? DOMTreeRowParagraph)?.identity
    }

    func row(for textLayoutFragment: NSTextLayoutFragment) -> DOMTreeRowRenderPlan? {
        guard let identity = rowIdentity(for: textLayoutFragment) else {
            return nil
        }
        return rowIndex.row(for: identity)
    }

    func textRange(for range: NSRange) -> NSTextRange? {
        let clampedRange = NSRange(
            location: min(max(0, range.location), backingTextStorage.length),
            length: min(max(0, range.length), max(0, backingTextStorage.length - min(max(0, range.location), backingTextStorage.length)))
        )
        guard let start = textContentStorage.location(
            textContentStorage.documentRange.location,
            offsetBy: clampedRange.location
        ) else {
            return nil
        }
        let end = textContentStorage.location(start, offsetBy: clampedRange.length)
        return NSTextRange(location: start, end: end)
    }

    func nsRange(for textLayoutFragment: NSTextLayoutFragment) -> NSRange {
        let startOffset = textContentStorage.offset(
            from: textContentStorage.documentRange.location,
            to: textLayoutFragment.rangeInElement.location
        )
        let endOffset = textContentStorage.offset(
            from: textContentStorage.documentRange.location,
            to: textLayoutFragment.rangeInElement.endLocation
        )
        return NSRange(location: startOffset, length: max(0, endOffset - startOffset))
    }

    func textContentStorage(
        _ textContentStorage: NSTextContentStorage,
        textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        guard range.location < backingTextStorage.length else {
            return nil
        }
        let identity = unsafe backingTextStorage.attribute(
            Self.rowIdentityAttribute,
            at: range.location,
            effectiveRange: nil
        ) as? DOMTreeRowIdentity ?? rowIdentityByParagraphLocation[range.location]
        guard let identity else {
            return nil
        }
        let safeLength = min(range.length, backingTextStorage.length - range.location)
        let attributedSubstring = backingTextStorage.attributedSubstring(
            from: NSRange(location: range.location, length: safeLength)
        )
        return DOMTreeRowParagraph(identity: identity, attributedString: attributedSubstring)
    }

    func foregroundColor(containing text: String) -> UIColor? {
        let range = (backingTextStorage.string as NSString).range(of: text)
        guard range.location != NSNotFound,
              range.location < backingTextStorage.length
        else {
            return nil
        }
        return unsafe backingTextStorage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
    }

    func hasAttachment(at location: Int) -> Bool {
        guard location >= 0,
              location < backingTextStorage.length else {
            return false
        }
        return unsafe backingTextStorage.attribute(.attachment, at: location, effectiveRange: nil) is NSTextAttachment
    }

    private func rebuildParagraphLocationIndex(rows: [DOMTreeRowRenderPlan]) {
        var nextIndex: [Int: DOMTreeRowIdentity] = [:]
        nextIndex.reserveCapacity(rows.count)
        for row in rows {
            nextIndex[row.documentRange.location] = row.identity
        }
        rowIdentityByParagraphLocation = nextIndex
    }

#if DEBUG
    func removeRowIndexForTesting(nodeID: DOMNode.ID) {
        rowIndex.removeRowIndex(for: nodeID)
    }
#endif
}

struct DOMTreeRowIdentity: Hashable, Sendable {
    let nodeID: DOMNode.ID
    let kind: DOMTreeRowKind

    init(nodeID: DOMNode.ID, kind: DOMTreeRowKind) {
        self.nodeID = nodeID
        self.kind = kind
    }
}

enum DOMTreeRowKind: Hashable, Sendable {
    case opening
    case closingTag
}

final class DOMTreeRowParagraph: NSTextParagraph {
    let identity: DOMTreeRowIdentity

    init(identity: DOMTreeRowIdentity, attributedString: NSAttributedString) {
        self.identity = identity
        super.init(attributedString: attributedString)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct DOMTreeRowRenderPlan: Equatable, Sendable {
    let identity: DOMTreeRowIdentity
    let depth: Int
    let rowIndex: Int
    let text: String
    let documentRange: NSRange
    let markupRange: NSRange
    let tokens: [DOMTreeTextView.Token]
    let displayColumnCount: Int
    let hasDisclosure: Bool
    let isOpen: Bool

    var nodeID: DOMNode.ID {
        identity.nodeID
    }

    var isClosingTag: Bool {
        identity.kind == .closingTag
    }

    func hasSameRenderedContent(as other: DOMTreeRowRenderPlan) -> Bool {
        identity == other.identity
            && depth == other.depth
            && text == other.text
            && tokens == other.tokens
            && displayColumnCount == other.displayColumnCount
            && hasDisclosure == other.hasDisclosure
            && isOpen == other.isOpen
    }
}

struct DOMTreeRowIndex {
    private(set) var rows: [DOMTreeRowRenderPlan]
    private(set) var visibleNodeIDs: Set<DOMNode.ID>
    private var rowIndexByIdentity: [DOMTreeRowIdentity: Int]
    private var firstRowIndexByNodeID: [DOMNode.ID: Int]

    init(rows: [DOMTreeRowRenderPlan] = []) {
        self.rows = rows
        visibleNodeIDs = []
        rowIndexByIdentity = [:]
        firstRowIndexByNodeID = [:]
        rebuildIndex()
    }

    mutating func replaceRows(_ rows: [DOMTreeRowRenderPlan]) {
        self.rows = rows
        rebuildIndex()
    }

    func contains(nodeID: DOMNode.ID) -> Bool {
        firstRowIndexByNodeID[nodeID] != nil
    }

    func row(for nodeID: DOMNode.ID) -> DOMTreeRowRenderPlan? {
        guard let rowIndex = firstRowIndexByNodeID[nodeID],
              rows.indices.contains(rowIndex) else {
            return nil
        }
        return rows[rowIndex]
    }

    func row(for identity: DOMTreeRowIdentity) -> DOMTreeRowRenderPlan? {
        guard let rowIndex = rowIndexByIdentity[identity],
              rows.indices.contains(rowIndex) else {
            return nil
        }
        return rows[rowIndex]
    }

    func rowIndex(for nodeID: DOMNode.ID) -> Int? {
        firstRowIndexByNodeID[nodeID]
    }

    func rowsInDisplayOrder(for nodeIDs: Set<DOMNode.ID>) -> [DOMTreeRowRenderPlan] {
        var rowIndexes = IndexSet()
        for nodeID in nodeIDs {
            guard let rowIndex = firstRowIndexByNodeID[nodeID],
                  rows.indices.contains(rowIndex) else {
                continue
            }
            rowIndexes.insert(rowIndex)
        }
        return rowIndexes.map { rows[$0] }
    }

    func rowsBetween(_ firstNodeID: DOMNode.ID, _ secondNodeID: DOMNode.ID) -> ArraySlice<DOMTreeRowRenderPlan> {
        guard let firstIndex = firstRowIndexByNodeID[firstNodeID],
              let secondIndex = firstRowIndexByNodeID[secondNodeID]
        else {
            return []
        }
        let lowerBound = min(firstIndex, secondIndex)
        let upperBound = max(firstIndex, secondIndex)
        return rows[lowerBound...upperBound]
    }

#if DEBUG
    mutating func removeRowIndex(for nodeID: DOMNode.ID) {
        firstRowIndexByNodeID.removeValue(forKey: nodeID)
    }
#endif

    private mutating func rebuildIndex() {
        var nextRowIndexByIdentity: [DOMTreeRowIdentity: Int] = [:]
        nextRowIndexByIdentity.reserveCapacity(rows.count)
        var nextFirstRowIndexByNodeID: [DOMNode.ID: Int] = [:]
        nextFirstRowIndexByNodeID.reserveCapacity(rows.count)
        var nextVisibleNodeIDs = Set<DOMNode.ID>()
        nextVisibleNodeIDs.reserveCapacity(rows.count)
        for row in rows {
            nextRowIndexByIdentity[row.identity] = row.rowIndex
            if !row.isClosingTag, nextFirstRowIndexByNodeID[row.nodeID] == nil {
                nextFirstRowIndexByNodeID[row.nodeID] = row.rowIndex
            }
            nextVisibleNodeIDs.insert(row.nodeID)
        }
        rowIndexByIdentity = nextRowIndexByIdentity
        firstRowIndexByNodeID = nextFirstRowIndexByNodeID
        visibleNodeIDs = nextVisibleNodeIDs
    }
}
#endif
