import Testing
import WebKit
@testable import WebInspectorUI
@testable import WebInspectorRuntime
@testable import WebInspectorEngine

#if canImport(AppKit)
import AppKit

@MainActor
struct TabViewControllerAppKitTabTests {
    private let tabPickerIdentifierRaw = "WIContainerToolbar.TabPicker"
    private let domPickIdentifierRaw = "WIContainerToolbar.DOMPick"
    private let domReloadIdentifierRaw = "WIContainerToolbar.DOMReload"
    private let networkFilterIdentifierRaw = "WIContainerToolbar.NetworkFilter"
    private let networkClearIdentifierRaw = "WIContainerToolbar.NetworkClear"
    private let networkSearchIdentifierRaw = "WIContainerToolbar.NetworkSearch"

    @Test
    func loadViewIfNeededRendersInitialContentAndSelection() {
        let controller = WIInspectorController()
        let descriptors = [
            makeDescriptor(id: "tab_a", title: "A"),
            makeDescriptor(id: "tab_b", title: "B")
        ]
        let container = WITabViewController(controller, webView: nil, tabs: descriptors)

        container.loadViewIfNeeded()

        #expect(container.displayedTabIDsForTesting == ["tab_a", "tab_b"])
        #expect(container.selectedTabIdentifierForTesting == "tab_a")
        #expect(container.visibleContentTabIDForTesting == "tab_a")
        #expect(container.hasVisibleContentForTesting == true)
    }

    @Test
    func appKitNormalizesStandaloneElementTabToDOM() {
        let controller = WIInspectorController()
        let descriptors = [
            makeDescriptor(id: WITab.elementTabID, title: "Element")
        ]
        let container = WITabViewController(controller, webView: nil, tabs: descriptors)

        container.loadViewIfNeeded()

        #expect(container.displayedTabIDsForTesting == [WITab.domTabID])
        #expect(container.selectedTabIdentifierForTesting == WITab.domTabID)
        #expect(container.visibleContentTabIDForTesting == WITab.domTabID)
        #expect(container.visibleContentViewControllerForTesting is WIDOMViewController)
        #expect(controller.tabs.map(\.identifier) == [WITab.elementTabID])
        #expect(controller.selectedTab?.identifier == WITab.elementTabID)
    }

    @Test
    func appKitKeepsSyntheticDOMFallbackWhenElementAndNetworkAreConfiguredWithoutDOM() {
        let controller = WIInspectorController()
        let descriptors = [
            makeDescriptor(id: WITab.elementTabID, title: "Element"),
            makeDescriptor(id: WITab.networkTabID, title: "Network")
        ]
        let container = WITabViewController(controller, webView: nil, tabs: descriptors)

        container.loadViewIfNeeded()

        #expect(container.displayedTabIDsForTesting == [WITab.domTabID, WITab.networkTabID])
        #expect(container.selectedTabIdentifierForTesting == WITab.domTabID)
        #expect(controller.tabs.map(\.identifier) == [WITab.elementTabID, WITab.networkTabID])
    }

    @Test
    func standaloneElementProxyKeepsDOMAutoSnapshotEnabled() async {
        let controller = WIInspectorController()
        let descriptors = [
            makeDescriptor(id: WITab.elementTabID, title: "Element")
        ]
        let container = WITabViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        await container.waitForRuntimeStateSyncForTesting()

        #expect(container.displayedTabIDsForTesting == [WITab.domTabID])
        #expect(controller.selectedTab?.identifier == WITab.elementTabID)
        #expect(controller.dom.session.isAutoSnapshotEnabled == true)
    }

    @Test
    func appKitRemovesElementWhenDOMTabExists() {
        let controller = WIInspectorController()
        let descriptors = [
            makeDescriptor(id: WITab.domTabID, title: "DOM"),
            makeDescriptor(id: WITab.elementTabID, title: "Element"),
            makeDescriptor(id: WITab.networkTabID, title: "Network")
        ]
        let container = WITabViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        #expect(container.displayedTabIDsForTesting == [WITab.domTabID, WITab.networkTabID])
        #expect(container.selectedTabIdentifierForTesting == WITab.domTabID)
        #expect(controller.tabs.map(\.identifier) == [WITab.domTabID, WITab.elementTabID, WITab.networkTabID])

        selectTabViaPicker(index: 1, in: window)
        #expect(container.selectedTabIdentifierForTesting == WITab.networkTabID)
        #expect(container.visibleContentTabIDForTesting == WITab.networkTabID)
        #expect(container.visibleContentViewControllerForTesting is WINetworkViewController)
    }

    @Test
    func appKitHiddenElementSelectionNormalizesToDOMWhenDOMExists() {
        let controller = WIInspectorController()
        let dom = makeDescriptor(id: WITab.domTabID, title: "DOM")
        let element = makeDescriptor(id: WITab.elementTabID, title: "Element")
        let network = makeDescriptor(id: WITab.networkTabID, title: "Network")
        let container = WITabViewController(controller, webView: nil, tabs: [dom, element, network])

        controller.setSelectedTab(element)
        #expect(controller.selectedTab?.identifier == WITab.elementTabID)

        container.loadViewIfNeeded()

        #expect(container.displayedTabIDsForTesting == [WITab.domTabID, WITab.networkTabID])
        #expect(container.selectedTabIdentifierForTesting == WITab.domTabID)
        #expect(controller.selectedTab?.identifier == WITab.domTabID)
    }

    @Test
    func toolbarContainsTabPickerAndUsesDescriptorTitles() {
        let controller = WIInspectorController()
        let descriptors = [
            makeDescriptor(id: "tab_a", title: "A"),
            makeDescriptor(id: "tab_b", title: "B")
        ]
        let container = WITabViewController(controller, webView: nil, tabs: descriptors)
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        let identifiers = toolbarIdentifierRawValues(in: window)
        #expect(identifiers == [tabPickerIdentifierRaw])
        #expect(tabPickerToolbarItem(in: window)?.isNavigational == true)

        guard let picker = tabPicker(in: window) else {
            Issue.record("Expected toolbar tab picker")
            return
        }

        let labels = (0..<picker.segmentCount).map { picker.label(forSegment: $0) }
        #expect(labels == ["A", "B"])
        #expect(container.visibleContentTabIDForTesting == "tab_a")
    }

    @Test
    func appKitDOMPickToolbarReflectsSelectionStateImmediately() async {
        let controller = WIInspectorController()
        let webView = makeTestWebView()
        let descriptors = [
            makeDescriptor(id: WITab.domTabID, title: "DOM"),
            makeDescriptor(id: WITab.networkTabID, title: "Network")
        ]
        let container = WITabViewController(controller, webView: webView, tabs: descriptors)
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        await container.waitForRuntimeStateSyncForTesting()
        await loadHTML("<html><body><div id=\"target\">Target</div></body></html>", in: webView)

        guard domPickToolbarItem(in: window) != nil else {
            Issue.record("Expected DOM pick toolbar item")
            return
        }

        #expect(waitUntil {
            domPickToolbarItem(in: window)?.isEnabled == true
        })

        guard
            let pickItem = domPickToolbarItem(in: window),
            let action = pickItem.action,
            let target = pickItem.target as? NSObject
        else {
            Issue.record("Expected DOM pick toolbar action")
            return
        }
        _ = unsafe target.perform(action, with: pickItem)

        #expect(controller.dom.isSelectingElement)
        #expect(domPickToolbarItem(in: window)?.isEnabled == true)

        _ = unsafe target.perform(action, with: pickItem)
        #expect(controller.dom.isSelectingElement == false)

        #expect(waitUntil {
            domPickToolbarItem(in: window)?.isEnabled == true
        })
    }

    @Test
    func pickerSelectionUpdatesVisibleContentAndModelSelectionWhenConnected() {
        let controller = WIInspectorController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WITabViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        selectTabViaPicker(index: 1, in: window)

        #expect(container.selectedTabIdentifierForTesting == "wi_network")
        #expect(container.visibleContentTabIDForTesting == "wi_network")
        #expect(controller.selectedTab?.id == "wi_network")
    }

    @Test
    func pickerCanSwitchBackFromNetworkToDOM() {
        let controller = WIInspectorController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WITabViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        selectTabViaPicker(index: 1, in: window)
        #expect(container.selectedTabIdentifierForTesting == "wi_network")
        #expect(container.visibleContentTabIDForTesting == "wi_network")

        selectTabViaPicker(index: 0, in: window)
        #expect(container.selectedTabIdentifierForTesting == "wi_dom")
        #expect(container.visibleContentTabIDForTesting == "wi_dom")

        drainMainQueue()
        #expect(controller.selectedTab?.id == "wi_dom")
        #expect(container.hasVisibleContentForTesting == true)
    }

    @Test
    func rebuildingTabsKeepsVisibleContentBoundToSelectedTab() {
        let controller = WIInspectorController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WITabViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        #expect(container.visibleContentTabIDForTesting == "wi_dom")

        controller.setTabs([
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ])
        drainMainQueue()

        #expect(container.selectedTabIdentifierForTesting == "wi_dom")
        #expect(container.visibleContentTabIDForTesting == "wi_dom")
        #expect(container.hasVisibleContentForTesting == true)
    }

    @Test
    func emptyTabsClearSelectionAndHideVisibleContent() {
        let controller = WIInspectorController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WITabViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        container.setTabs([])
        drainMainQueue()

        #expect(controller.selectedTab == nil)
        #expect(container.selectedTabIdentifierForTesting == nil)
        #expect(container.visibleContentTabIDForTesting == nil)
        #expect(container.hasVisibleContentForTesting == false)
    }

    @Test
    func toolbarLayoutTracksSelectedTab() {
        let controller = WIInspectorController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WITabViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        #expect(toolbarIdentifierRawValues(in: window) == [
            tabPickerIdentifierRaw,
            NSToolbarItem.Identifier.flexibleSpace.rawValue,
            domPickIdentifierRaw,
            domReloadIdentifierRaw
        ])

        selectTabViaPicker(index: 1, in: window)
        #expect(controller.selectedTab?.id == "wi_network")
        drainMainQueue()

        #expect(toolbarIdentifierRawValues(in: window) == [
            tabPickerIdentifierRaw,
            networkFilterIdentifierRaw,
            networkClearIdentifierRaw,
            networkSearchIdentifierRaw,
            NSToolbarItem.Identifier.flexibleSpace.rawValue
        ])
    }

    @Test
    func networkSearchToolbarFieldUpdatesSearchText() {
        let controller = WIInspectorController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WITabViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        selectTabViaPicker(index: 1, in: window)
        #expect(controller.selectedTab?.id == "wi_network")
        guard
            let searchItem = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == networkSearchIdentifierRaw }) as? NSSearchToolbarItem,
            let action = searchItem.searchField.action
        else {
            Issue.record("Expected network search toolbar item")
            return
        }

        searchItem.searchField.stringValue = "fetch target"
        searchItem.searchField.sendAction(action, to: searchItem.searchField.target)

        #expect(controller.network.searchText == "fetch target")
    }

    @Test
    func networkFilterToolbarItemBecomesProminentWhenFiltering() {
        let controller = WIInspectorController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WITabViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        selectTabViaPicker(index: 1, in: window)
        drainMainQueue()

        guard let filterItem = networkFilterToolbarItem(in: window) else {
            Issue.record("Expected network filter toolbar item")
            return
        }

        if #available(macOS 26.0, *) {
            #expect(filterItem.style == .plain)
        }

        guard
            let scriptItem = filterItem.menu.items.first(where: { ($0.representedObject as? String) == NetworkResourceFilter.script.rawValue }),
            let action = scriptItem.action,
            let target = scriptItem.target
        else {
            Issue.record("Expected script filter menu item")
            return
        }

        #expect(NSApp.sendAction(action, to: target, from: scriptItem))
        drainMainQueue()

        #expect(controller.network.activeResourceFilters.contains(.script))
        if #available(macOS 26.0, *) {
            #expect(filterItem.style == .prominent)
        }

        guard
            let allItem = filterItem.menu.items.first(where: { ($0.representedObject as? String) == NetworkResourceFilter.all.rawValue }),
            let allAction = allItem.action,
            let allTarget = allItem.target
        else {
            Issue.record("Expected all filter menu item")
            return
        }

        #expect(NSApp.sendAction(allAction, to: allTarget, from: allItem))
        drainMainQueue()

        #expect(controller.network.effectiveResourceFilters.isEmpty)
        if #available(macOS 26.0, *) {
            #expect(filterItem.style == .plain)
        }
    }

    @Test
    func replacingDescriptorWithSameIdentifierRebuildsCachedContentController() {
        let controller = WIInspectorController()
        let firstController = MarkerViewController(marker: "first")
        let secondController = MarkerViewController(marker: "second")

        let firstDescriptor = WITab(
            id: "custom",
            title: "Custom",
            systemImage: "circle",
            viewControllerProvider: { _ in firstController }
        )
        let container = WITabViewController(controller, webView: nil, tabs: [firstDescriptor])
        container.loadViewIfNeeded()

        let initialVisible = try? #require(container.visibleContentViewControllerForTesting as? MarkerViewController)
        #expect(initialVisible?.marker == "first")

        let replacedDescriptor = WITab(
            id: "custom",
            title: "Custom",
            systemImage: "circle",
            viewControllerProvider: { _ in secondController }
        )
        container.setTabs([replacedDescriptor])
        drainMainQueue()

        let replacedVisible = try? #require(container.visibleContentViewControllerForTesting as? MarkerViewController)
        #expect(replacedVisible?.marker == "second")
    }

    @Test
    func setInspectorControllerClearsContentControllerCacheAcrossImmediateRender() {
        var createdCount = 0
        let requestedTabs = [
            WITab(
                id: "custom",
                title: "Custom",
                systemImage: "circle",
                viewControllerProvider: { _ in
                    createdCount += 1
                    return MarkerViewController(marker: "\(createdCount)")
                }
            )
        ]
        let firstController = WIInspectorController()
        let secondController = WIInspectorController()
        let container = WITabViewController(firstController, webView: nil, tabs: requestedTabs)

        container.loadViewIfNeeded()
        #expect(createdCount == 1)

        container.setInspectorController(secondController)
        container.setTabs(requestedTabs)

        #expect(createdCount == 2)
    }

    @Test
    func setInspectorControllerPreservesLatestSelectionDuringAsyncSwap() async {
        let firstController = WIInspectorController()
        let secondController = WIInspectorController()
        let container = WITabViewController(
            firstController,
            webView: makeTestWebView(),
            tabs: [
                makeDescriptor(id: "wi_dom", title: "DOM"),
                makeDescriptor(id: "wi_network", title: "Network")
            ]
        )
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        container.setPageWebView(makeTestWebView())
        guard let networkTab = firstController.tabs.first(where: { $0.identifier == WITab.networkTabID }) else {
            Issue.record("Expected network tab")
            return
        }
        firstController.setSelectedTab(networkTab)
        container.setInspectorController(secondController)

        await container.waitForRuntimeStateSyncForTesting()

        #expect(secondController.selectedTab?.identifier == WITab.networkTabID)
        #expect(firstController.lifecycle == .disconnected)
    }

    @Test
    func setInspectorControllerReplaysPageWebViewUpdateThatArrivesDuringSwap() async {
        let firstController = WIInspectorController()
        let secondController = WIInspectorController()
        let container = WITabViewController(
            firstController,
            webView: nil,
            tabs: [
                makeDescriptor(id: WITab.domTabID, title: "DOM"),
                makeDescriptor(id: WITab.networkTabID, title: "Network")
            ]
        )
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

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
    func transientDisappearWhileWindowIsStillAttachedKeepsRuntimeActive() async {
        let controller = WIInspectorController()
        let container = WITabViewController(
            controller,
            webView: makeTestWebView(),
            tabs: [
                makeDescriptor(id: WITab.domTabID, title: "DOM"),
                makeDescriptor(id: WITab.networkTabID, title: "Network")
            ]
        )
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        await waitForControllerLifecycles(
            in: container,
            states: [(controller, .active)]
        )

        container.viewDidDisappear()
        await waitForControllerLifecycles(
            in: container,
            states: [(controller, .active)]
        )

        #expect(controller.lifecycle == .active)
    }

    @Test
    func consecutiveInspectorControllerSwapsKeepEarlierApplyTasksSequenced() async {
        let firstController = WIInspectorController()
        let secondController = WIInspectorController()
        let thirdController = WIInspectorController()
        let container = WITabViewController(
            firstController,
            webView: makeTestWebView(),
            tabs: [
                makeDescriptor(id: WITab.domTabID, title: "DOM"),
                makeDescriptor(id: WITab.networkTabID, title: "Network")
            ]
        )
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

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
            tabs: [
                makeDescriptor(id: WITab.domTabID, title: "DOM"),
                makeDescriptor(id: WITab.networkTabID, title: "Network")
            ]
        )
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        await waitForControllerLifecycles(
            in: container,
            states: [(controller, .active)]
        )

        container.setInspectorController(controller)
        await container.waitForRuntimeStateSyncForTesting()

        #expect(container.inspectorController === controller)
        #expect(controller.lifecycle == .active)
    }

    @Test
    func appKitProgrammaticSelectionReappliesRuntimeState() async {
        let controller = WIInspectorController()
        let container = WITabViewController(
            controller,
            webView: makeTestWebView(),
            tabs: [
                makeDescriptor(id: WITab.domTabID, title: "DOM"),
                makeDescriptor(id: WITab.networkTabID, title: "Network")
            ]
        )
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        await container.waitForRuntimeStateSyncForTesting()

        guard let networkTab = controller.tabs.first(where: { $0.identifier == WITab.networkTabID }) else {
            Issue.record("Expected network tab")
            return
        }

        controller.setSelectedTab(networkTab)
        await container.waitForRuntimeStateSyncForTesting()

        #expect(container.selectedTabIdentifierForTesting == WITab.networkTabID)
        #expect(controller.network.session.mode == .active)
    }

    @Test
    func duplicateIdentifierTabsUseDistinctCachedContentControllers() {
        let controller = WIInspectorController()
        let firstController = MarkerViewController(marker: "first")
        let secondController = MarkerViewController(marker: "second")
        let firstDescriptor = WITab(
            id: "custom",
            title: "First",
            systemImage: "circle",
            viewControllerProvider: { _ in firstController }
        )
        let secondDescriptor = WITab(
            id: "custom",
            title: "Second",
            systemImage: "circle",
            viewControllerProvider: { _ in secondController }
        )

        let container = WITabViewController(
            controller,
            webView: nil,
            tabs: [firstDescriptor, secondDescriptor]
        )
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        let initialVisible = try? #require(container.visibleContentViewControllerForTesting as? MarkerViewController)
        #expect(initialVisible?.marker == "first")
        #expect(tabPicker(in: window)?.selectedSegment == 0)

        selectTabViaPicker(index: 1, in: window)

        let switchedVisible = try? #require(container.visibleContentViewControllerForTesting as? MarkerViewController)
        #expect(switchedVisible?.marker == "second")
        #expect(initialVisible !== switchedVisible)
        #expect(controller.selectedTab === secondDescriptor)
        #expect(tabPicker(in: window)?.selectedSegment == 1)
    }

    @Test
    func appKitSplitViewsUseStableAutosaveNamesAcrossTabSwitches() {
        let controller = WIInspectorController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WITabViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        let domController = try? #require(container.visibleContentViewControllerForTesting as? WIDOMViewController)
        #expect(domController?.splitView.autosaveName == "WebInspectorKit.DOMSplitView")

        selectTabViaPicker(index: 1, in: window)
        let networkController = try? #require(container.visibleContentViewControllerForTesting as? WINetworkViewController)
        #expect(networkController?.splitView.autosaveName == "WebInspectorKit.NetworkSplitView")
    }

    private func makeDescriptor(id: String, title: String) -> WITab {
        WITab(
            id: id,
            title: title,
            systemImage: "circle"
        )
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func mountInWindow(_ container: WITabViewController) -> NSWindow {
        let window = NSWindow(contentViewController: container)
        container.loadViewIfNeeded()
        container.viewWillAppear()
        window.makeKeyAndOrderFront(nil)
        drainMainQueue()
        return window
    }

    private func tabPicker(in window: NSWindow) -> NSSegmentedControl? {
        waitForToolbarItemsIfNeeded(in: window)
        guard let toolbar = window.toolbar else {
            return nil
        }
        guard
            let item = toolbar.items.first(where: { $0.itemIdentifier.rawValue == tabPickerIdentifierRaw }),
            let picker = item.view as? NSSegmentedControl
        else {
            return nil
        }
        return picker
    }

    private func toolbarIdentifierRawValues(in window: NSWindow) -> [String] {
        waitForToolbarItemsIfNeeded(in: window)
        return window.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? []
    }

    private func tabPickerToolbarItem(in window: NSWindow) -> NSToolbarItem? {
        waitForToolbarItemsIfNeeded(in: window)
        return window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == tabPickerIdentifierRaw })
    }

    private func domPickToolbarItem(in window: NSWindow) -> NSToolbarItem? {
        waitForToolbarItemsIfNeeded(in: window)
        return window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == domPickIdentifierRaw })
    }

    private func networkFilterToolbarItem(in window: NSWindow) -> NSMenuToolbarItem? {
        waitForToolbarItemsIfNeeded(in: window)
        return window.toolbar?.items
            .first(where: { $0.itemIdentifier.rawValue == networkFilterIdentifierRaw }) as? NSMenuToolbarItem
    }

    private func waitForToolbarItemsIfNeeded(in window: NSWindow, cycles: Int = 5) {
        guard window.toolbar?.items.isEmpty != false else {
            return
        }
        for _ in 0..<cycles {
            drainMainQueue()
            if window.toolbar?.items.isEmpty == false {
                return
            }
        }
    }

    private func waitUntil(cycles: Int = 20, _ condition: () -> Bool) -> Bool {
        for _ in 0..<cycles {
            drainMainQueue()
            if condition() {
                return true
            }
        }
        return condition()
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    private func loadHTML(_ html: String, in webView: WKWebView) async {
        let navigationDelegate = NavigationDelegate()
        webView.navigationDelegate = navigationDelegate

        await withCheckedContinuation { continuation in
            navigationDelegate.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func selectTabViaPicker(index: Int, in window: NSWindow) {
        guard
            let picker = tabPicker(in: window),
            let action = picker.action
        else {
            Issue.record("Expected toolbar tab picker")
            return
        }
        picker.selectedSegment = index
        picker.sendAction(action, to: picker.target)
        drainMainQueue()
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

@MainActor
private final class MarkerViewController: NSViewController {
    let marker: String

    init(marker: String) {
        self.marker = marker
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }
}
#endif
