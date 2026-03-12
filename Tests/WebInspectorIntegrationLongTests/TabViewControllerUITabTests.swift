import Testing
import WebKit
import WebInspectorTestSupport
@testable import WebInspectorUI
@testable import WebInspectorCore
@testable import WebInspectorDOM
@testable import WebInspectorNetwork
@testable import WebInspectorShell

#if canImport(UIKit)
import UIKit

@MainActor
struct TabViewControllerUITabTests {
    @Test
    func containerUsesCompactHostWhenSizeClassIsCompact() {
        let controller = WIInspectorController()
        let container = WIInspectorViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .network()]
        )

        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: [.dom(), .network()])

        #expect(container.activeHostKindForTesting == "compact")
        #expect(container.activeHostViewControllerForTesting is WICompactTabHostViewController)
        #expect(container.resolvedTabIDsForTesting == ["wi_dom", "wi_network"])
    }

    @Test
    func containerSwitchesHostWhenSizeClassChanges() {
        let controller = WIInspectorController()
        let container = WIInspectorViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .network()]
        )
        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: [.dom(), .network()])

        configureSizeClass(.regular, for: container, requestedTabs: [.dom(), .network()])

        #expect(container.activeHostKindForTesting == "regular")
        #expect(container.activeHostViewControllerForTesting is WIRegularTabHostViewController)
        #expect(container.activeHostViewControllerForTesting is UINavigationController)
        #expect(container.resolvedTabIDsForTesting == ["wi_dom", "wi_network"])
    }

    @Test
    func containerSwitchesHostWhenChangingFromRegularToCompact() {
        let controller = WIInspectorController()
        let tabs: [WIInspectorTab] = [.dom(), .network()]
        let container = WIInspectorViewController(
            controller,
            webView: nil,
            tabs: tabs
        )
        container.loadViewIfNeeded()

        configureSizeClass(.regular, for: container, requestedTabs: tabs)
        #expect(container.activeHostKindForTesting == "regular")

        configureSizeClass(.compact, for: container, requestedTabs: tabs)

        #expect(container.activeHostKindForTesting == "compact")
        #expect(container.activeHostViewControllerForTesting is WICompactTabHostViewController)
        #expect(container.resolvedTabIDsForTesting == ["wi_dom", "wi_network"])
    }

    @Test
    func regularHostFiltersElementTabWhenRequested() {
        let controller = WIInspectorController()
        let custom = makeTab(id: "custom", title: "Custom")
        let container = WIInspectorViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .element(), custom, .network()]
        )

        container.loadViewIfNeeded()
        configureSizeClass(.regular, for: container, requestedTabs: [.dom(), .element(), custom, .network()])

        #expect(container.resolvedTabIDsForTesting == ["wi_dom", "wi_element", "custom", "wi_network"])

        guard let regularHost = container.activeHostViewControllerForTesting as? WIRegularTabHostViewController else {
            Issue.record("Expected regular host")
            return
        }

        #expect(regularHost.displayedTabIDsForTesting == ["wi_dom", "custom", "wi_network"])
    }

    @Test
    func regularHostRoutesUserSelectionIntoModel() {
        let controller = WIInspectorController()
        let tabs: [WIInspectorTab] = [.dom(), .network()]
        let container = WIInspectorViewController(
            controller,
            webView: nil,
            tabs: tabs
        )
        container.loadViewIfNeeded()
        configureSizeClass(.regular, for: container, requestedTabs: tabs)

        guard
            let host = container.activeHostViewControllerForTesting as? WIRegularTabHostViewController,
            let segmentedControl = host.viewControllers.first?.navigationItem.titleView as? UISegmentedControl
        else {
            Issue.record("Expected segmented control in navigation title view")
            return
        }

        segmentedControl.selectedSegmentIndex = 1
        host.handleSegmentSelectionChangedForTesting(segmentedControl)

        #expect(controller.selectedPanelConfiguration?.identifier == "wi_network")
    }

    @Test
    func compactToRegularMapsElementSelectionToDOM() {
        let controller = WIInspectorController()
        let tabs: [WIInspectorTab] = [.dom(), .element(), .network()]
        let container = WIInspectorViewController(
            controller,
            webView: nil,
            tabs: tabs
        )

        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: tabs)

        let elementPanel = controller.panelConfigurations.first(where: { $0.identifier == WIInspectorTab.elementTabID })
        controller.setSelectedPanelFromUI(elementPanel)
        #expect(controller.selectedPanelConfiguration?.identifier == WIInspectorTab.elementTabID)

        configureSizeClass(.regular, for: container, requestedTabs: tabs)

        #expect(controller.selectedPanelConfiguration?.identifier == WIInspectorTab.domTabID)
    }

    @Test
    func sizeClassChangeKeepsSelectedTabWhenTabStillExists() {
        let controller = WIInspectorController()
        let requestedTabs: [WIInspectorTab] = [.dom(), .network()]
        let container = WIInspectorViewController(
            controller,
            webView: nil,
            tabs: requestedTabs
        )
        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: requestedTabs)
        let selectedNetworkPanel = controller.panelConfigurations.first(where: { $0.identifier == WIInspectorTab.networkTabID })
        controller.setSelectedPanelFromUI(selectedNetworkPanel)
        #expect(controller.selectedPanelConfiguration?.identifier == WIInspectorTab.networkTabID)

        configureSizeClass(.regular, for: container, requestedTabs: requestedTabs)

        #expect(controller.selectedPanelConfiguration?.identifier == WIInspectorTab.networkTabID)
        #expect(container.resolvedTabIDsForTesting == ["wi_dom", "wi_network"])
    }

    @Test
    func compactHostSelectionUpdatesControllerSelectionWhenConnected() {
        let controller = WIInspectorController()
        let container = WIInspectorViewController(
            controller,
            webView: makeTestWebView(),
            tabs: [.dom(), .network()]
        )

        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: [.dom(), .network()])
        container.viewWillAppear(false)

        guard let compactHost = container.activeHostViewControllerForTesting as? WICompactTabHostViewController else {
            Issue.record("Expected compact host")
            return
        }

        guard
            let domTab = compactHost.currentUITabsForTesting.first(where: { $0.identifier == WIInspectorTab.domTabID }),
            let networkTab = compactHost.currentUITabsForTesting.first(where: { $0.identifier == WIInspectorTab.networkTabID })
        else {
            Issue.record("Expected DOM and Network tabs")
            return
        }

        #expect(compactHost.tabBarController(compactHost, shouldSelectTab: networkTab))
        compactHost.selectedTab = networkTab
        compactHost.tabBarController(compactHost, didSelectTab: networkTab, previousTab: domTab)

        #expect(controller.selectedPanelConfiguration?.identifier == "wi_network")
    }

    @Test
    func compactHostPreservesSelectionWhenTabIdentifiersDuplicate() {
        let controller = WIInspectorController()
        let firstCustom = makeTab(id: "custom", title: "First")
        let secondCustom = makeTab(id: "custom", title: "Second")
        let requestedTabs: [WIInspectorTab] = [firstCustom, secondCustom, .network()]
        let container = WIInspectorViewController(
            controller,
            webView: nil,
            tabs: requestedTabs
        )

        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: requestedTabs)

        guard let compactHost = container.activeHostViewControllerForTesting as? WICompactTabHostViewController else {
            Issue.record("Expected compact host")
            return
        }

        let duplicateUITabs = compactHost.currentUITabsForTesting.filter { $0.identifier == "custom" }
        guard duplicateUITabs.count == 2 else {
            Issue.record("Expected two visible tabs for duplicate identifier")
            return
        }

        let firstUITab = duplicateUITabs[0]
        let secondUITab = duplicateUITabs[1]
        #expect(compactHost.tabBarController(compactHost, shouldSelectTab: secondUITab))
        compactHost.selectedTab = secondUITab
        compactHost.tabBarController(compactHost, didSelectTab: secondUITab, previousTab: firstUITab)

        #expect(controller.selectedPanelConfiguration?.identifier == secondCustom.identifier)
    }

    @Test
    func compactHostUsesTabIdentifiersDirectly() {
        let controller = WIInspectorController()
        let container = WIInspectorViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .network()]
        )

        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: [.dom(), .network()])

        guard let compactHost = container.activeHostViewControllerForTesting as? WICompactTabHostViewController else {
            Issue.record("Expected compact host")
            return
        }

        #expect(compactHost.displayedTabIdentifiersForTesting == [WIInspectorTab.domTabID, WIInspectorTab.networkTabID])
    }

    @Test
    func externalPanelUpdatesRefreshVisibleTabs() async {
        let controller = WIInspectorController()
        let container = WIInspectorViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .network()]
        )
        let tabResolutionRevisions = AsyncValueQueue<UInt64>()
        container.onTabResolutionForTesting = { revision in
            Task {
                await tabResolutionRevisions.push(revision)
            }
        }

        container.loadViewIfNeeded()
        configureSizeClass(.regular, for: container, requestedTabs: [.dom(), .network()])
        #expect(container.resolvedTabIDsForTesting == [WIInspectorTab.domTabID, WIInspectorTab.networkTabID])

        controller.configurePanels([WIInspectorTab.dom().configuration])
        _ = await tabResolutionRevisions.next()

        #expect(container.resolvedTabIDsForTesting == [WIInspectorTab.domTabID])
        #expect(controller.selectedPanelConfiguration?.identifier == WIInspectorTab.domTabID)
    }

    @Test
    func sharedTabsDoNotShareCompactCacheAcrossContainers() {
        var createdControllers: [UIViewController] = []
        let sharedTab = makeProviderTab(id: "custom", title: "Custom") {
            let viewController = UIViewController()
            createdControllers.append(viewController)
            return viewController
        }
        let sharedTabs: [WIInspectorTab] = [sharedTab]

        let firstController = WIInspectorController()
        let secondController = WIInspectorController()
        let firstContainer = WIInspectorViewController(
            firstController,
            webView: nil,
            tabs: sharedTabs
        )
        let secondContainer = WIInspectorViewController(
            secondController,
            webView: nil,
            tabs: sharedTabs
        )

        firstContainer.loadViewIfNeeded()
        configureSizeClass(.compact, for: firstContainer, requestedTabs: sharedTabs)
        secondContainer.loadViewIfNeeded()
        configureSizeClass(.compact, for: secondContainer, requestedTabs: sharedTabs)

        #expect(createdControllers.count == 2)
        #expect(createdControllers[0] !== createdControllers[1])
    }

    @Test
    func setInspectorControllerResetsContainerRenderCacheAcrossRegularSwap() {
        var createdCount = 0
        let requestedTabs: [WIInspectorTab] = [
            makeProviderTab(id: "custom", title: "Custom") {
                createdCount += 1
                return UIViewController()
            }
        ]
        let firstController = WIInspectorController()
        let secondController = WIInspectorController()
        let container = WIInspectorViewController(
            firstController,
            webView: nil,
            tabs: requestedTabs
        )

        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: requestedTabs)
        #expect(createdCount == 1)
        configureSizeClass(.regular, for: container, requestedTabs: requestedTabs)
        container.setInspectorController(secondController)
        configureSizeClass(.compact, for: container, requestedTabs: requestedTabs)

        #expect(createdCount == 2)
    }

    @Test
    func compactToRegularDropCompactTabCacheWhilePreservingSharedRootCache() {
        var createdCount = 0
        let requestedTabs: [WIInspectorTab] = [
            makeProviderTab(id: "custom", title: "Custom") {
                createdCount += 1
                return UIViewController()
            }
        ]

        let controller = WIInspectorController()
        let container = WIInspectorViewController(
            controller,
            webView: nil,
            tabs: requestedTabs
        )
        container.loadViewIfNeeded()

        configureSizeClass(.compact, for: container, requestedTabs: requestedTabs)
        guard
            let firstCompactHost = container.activeHostViewControllerForTesting as? WICompactTabHostViewController,
            let firstUITab = firstCompactHost.currentUITabsForTesting.first
        else {
            Issue.record("Expected first compact host and tab")
            return
        }

        configureSizeClass(.regular, for: container, requestedTabs: requestedTabs)
        configureSizeClass(.compact, for: container, requestedTabs: requestedTabs)

        guard
            let secondCompactHost = container.activeHostViewControllerForTesting as? WICompactTabHostViewController,
            let secondUITab = secondCompactHost.currentUITabsForTesting.first
        else {
            Issue.record("Expected second compact host and tab")
            return
        }

        #expect(createdCount == 1)
        #expect(firstUITab !== secondUITab)
    }

    @Test
    func initialRegularLayoutMapsElementSelectionToDOM() {
        let controller = WIInspectorController()
        let tabs: [WIInspectorTab] = [.dom(), .element(), .network()]
        let container = WIInspectorViewController(
            controller,
            webView: nil,
            tabs: tabs
        )
        container.horizontalSizeClassOverrideForTesting = .regular

        let elementPanel = tabs.first(where: { $0.identifier == WIInspectorTab.elementTabID })?.configuration
        controller.setSelectedPanelFromUI(elementPanel)
        #expect(controller.selectedPanelConfiguration?.identifier == WIInspectorTab.elementTabID)

        container.loadViewIfNeeded()

        #expect(container.activeHostKindForTesting == "regular")
        #expect(controller.selectedPanelConfiguration?.identifier == WIInspectorTab.domTabID)
    }

    @Test
    func sizeClassSwitchDoesNotRewriteModelTabs() {
        let controller = WIInspectorController()
        let requestedTabs: [WIInspectorTab] = [.dom(), .network()]
        let container = WIInspectorViewController(
            controller,
            webView: nil,
            tabs: requestedTabs
        )
        container.loadViewIfNeeded()
        #expect(controller.panelConfigurations.map(\.identifier) == [WIInspectorTab.domTabID, WIInspectorTab.networkTabID])

        configureSizeClass(.compact, for: container, requestedTabs: requestedTabs)
        #expect(controller.panelConfigurations.map(\.identifier) == [WIInspectorTab.domTabID, WIInspectorTab.networkTabID])

        configureSizeClass(.regular, for: container, requestedTabs: requestedTabs)
        #expect(controller.panelConfigurations.map(\.identifier) == [WIInspectorTab.domTabID, WIInspectorTab.networkTabID])
    }

    @Test
    func domTabProviderReturnsDOMHostControllerInCompactSizeClass() {
        let controller = WIInspectorController()
        let container = WIInspectorViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .network()]
        )
        container.horizontalSizeClassOverrideForTesting = .compact
        let tab = WIInspectorTab.dom()
        let viewController = container.makeTabRootViewController(for: tab)

        guard let domViewController = viewController as? WIDOMViewController else {
            Issue.record("Expected compact DOM tab root to be WIDOMViewController")
            return
        }
        domViewController.loadViewIfNeeded()
        #expect(domViewController.activeHostKindForTesting == "compact")
        #expect(domViewController.activeHostViewControllerForTesting is UINavigationController)
    }

    @Test
    func domTabProviderReturnsSplitControllerInRegularSizeClass() {
        let controller = WIInspectorController()
        let container = WIInspectorViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .network()]
        )
        container.horizontalSizeClassOverrideForTesting = .regular
        let viewController = container.makeTabRootViewController(for: .dom())

        #expect(viewController is WIDOMViewController)
    }

    @Test
    func domTabProviderReturnsSplitControllerWhenSizeClassIsUnspecified() {
        let controller = WIInspectorController()
        let container = WIInspectorViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .network()]
        )
        let viewController = container.makeTabRootViewController(for: .dom())

        #expect(viewController is WIDOMViewController)
    }

    @Test
    func networkTabProviderReturnsHostControllerInCompactSizeClass() {
        let controller = WIInspectorController()
        let container = WIInspectorViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .network()]
        )
        container.horizontalSizeClassOverrideForTesting = .compact
        let viewController = container.makeTabRootViewController(for: .network())

        guard let networkViewController = viewController as? WINetworkViewController else {
            Issue.record("Expected compact Network tab root to be WINetworkViewController")
            return
        }
        networkViewController.loadViewIfNeeded()
        #expect(networkViewController.activeHostKindForTesting == "compact")
        #expect(networkViewController.activeHostViewControllerForTesting is UINavigationController)
    }

    @Test
    func networkTabProviderReturnsSplitControllerInRegularSizeClass() {
        let controller = WIInspectorController()
        let container = WIInspectorViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .network()]
        )
        container.horizontalSizeClassOverrideForTesting = .regular
        let viewController = container.makeTabRootViewController(for: .network())

        #expect(viewController is WINetworkViewController)
    }

    private func makeTab(id: String, title: String) -> WIInspectorTab {
        WIInspectorTab(
            id: id,
            title: title,
            systemImage: "circle"
        )
    }

    private func makeProviderTab(
        id: String,
        title: String,
        viewControllerBuilder: @escaping @MainActor () -> UIViewController
    ) -> WIInspectorTab {
        WIInspectorTab(
            id: id,
            title: title,
            systemImage: "circle",
            viewControllerProvider: { _ in
                viewControllerBuilder()
            }
        )
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func configureSizeClass(
        _ sizeClass: UIUserInterfaceSizeClass,
        for container: WIInspectorViewController,
        requestedTabs: [WIInspectorTab]
    ) {
        container.horizontalSizeClassOverrideForTesting = sizeClass
        container.setTabs(requestedTabs)
    }
}
#endif
