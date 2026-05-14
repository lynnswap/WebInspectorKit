#if canImport(UIKit)
import UIKit

@MainActor
final class V2_DOMTreeFindCoordinator: NSObject, @MainActor UIFindInteractionDelegate, @MainActor UITextSearching {
    typealias DocumentIdentifier = Int

    private let documentIdentifier = 0
    private weak var textView: V2_DOMTreeTextView?
    lazy var findInteraction = UIFindInteraction(sessionDelegate: self)
    private var activeResultAggregator: UITextSearchAggregator<Int>?
    private var activeSearchCancellation: V2_DOMTreeFindSearchCancellation?
    private var activeSearchIdentifier: Int?
    private var nextSearchIdentifier = 0

    init(textView: V2_DOMTreeTextView) {
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
        invalidateActiveResultAggregator()
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

        cancelActiveSearch()
        let cancellation = V2_DOMTreeFindSearchCancellation()
        let searchIdentifier = nextSearchIdentifier
        nextSearchIdentifier += 1
        activeSearchCancellation = cancellation
        activeSearchIdentifier = searchIdentifier
        activeResultAggregator = resultAggregator
        let search = V2_DOMTreeFindSearchRequest(
            identifier: searchIdentifier,
            source: textView.renderedTextForFind,
            queryString: queryString,
            compareOptions: sanitizedCompareOptions(options.stringCompareOptions),
            wordMatchMethod: options.wordMatchMethod,
            documentIdentifier: documentIdentifier,
            resultAggregator: resultAggregator,
            cancellation: cancellation
        )

        textView.clearFindDecorations()
        textView.beginFindDecorationBatch()
        cancellation.beginDecorationBatch()

        Task.detached(priority: .userInitiated) { [weak self, search] in
            let searchResultBatchSize = 128
            var pendingRanges: [NSRange] = []
            pendingRanges.reserveCapacity(searchResultBatchSize)

            func flushPendingRanges() async -> Bool {
                guard !pendingRanges.isEmpty else {
                    return !search.cancellation.isCancelled
                }

                let ranges = pendingRanges
                pendingRanges.removeAll(keepingCapacity: true)
                return await MainActor.run {
                    guard !search.cancellation.isCancelled else {
                        return false
                    }
                    for range in ranges {
                        guard !search.cancellation.isCancelled else {
                            return false
                        }
                        search.resultAggregator.foundRange(
                            V2_DOMTreeTextRange(nsRange: range, findSearchIdentifier: search.identifier),
                            searchString: search.queryString,
                            document: search.documentIdentifier
                        )
                    }
                    return true
                }
            }

            let completedSearch = await Self.enumerateSearchRangesAsync(
                in: search.source,
                queryString: search.queryString,
                compareOptions: search.compareOptions,
                wordMatchMethod: search.wordMatchMethod
            ) { range in
                guard !search.cancellation.isCancelled else {
                    return false
                }
                pendingRanges.append(range)
                if pendingRanges.count >= searchResultBatchSize {
                    return await flushPendingRanges()
                }
                return true
            }

            if completedSearch, await flushPendingRanges(), !search.cancellation.isCancelled {
                await MainActor.run {
                    guard !search.cancellation.isCancelled else {
                        return
                    }
                    search.resultAggregator.finishedSearching()
                }
            }

            await self?.finishTextSearch(cancellation: search.cancellation)
        }
    }

    func decorate(
        foundTextRange: UITextRange,
        document: Int?,
        usingStyle: UITextSearchFoundTextStyle
    ) {
        guard isCurrentFindTextRange(foundTextRange) else {
            return
        }
        guard let range = nsRange(for: foundTextRange) else {
            return
        }
        textView?.decorateFindTextRange(range, style: usingStyle)
    }

    func clearAllDecoratedFoundText() {
        textView?.clearFindDecorations()
    }

    func invalidateResultsAfterTextChange() {
        invalidateActiveResultAggregator()
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
        guard let range = textRange as? V2_DOMTreeTextRange else {
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

    func invalidateActiveSearch() {
        invalidateActiveResultAggregator()
    }

    private func invalidateActiveResultAggregator() {
        cancelActiveSearch()
    }

    private func cancelActiveSearch() {
        if activeSearchCancellation?.cancelAndClaimDecorationBatch() == true {
            textView?.endFindDecorationBatch()
        }
        activeSearchCancellation = nil
        activeSearchIdentifier = nil

        let resultAggregator = activeResultAggregator
        activeResultAggregator = nil
        resultAggregator?.invalidate()
    }

    private func finishTextSearch(cancellation: V2_DOMTreeFindSearchCancellation) {
        if cancellation.finishAndClaimDecorationBatch() {
            textView?.endFindDecorationBatch()
        }
        if activeSearchCancellation === cancellation {
            activeSearchCancellation = nil
        }
    }

    private func isCurrentFindTextRange(_ textRange: UITextRange) -> Bool {
        guard let findSearchIdentifier = (textRange as? V2_DOMTreeTextRange)?.findSearchIdentifier else {
            return true
        }
        return findSearchIdentifier == activeSearchIdentifier
    }

#if DEBUG
    func decorateStaleFoundTextForTesting(queryString: String) {
        guard let textView,
              let range = Self.searchRanges(in: textView.renderedTextForFind, queryString: queryString).first
        else {
            return
        }

        decorate(
            foundTextRange: V2_DOMTreeTextRange(nsRange: range, findSearchIdentifier: Int.max),
            document: documentIdentifier,
            usingStyle: .found
        )
        decorate(
            foundTextRange: V2_DOMTreeTextRange(nsRange: range, findSearchIdentifier: Int.max),
            document: documentIdentifier,
            usingStyle: .highlighted
        )
    }
#endif

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

    @discardableResult
    private nonisolated static func enumerateSearchRangesAsync(
        in source: String,
        queryString: String,
        compareOptions: NSString.CompareOptions,
        wordMatchMethod: UITextSearchOptions.WordMatchMethod,
        _ body: (NSRange) async -> Bool
    ) async -> Bool {
        guard !source.isEmpty, !queryString.isEmpty else {
            return true
        }

        let sourceString = source as NSString
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
                guard await body(alignedRange) else {
                    return false
                }
            }

            let nextLocation = foundRange.location + max(foundRange.length, 1)
            guard nextLocation <= sourceString.length else {
                break
            }
            searchRange = NSRange(location: nextLocation, length: sourceString.length - nextLocation)
        }

        return true
    }

    private nonisolated static func composedCharacterAlignedRange(_ range: NSRange, in source: NSString) -> NSRange {
        guard range.length > 0, source.length > 0 else {
            return range
        }

        let startRange = source.rangeOfComposedCharacterSequence(at: range.location)
        let endRange = source.rangeOfComposedCharacterSequence(at: range.location + range.length - 1)
        let lower = min(startRange.location, range.location)
        let upper = max(endRange.location + endRange.length, range.location + range.length)
        return NSRange(location: lower, length: upper - lower)
    }

    private nonisolated static func accepts(
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

    private nonisolated static func isIdentifierBoundary(at offset: Int, in source: NSString) -> Bool {
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

    private nonisolated static func stringIndex(forUTF16Offset offset: Int, in source: String) -> String.Index? {
        let utf16Index = source.utf16.index(source.utf16.startIndex, offsetBy: offset)
        return String.Index(utf16Index, within: source)
    }

    private nonisolated static func isIdentifierCharacter(_ character: Character) -> Bool {
        if character == "_" {
            return true
        }
        return character.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
    }
}

private final class V2_DOMTreeTextPosition: UITextPosition {
    let offset: Int

    init(offset: Int) {
        self.offset = offset
        super.init()
    }
}

private final class V2_DOMTreeTextRange: UITextRange {
    let nsRange: NSRange
    let findSearchIdentifier: Int?
    private let startPosition: V2_DOMTreeTextPosition
    private let endPosition: V2_DOMTreeTextPosition

    init(nsRange: NSRange, findSearchIdentifier: Int? = nil) {
        let location = max(0, nsRange.location)
        let length = max(0, nsRange.length)
        self.nsRange = NSRange(location: location, length: length)
        self.findSearchIdentifier = findSearchIdentifier
        self.startPosition = V2_DOMTreeTextPosition(offset: location)
        self.endPosition = V2_DOMTreeTextPosition(offset: location + length)
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

private struct V2_DOMTreeFindSearchRequest: @unchecked Sendable {
    let identifier: Int
    let source: String
    let queryString: String
    let compareOptions: NSString.CompareOptions
    let wordMatchMethod: UITextSearchOptions.WordMatchMethod
    let documentIdentifier: Int
    let resultAggregator: UITextSearchAggregator<Int>
    let cancellation: V2_DOMTreeFindSearchCancellation
}

private final class V2_DOMTreeFindSearchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var decorationBatchActive = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func beginDecorationBatch() {
        lock.lock()
        decorationBatchActive = true
        lock.unlock()
    }

    func cancelAndClaimDecorationBatch() -> Bool {
        lock.lock()
        cancelled = true
        let shouldEndDecorationBatch = decorationBatchActive
        decorationBatchActive = false
        lock.unlock()
        return shouldEndDecorationBatch
    }

    func finishAndClaimDecorationBatch() -> Bool {
        lock.lock()
        let shouldEndDecorationBatch = decorationBatchActive
        decorationBatchActive = false
        lock.unlock()
        return shouldEndDecorationBatch
    }
}

#endif
