#if canImport(UIKit)
import UIKit

@MainActor
final class DOMTreeFindCoordinator: NSObject, @MainActor UIFindInteractionDelegate, @MainActor UITextSearching {
    typealias DocumentIdentifier = Int

    private let documentIdentifier = 0
    private weak var textView: DOMTreeTextView?
    lazy var findInteraction = UIFindInteraction(sessionDelegate: self)

    init(textView: DOMTreeTextView) {
        self.textView = textView
        super.init()
    }

    var selectedTextRange: UITextRange? {
        nil
    }

    var selectedTextSearchDocument: Int? {
        documentIdentifier
    }

    var supportsTextReplacement: Bool {
        false
    }

    func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
        guard textView != nil else {
            return nil
        }
        return UITextSearchingFindSession(searchableObject: self)
    }

    func findInteraction(_ interaction: UIFindInteraction, didEnd session: UIFindSession) {
        textView?.clearFindDecorations()
    }

    func compare(
        _ foundRange: UITextRange,
        toRange: UITextRange,
        document: Int?
    ) -> ComparisonResult {
        guard let lhs = nsRange(for: foundRange),
              let rhs = nsRange(for: toRange)
        else {
            return .orderedSame
        }

        if lhs.location < rhs.location { return .orderedAscending }
        if lhs.location > rhs.location { return .orderedDescending }
        if lhs.length < rhs.length { return .orderedAscending }
        if lhs.length > rhs.length { return .orderedDescending }
        return .orderedSame
    }

    func compare(document: Int, toDocument: Int) -> ComparisonResult {
        if document < toDocument { return .orderedAscending }
        if document > toDocument { return .orderedDescending }
        return .orderedSame
    }

    func performTextSearch(
        queryString: String,
        options: UITextSearchOptions,
        resultAggregator: UITextSearchAggregator<Int>
    ) {
        guard let textView else {
            resultAggregator.finishedSearching()
            return
        }

        textView.clearFindDecorations()
        for range in Self.searchRanges(
            in: textView.renderedTextForFind,
            queryString: queryString,
            compareOptions: sanitizedCompareOptions(options.stringCompareOptions),
            wordMatchMethod: options.wordMatchMethod
        ) {
            resultAggregator.foundRange(
                DOMTreeTextRange(nsRange: range),
                searchString: queryString,
                document: documentIdentifier
            )
        }
        resultAggregator.finishedSearching()
    }

    func decorate(
        foundTextRange: UITextRange,
        document: Int?,
        usingStyle: UITextSearchFoundTextStyle
    ) {
        guard let range = nsRange(for: foundTextRange) else {
            return
        }
        textView?.decorateFindTextRange(range, style: usingStyle)
    }

    func clearAllDecoratedFoundText() {
        textView?.clearFindDecorations()
    }

    func invalidateResultsAfterTextChange() {
        findInteraction.updateResultCount()
    }

    func willHighlight(foundTextRange: UITextRange, document: Int?) {
        scrollRangeToVisible(foundTextRange, inDocument: document)
    }

    func scrollRangeToVisible(_ range: UITextRange, inDocument: Int?) {
        guard let range = nsRange(for: range) else {
            return
        }
        textView?.scrollRangeToVisible(range)
    }

    func shouldReplace(foundTextRange: UITextRange, document: Int?, withText: String) -> Bool {
        false
    }

    func replace(foundTextRange: UITextRange, document: Int?, withText text: String) {
    }

    @objc(replaceAllOccurrencesOfQueryString:usingOptions:withText:)
    func replaceAll(queryString: String, options: UITextSearchOptions, withText text: String) {
    }

    func nsRange(for textRange: UITextRange) -> NSRange? {
        guard let range = textRange as? DOMTreeTextRange else {
            return nil
        }
        return textView?.clampedTextRange(range.nsRange)
    }

    func sanitizedCompareOptions(_ options: NSString.CompareOptions) -> NSString.CompareOptions {
        var sanitized = options
        sanitized.remove(.backwards)
        sanitized.remove(.anchored)
        return sanitized
    }

    static func searchRanges(
        in source: String,
        queryString: String,
        compareOptions: NSString.CompareOptions = [],
        wordMatchMethod: UITextSearchOptions.WordMatchMethod = .contains
    ) -> [NSRange] {
        guard !source.isEmpty, !queryString.isEmpty else {
            return []
        }

        let sourceString = source as NSString
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: sourceString.length)
        var options = compareOptions
        options.remove(.backwards)
        options.remove(.anchored)

        while searchRange.length > 0 {
            let foundRange = sourceString.range(
                of: queryString,
                options: options,
                range: searchRange
            )
            guard foundRange.location != NSNotFound, foundRange.length > 0 else {
                break
            }

            let alignedRange = composedCharacterAlignedRange(foundRange, in: sourceString)
            if accepts(range: alignedRange, in: sourceString, wordMatchMethod: wordMatchMethod) {
                ranges.append(alignedRange)
            }

            let nextLocation = foundRange.location + max(foundRange.length, 1)
            guard nextLocation <= sourceString.length else {
                break
            }
            searchRange = NSRange(location: nextLocation, length: sourceString.length - nextLocation)
        }

        return ranges
    }

    private static func composedCharacterAlignedRange(_ range: NSRange, in source: NSString) -> NSRange {
        guard range.length > 0, source.length > 0 else {
            return range
        }

        let startRange = source.rangeOfComposedCharacterSequence(at: range.location)
        let endRange = source.rangeOfComposedCharacterSequence(at: range.location + range.length - 1)
        let lower = min(startRange.location, range.location)
        let upper = max(endRange.location + endRange.length, range.location + range.length)
        return NSRange(location: lower, length: upper - lower)
    }

    private static func accepts(
        range: NSRange,
        in source: NSString,
        wordMatchMethod: UITextSearchOptions.WordMatchMethod
    ) -> Bool {
        switch wordMatchMethod {
        case .contains:
            true
        case .startsWith:
            isIdentifierBoundary(at: range.location, in: source)
        case .fullWord:
            isIdentifierBoundary(at: range.location, in: source)
                && isIdentifierBoundary(at: range.location + range.length, in: source)
        @unknown default:
            true
        }
    }

    private static func isIdentifierBoundary(at offset: Int, in source: NSString) -> Bool {
        guard offset > 0, offset < source.length else {
            return true
        }
        let source = source as String
        guard let index = stringIndex(forUTF16Offset: offset, in: source) else {
            return false
        }

        let previousIndex = source.index(before: index)
        return !isIdentifierCharacter(source[previousIndex])
            || !isIdentifierCharacter(source[index])
    }

    private static func stringIndex(forUTF16Offset offset: Int, in source: String) -> String.Index? {
        let utf16Index = source.utf16.index(source.utf16.startIndex, offsetBy: offset)
        return String.Index(utf16Index, within: source)
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        if character == "_" {
            return true
        }
        return character.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
    }
}

private final class DOMTreeTextPosition: UITextPosition {
    let offset: Int

    init(offset: Int) {
        self.offset = offset
        super.init()
    }
}

private final class DOMTreeTextRange: UITextRange {
    let nsRange: NSRange
    private let startPosition: DOMTreeTextPosition
    private let endPosition: DOMTreeTextPosition

    init(nsRange: NSRange) {
        let location = max(0, nsRange.location)
        let length = max(0, nsRange.length)
        self.nsRange = NSRange(location: location, length: length)
        self.startPosition = DOMTreeTextPosition(offset: location)
        self.endPosition = DOMTreeTextPosition(offset: location + length)
        super.init()
    }

    override var start: UITextPosition {
        startPosition
    }

    override var end: UITextPosition {
        endPosition
    }

    override var isEmpty: Bool {
        nsRange.length == 0
    }
}

#endif
