#if canImport(UIKit)
import Foundation
import UIKit

extension DOMTreeTextView {
    @MainActor
    final class FindDecorationState {
        private(set) var foundRanges: [NSRange] = []
        private(set) var highlightedRanges: [NSRange] = []
        private var batchDepth = 0
        private var pendingInvalidationRanges: [NSRange] = []

        var isEmpty: Bool {
            foundRanges.isEmpty && highlightedRanges.isEmpty
        }

        func decorate(_ clampedRange: NSRange, style: UITextSearchFoundTextStyle) -> [NSRange] {
            guard clampedRange.length > 0 else {
                return []
            }

            switch style {
            case .normal:
                guard foundRanges.contains(clampedRange) || highlightedRanges.contains(clampedRange) else {
                    return []
                }
                remove(clampedRange)
            case .found:
                guard !foundRanges.contains(clampedRange) || highlightedRanges.contains(clampedRange) else {
                    return []
                }
                remove(clampedRange)
                foundRanges.append(clampedRange)
            case .highlighted:
                guard foundRanges.contains(clampedRange) || !highlightedRanges.contains(clampedRange) else {
                    return []
                }
                remove(clampedRange)
                highlightedRanges.append(clampedRange)
            @unknown default:
                guard !foundRanges.contains(clampedRange) || highlightedRanges.contains(clampedRange) else {
                    return []
                }
                remove(clampedRange)
                foundRanges.append(clampedRange)
            }
            return invalidatedRanges([clampedRange])
        }

        func clear() -> [NSRange] {
            let previousRanges = foundRanges + highlightedRanges
            guard !previousRanges.isEmpty else {
                return []
            }
            foundRanges.removeAll()
            highlightedRanges.removeAll()
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

        private func remove(_ range: NSRange) {
            foundRanges.removeAll { $0 == range }
            highlightedRanges.removeAll { $0 == range }
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
    }
}
#endif
