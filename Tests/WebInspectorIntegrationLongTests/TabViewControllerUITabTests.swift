import Foundation
import Testing
import WebKit
@testable import WebInspectorUI
@testable import WebInspectorEngine
@_spi(Monocly) @testable import WebInspectorRuntime

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
    func compactHostHierarchyUsesClearBackgrounds() {
        let controller = WIInspectorController()
        let container = WITabViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .network()]
        )

        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: [.dom(), .network()])

        #expect(container.view.backgroundColor == .clear)

        guard let compactHost = container.activeHostViewControllerForTesting as? WICompactTabHostViewController else {
            Issue.record("Expected compact host")
            return
        }
        #expect(compactHost.view.backgroundColor == .clear)

        guard let domViewController = compactHost.selectedViewController as? WIDOMViewController else {
            Issue.record("Expected DOM split controller")
            return
        }
        #expect(domViewController.view.backgroundColor == .clear)
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
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        container.loadViewIfNeeded()
        drainMainQueue()
        configureSizeClass(.compact, for: container, requestedTabs: [.dom(), .network()])
        drainMainQueue()

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
    func compactContainerRecreationRestoresExplicitDOMSelectionAfterElementWasShown() {
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
        #expect(controller.preferredCompactSelectedTabIdentifier == WITab.elementTabID)

        #expect(firstHost.tabBarController(firstHost, shouldSelectTab: domTab))
        firstHost.selectedTab = domTab
        firstHost.tabBarController(firstHost, didSelectTab: domTab, previousTab: elementTab)
        #expect(controller.selectedTab?.identifier == WITab.domTabID)
        #expect(controller.preferredCompactSelectedTabIdentifier == WITab.domTabID)

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
        #expect(controller.selectedTab?.identifier == WITab.domTabID)
        #expect(controller.preferredCompactSelectedTabIdentifier == WITab.domTabID)
        #expect(secondHost.selectedTab?.identifier == WITab.domTabID)
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
        drainMainQueue()
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
        #expect(buttonIdentifiers == ["WI.DOM.PickButton"])
        #expect(compactColumn.topViewController?.navigationItem.additionalOverflowItems != nil)
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
    func domSplitAttachesSharedInspectorWebViewOnlyToVisibleTreeHost() {
        let inspector = makeDOMInspectorWithSelection()
        let domViewController = WIDOMViewController(inspector: inspector)
        domViewController.regularLayoutModeOverrideForTesting = .legacyPrimarySecondary
        domViewController.horizontalSizeClassOverrideForTesting = .compact

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = domViewController
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        domViewController.loadViewIfNeeded()
        drainMainQueue()

        #expect(domViewController.compactTreeViewControllerForTesting.isInspectorWebViewAttachedForTesting)
        #expect(domViewController.regularTreeViewControllerForTesting.isInspectorWebViewAttachedForTesting == false)

        domViewController.horizontalSizeClassOverrideForTesting = .regular
        drainMainQueue()

        #expect(domViewController.compactTreeViewControllerForTesting.isInspectorWebViewAttachedForTesting == false)
        #expect(domViewController.regularTreeViewControllerForTesting.isInspectorWebViewAttachedForTesting)
    }

    @Test
    func domSplitKeepsRegularTreeHostActiveInInspectorColumnLayout() {
        guard #available(iOS 26.0, *) else {
            return
        }

        let inspector = makeDOMInspectorWithSelection()
        let domViewController = WIDOMViewController(inspector: inspector)
        domViewController.regularLayoutModeOverrideForTesting = .secondaryWithInspector
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

        #expect(domViewController.compactTreeViewControllerForTesting.isInspectorWebViewAttachedForTesting == false)
        #expect(domViewController.regularTreeViewControllerForTesting.isInspectorWebViewAttachedForTesting)
        #expect(domViewController.isInspectorColumnVisibleForTesting)
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

        inspector.document.applySelectionSnapshot(nil)

        let unselectedDeleteAction = deleteAction(in: viewController.resolvedSecondaryMenuForTesting)
        let unselectedHTMLAction = copyHTMLAction(in: viewController.resolvedSecondaryMenuForTesting)
        #expect(unselectedDeleteAction?.attributes.contains(.disabled) == true)
        #expect(unselectedHTMLAction?.attributes.contains(.disabled) == true)
    }

    @Test
    func domHostDeleteCapturesSelectionBeforeAsyncTaskStarts() async {
        let controller = WIInspectorController()
        let inspector = controller.dom
        inspector.document.replaceDocument(
            with: .init(
                root: DOMGraphNodeDescriptor(
                    localID: 1,
                    backendNodeID: 1,
                    nodeType: 1,
                    nodeName: "HTML",
                    localName: "html",
                    nodeValue: "",
                    attributes: [],
                    childCount: 2,
                    layoutFlags: [],
                    isRendered: true,
                    children: [
                        DOMGraphNodeDescriptor(
                            localID: 42,
                            backendNodeID: 42,
                            nodeType: 1,
                            nodeName: "DIV",
                            localName: "div",
                            nodeValue: "",
                            attributes: [.init(nodeId: 42, name: "id", value: "first")],
                            childCount: 0,
                            layoutFlags: [],
                            isRendered: true,
                            children: []
                        ),
                        DOMGraphNodeDescriptor(
                            localID: 43,
                            backendNodeID: 43,
                            nodeType: 1,
                            nodeName: "DIV",
                            localName: "div",
                            nodeValue: "",
                            attributes: [.init(nodeId: 43, name: "id", value: "second")],
                            childCount: 0,
                            layoutFlags: [],
                            isRendered: true,
                            children: []
                        ),
                    ]
                ),
                selectedLocalID: 42
            )
        )
        inspector.document.applySelectionSnapshot(
            .init(
                localID: 42,
                attributes: [.init(nodeId: 42, name: "id", value: "first")],
                path: ["html", "body", "div"],
                selectorPath: "#first",
                styleRevision: 0
            )
        )
        let viewController = WIDOMViewController(inspector: inspector)
        viewController.loadViewIfNeeded()

        viewController.invokeDeleteSelectionForTesting()
        inspector.document.applySelectionSnapshot(
            .init(
                localID: 43,
                attributes: [.init(nodeId: 43, name: "id", value: "second")],
                path: ["html", "body", "div"],
                selectorPath: "#second",
                styleRevision: 0
            )
        )

        #expect(inspector.document.selectedNode?.localID == 43)
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
        #expect(buttonIdentifiers == ["WI.DOM.PickButton"])
        #expect(hostNavigationItem.additionalOverflowItems != nil)
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

    @Test
    func compactActualWebViewTabSwitchKeepsSelectedNodeAndElementDetailInSync() async throws {
        let controller = WIInspectorController()
        let webView = makeTestWebView()
        await loadHTML(
            """
            <!doctype html>
            <html>
            <body>
                <div id="first">First</div>
                <section id="secondary" class="updated" data-role="hero">Second</section>
            </body>
            </html>
            """,
            in: webView
        )

        let requestedTabs: [WITab] = [.dom(), .network()]
        let container = WITabViewController(
            controller,
            webView: webView,
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
        await waitForControllerLifecycles(
            in: container,
            states: [(controller, .active)]
        )

        guard let compactHost = container.activeHostViewControllerForTesting as? WICompactTabHostViewController else {
            Issue.record("Expected compact host")
            return
        }
        guard let domViewController = compactHost.rootViewControllerForTesting(tabIdentifier: WITab.domTabID) as? WIDOMViewController else {
            Issue.record("Expected DOM root view controller")
            return
        }
        guard let elementViewController = compactHost.rootViewControllerForTesting(tabIdentifier: WITab.elementTabID) as? WIDOMDetailViewController else {
            Issue.record("Expected Element detail view controller")
            return
        }

        let selectedNodeID = try await selectNodeAndWaitForCompactProjection(
            cssSelector: "#secondary",
            expectedAttributes: [
                "id": "secondary",
                "class": "updated",
                "data-role": "hero"
            ],
            in: controller,
            domViewController: domViewController,
            elementViewController: elementViewController,
            requiresTreeSelection: false
        )
        let initialDocumentIdentity = controller.dom.document.documentIdentity
        controller.dom.resetFreshContextDiagnosticsForTesting()

        guard
            let domTab = compactHost.currentUITabsForTesting.first(where: { $0.identifier == WITab.domTabID }),
            let elementTab = compactHost.currentUITabsForTesting.first(where: { $0.identifier == WITab.elementTabID })
        else {
            Issue.record("Expected DOM and Element tabs")
            return
        }

        #expect(compactHost.tabBarController(compactHost, shouldSelectTab: elementTab))
        compactHost.selectedTab = elementTab
        compactHost.tabBarController(compactHost, didSelectTab: elementTab, previousTab: domTab)
        await controller.waitForRuntimeApplyForTesting()

        let elementStatePreserved = await waitForCondition {
            elementViewController.renderedSelectorTextForTesting() == "#secondary"
                && elementViewController.renderedAttributeValueForTesting(nodeID: selectedNodeID, name: "class") == "updated"
        }
        #expect(elementStatePreserved)
        #expect(controller.selectedTab?.identifier == WITab.elementTabID)
        #expect(controller.dom.document.documentIdentity == initialDocumentIdentity)
        #expect(controller.dom.document.selectedNode?.id == selectedNodeID)
        #expect(elementViewController.renderedAttributeValueForTesting(nodeID: selectedNodeID, name: "class") == "updated")
        #expect(controller.dom.freshContextDiagnosticsForTesting.isEmpty)

        #expect(compactHost.tabBarController(compactHost, shouldSelectTab: domTab))
        compactHost.selectedTab = domTab
        compactHost.tabBarController(compactHost, didSelectTab: domTab, previousTab: elementTab)
        await controller.waitForRuntimeApplyForTesting()

        #expect(controller.selectedTab?.identifier == WITab.domTabID)
        #expect(controller.dom.document.documentIdentity == initialDocumentIdentity)
        #expect(controller.dom.document.selectedNode?.id == selectedNodeID)
        #expect(controller.dom.freshContextDiagnosticsForTesting.isEmpty)
    }

    @Test
    func compactActualWebViewNavigationRefreshesDOMTree() async throws {
        let controller = WIInspectorController()
        let webView = makeTestWebView()
        await loadHTML(
            """
            <!doctype html>
            <html>
            <body>
                <main id="page-a">
                    <h1>Alpha</h1>
                </main>
            </body>
            </html>
            """,
            in: webView
        )

        let requestedTabs: [WITab] = [.dom(), .network()]
        let container = WITabViewController(
            controller,
            webView: webView,
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
        await waitForControllerLifecycles(
            in: container,
            states: [(controller, .active)]
        )

        guard let compactHost = container.activeHostViewControllerForTesting as? WICompactTabHostViewController else {
            Issue.record("Expected compact host")
            return
        }
        guard let domViewController = compactHost.rootViewControllerForTesting(tabIdentifier: WITab.domTabID) as? WIDOMViewController else {
            Issue.record("Expected DOM root view controller")
            return
        }

        let domFrontendReady = await waitForCondition(attempts: 120) {
            guard controller.lifecycle == .active else {
                return false
            }
            guard controller.dom.currentContextIDForDiagnostics() != nil else {
                return false
            }
            return await domViewController.compactTreeViewControllerForTesting.frontendIsReadyForTesting()
        }
        #expect(domFrontendReady)

        let initialContextID = controller.dom.currentContextIDForDiagnostics()
        controller.dom.resetFrontendHydrationDiagnosticsForTesting()

        await loadHTML(
            """
            <!doctype html>
            <html>
            <body>
                <section id="page-b">
                    <h2>Beta</h2>
                </section>
            </body>
            </html>
            """,
            in: webView
        )

        let navigationUpdatedTree = await waitForCondition(attempts: 180) {
            guard let currentContextID = controller.dom.currentContextIDForDiagnostics(),
                  currentContextID != initialContextID
            else {
                return false
            }

            let frontendIsReady = await domViewController.compactTreeViewControllerForTesting.frontendIsReadyForTesting()
            let frontendHydrated = controller.dom.frontendHydrationDiagnosticsForTesting.contains {
                switch $0 {
                case let .hydrated(reason, eventContextID, _, _),
                     let .skippedDuplicateReady(reason, eventContextID, _, _):
                    return eventContextID == currentContextID
                        && (reason == "transport.refreshCurrentDocument" || reason == "ready.currentContext")
                }
            }
            return frontendIsReady && frontendHydrated
        }
        #expect(navigationUpdatedTree)
    }

    @Test
    func compactActualWebViewNavigationAllowsPostNavigationSelection() async throws {
        let controller = WIInspectorController()
        let webView = makeTestWebView()
        await loadHTML(
            """
            <!doctype html>
            <html>
            <body>
                <main id="page-a">
                    <h1>Alpha</h1>
                </main>
            </body>
            </html>
            """,
            in: webView
        )

        let requestedTabs: [WITab] = [.dom(), .network()]
        let container = WITabViewController(
            controller,
            webView: webView,
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
        await waitForControllerLifecycles(
            in: container,
            states: [(controller, .active)]
        )

        guard let compactHost = container.activeHostViewControllerForTesting as? WICompactTabHostViewController else {
            Issue.record("Expected compact host")
            return
        }
        guard let domViewController = compactHost.rootViewControllerForTesting(tabIdentifier: WITab.domTabID) as? WIDOMViewController else {
            Issue.record("Expected DOM root view controller")
            return
        }
        guard let elementViewController = compactHost.rootViewControllerForTesting(tabIdentifier: WITab.elementTabID) as? WIDOMDetailViewController else {
            Issue.record("Expected Element detail view controller")
            return
        }

        let initialDOMReady = await waitForCondition(attempts: 120) {
            guard controller.lifecycle == .active else {
                return false
            }
            guard controller.dom.currentContextIDForDiagnostics() != nil else {
                return false
            }
            return await domViewController.compactTreeViewControllerForTesting.frontendIsReadyForTesting()
        }
        #expect(initialDOMReady)
        guard initialDOMReady else {
            return
        }

        let initialContextID = controller.dom.currentContextIDForDiagnostics()
        controller.dom.resetFrontendHydrationDiagnosticsForTesting()
        await loadHTML(
            """
            <!doctype html>
            <html>
            <head>
                <style>
                    html, body { margin: 0; padding: 0; }
                    section {
                        display: block;
                        width: 220px;
                        height: 140px;
                        margin-top: 8px;
                    }
                </style>
            </head>
            <body>
                <section id="page-b" class="updated" data-role="hero">
                    <h2>Beta</h2>
                </section>
            </body>
            </html>
            """,
            in: webView
        )

        let navigationReady = await waitForCondition(attempts: 180) {
            guard let currentContextID = controller.dom.currentContextIDForDiagnostics(),
                  currentContextID != initialContextID
            else {
                return false
            }

            let frontendIsReady = await domViewController.compactTreeViewControllerForTesting.frontendIsReadyForTesting()
            let frontendHydrated = controller.dom.frontendHydrationDiagnosticsForTesting.contains {
                switch $0 {
                case let .hydrated(reason, eventContextID, _, _),
                     let .skippedDuplicateReady(reason, eventContextID, _, _):
                    return eventContextID == currentContextID
                        && (reason == "transport.refreshCurrentDocument" || reason == "ready.currentContext")
                }
            }
            return frontendIsReady && frontendHydrated
        }
        #expect(navigationReady)
        guard navigationReady else {
            return
        }

        let selectedNodeID = try await selectNodeAndWaitForCompactProjection(
            cssSelector: "#page-b",
            expectedAttributes: [
                "id": "page-b",
                "class": "updated",
                "data-role": "hero",
            ],
            in: controller,
            domViewController: domViewController,
            elementViewController: elementViewController,
            requiresTreeSelection: true
        )

        #expect(controller.dom.document.selectedNode?.id == selectedNodeID)
        #expect(controller.dom.isSelectingElement == false)
    }

    @Test
    func compactSameOriginIFrameSelectionProjectsIntoTreeAndDetail() async throws {
        let controller = WIInspectorController()
        let webView = makeTestWebView()
        await loadHTML(
            """
            <!doctype html>
            <html>
            <body>
                <iframe
                    id="frame-owner"
                    srcdoc="<!doctype html><html><body><button id='frame-target' data-role='nested'>Frame</button></body></html>">
                </iframe>
            </body>
            </html>
            """,
            in: webView
        )

        let requestedTabs: [WITab] = [.dom(), .network()]
        let container = WITabViewController(
            controller,
            webView: webView,
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
        await waitForControllerLifecycles(
            in: container,
            states: [(controller, .active)]
        )

        guard let compactHost = container.activeHostViewControllerForTesting as? WICompactTabHostViewController else {
            Issue.record("Expected compact host")
            return
        }
        guard let domViewController = compactHost.rootViewControllerForTesting(tabIdentifier: WITab.domTabID) as? WIDOMViewController else {
            Issue.record("Expected DOM root view controller")
            return
        }
        guard let elementViewController = compactHost.rootViewControllerForTesting(tabIdentifier: WITab.elementTabID) as? WIDOMDetailViewController else {
            Issue.record("Expected Element detail view controller")
            return
        }

        let iframeContentReady = await waitForPageCondition(
            "document.getElementById('frame-owner')?.contentDocument?.getElementById('frame-target')",
            in: webView,
            attempts: 600
        )
        #expect(iframeContentReady)
        guard iframeContentReady else {
            return
        }

        let selectedNodeID = try await selectNodeAndWaitForCompactProjection(
            cssSelector: "#frame-target",
            expectedAttributes: [
                "id": "frame-target",
                "data-role": "nested",
            ],
            in: controller,
            domViewController: domViewController,
            elementViewController: elementViewController,
            requiresTreeSelection: true
        )

        let treeReady = await waitForCondition(attempts: 600) {
            let treeText = await domViewController.compactTreeViewControllerForTesting.treeTextContentForTesting() ?? ""
            return treeText.contains("#document")
                && treeText.contains("iframe")
                && treeText.contains("frame-target")
        }
        #expect(treeReady)

        let treeText = await domViewController.compactTreeViewControllerForTesting.treeTextContentForTesting() ?? ""
        #expect(treeText.contains("#document"))
        #expect(treeText.contains("iframe"))
        #expect(treeText.contains("frame-target"))
        #expect(controller.dom.document.selectedNode?.id == selectedNodeID)
    }

    @Test
    func compactDelayedIFrameInsertionProjectsIntoTreeAndDetail() async throws {
        let controller = WIInspectorController()
        let webView = makeTestWebView()
        await loadHTML(
            """
            <!doctype html>
            <html>
            <body>
                <main id="page">
                    <div class="gw-shell">
                        <ul id="generic-list">
                            <li>one</li>
                            <li>two</li>
                            <li>three</li>
                        </ul>
                        <div id="delayed-slot"></div>
                    </div>
                </main>
                <script>
                    setTimeout(() => {
                        const slot = document.getElementById("delayed-slot");
                        slot.innerHTML = `
                            <div class="ad-container">
                                <iframe
                                    id="delayed-frame-owner"
                                    title="delayed-frame"
                                    srcdoc="<!doctype html><html><body><button id='delayed-frame-target' data-role='nested-delayed'>Late Frame</button></body></html>">
                                </iframe>
                            </div>
                        `;
                    }, 150);
                </script>
            </body>
            </html>
            """,
            in: webView
        )

        let requestedTabs: [WITab] = [.dom(), .network()]
        let container = WITabViewController(
            controller,
            webView: webView,
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
        await waitForControllerLifecycles(
            in: container,
            states: [(controller, .active)]
        )

        guard let compactHost = container.activeHostViewControllerForTesting as? WICompactTabHostViewController else {
            Issue.record("Expected compact host")
            return
        }
        guard let domViewController = compactHost.rootViewControllerForTesting(tabIdentifier: WITab.domTabID) as? WIDOMViewController else {
            Issue.record("Expected DOM root view controller")
            return
        }
        guard let elementViewController = compactHost.rootViewControllerForTesting(tabIdentifier: WITab.elementTabID) as? WIDOMDetailViewController else {
            Issue.record("Expected Element detail view controller")
            return
        }

        let iframeContentReady = await waitForPageCondition(
            "document.getElementById('delayed-frame-owner')?.contentDocument?.getElementById('delayed-frame-target')",
            in: webView,
            attempts: 600
        )
        #expect(iframeContentReady)
        guard iframeContentReady else {
            return
        }

        let selectedNodeID = try await selectNodeAndWaitForCompactProjection(
            cssSelector: "#delayed-frame-target",
            expectedAttributes: [
                "id": "delayed-frame-target",
                "data-role": "nested-delayed",
            ],
            in: controller,
            domViewController: domViewController,
            elementViewController: elementViewController,
            requiresTreeSelection: true
        )

        let treeReady = await waitForCondition(attempts: 600) {
            let treeText = await domViewController.compactTreeViewControllerForTesting.treeTextContentForTesting() ?? ""
            return treeText.contains("#document")
                && treeText.contains("iframe")
                && treeText.contains("delayed-frame-target")
        }
        #expect(treeReady)

        let treeText = await domViewController.compactTreeViewControllerForTesting.treeTextContentForTesting() ?? ""
        #expect(treeText.contains("#document"))
        #expect(treeText.contains("iframe"))
        #expect(treeText.contains("delayed-frame-target"))
        #expect(controller.dom.document.selectedNode?.id == selectedNodeID)
    }

    @Test
    func compactDelayedAdLikeIFrameOwnerSelectionProjectsIntoTreeAndDetail() async throws {
        let controller = WIInspectorController()
        let webView = makeTestWebView()
        await loadHTML(
            """
            <!doctype html>
            <html>
            <body>
                <section id="page">
                    <div id="ad-slot"></div>
                </section>
                <script>
                    setTimeout(() => {
                        const slot = document.getElementById("ad-slot");
                        const iframe = document.createElement("iframe");
                        iframe.id = "delayed-ad-frame";
                        iframe.title = "ad-frame";
                        iframe.loading = "lazy";
                        iframe.src = "about:blank";
                        slot.appendChild(iframe);
                    }, 120);
                </script>
            </body>
            </html>
            """,
            in: webView
        )

        let requestedTabs: [WITab] = [.dom(), .network()]
        let container = WITabViewController(
            controller,
            webView: webView,
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
        await waitForControllerLifecycles(
            in: container,
            states: [(controller, .active)]
        )

        guard let compactHost = container.activeHostViewControllerForTesting as? WICompactTabHostViewController else {
            Issue.record("Expected compact host")
            return
        }
        guard let domViewController = compactHost.rootViewControllerForTesting(tabIdentifier: WITab.domTabID) as? WIDOMViewController else {
            Issue.record("Expected DOM root view controller")
            return
        }
        guard let elementViewController = compactHost.rootViewControllerForTesting(tabIdentifier: WITab.elementTabID) as? WIDOMDetailViewController else {
            Issue.record("Expected Element detail view controller")
            return
        }

        let iframeReady = await waitForPageCondition(
            "document.getElementById('delayed-ad-frame')",
            in: webView,
            attempts: 600
        )
        #expect(iframeReady)
        guard iframeReady else {
            return
        }

        let selectedNodeID = try await selectNodeAndWaitForCompactProjection(
            cssSelector: "#delayed-ad-frame",
            expectedAttributes: [
                "id": "delayed-ad-frame",
                "loading": "lazy",
                "src": "about:blank",
                "title": "ad-frame",
            ],
            in: controller,
            domViewController: domViewController,
            elementViewController: elementViewController,
            requiresTreeSelection: true
        )

        let treeReady = await waitForCondition(attempts: 600) {
            let treeText = await domViewController.compactTreeViewControllerForTesting.treeTextContentForTesting() ?? ""
            return treeText.contains("iframe")
                && treeText.contains("delayed-ad-frame")
        }
        #expect(treeReady)

        let treeText = await domViewController.compactTreeViewControllerForTesting.treeTextContentForTesting() ?? ""
        #expect(treeText.contains("iframe"))
        #expect(treeText.contains("delayed-ad-frame"))
        #expect(controller.dom.document.selectedNode?.id == selectedNodeID)
        #expect(elementViewController.renderedSelectorTextForTesting() == "#delayed-ad-frame")
    }

    @Test
    func sameWebViewHandoffKeepsSelectedNodeUntilContainerCloses() async throws {
        let controller = WIInspectorController()
        let webView = makeTestWebView()
        await loadHTML(
            """
            <!doctype html>
            <html>
            <body>
                <div id="first">First</div>
                <section id="secondary" class="updated" data-role="hero">Second</section>
            </body>
            </html>
            """,
            in: webView
        )

        let requestedTabs: [WITab] = [.dom(), .network()]
        controller.setTabs(requestedTabs)
        await controller.applyHostState(pageWebView: webView, visibility: .visible)
        await controller.waitForRuntimeApplyForTesting()

        var container: WITabViewController? = WITabViewController(
            controller,
            webView: webView,
            tabs: requestedTabs
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            container = nil
        }

        container?.loadViewIfNeeded()
        drainMainQueue()
        container?.horizontalSizeClassOverrideForTesting = .compact
        container?.setTabs(requestedTabs)
        drainMainQueue()
        if let container {
            await waitForControllerLifecycles(
                in: container,
                states: [(controller, .active)]
            )
        }

        let detailControllersReady = await waitForCondition(attempts: 200) {
            guard let hostedContainer = container,
                  let compactHost = hostedContainer.activeHostViewControllerForTesting as? WICompactTabHostViewController
            else {
                return false
            }
            return compactHost.rootViewControllerForTesting(tabIdentifier: WITab.domTabID) is WIDOMViewController
                && compactHost.rootViewControllerForTesting(tabIdentifier: WITab.elementTabID) is WIDOMDetailViewController
        }
        #expect(detailControllersReady)
        guard detailControllersReady else {
            return
        }

        guard let hostedContainer = container else {
            Issue.record("Expected container")
            return
        }
        guard let compactHost = hostedContainer.activeHostViewControllerForTesting as? WICompactTabHostViewController else {
            Issue.record("Expected compact host")
            return
        }
        guard let domViewController = compactHost.rootViewControllerForTesting(tabIdentifier: WITab.domTabID) as? WIDOMViewController else {
            Issue.record("Expected DOM root view controller")
            return
        }
        guard let elementViewController = compactHost.rootViewControllerForTesting(tabIdentifier: WITab.elementTabID) as? WIDOMDetailViewController else {
            Issue.record("Expected Element detail view controller")
            return
        }

        let selectedNodeID = try await selectNodeAndWaitForCompactProjection(
            cssSelector: "#secondary",
            expectedAttributes: [
                "id": "secondary",
                "class": "updated",
                "data-role": "hero"
            ],
            in: controller,
            domViewController: domViewController,
            elementViewController: elementViewController,
            requiresTreeSelection: true
        )

        controller.dom.resetFreshContextDiagnosticsForTesting()
        await controller.applyHostState(pageWebView: webView, visibility: .hidden)
        await controller.waitForRuntimeApplyForTesting()

        #expect(controller.lifecycle == .active)
        #expect(controller.dom.document.selectedNode?.id == selectedNodeID)
        #expect(controller.dom.freshContextDiagnosticsForTesting.isEmpty)

        let treeSelectionStillVisible = await waitForCondition {
            let selectedNodeLocalID = await domViewController.compactTreeViewControllerForTesting.selectedNodeIDForTesting()
            return selectedNodeLocalID == Int(selectedNodeID.localID)
        }
        #expect(treeSelectionStillVisible)
        #expect(elementViewController.renderedSelectorTextForTesting() == "#secondary")
        #expect(elementViewController.renderedAttributeValueForTesting(nodeID: selectedNodeID, name: "class") == "updated")

        window.isHidden = true
        window.rootViewController = nil
        container = nil
        await controller.waitForRuntimeApplyForTesting()

        #expect(controller.lifecycle == .suspended)
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

    private func loadHTML(_ html: String, in webView: WKWebView) async {
        let navigationDelegate = NavigationDelegate()
        webView.navigationDelegate = navigationDelegate

        await withCheckedContinuation { continuation in
            navigationDelegate.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func waitForPageCondition(
        _ expression: String,
        in webView: WKWebView,
        attempts: Int = 120
    ) async -> Bool {
        await waitForCondition(attempts: attempts) {
            do {
                let result = try await webView.callAsyncJavaScript(
                    "return Boolean(\(expression));",
                    arguments: [:],
                    in: nil,
                    contentWorld: .page
                ) as? Bool
                return result == true
            } catch {
                return false
            }
        }
    }

    private func makeDOMInspectorWithSelection() -> WIDOMInspector {
        let controller = WIInspectorController()
        let inspector = controller.dom
        let selectedLocalID: UInt64 = 42
        let attributes = [DOMAttribute(nodeId: Int(selectedLocalID), name: "id", value: "selected")]

        inspector.document.replaceDocument(
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
        inspector.document.applySelectionSnapshot(
            .init(
                localID: selectedLocalID,
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

    private func waitForCondition(
        attempts: Int = 50,
        intervalNanoseconds: UInt64 = 10_000_000,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return await condition()
    }

    private func selectNodeAndWaitForCompactProjection(
        cssSelector: String,
        expectedAttributes: [String: String],
        in controller: WIInspectorController,
        domViewController: WIDOMViewController,
        elementViewController: WIDOMDetailViewController,
        requiresTreeSelection: Bool
    ) async throws -> DOMNodeModel.ID {
        let runtimeReady = await waitForCondition {
            guard controller.lifecycle == .active else {
                return false
            }
            guard controller.dom.currentContextIDForDiagnostics() != nil else {
                return false
            }
            return await domViewController.compactTreeViewControllerForTesting.frontendIsReadyForTesting()
        }
        #expect(runtimeReady)

        try await controller.dom.selectNodeForTesting(cssSelector: cssSelector)

        let selectedNodeReady = await waitForCondition(attempts: 120) {
            controller.dom.document.selectedNode?.selectorPath == cssSelector
        }
        #expect(selectedNodeReady)

        let selectedNodeID = try #require(controller.dom.document.selectedNode?.id)
        if requiresTreeSelection {
            var treeSelectionReady = await waitForCondition(attempts: 600) {
                let selectedNodeLocalID = await domViewController.compactTreeViewControllerForTesting.selectedNodeIDForTesting()
                return selectedNodeLocalID == Int(selectedNodeID.localID)
            }
            if !treeSelectionReady {
                try await controller.dom.selectNodeForTesting(cssSelector: cssSelector)
                treeSelectionReady = await waitForCondition(attempts: 600) {
                    let selectedNodeLocalID = await domViewController.compactTreeViewControllerForTesting.selectedNodeIDForTesting()
                    return selectedNodeLocalID == Int(selectedNodeID.localID)
                }
            }
            #expect(treeSelectionReady)
        }

        let detailReady = await waitForCondition(attempts: 120) {
            elementViewController.renderedSelectorTextForTesting() == cssSelector
                && Set(elementViewController.renderedAttributeNamesForTesting()) == Set(expectedAttributes.keys)
        }
        #expect(detailReady)

        for (name, value) in expectedAttributes {
            #expect(elementViewController.renderedAttributeValueForTesting(nodeID: selectedNodeID, name: name) == value)
        }

        return selectedNodeID
    }
}
#endif

private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Never>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume()
        continuation = nil
    }
}
