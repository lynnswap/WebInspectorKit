#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorUINetwork
@testable import WebInspectorUIDOM
@testable import WebInspectorUIBase

@MainActor
struct DOMTreeFindDecorationStateTests {
    @Test
    func duplicateDecorateKeepsSingleRangeAndSkipsInvalidation() {
        let state = DOMTreeTextView.FindDecorationState()
        let range = NSRange(location: 4, length: 2)

        #expect(state.decorate(range, style: .found) == [range])
        #expect(state.decorate(range, style: .found).isEmpty)
        #expect(state.foundRanges == [range])
        #expect(state.highlightedRanges.isEmpty)

        #expect(state.decorate(range, style: .highlighted) == [range])
        #expect(state.decorate(range, style: .highlighted).isEmpty)
        #expect(state.foundRanges.isEmpty)
        #expect(state.highlightedRanges == [range])
    }

    @Test
    func highlightTransitionMovesRangesBetweenDecorationsInPublishOrder() {
        let state = DOMTreeTextView.FindDecorationState()
        let first = NSRange(location: 1, length: 1)
        let second = NSRange(location: 6, length: 3)

        #expect(state.decorate(first, style: .found) == [first])
        #expect(state.decorate(second, style: .found) == [second])
        #expect(state.foundRanges == [first, second])

        #expect(state.decorate(first, style: .highlighted) == [first])
        #expect(state.foundRanges == [second])
        #expect(state.highlightedRanges == [first])

        #expect(state.decorate(first, style: .found) == [first])
        #expect(state.foundRanges == [second, first])
        #expect(state.highlightedRanges.isEmpty)
    }

    @Test
    func normalDecorationRemovesExistingRangeOnly() {
        let state = DOMTreeTextView.FindDecorationState()
        let found = NSRange(location: 2, length: 2)
        let highlighted = NSRange(location: 10, length: 4)
        let missing = NSRange(location: 20, length: 1)

        #expect(state.decorate(found, style: .found) == [found])
        #expect(state.decorate(highlighted, style: .highlighted) == [highlighted])

        #expect(state.decorate(missing, style: .normal).isEmpty)
        #expect(state.foundRanges == [found])
        #expect(state.highlightedRanges == [highlighted])

        #expect(state.decorate(highlighted, style: .normal) == [highlighted])
        #expect(state.foundRanges == [found])
        #expect(state.highlightedRanges.isEmpty)

        #expect(state.decorate(found, style: .normal) == [found])
        #expect(state.isEmpty)
    }

    @Test
    func clearInvalidatesPreviousRangesAndEmptiesState() {
        let state = DOMTreeTextView.FindDecorationState()
        let firstFound = NSRange(location: 0, length: 1)
        let secondFound = NSRange(location: 5, length: 2)
        let highlighted = NSRange(location: 12, length: 3)

        #expect(state.decorate(firstFound, style: .found) == [firstFound])
        #expect(state.decorate(highlighted, style: .highlighted) == [highlighted])
        #expect(state.decorate(secondFound, style: .found) == [secondFound])

        #expect(state.clear() == [firstFound, secondFound, highlighted])
        #expect(state.isEmpty)
        #expect(state.foundRanges.isEmpty)
        #expect(state.highlightedRanges.isEmpty)
        #expect(state.clear().isEmpty)
    }

    @Test
    func batchInvalidationDefersRangesUntilOuterBatchEnds() {
        let state = DOMTreeTextView.FindDecorationState()
        let first = NSRange(location: 3, length: 1)
        let second = NSRange(location: 9, length: 2)

        state.beginBatch()
        state.beginBatch()

        #expect(state.decorate(first, style: .found).isEmpty)
        #expect(state.decorate(second, style: .highlighted).isEmpty)
        #expect(state.endBatch().isEmpty)
        #expect(state.decorate(first, style: .highlighted).isEmpty)

        #expect(state.endBatch() == [first, second, first])
        #expect(state.endBatch().isEmpty)
        #expect(state.foundRanges.isEmpty)
        #expect(state.highlightedRanges == [second, first])
    }
}
#endif
