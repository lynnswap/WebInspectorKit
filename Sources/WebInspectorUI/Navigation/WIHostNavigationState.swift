#if canImport(UIKit)
import UIKit
import Observation

@MainActor
@Observable
public final class WIHostNavigationState {
    public var searchController: UISearchController?
    public var preferredSearchBarPlacement: UINavigationItem.SearchBarPlacement?
    public var hidesSearchBarWhenScrolling = false
    public var leftBarButtonItems: [UIBarButtonItem]?
    public var rightBarButtonItems: [UIBarButtonItem]?
    public var additionalOverflowItems: UIDeferredMenuElement?

    public init() {}

    public func clearManagedItems() {
        searchController = nil
        preferredSearchBarPlacement = nil
        hidesSearchBarWhenScrolling = false
        leftBarButtonItems = nil
        rightBarButtonItems = nil
        additionalOverflowItems = nil
    }
}
#endif
