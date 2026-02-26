#if canImport(UIKit)
import UIKit

@MainActor
final class WICompactTabHostViewController: UITabBarController, UITabBarControllerDelegate, WIUIKitInspectorHostProtocol {
    var onSelectedTabIDChange: ((WITabDescriptor.ID) -> Void)?

    private var tabDescriptors: [WITabDescriptor] = []
    private var context: WITabContext?

    private var canonicalIdentifierByUITabIdentifier: [String: WITabDescriptor.ID] = [:]
    private var primaryUITabIdentifierByCanonicalIdentifier: [WITabDescriptor.ID: String] = [:]
    private var uiTabByIdentifier: [String: UITab] = [:]
    private var viewControllerByUITabIdentifier: [String: UIViewController] = [:]
    private var orderedUITabIdentifiers: [String] = []
    private var isApplyingSelectionFromController = false

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        tabBar.scrollEdgeAppearance = tabBar.standardAppearance
        rebuildNativeTabsIfPossible()
    }

    func setTabDescriptors(_ descriptors: [WITabDescriptor], context: WITabContext) {
        tabDescriptors = descriptors
        self.context = context
        if isViewLoaded {
            rebuildNativeTabsIfPossible()
        }
    }

    func setSelectedTabID(_ tabID: WITabDescriptor.ID?) {
        syncNativeSelection(with: tabID)
    }

    func prepareForRemoval() {
        delegate = nil
        onSelectedTabIDChange = nil
    }

    var displayedTabIdentifiersForTesting: [String] {
        tabs.map(\.identifier)
    }

    var allTabRootsAreNavigationControllersForTesting: Bool {
        viewControllerByUITabIdentifier.values.allSatisfy { viewController in
            if viewController is UINavigationController {
                return true
            }
            if let compactNavigationHosting = viewController as? (any WICompactNavigationHosting) {
                return compactNavigationHosting.providesCompactNavigationController
            }
            return false
        }
    }

    var networkTabRootIsNavigationControllerForTesting: Bool {
        guard
            let networkUITabIdentifier = primaryUITabIdentifierByCanonicalIdentifier["wi_network"],
            let networkRoot = viewControllerByUITabIdentifier[networkUITabIdentifier]
        else {
            return false
        }
        if networkRoot is UINavigationController {
            return true
        }
        if let compactNavigationHosting = networkRoot as? (any WICompactNavigationHosting) {
            return compactNavigationHosting.providesCompactNavigationController
        }
        return false
    }

    private func rebuildNativeTabsIfPossible() {
        guard let context else {
            clearMappings()
            setTabs([], animated: false)
            return
        }

        var usedUITabIdentifiers = Set<String>()
        var builtTabs: [UITab] = []
        builtTabs.reserveCapacity(tabDescriptors.count)

        clearMappings(keepingTabsOrderCapacity: tabDescriptors.count)

        for (index, descriptor) in tabDescriptors.enumerated() {
            let viewController = wrappedInNavigationControllerIfNeeded(
                descriptor.makeViewController(context: context)
            )
            let uiIdentifier = makeUniqueUITabIdentifier(
                for: descriptor.id,
                index: index,
                used: &usedUITabIdentifiers
            )
            let tab = UITab(
                title: descriptor.title,
                image: UIImage(systemName: descriptor.systemImage),
                identifier: uiIdentifier
            ) { _ in
                viewController
            }

            canonicalIdentifierByUITabIdentifier[uiIdentifier] = descriptor.id
            if primaryUITabIdentifierByCanonicalIdentifier[descriptor.id] == nil {
                primaryUITabIdentifierByCanonicalIdentifier[descriptor.id] = uiIdentifier
            }
            uiTabByIdentifier[uiIdentifier] = tab
            viewControllerByUITabIdentifier[uiIdentifier] = viewController
            orderedUITabIdentifiers.append(uiIdentifier)
            builtTabs.append(tab)
        }

        setTabs(builtTabs, animated: false)
        syncNativeSelection(with: nil)
    }

    private func clearMappings(keepingTabsOrderCapacity capacity: Int = 0) {
        canonicalIdentifierByUITabIdentifier = [:]
        primaryUITabIdentifierByCanonicalIdentifier = [:]
        uiTabByIdentifier = [:]
        viewControllerByUITabIdentifier = [:]
        orderedUITabIdentifiers = []
        if capacity > 0 {
            orderedUITabIdentifiers.reserveCapacity(capacity)
        }
    }

    private func syncNativeSelection(with tabID: WITabDescriptor.ID?) {
        guard orderedUITabIdentifiers.isEmpty == false else {
            return
        }

        if let tabID,
           let uiIdentifier = primaryUITabIdentifierByCanonicalIdentifier[tabID] {
            selectTabIfNeeded(withUIIdentifier: uiIdentifier)
            return
        }

        let resolvedUIIdentifier: String
        if let currentlySelectedUIIdentifier = selectedTab?.identifier,
           canonicalIdentifierByUITabIdentifier[currentlySelectedUIIdentifier] != nil {
            resolvedUIIdentifier = currentlySelectedUIIdentifier
        } else {
            resolvedUIIdentifier = orderedUITabIdentifiers[0]
        }

        selectTabIfNeeded(withUIIdentifier: resolvedUIIdentifier)
        if let canonicalTabID = canonicalIdentifierByUITabIdentifier[resolvedUIIdentifier] {
            onSelectedTabIDChange?(canonicalTabID)
        }
    }

    private func selectTabIfNeeded(withUIIdentifier uiIdentifier: String) {
        guard
            selectedTab?.identifier != uiIdentifier,
            let tab = uiTabByIdentifier[uiIdentifier]
        else {
            return
        }

        isApplyingSelectionFromController = true
        selectedTab = tab
        isApplyingSelectionFromController = false
    }

    private func makeUniqueUITabIdentifier(
        for canonicalIdentifier: WITabDescriptor.ID,
        index: Int,
        used: inout Set<String>
    ) -> String {
        let base = canonicalIdentifier.isEmpty ? "tab_\(index)" : canonicalIdentifier
        if used.insert(base).inserted {
            return base
        }

        var suffix = 2
        while true {
            let candidate = "\(base)__\(suffix)"
            if used.insert(candidate).inserted {
                return candidate
            }
            suffix += 1
        }
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        canonicalIdentifierByUITabIdentifier[tab.identifier] != nil
    }

    func tabBarController(
        _ tabBarController: UITabBarController,
        didSelectTab selectedTab: UITab,
        previousTab: UITab?
    ) {
        guard isApplyingSelectionFromController == false else {
            return
        }

        guard let canonicalTabID = canonicalIdentifierByUITabIdentifier[selectedTab.identifier] else {
            return
        }
        onSelectedTabIDChange?(canonicalTabID)
    }

    private func wrappedInNavigationControllerIfNeeded(_ viewController: UIViewController) -> UIViewController {
        if viewController is UINavigationController {
            return viewController
        }
        if let compactNavigationHosting = viewController as? (any WICompactNavigationHosting),
           compactNavigationHosting.providesCompactNavigationController {
            return viewController
        }
        let navigationController = UINavigationController(rootViewController: viewController)
        wiApplyClearNavigationBarStyle(to: navigationController)
        return navigationController
    }
}
#endif
