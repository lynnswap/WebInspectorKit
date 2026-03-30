import Foundation
import Testing
import WebKit
@testable import WebInspectorUI
@testable import WebInspectorEngine
@testable import WebInspectorRuntime

#if canImport(UIKit)
import UIKit

@MainActor
@Suite(.serialized)
struct TabViewControllerUITabTests {
    @Test
    func containerUsesCompactHostWhenSizeClassIsCompact() {
        let controller = WIInspectorController()
        let container = WITabViewController(
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
        let container = WITabViewController(
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
        let tabs: [WITab] = [.dom(), .network()]
        let container = WITabViewController(
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
        let container = WITabViewController(
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
        let tabs: [WITab] = [.dom(), .network()]
        let container = WITabViewController(
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

        #expect(controller.selectedTab?.id == "wi_network")
    }

    @Test
    func compactToRegularMapsElementSelectionToDOM() {
        let controller = WIInspectorController()
        let tabs: [WITab] = [.dom(), .element(), .network()]
        let container = WITabViewController(
            controller,
            webView: nil,
            tabs: tabs
        )

        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: tabs)

        let elementTab = controller.tabs.first(where: { $0.identifier == WITab.elementTabID })
        controller.setSelectedTab(elementTab)
        #expect(controller.selectedTab?.id == WITab.elementTabID)

        configureSizeClass(.regular, for: container, requestedTabs: tabs)

        #expect(controller.selectedTab?.id == WITab.domTabID)
    }

    @Test
    func sizeClassChangeKeepsSelectedTabWhenTabStillExists() {
        let controller = WIInspectorController()
        let requestedTabs: [WITab] = [.dom(), .network()]
        let container = WITabViewController(
            controller,
            webView: nil,
            tabs: requestedTabs
        )
        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: requestedTabs)
        let selectedNetworkTab = controller.tabs.first(where: { $0.identifier == WITab.networkTabID })
        controller.setSelectedTab(selectedNetworkTab)
        #expect(controller.selectedTab?.id == WITab.networkTabID)

        configureSizeClass(.regular, for: container, requestedTabs: requestedTabs)

        #expect(controller.selectedTab?.id == WITab.networkTabID)
        #expect(container.resolvedTabIDsForTesting == ["wi_dom", "wi_network"])
    }

    @Test
    func compactHostSelectionUpdatesControllerSelectionWhenConnected() {
        let controller = WIInspectorController()
        let container = WITabViewController(
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
            let domTab = compactHost.currentUITabsForTesting.first(where: { $0.identifier == WITab.domTabID }),
            let networkTab = compactHost.currentUITabsForTesting.first(where: { $0.identifier == WITab.networkTabID })
        else {
            Issue.record("Expected DOM and Network tabs")
            return
        }

        #expect(compactHost.tabBarController(compactHost, shouldSelectTab: networkTab))
        compactHost.selectedTab = networkTab
        compactHost.tabBarController(compactHost, didSelectTab: networkTab, previousTab: domTab)

        #expect(controller.selectedTab?.id == "wi_network")
    }

    @Test
    func compactHostProgrammaticSelectionReappliesRuntimeState() async {
        let controller = WIInspectorController()
        let container = WITabViewController(
            controller,
            webView: makeTestWebView(),
            tabs: [.dom(), .network()]
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        container.loadViewIfNeeded()
        container.viewWillAppear(false)
        drainMainQueue()
        configureSizeClass(.compact, for: container, requestedTabs: [.dom(), .network()])
        drainMainQueue()
        await container.waitForRuntimeStateSyncForTesting()

        guard let networkTab = controller.tabs.first(where: { $0.identifier == WITab.networkTabID }) else {
            Issue.record("Expected network tab")
            return
        }

        controller.setSelectedTab(networkTab)
        await waitForRuntimeState(
            in: container,
            inspector: controller,
            selectedTabID: WITab.networkTabID,
            networkMode: .active
        )

        #expect(controller.selectedTab?.id == WITab.networkTabID)
        #expect(controller.network.session.mode == .active)
    }

    @Test
    func sharedControllerProgrammaticSelectionReappliesRuntimeStateForEachVisibleContainer() async {
        let controller = WIInspectorController()
        let firstContainer = WITabViewController(
            controller,
            webView: makeTestWebView(),
            tabs: [.dom(), .network()]
        )
        let secondContainer = WITabViewController(
            controller,
            webView: makeTestWebView(),
            tabs: [.dom(), .network()]
        )
        let firstWindow = UIWindow(frame: UIScreen.main.bounds)
        let secondWindow = UIWindow(frame: UIScreen.main.bounds)
        firstWindow.rootViewController = firstContainer
        secondWindow.rootViewController = secondContainer
        firstWindow.makeKeyAndVisible()
        secondWindow.makeKeyAndVisible()
        defer {
            firstWindow.isHidden = true
            firstWindow.rootViewController = nil
            secondWindow.isHidden = true
            secondWindow.rootViewController = nil
        }

        firstContainer.loadViewIfNeeded()
        secondContainer.loadViewIfNeeded()
        firstContainer.viewWillAppear(false)
        secondContainer.viewWillAppear(false)
        drainMainQueue()
        await firstContainer.waitForRuntimeStateSyncForTesting()
        await secondContainer.waitForRuntimeStateSyncForTesting()

        guard let networkTab = controller.tabs.first(where: { $0.identifier == WITab.networkTabID }) else {
            Issue.record("Expected network tab")
            return
        }

        controller.setSelectedTab(networkTab)

        await waitForRuntimeState(
            in: firstContainer,
            inspector: controller,
            selectedTabID: WITab.networkTabID,
            networkMode: .active
        )
        await waitForRuntimeState(
            in: secondContainer,
            inspector: controller,
            selectedTabID: WITab.networkTabID,
            networkMode: .active
        )
    }

    @Test
    func compactHostPreservesSelectionWhenTabIdentifiersDuplicate() {
        let controller = WIInspectorController()
        let firstCustom = makeTab(id: "custom", title: "First")
        let secondCustom = makeTab(id: "custom", title: "Second")
        let requestedTabs: [WITab] = [firstCustom, secondCustom, .network()]
        let container = WITabViewController(
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

        #expect(controller.selectedTab === secondCustom)
    }

    @Test
    func compactHostUsesTabIdentifiersDirectly() {
        let controller = WIInspectorController()
        let container = WITabViewController(
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

        #expect(compactHost.displayedTabIdentifiersForTesting == [WITab.domTabID, WITab.elementTabID, WITab.networkTabID])
    }

    @Test
    func compactContainerRecreationRestoresSyntheticElementSelection() {
        let controller = WIInspectorController()
        let requestedTabs: [WITab] = [.dom(), .network()]
        let firstContainer = WITabViewController(
            controller,
            webView: nil,
            tabs: requestedTabs
        )
        firstContainer.horizontalSizeClassOverrideForTesting = .compact
        firstContainer.loadViewIfNeeded()
        firstContainer.beginAppearanceTransition(true, animated: false)
        firstContainer.endAppearanceTransition()

        guard let firstHost = firstContainer.activeHostViewControllerForTesting as? WICompactTabHostViewController else {
            Issue.record("Expected first compact host")
            return
        }
        guard
            let domTab = firstHost.currentUITabsForTesting.first(where: { $0.identifier == WITab.domTabID }),
            let elementTab = firstHost.currentUITabsForTesting.first(where: { $0.identifier == WITab.elementTabID })
        else {
            Issue.record("Expected DOM and Element tabs")
            return
        }

        #expect(firstHost.tabBarController(firstHost, shouldSelectTab: elementTab))
        firstHost.selectedTab = elementTab
        firstHost.tabBarController(firstHost, didSelectTab: elementTab, previousTab: domTab)
        #expect(controller.selectedTab?.identifier == WITab.elementTabID)

        let secondContainer = WITabViewController(
            controller,
            webView: nil,
            tabs: requestedTabs
        )
        secondContainer.horizontalSizeClassOverrideForTesting = .compact
        secondContainer.loadViewIfNeeded()
        secondContainer.beginAppearanceTransition(true, animated: false)
        secondContainer.endAppearanceTransition()
        drainMainQueue()

        guard let secondHost = secondContainer.activeHostViewControllerForTesting as? WICompactTabHostViewController else {
            Issue.record("Expected second compact host")
            return
        }

        #expect(secondHost.displayedTabIdentifiersForTesting == [WITab.domTabID, WITab.elementTabID, WITab.networkTabID])
        #expect(controller.preferredCompactSelectedTabIdentifier == WITab.elementTabID)
    }

    @Test
    func sharedTabsDoNotShareCompactCacheAcrossContainers() {
        var createdControllers: [UIViewController] = []
        let sharedTab = makeProviderTab(id: "custom", title: "Custom") {
            let viewController = UIViewController()
            createdControllers.append(viewController)
            return viewController
        }
        let sharedTabs: [WITab] = [sharedTab]

        let firstController = WIInspectorController()
        let secondController = WIInspectorController()
        let firstContainer = WITabViewController(
            firstController,
            webView: nil,
            tabs: sharedTabs
        )
        let secondContainer = WITabViewController(
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
        let requestedTabs: [WITab] = [
            makeProviderTab(id: "custom", title: "Custom") {
                createdCount += 1
                return UIViewController()
            }
        ]
        let firstController = WIInspectorController()
        let secondController = WIInspectorController()
        let container = WITabViewController(
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
    func setInspectorControllerPreservesLatestCompactSelectionDuringAsyncSwap() async {
        let firstController = WIInspectorController()
        let secondController = WIInspectorController()
        let container = WITabViewController(
            firstController,
            webView: makeTestWebView(),
            tabs: [.dom(), .network()]
        )

        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: [.dom(), .network()])
        guard let networkTab = firstController.tabs.first(where: { $0.identifier == WITab.networkTabID }) else {
            Issue.record("Expected network tab")
            return
        }
        firstController.setSelectedTab(networkTab)
        let replacementWebView = makeTestWebView()
        container.setPageWebView(replacementWebView)
        container.setInspectorController(secondController)

        await container.waitForRuntimeStateSyncForTesting()

        #expect(secondController.selectedTab?.identifier == WITab.networkTabID)
        #expect(secondController.preferredCompactSelectedTabIdentifier == WITab.networkTabID)
        #expect(firstController.lifecycle == .disconnected)
    }

    @Test
    func setInspectorControllerReplaysPageWebViewUpdateThatArrivesDuringSwap() async {
        let firstController = WIInspectorController()
        let secondController = WIInspectorController()
        let container = WITabViewController(
            firstController,
            webView: nil,
            tabs: [.dom(), .network()]
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        container.loadViewIfNeeded()
        await waitForControllerLifecycles(
            in: container,
            states: [(firstController, .suspended)]
        )

        container.setInspectorController(secondController)
        container.setPageWebView(makeTestWebView())

        await waitForControllerLifecycles(
            in: container,
            states: [
                (firstController, .disconnected),
                (secondController, .active)
            ]
        )

        #expect(secondController.lifecycle == .active)
    }

    @Test
    func consecutiveInspectorControllerSwapsKeepEarlierApplyTasksSequenced() async {
        let firstController = WIInspectorController()
        let secondController = WIInspectorController()
        let thirdController = WIInspectorController()
        let initialWebView = makeTestWebView()
        let container = WITabViewController(
            firstController,
            webView: initialWebView,
            tabs: [.dom(), .network()]
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: [.dom(), .network()])
        await container.waitForRuntimeStateSyncForTesting()

        container.setPageWebView(makeTestWebView())
        container.setInspectorController(secondController)
        container.setInspectorController(thirdController)

        await waitForControllerLifecycles(
            in: container,
            states: [
                (firstController, .disconnected),
                (thirdController, .active)
            ]
        )

        #expect(container.inspectorController === thirdController)
        #expect(firstController.lifecycle == .disconnected)
        #expect(secondController.lifecycle == .disconnected)
        #expect(thirdController.lifecycle == .active)
    }

    @Test
    func setInspectorControllerWithSameControllerKeepsExistingController() async {
        let controller = WIInspectorController()
        let container = WITabViewController(
            controller,
            webView: makeTestWebView(),
            tabs: [.dom(), .network()]
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: [.dom(), .network()])
        await waitForControllerLifecycles(
            in: container,
            states: [(controller, .active)]
        )

        container.setInspectorController(controller)
        container.viewWillAppear(false)
        await container.waitForRuntimeStateSyncForTesting()

        #expect(container.inspectorController === controller)
        #expect(controller.lifecycle == .active)
    }

    @Test
    func setInspectorControllerWithCurrentControllerOverridesPendingSwap() async {
        let firstController = WIInspectorController()
        let secondController = WIInspectorController()
        let container = WITabViewController(
            firstController,
            webView: makeTestWebView(),
            tabs: [.dom(), .network()]
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: [.dom(), .network()])
        await waitForControllerLifecycles(
            in: container,
            states: [(firstController, .active)]
        )

        container.setInspectorController(secondController)
        container.setInspectorController(firstController)

        await waitForControllerLifecycles(
            in: container,
            states: [
                (firstController, .active),
                (secondController, .disconnected)
            ]
        )

        #expect(container.inspectorController === firstController)
        #expect(firstController.lifecycle == .active)
        #expect(secondController.lifecycle == .disconnected)
    }

    @Test
    func compactToRegularDropCompactTabCacheWhilePreservingSharedRootCache() {
        var createdCount = 0
        let requestedTabs: [WITab] = [
            makeProviderTab(id: "custom", title: "Custom") {
                createdCount += 1
                return UIViewController()
            }
        ]

        let controller = WIInspectorController()
        let container = WITabViewController(
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
        let tabs: [WITab] = [.dom(), .element(), .network()]
        let container = WITabViewController(
            controller,
            webView: nil,
            tabs: tabs
        )
        container.horizontalSizeClassOverrideForTesting = .regular

        let elementTab = tabs.first(where: { $0.identifier == WITab.elementTabID })
        controller.setSelectedTab(elementTab)
        #expect(controller.selectedTab?.id == WITab.elementTabID)

        container.loadViewIfNeeded()

        #expect(container.activeHostKindForTesting == "regular")
        #expect(controller.selectedTab?.id == WITab.domTabID)
    }

    @Test
    func sizeClassSwitchDoesNotRewriteModelTabs() {
        let controller = WIInspectorController()
        let requestedTabs: [WITab] = [.dom(), .network()]
        let container = WITabViewController(
            controller,
            webView: nil,
            tabs: requestedTabs
        )
        container.loadViewIfNeeded()
        #expect(controller.tabs.map(\.identifier) == [WITab.domTabID, WITab.networkTabID])

        configureSizeClass(.compact, for: container, requestedTabs: requestedTabs)
        #expect(controller.tabs.map(\.identifier) == [WITab.domTabID, WITab.networkTabID])

        configureSizeClass(.regular, for: container, requestedTabs: requestedTabs)
        #expect(controller.tabs.map(\.identifier) == [WITab.domTabID, WITab.networkTabID])
    }

    @Test
    func domTabProviderUsesCompactSplitColumnInCompactSizeClass() {
        let controller = WIInspectorController()
        let container = WITabViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .network()]
        )
        container.horizontalSizeClassOverrideForTesting = .compact
        let tab = WITab.dom()
        let viewController = container.makeTabRootViewController(for: tab)

        guard let domViewController = viewController as? WIDOMViewController else {
            Issue.record("Expected compact DOM tab root to be WIDOMViewController")
            return
        }
        domViewController.loadViewIfNeeded()

        guard let compactColumn = domViewController.compactColumnViewControllerForTesting as? UINavigationController else {
            Issue.record("Expected compact DOM split column to be a navigation controller")
            return
        }
        guard let secondaryColumn = domViewController.secondaryColumnViewControllerForTesting as? UINavigationController else {
            Issue.record("Expected secondary DOM split column to be a navigation controller")
            return
        }

        #expect(domViewController.activeHostKindForTesting == "compact")
        #expect(domViewController.activeHostViewControllerForTesting is UISplitViewController)
        #expect(compactColumn.topViewController is WIDOMTreeViewController)
        let buttonIdentifiers = compactColumn.topViewController?.navigationItem.rightBarButtonItems?.compactMap(\.accessibilityIdentifier) ?? []
        #expect(buttonIdentifiers == ["WI.DOM.MenuButton", "WI.DOM.PickButton"])
        if #available(iOS 26.0, *) {
            #expect(domViewController.primaryColumnViewControllerForTesting == nil)
            #expect(secondaryColumn.topViewController is WIDOMTreeViewController)
            #expect(domViewController.inspectorColumnViewControllerForTesting is UINavigationController)
        } else {
            guard let primaryColumn = domViewController.primaryColumnViewControllerForTesting as? UINavigationController else {
                Issue.record("Expected primary DOM split column to be a navigation controller")
                return
            }
            #expect(primaryColumn.topViewController is WIDOMTreeViewController)
            #expect(secondaryColumn.topViewController is WIDOMDetailViewController)
        }
    }

    @Test
    func domTabProviderUsesInspectorColumnInRegularSizeClassOnIOS26() {
        let controller = WIInspectorController()
        let container = WITabViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .network()]
        )
        container.horizontalSizeClassOverrideForTesting = .regular
        let viewController = container.makeTabRootViewController(for: .dom())

        guard let domViewController = viewController as? WIDOMViewController else {
            Issue.record("Expected regular DOM tab root to be WIDOMViewController")
            return
        }
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = domViewController
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        domViewController.loadViewIfNeeded()
        drainMainQueue()

        #expect(domViewController.activeHostKindForTesting == "regular")
        #expect(domViewController.activeHostViewControllerForTesting is UISplitViewController)
        #expect(domViewController.compactColumnViewControllerForTesting is UINavigationController)

        if #available(iOS 26.0, *) {
            #expect(domViewController.primaryColumnViewControllerForTesting == nil)
            #expect(domViewController.secondaryColumnViewControllerForTesting is UINavigationController)
            #expect(domViewController.inspectorColumnViewControllerForTesting is UINavigationController)
            #expect(domViewController.isInspectorColumnVisibleForTesting)
        } else {
            #expect(domViewController.primaryColumnViewControllerForTesting is UINavigationController)
            #expect(domViewController.secondaryColumnViewControllerForTesting is UINavigationController)
            #expect(domViewController.inspectorColumnViewControllerForTesting == nil)
            #expect(domViewController.isInspectorColumnVisibleForTesting == false)
        }
    }

    @Test
    func domTabProviderCanForceLegacyRegularSplitForTesting() {
        let domViewController = WIDOMViewController(inspector: WIInspectorController().dom)
        domViewController.regularLayoutModeOverrideForTesting = .legacyPrimarySecondary
        domViewController.horizontalSizeClassOverrideForTesting = .regular

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = domViewController
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        domViewController.loadViewIfNeeded()
        drainMainQueue()

        #expect(domViewController.activeHostKindForTesting == "regular")
        #expect(domViewController.primaryColumnViewControllerForTesting is UINavigationController)
        #expect(domViewController.secondaryColumnViewControllerForTesting is UINavigationController)
        #expect(domViewController.compactColumnViewControllerForTesting is UINavigationController)
        #expect(domViewController.inspectorColumnViewControllerForTesting == nil)
        #expect(domViewController.isInspectorColumnVisibleForTesting == false)
    }

    @Test
    func domHostMenuResolvesLatestSelectionStateOnDemand() {
        let inspector = makeDOMInspectorWithSelection()
        let viewController = WIDOMViewController(inspector: inspector)

        viewController.loadViewIfNeeded()

        #expect(viewController.usesDeferredSecondaryMenuForTesting)

        let selectedDeleteAction = deleteAction(in: viewController.resolvedSecondaryMenuForTesting)
        let selectedHTMLAction = copyHTMLAction(in: viewController.resolvedSecondaryMenuForTesting)
        #expect(selectedDeleteAction?.attributes.contains(.disabled) == false)
        #expect(selectedHTMLAction?.attributes.contains(.disabled) == false)

        inspector.documentStore.applySelectionSnapshot(nil)

        let unselectedDeleteAction = deleteAction(in: viewController.resolvedSecondaryMenuForTesting)
        let unselectedHTMLAction = copyHTMLAction(in: viewController.resolvedSecondaryMenuForTesting)
        #expect(unselectedDeleteAction?.attributes.contains(.disabled) == true)
        #expect(unselectedHTMLAction?.attributes.contains(.disabled) == true)
    }

    @Test
    func domSplitReappliesNavigationItemsWhenRegularHostAppearsAfterCompactSwitch() {
        let controller = WIInspectorController()
        let requestedTabs: [WITab] = [.dom(), .network()]
        let container = WITabViewController(
            controller,
            webView: makeTestWebView(),
            tabs: requestedTabs
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        container.loadViewIfNeeded()
        drainMainQueue()
        configureSizeClass(.compact, for: container, requestedTabs: requestedTabs)
        drainMainQueue()
        configureSizeClass(.regular, for: container, requestedTabs: requestedTabs)
        drainMainQueue()

        guard let regularHost = container.activeHostViewControllerForTesting as? WIRegularTabHostViewController else {
            Issue.record("Expected regular host")
            return
        }
        guard let domViewController = regularHost.displayedRootViewControllerForTesting as? WIDOMViewController else {
            Issue.record("Expected DOM root to be displayed in regular host")
            return
        }
        guard let rootContainerViewController = regularHost.viewControllers.first else {
            Issue.record("Expected regular host root container")
            return
        }
        let hostNavigationItem = rootContainerViewController.navigationItem

        regularHost.loadViewIfNeeded()
        rootContainerViewController.loadViewIfNeeded()
        #expect(domViewController.parent === rootContainerViewController)
        drainMainQueue()

        let buttonIdentifiers = hostNavigationItem.rightBarButtonItems?.compactMap(\.accessibilityIdentifier) ?? []
        #expect(buttonIdentifiers == ["WI.DOM.MenuButton", "WI.DOM.PickButton"])
    }

    @Test
    func domTabProviderReturnsSplitControllerWhenSizeClassIsUnspecified() {
        let controller = WIInspectorController()
        let container = WITabViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .network()]
        )
        let viewController = container.makeTabRootViewController(for: .dom())

        #expect(viewController is WIDOMViewController)
    }

    @Test
    func networkTabProviderUsesCompactSplitColumnInCompactSizeClass() {
        let controller = WIInspectorController()
        let container = WITabViewController(
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

        guard let compactColumn = networkViewController.compactColumnViewControllerForTesting as? WINetworkCompactViewController else {
            Issue.record("Expected compact Network split column to be WINetworkCompactViewController")
            return
        }
        guard let primaryColumn = networkViewController.primaryColumnViewControllerForTesting as? UINavigationController else {
            Issue.record("Expected primary Network split column to be a navigation controller")
            return
        }
        guard let secondaryColumn = networkViewController.secondaryColumnViewControllerForTesting as? UINavigationController else {
            Issue.record("Expected secondary Network split column to be a navigation controller")
            return
        }

        #expect(networkViewController.activeHostKindForTesting == "compact")
        #expect(networkViewController.activeHostViewControllerForTesting is UISplitViewController)
        #expect(compactColumn.topViewController is WINetworkListViewController)
        #expect(primaryColumn.topViewController is WINetworkListViewController)
        #expect(secondaryColumn.topViewController is WINetworkDetailViewController)
    }

    @Test
    func networkTabProviderRetainsSplitColumnsInRegularSizeClass() {
        let controller = WIInspectorController()
        let container = WITabViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .network()]
        )
        container.horizontalSizeClassOverrideForTesting = .regular
        let viewController = container.makeTabRootViewController(for: .network())

        guard let networkViewController = viewController as? WINetworkViewController else {
            Issue.record("Expected regular Network tab root to be WINetworkViewController")
            return
        }
        networkViewController.loadViewIfNeeded()

        #expect(networkViewController.activeHostKindForTesting == "regular")
        #expect(networkViewController.activeHostViewControllerForTesting is UISplitViewController)
        #expect(networkViewController.primaryColumnViewControllerForTesting is UINavigationController)
        #expect(networkViewController.secondaryColumnViewControllerForTesting is UINavigationController)
        #expect(networkViewController.compactColumnViewControllerForTesting is WINetworkCompactViewController)
    }

    @Test
    func networkSplitReappliesNavigationItemsWhenRegularHostAppearsAfterCompactSwitch() {
        let controller = WIInspectorController()
        let requestedTabs: [WITab] = [.dom(), .network()]
        let container = WITabViewController(
            controller,
            webView: makeTestWebView(),
            tabs: requestedTabs
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        container.loadViewIfNeeded()
        let networkTab = controller.tabs.first(where: { $0.identifier == WITab.networkTabID })
        controller.setSelectedTab(networkTab)
        drainMainQueue()
        configureSizeClass(.compact, for: container, requestedTabs: requestedTabs)
        drainMainQueue()
        configureSizeClass(.regular, for: container, requestedTabs: requestedTabs)
        drainMainQueue()

        guard let regularHost = container.activeHostViewControllerForTesting as? WIRegularTabHostViewController else {
            Issue.record("Expected regular host")
            return
        }
        guard let networkViewController = regularHost.displayedRootViewControllerForTesting as? WINetworkViewController else {
            Issue.record("Expected Network root to be displayed in regular host")
            return
        }
        guard let rootContainerViewController = regularHost.viewControllers.first else {
            Issue.record("Expected regular host root container")
            return
        }
        let hostNavigationItem = rootContainerViewController.navigationItem

        regularHost.loadViewIfNeeded()
        rootContainerViewController.loadViewIfNeeded()
        #expect(networkViewController.parent === rootContainerViewController)
        drainMainQueue()

        #expect(hostNavigationItem.rightBarButtonItems?.count == 1)
        #expect(hostNavigationItem.additionalOverflowItems != nil)
    }

    @Test
    func regularHostPrepareForRemovalDetachesDisplayedRootController() {
        let controller = WIInspectorController()
        let tabs: [WITab] = [.dom(), .network()]
        controller.setTabs(tabs)
        let host = WIRegularTabHostViewController(model: controller, renderCache: WIUIKitTabRenderCache())

        host.loadViewIfNeeded()

        #expect(host.displayedRootViewControllerForTesting is WIDOMViewController)

        host.prepareForRemoval()

        #expect(host.displayedRootViewControllerForTesting == nil)
    }

    @Test
    func compactHostPrepareForRemovalClearsInstalledTabs() {
        let controller = WIInspectorController()
        controller.setTabs([.dom(), .network()])
        let host = WICompactTabHostViewController(model: controller, renderCache: WIUIKitTabRenderCache())

        host.loadViewIfNeeded()
        #expect(host.currentUITabsForTesting.isEmpty == false)

        host.prepareForRemoval()

        #expect(host.currentUITabsForTesting.isEmpty)
    }

    @Test
    func builtInTabsSurviveCompactRegularCompactSwitchWithoutRetainingOldTabs() {
        let controller = WIInspectorController()
        let requestedTabs: [WITab] = [.dom(), .network()]
        let container = WITabViewController(
            controller,
            webView: nil,
            tabs: requestedTabs
        )

        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: requestedTabs)

        guard let firstCompactHost = container.activeHostViewControllerForTesting as? WICompactTabHostViewController else {
            Issue.record("Expected first compact host")
            return
        }
        #expect(firstCompactHost.currentUITabsForTesting.map(\.identifier) == [WITab.domTabID, WITab.elementTabID, WITab.networkTabID])

        configureSizeClass(.regular, for: container, requestedTabs: requestedTabs)
        #expect(firstCompactHost.currentUITabsForTesting.isEmpty)

        configureSizeClass(.compact, for: container, requestedTabs: requestedTabs)

        guard let secondCompactHost = container.activeHostViewControllerForTesting as? WICompactTabHostViewController else {
            Issue.record("Expected second compact host")
            return
        }

        #expect(firstCompactHost !== secondCompactHost)
        #expect(secondCompactHost.currentUITabsForTesting.map(\.identifier) == [WITab.domTabID, WITab.elementTabID, WITab.networkTabID])
    }

    private func makeTab(id: String, title: String) -> WITab {
        WITab(
            id: id,
            title: title,
            systemImage: "circle"
        )
    }

    private func makeProviderTab(
        id: String,
        title: String,
        viewControllerBuilder: @escaping @MainActor () -> UIViewController
    ) -> WITab {
        WITab(
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

    private func makeDOMInspectorWithSelection() -> WIDOMModel {
        let controller = WIInspectorController()
        let inspector = controller.dom
        let selectedLocalID: UInt64 = 42
        let attributes = [DOMAttribute(nodeId: Int(selectedLocalID), name: "id", value: "selected")]

        inspector.documentStore.replaceDocument(
            with: .init(
                root: DOMGraphNodeDescriptor(
                    localID: 1,
                    backendNodeID: 1,
                    nodeType: 1,
                    nodeName: "HTML",
                    localName: "html",
                    nodeValue: "",
                    attributes: [],
                    childCount: 1,
                    layoutFlags: [],
                    isRendered: true,
                    children: [
                        DOMGraphNodeDescriptor(
                            localID: selectedLocalID,
                            backendNodeID: Int(selectedLocalID),
                            nodeType: 1,
                            nodeName: "DIV",
                            localName: "div",
                            nodeValue: "",
                            attributes: attributes,
                            childCount: 0,
                            layoutFlags: [],
                            isRendered: true,
                            children: []
                        )
                    ]
                )
            )
        )
        inspector.documentStore.applySelectionSnapshot(
            .init(
                localID: selectedLocalID,
                preview: "<div id=\"selected\"></div>",
                attributes: attributes,
                path: ["html", "body", "div"],
                selectorPath: "#selected",
                styleRevision: 0
            )
        )
        return inspector
    }

    private func copyHTMLAction(in menu: UIMenu) -> UIAction? {
        guard let copyMenu = menu.children.first as? UIMenu else {
            return nil
        }
        return copyMenu.children.first as? UIAction
    }

    private func deleteAction(in menu: UIMenu) -> UIAction? {
        guard let destructiveMenu = menu.children.last as? UIMenu else {
            return nil
        }
        return destructiveMenu.children.first as? UIAction
    }

    private func configureSizeClass(
        _ sizeClass: UIUserInterfaceSizeClass,
        for container: WITabViewController,
        requestedTabs: [WITab]
    ) {
        container.horizontalSizeClassOverrideForTesting = sizeClass
        container.setTabs(requestedTabs)
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func waitForRuntimeState(
        in container: WITabViewController,
        inspector: WIInspectorController,
        selectedTabID: String,
        networkMode: NetworkLoggingMode,
        attempts: Int = 60
    ) async {
        for _ in 0..<attempts {
            drainMainQueue()
            await container.waitForRuntimeStateSyncForTesting()
            if inspector.selectedTab?.identifier == selectedTabID,
               inspector.network.session.mode == networkMode {
                return
            }
        }

        Issue.record(
            """
            Timed out waiting for runtime state \
            lifecycle=\(inspector.lifecycle) \
            selectedTab=\(inspector.selectedTab?.identifier ?? "nil") \
            networkMode=\(inspector.network.session.mode) \
            activeHost=\(container.activeHostKindForTesting ?? "nil")
            """
        )
    }

    private func waitForControllerLifecycles(
        in container: WITabViewController,
        states: [(WIInspectorController, WISessionLifecycle)],
        attempts: Int = 20
    ) async {
        for _ in 0..<attempts {
            drainMainQueue()
            await container.waitForRuntimeStateSyncForTesting()
            if states.allSatisfy({ controller, lifecycle in
                controller.lifecycle == lifecycle
            }) {
                return
            }
        }
    }
}
#endif
