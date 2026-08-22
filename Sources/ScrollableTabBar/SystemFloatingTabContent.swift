#if canImport(UIKit)
import OSLog
import UIKit

let scrollableTabBarLogger = Logger(
    subsystem: "com.lynnswap.ScrollableTabBar",
    category: "ScrollableTabBar.Runtime"
)

@MainActor
struct SystemFloatingTabComponents {
    let tabController: UITabBarController
    let tabs: [UITab]
    let floatingTabBar: UIView
    let collectionView: UICollectionView
}

@MainActor
enum SystemFloatingTabRuntime {
    private static let floatingTabBarClassName = "_UIFloatingTabBar"
    private static let tabModelKey = "_tabModel"
    private static let tabModelSelector = NSSelectorFromString(tabModelKey)
    private static let setTabModelSelector = NSSelectorFromString("setTabModel:")
    private static let collectionViewSelector = NSSelectorFromString("collectionView")
    private static let showsSidebarButtonSelector = NSSelectorFromString("showsSidebarButton")

    static func makeComponents(
        items: [ScrollableTabBarPresentationItem],
        selectedIndex: Int
    ) -> SystemFloatingTabComponents? {
        guard let floatingTabBarClass = NSClassFromString(floatingTabBarClassName) as? UIView.Type else {
            scrollableTabBarLogger.error(
                "UIKit's floating tab bar class is unavailable; using the public adaptive tab control."
            )
            return nil
        }

        let tabController = UITabBarController()
        tabController.mode = .tabBar
        let tabs = items.enumerated().map { index, item in
            let tab = UITab(
                title: item.title,
                image: item.image,
                identifier: "ScrollableTabBar.Item.\(index)"
            ) { _ in
                UIViewController()
            }
            tab.preferredPlacement = .fixed
            tab.accessibilityIdentifier = item.accessibilityIdentifier
            return tab
        }
        tabController.tabs = tabs
        tabController.selectedTab = tabs[selectedIndex]

        guard let firstTab = tabs.first,
              firstTab.responds(to: tabModelSelector),
              let tabModel = firstTab.value(forKey: tabModelKey) as AnyObject? else {
            scrollableTabBarLogger.error(
                "UITab did not expose its configured tab model; using the public adaptive tab control."
            )
            return nil
        }

        let floatingTabBar = ExpandedPaginationRuntime.makeFloatingTabBar(
            baseClass: floatingTabBarClass
        )
        guard floatingTabBar.responds(to: setTabModelSelector),
              floatingTabBar.responds(to: collectionViewSelector),
              floatingTabBar.responds(to: showsSidebarButtonSelector) else {
            scrollableTabBarLogger.error(
                "UIKit's floating tab bar contract changed; using the public adaptive tab control."
            )
            return nil
        }
        floatingTabBar.setValue(tabModel, forKey: "tabModel")

        guard floatingTabBar.value(forKey: "showsSidebarButton") as? Bool == false,
              let collectionView = floatingTabBar.value(forKey: "collectionView") as? UICollectionView else {
            floatingTabBar.setValue(nil, forKey: "tabModel")
            scrollableTabBarLogger.error(
                "UIKit's floating tab bar produced unexpected sidebar chrome; using the public adaptive tab control."
            )
            return nil
        }

        return SystemFloatingTabComponents(
            tabController: tabController,
            tabs: tabs,
            floatingTabBar: floatingTabBar,
            collectionView: collectionView
        )
    }

    static func detachTabModel(from floatingTabBar: UIView) {
        floatingTabBar.setValue(nil, forKey: "tabModel")
    }
}

@MainActor
final class SystemFloatingTabContent: NSObject,
    ScrollableTabBarContent,
    UITabBarControllerDelegate
{
    var view: UIView { floatingView }
    var selectionHandler: ((Int) -> Void)?
    let floatingView: SystemFloatingTabView
    let tabController: UITabBarController
    let tabs: [UITab]
    let collectionView: UICollectionView
    private var renderedIndex: Int

    static func makeIfAvailable(
        items: [ScrollableTabBarPresentationItem],
        selectedIndex: Int
    ) -> SystemFloatingTabContent? {
        guard let components = SystemFloatingTabRuntime.makeComponents(
            items: items,
            selectedIndex: selectedIndex
        ) else {
            return nil
        }
        return SystemFloatingTabContent(
            selectedIndex: selectedIndex,
            components: components
        )
    }

    private init(
        selectedIndex: Int,
        components: SystemFloatingTabComponents
    ) {
        renderedIndex = selectedIndex
        tabController = components.tabController
        tabs = components.tabs
        collectionView = components.collectionView
        floatingView = SystemFloatingTabView(
            floatingTabBar: components.floatingTabBar
        )
        super.init()
        tabController.delegate = self
    }

    isolated deinit {
        SystemFloatingTabRuntime.detachTabModel(from: floatingView.floatingTabBar)
        tabController.delegate = nil
        tabController.tabs = []
    }

    func render(
        selectedIndex: Int,
        isEnabled: Bool,
        accessibilityLabel: String?
    ) {
        renderedIndex = selectedIndex
        let selectedTab = tabs[selectedIndex]
        if tabController.selectedTab !== selectedTab {
            tabController.selectedTab = selectedTab
        }

        floatingView.isUserInteractionEnabled = isEnabled
        floatingView.alpha = isEnabled ? 1 : 0.5
        floatingView.accessibilityLabel = accessibilityLabel
        if #available(iOS 18.4, *) {
            for tab in tabs {
                tab.isEnabled = isEnabled
            }
        }
    }

    func tabBarController(
        _ tabBarController: UITabBarController,
        didSelectTab selectedTab: UITab,
        previousTab: UITab?
    ) {
        guard let selectedIndex = tabs.firstIndex(where: { $0 === selectedTab }) else {
            scrollableTabBarLogger.fault(
                "UIKit's floating tab bar selected an item outside ScrollableTabBar's membership."
            )
            return
        }
        guard selectedIndex != renderedIndex else {
            return
        }
        selectionHandler?(selectedIndex)
    }
}

@MainActor
final class SystemFloatingTabView: UIView {
    let floatingTabBar: UIView

    init(floatingTabBar: UIView) {
        self.floatingTabBar = floatingTabBar
        super.init(frame: .zero)

        isAccessibilityElement = false
        addSubview(floatingTabBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        floatingTabBar.frame = bounds
        floatingTabBar.layoutIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            return
        }
        setNeedsLayout()
        layoutIfNeeded()
        if #available(iOS 26.0, *), hasLiquidLens == false {
            scrollableTabBarLogger.error(
                "UIKit's floating tab bar did not create its Liquid Glass selection lens."
            )
        }
    }

    var hasLiquidLens: Bool {
        containsView(named: "_UILiquidLensView", below: floatingTabBar)
    }

    private func containsView(named className: String, below view: UIView) -> Bool {
        NSStringFromClass(type(of: view)) == className
            || view.subviews.contains { containsView(named: className, below: $0) }
    }
}
#endif
