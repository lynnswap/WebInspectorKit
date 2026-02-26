#if canImport(UIKit)
import UIKit

@MainActor
public protocol WIHostNavigationItemProvider: AnyObject {
    var onHostNavigationItemsDidChange: (() -> Void)? { get set }

    func applyHostNavigationItems(to navigationItem: UINavigationItem)
}
#endif
