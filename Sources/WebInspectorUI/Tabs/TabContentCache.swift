#if canImport(UIKit)
import UIKit

@MainActor
final class TabContentCache {
    private var viewControllerByKey: [TabContentKey: UIViewController] = [:]

    func viewController<Content: UIViewController>(
        for key: TabContentKey,
        make: () -> Content
    ) -> Content {
        if let cachedViewController = viewControllerByKey[key] {
            if let contentViewController = cachedViewController as? Content {
                return contentViewController
            }
            cachedViewController.wiDetachFromContainerForReuse()
        }

        let viewController = make()
        viewControllerByKey[key] = viewController
        return viewController
    }

    func prune(retaining keys: Set<TabContentKey>) {
        for (key, viewController) in viewControllerByKey where keys.contains(key) == false {
            viewController.wiDetachFromContainerForReuse()
            viewControllerByKey[key] = nil
        }
    }

    func removeAll() {
        for viewController in viewControllerByKey.values {
            viewController.wiDetachFromContainerForReuse()
        }
        viewControllerByKey.removeAll()
    }
}
#endif
