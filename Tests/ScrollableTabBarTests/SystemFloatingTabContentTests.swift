#if canImport(UIKit)
import Testing
import UIKit
@testable import ScrollableTabBar

@MainActor
@Suite(.serialized)
struct SystemFloatingTabContentTests {
    @Test
    func usesUIKitPagingExpandedWidthAndStableTabIdentity() throws {
        let content = try #require(makeContent())
        let originalTabIdentities = content.tabs.map(ObjectIdentifier.init)
        content.view.frame = CGRect(x: 0, y: 0, width: 314, height: 49)
        let host = UIViewController()
        host.view.addSubview(content.view)
        let window = showInWindow(host)
        defer { window.isHidden = true }

        content.render(
            selectedIndex: 0,
            isEnabled: true,
            accessibilityLabel: "Detail Mode"
        )
        window.layoutIfNeeded()
        content.view.layoutIfNeeded()
        content.floatingView.floatingTabBar.layoutIfNeeded()

        let floatingTabBarClass: AnyClass = try #require(
            NSClassFromString("_UIFloatingTabBar")
        )
        #expect(content.floatingView.floatingTabBar.isKind(of: floatingTabBarClass))
        #expect(content.tabs.map(\.title) == ["Headers", "Preview", "Cookie", "Security"])
        #expect(content.tabs[0].accessibilityIdentifier == "ScrollableTabBar.Test.0")
        #expect(content.tabController.selectedTab === content.tabs[0])
        #expect(content.floatingView.accessibilityContainerType == .semanticGroup)
        #expect(content.floatingView.accessibilityLabel == "Detail Mode")
        #expect(content.collectionView.contentSize.width > content.collectionView.bounds.width)
        #expect(
            descendants(of: content.floatingView.floatingTabBar).count {
                NSStringFromClass(type(of: $0)) == "_UIFloatingTabBarPageButton"
            } == 2
        )

        content.render(
            selectedIndex: 3,
            isEnabled: true,
            accessibilityLabel: "Detail Mode"
        )

        #expect(content.tabController.selectedTab === content.tabs[3])
        #expect(content.tabs.map(ObjectIdentifier.init) == originalTabIdentities)

        if #available(iOS 26.0, *) {
            #expect(
                NSStringFromClass(type(of: content.floatingView.floatingTabBar))
                    == "LynnswapScrollableTabBarExpandedPaginationFloatingTabBar"
            )
            let maximumContainerWidth = try #require(
                ExpandedPaginationRuntime.maximumContainerSize(
                    of: content.floatingView.floatingTabBar
                )?.width
            )
            #expect(maximumContainerWidth > content.floatingView.floatingTabBar.bounds.width * 0.8)
            #expect(maximumContainerWidth < content.floatingView.floatingTabBar.bounds.width)
            #expect(content.floatingView.hasLiquidLens)
        }
    }

    @Test
    func wideLayoutFitsTheCurrentFourItemsWithoutPagination() throws {
        let content = try #require(makeContent())
        content.view.frame = CGRect(x: 0, y: 0, width: 640, height: 49)
        let host = UIViewController()
        host.view.addSubview(content.view)
        let window = showInWindow(
            host,
            size: CGSize(width: 1_024, height: 768)
        )
        defer { window.isHidden = true }

        content.render(
            selectedIndex: 0,
            isEnabled: true,
            accessibilityLabel: "Detail Mode"
        )
        window.layoutIfNeeded()
        content.view.layoutIfNeeded()
        content.floatingView.floatingTabBar.layoutIfNeeded()

        #expect(content.collectionView.contentSize.width <= content.collectionView.bounds.width)
    }

    @Test
    func translatesDelegateSelectionAndDisabledState() throws {
        let content = try #require(makeContent())
        var selectedIndices: [Int] = []
        content.selectionHandler = { index in
            selectedIndices.append(index)
        }
        content.render(
            selectedIndex: 0,
            isEnabled: true,
            accessibilityLabel: "Detail Mode"
        )

        content.tabBarController(
            content.tabController,
            didSelectTab: content.tabs[2],
            previousTab: content.tabs[0]
        )

        #expect(selectedIndices == [2])

        content.render(
            selectedIndex: 2,
            isEnabled: false,
            accessibilityLabel: "Detail Mode"
        )
        #expect(content.floatingView.isUserInteractionEnabled == false)
        #expect(content.floatingView.alpha == 0.5)
        if #available(iOS 18.4, *) {
            #expect(content.tabs.allSatisfy { $0.isEnabled == false })
        }

        content.tabBarController(
            content.tabController,
            didSelectTab: content.tabs[2],
            previousTab: content.tabs[0]
        )
        #expect(selectedIndices == [2])
    }

    @Test
    func detachesTabModelAndControllerRelationships() throws {
        var content: SystemFloatingTabContent? = makeContent()
        let floatingTabBar = try #require(content?.floatingView.floatingTabBar)
        let tabController = try #require(content?.tabController)
        #expect(floatingTabBar.value(forKey: "_tabModel") != nil)

        content = nil

        #expect(floatingTabBar.value(forKey: "_tabModel") == nil)
        #expect(tabController.delegate == nil)
        #expect(tabController.tabs.isEmpty)
    }

    private func makeContent() -> SystemFloatingTabContent? {
        SystemFloatingTabContent.makeIfAvailable(
            items: [
                .init(
                    title: "Headers",
                    image: nil,
                    accessibilityIdentifier: "ScrollableTabBar.Test.0"
                ),
                .init(
                    title: "Preview",
                    image: nil,
                    accessibilityIdentifier: "ScrollableTabBar.Test.1"
                ),
                .init(
                    title: "Cookie",
                    image: nil,
                    accessibilityIdentifier: "ScrollableTabBar.Test.2"
                ),
                .init(
                    title: "Security",
                    image: nil,
                    accessibilityIdentifier: "ScrollableTabBar.Test.3"
                ),
            ],
            selectedIndex: 0
        )
    }

    private func showInWindow(
        _ viewController: UIViewController,
        size: CGSize = CGSize(width: 390, height: 844)
    ) -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = viewController
        viewController.loadViewIfNeeded()
        viewController.view.frame = window.bounds
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { subview in
            [subview] + descendants(of: subview)
        }
    }
}
#endif
