#if canImport(UIKit)
import Foundation
import UIKit

extension DOMTreeTextView {
    @MainActor
    final class FindDecorationState {
        private var foundRangeIndex = OrderedRangeIndex()
        private var highlightedRangeIndex = OrderedRangeIndex()
        private var batchDepth = 0
        private var pendingInvalidationRanges: [NSRange] = []

        var foundRanges: [NSRange] {
            foundRangeIndex.ranges
        }

        var highlightedRanges: [NSRange] {
            highlightedRangeIndex.ranges
        }

        var isEmpty: Bool {
            foundRangeIndex.isEmpty && highlightedRangeIndex.isEmpty
        }

        func decorate(_ clampedRange: NSRange, style: UITextSearchFoundTextStyle) -> [NSRange] {
            guard clampedRange.length > 0 else {
                return []
            }

            switch style {
            case .normal:
                guard remove(clampedRange) else {
                    return []
                }
            case .found:
                guard decorateFound(clampedRange) else {
                    return []
                }
            case .highlighted:
                guard decorateHighlighted(clampedRange) else {
                    return []
                }
            @unknown default:
                guard decorateFound(clampedRange) else {
                    return []
                }
            }
            return invalidatedRanges([clampedRange])
        }

        func clear() -> [NSRange] {
            let previousRanges = foundRanges + highlightedRanges
            guard !previousRanges.isEmpty else {
                return []
            }
            foundRangeIndex.removeAll()
            highlightedRangeIndex.removeAll()
            return invalidatedRanges(previousRanges)
        }

        func beginBatch() {
            batchDepth += 1
        }

        func endBatch() -> [NSRange] {
            guard batchDepth > 0 else {
                return []
            }
            batchDepth -= 1
            guard batchDepth == 0 else {
                return []
            }

            let ranges = pendingInvalidationRanges
            pendingInvalidationRanges.removeAll(keepingCapacity: true)
            return ranges
        }

        private func decorateFound(_ range: NSRange) -> Bool {
            let isFound = foundRangeIndex.contains(range)
            let isHighlighted = highlightedRangeIndex.contains(range)
            guard !isFound || isHighlighted else {
                return false
            }
            if isFound {
                foundRangeIndex.remove(range)
            }
            if isHighlighted {
                highlightedRangeIndex.remove(range)
            }
            foundRangeIndex.append(range)
            return true
        }

        private func decorateHighlighted(_ range: NSRange) -> Bool {
            let isFound = foundRangeIndex.contains(range)
            let isHighlighted = highlightedRangeIndex.contains(range)
            guard isFound || !isHighlighted else {
                return false
            }
            if isFound {
                foundRangeIndex.remove(range)
            }
            if isHighlighted {
                highlightedRangeIndex.remove(range)
            }
            highlightedRangeIndex.append(range)
            return true
        }

        @discardableResult
        private func remove(_ range: NSRange) -> Bool {
            let removedFound = foundRangeIndex.remove(range)
            let removedHighlighted = highlightedRangeIndex.remove(range)
            return removedFound || removedHighlighted
        }

        private func invalidatedRanges(_ ranges: [NSRange]) -> [NSRange] {
            guard !ranges.isEmpty else {
                return []
            }
            if batchDepth > 0 {
                pendingInvalidationRanges.append(contentsOf: ranges)
                return []
            }
            return ranges
        }

        private struct OrderedRangeIndex {
            private var slots: [NSRange?] = []
            private var positionsByRange: [NSRange: Int] = [:]
            private var cachedRanges: [NSRange] = []
            private var isCacheValid = true
            private var liveCount = 0

            var ranges: [NSRange] {
                mutating get {
                    if !isCacheValid {
                        rebuildCache()
                    }
                    return cachedRanges
                }
            }

            var isEmpty: Bool {
                liveCount == 0
            }

            func contains(_ range: NSRange) -> Bool {
                positionsByRange[range] != nil
            }

            mutating func append(_ range: NSRange) {
                guard positionsByRange[range] == nil else {
                    return
                }
                positionsByRange[range] = slots.count
                slots.append(range)
                liveCount += 1
                if isCacheValid {
                    cachedRanges.append(range)
                }
            }

            @discardableResult
            mutating func remove(_ range: NSRange) -> Bool {
                guard let position = positionsByRange.removeValue(forKey: range) else {
                    return false
                }

                slots[position] = nil
                liveCount -= 1
                isCacheValid = false
                compactIfNeeded()
                return true
            }

            mutating func removeAll() {
                slots.removeAll()
                positionsByRange.removeAll()
                cachedRanges.removeAll()
                isCacheValid = true
                liveCount = 0
            }

            private mutating func rebuildCache() {
                var ranges: [NSRange] = []
                ranges.reserveCapacity(liveCount)
                for case let range? in slots {
                    ranges.append(range)
                }
                cachedRanges = ranges
                isCacheValid = true
            }

            private mutating func compactIfNeeded() {
                guard slots.count > 64, liveCount * 2 < slots.count else {
                    return
                }

                var compactedSlots: [NSRange?] = []
                compactedSlots.reserveCapacity(liveCount)
                var compactedPositions: [NSRange: Int] = [:]
                compactedPositions.reserveCapacity(liveCount)

                for range in slots.compactMap(\.self) {
                    compactedPositions[range] = compactedSlots.count
                    compactedSlots.append(range)
                }

                slots = compactedSlots
                positionsByRange = compactedPositions
            }
        }
    }
}
#endif
