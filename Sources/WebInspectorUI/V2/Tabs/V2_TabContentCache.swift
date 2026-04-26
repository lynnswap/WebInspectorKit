#if canImport(UIKit)
import UIKit

@MainActor
final class V2_TabContentCache {
    private var viewControllerByKey: [V2_TabContentKey: UIViewController] = [:]

    func viewController<Content: UIViewController>(
        for key: V2_TabContentKey,
        make: () -> Content
    ) -> Content {
        if let cachedViewController = viewControllerByKey[key] {
            if let contentViewController = cachedViewController as? Content {
                return contentViewController
            }
            cachedViewController.wiDetachFromV2ContainerForReuse()
        }

        let viewController = make()
        viewControllerByKey[key] = viewController
        return viewController
    }

    func prune(retaining keys: Set<V2_TabContentKey>) {
        for (key, viewController) in viewControllerByKey where keys.contains(key) == false {
            viewController.wiDetachFromV2ContainerForReuse()
            viewControllerByKey[key] = nil
        }
    }

    func removeAll() {
        for viewController in viewControllerByKey.values {
            viewController.wiDetachFromV2ContainerForReuse()
        }
        viewControllerByKey.removeAll()
    }
}
#endif
