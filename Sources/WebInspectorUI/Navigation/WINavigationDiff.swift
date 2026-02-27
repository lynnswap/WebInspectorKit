#if canImport(UIKit)
import UIKit

enum WINavigationDiff {
    static func areBarButtonItemsEquivalent(
        _ lhs: [UIBarButtonItem]?,
        _ rhs: [UIBarButtonItem]?
    ) -> Bool {
        let left = lhs ?? []
        let right = rhs ?? []
        guard left.count == right.count else {
            return false
        }
        return zip(left, right).allSatisfy { ObjectIdentifier($0.0) == ObjectIdentifier($0.1) }
    }

    static func isSameOverflowItem(
        _ lhs: UIDeferredMenuElement?,
        _ rhs: UIDeferredMenuElement?
    ) -> Bool {
        lhs === rhs
    }
}
#endif
