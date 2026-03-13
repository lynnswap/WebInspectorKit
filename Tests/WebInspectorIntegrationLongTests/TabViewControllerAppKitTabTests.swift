import Testing
import WebKit
import WebInspectorKit
import WebInspectorTestSupport
@testable import WebInspectorUI
@testable import WebInspectorCore
@testable import WebInspectorCore
@testable import WebInspectorCore
@testable import WebInspectorCore

#if canImport(AppKit)
import AppKit

@MainActor
@Suite(.serialized, .webKitIsolated)
struct TabViewControllerAppKitTabTests {
    private let tabPickerIdentifierRaw = "WIContainerToolbar.TabPicker"
    private let domPickIdentifierRaw = "WIContainerToolbar.DOMPick"
    private let domReloadIdentifierRaw = "WIContainerToolbar.DOMReload"
    private let networkFilterIdentifierRaw = "WIContainerToolbar.NetworkFilter"
    private let networkClearIdentifierRaw = "WIContainerToolbar.NetworkClear"
    private let networkSearchIdentifierRaw = "WIContainerToolbar.NetworkSearch"

    @Test
    func loadViewIfNeededRendersInitialContentAndSelection() {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "tab_a", title: "A"),
            makeDescriptor(id: "tab_b", title: "B")
        ]
        let container = WIContainerViewController(controller, webView: nil, tabs: descriptors)

        container.loadViewIfNeeded()

        #expect(container.displayedTabIDsForTesting == ["tab_a", "tab_b"])
        #expect(container.selectedTabIdentifierForTesting == "tab_a")
        #expect(container.visibleContentTabIDForTesting == "tab_a")
        #expect(container.hasVisibleContentForTesting == true)
    }

    @Test
    func appKitNormalizesStandaloneElementTabToDOM() {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: WITab.elementTabID, title: "Element")
        ]
        let container = WIContainerViewController(controller, webView: nil, tabs: descriptors)

        container.loadViewIfNeeded()

        #expect(container.displayedTabIDsForTesting == [WITab.domTabID])
        #expect(container.selectedTabIdentifierForTesting == WITab.domTabID)
        #expect(container.visibleContentTabIDForTesting == WITab.domTabID)
        #expect(container.visibleContentViewControllerForTesting is WIDOMViewController)
        #expect(controller.panelConfigurations.map(\.identifier) == [WITab.elementTabID])
        #expect(controller.selectedPanelConfiguration?.identifier == WITab.elementTabID)
    }

    @Test
    func appKitKeepsSyntheticDOMFallbackWhenElementAndNetworkAreConfiguredWithoutDOM() {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: WITab.elementTabID, title: "Element"),
            makeDescriptor(id: WITab.networkTabID, title: "Network")
        ]
        let container = WIContainerViewController(controller, webView: nil, tabs: descriptors)

        container.loadViewIfNeeded()

        #expect(container.displayedTabIDsForTesting == [WITab.domTabID, WITab.networkTabID])
        #expect(container.selectedTabIdentifierForTesting == WITab.domTabID)
        #expect(controller.panelConfigurations.map(\.identifier) == [WITab.elementTabID, WITab.networkTabID])
    }

    @Test
    func standaloneElementProxyKeepsDOMAutoSnapshotEnabled() {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: WITab.elementTabID, title: "Element")
        ]
        let container = WIContainerViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let window = mountInWindow(container)
        defer {
            disposeWindow(window, containing: container)
        }

        #expect(container.displayedTabIDsForTesting == [WITab.domTabID])
        #expect(controller.selectedPanelConfiguration?.identifier == WITab.elementTabID)
        #expect(controller.domStore.session.isAutoSnapshotEnabled == true)
    }

    @Test
    func appKitRemovesElementWhenDOMTabExists() async {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: WITab.domTabID, title: "DOM"),
            makeDescriptor(id: WITab.elementTabID, title: "Element"),
            makeDescriptor(id: WITab.networkTabID, title: "Network")
        ]
        let container = WIContainerViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let observers = attachTestObservers(to: container)
        let window = mountInWindow(container)
        defer {
            disposeWindow(window, containing: container)
        }

        #expect(container.displayedTabIDsForTesting == [WITab.domTabID, WITab.networkTabID])
        #expect(container.selectedTabIdentifierForTesting == WITab.domTabID)
        #expect(controller.panelConfigurations.map(\.identifier) == [WITab.domTabID, WITab.elementTabID, WITab.networkTabID])

        await selectTabViaPicker(index: 1, in: window, container: container, renderEvents: observers.render)
        #expect(container.selectedTabIdentifierForTesting == WITab.networkTabID)
        #expect(container.visibleContentTabIDForTesting == WITab.networkTabID)
        #expect(container.visibleContentViewControllerForTesting is WINetworkViewController)
    }

    @Test
    func appKitHiddenElementSelectionNormalizesToDOMWhenDOMExists() {
        let controller = WISessionController()
        let dom = makeDescriptor(id: WITab.domTabID, title: "DOM")
        let element = makeDescriptor(id: WITab.elementTabID, title: "Element")
        let network = makeDescriptor(id: WITab.networkTabID, title: "Network")
        let container = WIContainerViewController(controller, webView: nil, tabs: [dom, element, network])

        controller.setSelectedPanelFromUI(element.configuration)
        #expect(controller.selectedPanelConfiguration?.identifier == WITab.elementTabID)

        container.loadViewIfNeeded()

        #expect(container.displayedTabIDsForTesting == [WITab.domTabID, WITab.networkTabID])
        #expect(container.selectedTabIdentifierForTesting == WITab.domTabID)
        #expect(controller.selectedPanelConfiguration?.identifier == WITab.domTabID)
    }

    @Test
    func toolbarContainsTabPickerAndUsesDescriptorTitles() {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "tab_a", title: "A"),
            makeDescriptor(id: "tab_b", title: "B")
        ]
        let container = WIContainerViewController(controller, webView: nil, tabs: descriptors)
        let window = mountInWindow(container)
        defer {
            disposeWindow(window, containing: container)
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
    func pickerSelectionUpdatesVisibleContentAndModelSelectionWhenConnected() async {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WIContainerViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let observers = attachTestObservers(to: container)
        let window = mountInWindow(container)
        defer {
            disposeWindow(window, containing: container)
        }

        await selectTabViaPicker(index: 1, in: window, container: container, renderEvents: observers.render)

        #expect(container.selectedTabIdentifierForTesting == "wi_network")
        #expect(container.visibleContentTabIDForTesting == "wi_network")
        #expect(controller.selectedPanelConfiguration?.identifier == "wi_network")
    }

    @Test
    func externalPanelUpdatesRefreshDisplayedTabs() async {
        let controller = WISessionController()
        let container = WIContainerViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .network()]
        )
        let observers = attachTestObservers(to: container)

        container.loadViewIfNeeded()
        #expect(container.displayedTabIDsForTesting == [WITab.domTabID, WITab.networkTabID])

        let renderBaseline = container.contentRenderRevisionForTesting
        controller.configurePanels([WITab.dom().configuration])
        await waitForRender(on: observers.render, after: renderBaseline)

        #expect(container.displayedTabIDsForTesting == [WITab.domTabID])
        #expect(container.selectedTabIdentifierForTesting == WITab.domTabID)
    }

    @Test
    func externalPanelUpdatesPreserveDuplicateCustomTabMetadata() async {
        let controller = WISessionController()
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
        let container = WIContainerViewController(
            controller,
            webView: nil,
            tabs: [firstDescriptor, secondDescriptor]
        )
        let observers = attachTestObservers(to: container)
        let window = mountInWindow(container)
        defer {
            disposeWindow(window, containing: container)
        }

        let renderBaseline = container.contentRenderRevisionForTesting
        controller.configurePanels([
            WIPanelConfiguration(kind: .custom("custom")),
            WIPanelConfiguration(kind: .custom("custom"))
        ])
        await waitForRender(on: observers.render, after: renderBaseline)

        let labels = (0..<(tabPicker(in: window)?.segmentCount ?? 0)).compactMap {
            tabPicker(in: window)?.label(forSegment: $0)
        }
        #expect(labels == ["First", "Second"])

        await selectTabViaPicker(index: 1, in: window, container: container, renderEvents: observers.render)

        let visible = try? #require(container.visibleContentViewControllerForTesting as? MarkerViewController)
        #expect(visible?.marker == "second")
    }

    @Test
    func externalPanelUpdatesRejectUnsupportedCustomPanels() async {
        let controller = WISessionController()
        let container = WIContainerViewController(
            controller,
            webView: nil,
            tabs: [.dom()]
        )
        let observers = attachTestObservers(to: container)

        container.loadViewIfNeeded()
        #expect(container.displayedTabIDsForTesting == [WITab.domTabID])

        let renderBaseline = container.contentRenderRevisionForTesting
        controller.configurePanels([
            WIPanelConfiguration(kind: .custom("remote-custom"))
        ])
        await waitForRender(on: observers.render, after: renderBaseline)

        #expect(container.displayedTabIDsForTesting.isEmpty)
        #expect(container.selectedTabIdentifierForTesting == nil)
        #expect(container.visibleContentViewControllerForTesting == nil)
    }

    @Test
    func pickerCanSwitchBackFromNetworkToDOM() async {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WIContainerViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let observers = attachTestObservers(to: container)
        let window = mountInWindow(container)
        defer {
            disposeWindow(window, containing: container)
        }

        await selectTabViaPicker(index: 1, in: window, container: container, renderEvents: observers.render)
        #expect(container.selectedTabIdentifierForTesting == "wi_network")
        #expect(container.visibleContentTabIDForTesting == "wi_network")

        await selectTabViaPicker(index: 0, in: window, container: container, renderEvents: observers.render)
        #expect(container.selectedTabIdentifierForTesting == "wi_dom")
        #expect(container.visibleContentTabIDForTesting == "wi_dom")

        #expect(controller.selectedPanelConfiguration?.identifier == "wi_dom")
        #expect(container.hasVisibleContentForTesting == true)
    }

    @Test
    func rebuildingTabsKeepsVisibleContentBoundToSelectedTab() async {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WIContainerViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let observers = attachTestObservers(to: container)
        let window = mountInWindow(container)
        defer {
            disposeWindow(window, containing: container)
        }

        #expect(container.visibleContentTabIDForTesting == "wi_dom")

        let renderBaseline = container.contentRenderRevisionForTesting
        container.setTabs([
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ])
        await waitForRender(on: observers.render, after: renderBaseline)

        #expect(container.selectedTabIdentifierForTesting == "wi_dom")
        #expect(container.visibleContentTabIDForTesting == "wi_dom")
        #expect(container.hasVisibleContentForTesting == true)
    }

    @Test
    func emptyTabsClearSelectionAndHideVisibleContent() async {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WIContainerViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let observers = attachTestObservers(to: container)
        let window = mountInWindow(container)
        defer {
            disposeWindow(window, containing: container)
        }

        let renderBaseline = container.contentRenderRevisionForTesting
        container.setTabs([])
        await waitForRender(on: observers.render, after: renderBaseline)

        #expect(controller.selectedPanelConfiguration == nil)
        #expect(container.selectedTabIdentifierForTesting == nil)
        #expect(container.visibleContentTabIDForTesting == nil)
        #expect(container.hasVisibleContentForTesting == false)
    }

    @Test
    func toolbarLayoutTracksSelectedTab() async {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WIContainerViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let observers = attachTestObservers(to: container)
        let window = mountInWindow(container)
        defer {
            disposeWindow(window, containing: container)
        }

        #expect(toolbarIdentifierRawValues(in: window) == [
            tabPickerIdentifierRaw,
            NSToolbarItem.Identifier.flexibleSpace.rawValue,
            domPickIdentifierRaw,
            domReloadIdentifierRaw
        ])

        let toolbarBaseline = container.toolbarStateRevisionForTesting
        await selectTabViaPicker(index: 1, in: window, container: container, renderEvents: observers.render)
        await waitForToolbarState(on: observers.toolbar, after: toolbarBaseline)
        container.forceToolbarRefreshForTesting()
        #expect(controller.selectedPanelConfiguration?.identifier == "wi_network")

        #expect(toolbarIdentifierRawValues(in: window) == [
            tabPickerIdentifierRaw,
            networkFilterIdentifierRaw,
            networkClearIdentifierRaw,
            networkSearchIdentifierRaw,
            NSToolbarItem.Identifier.flexibleSpace.rawValue
        ])
    }

    @Test
    func networkSearchToolbarFieldUpdatesSearchText() async {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WIContainerViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let observers = attachTestObservers(to: container)
        let window = mountInWindow(container)
        defer {
            disposeWindow(window, containing: container)
        }

        await selectTabViaPicker(index: 1, in: window, container: container, renderEvents: observers.render)
        container.forceToolbarRefreshForTesting()
        #expect(controller.selectedPanelConfiguration?.identifier == "wi_network")
        guard
            let searchItem = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == networkSearchIdentifierRaw }) as? NSSearchToolbarItem,
            let action = searchItem.searchField.action
        else {
            Issue.record("Expected network search toolbar item")
            return
        }

        searchItem.searchField.stringValue = "fetch target"
        searchItem.searchField.sendAction(action, to: searchItem.searchField.target)

        #expect(container.networkQueryModelForTesting.searchText == "fetch target")
    }

    @Test
    func networkFilterToolbarItemBecomesProminentWhenFiltering() async {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WIContainerViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let observers = attachTestObservers(to: container)
        let window = mountInWindow(container)
        defer {
            disposeWindow(window, containing: container)
        }

        let initialToolbarBaseline = container.toolbarStateRevisionForTesting
        await selectTabViaPicker(index: 1, in: window, container: container, renderEvents: observers.render)
        await waitForToolbarState(on: observers.toolbar, after: initialToolbarBaseline)
        container.forceToolbarRefreshForTesting()

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
        let filteredToolbarBaseline = container.toolbarStateRevisionForTesting
        await waitForToolbarState(on: observers.toolbar, after: filteredToolbarBaseline)
        container.forceToolbarRefreshForTesting()

        #expect(container.networkQueryModelForTesting.activeFilters.contains(.script))
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
        let clearedToolbarBaseline = container.toolbarStateRevisionForTesting
        await waitForToolbarState(on: observers.toolbar, after: clearedToolbarBaseline)
        container.forceToolbarRefreshForTesting()

        #expect(container.networkQueryModelForTesting.effectiveFilters.isEmpty)
        let refreshedFilterItem = networkFilterToolbarItem(in: window)
        if #available(macOS 26.0, *) {
            #expect(refreshedFilterItem?.style == .plain)
        }
    }

    @Test
    func replacingDescriptorWithSameIdentifierRebuildsCachedContentController() async {
        let controller = WISessionController()
        let firstController = MarkerViewController(marker: "first")
        let secondController = MarkerViewController(marker: "second")

        let firstDescriptor = WITab(
            id: "custom",
            title: "Custom",
            systemImage: "circle",
            viewControllerProvider: { _ in firstController }
        )
        let container = WIContainerViewController(controller, webView: nil, tabs: [firstDescriptor])
        let observers = attachTestObservers(to: container)
        container.loadViewIfNeeded()

        let initialVisible = try? #require(container.visibleContentViewControllerForTesting as? MarkerViewController)
        #expect(initialVisible?.marker == "first")

        let renderBaseline = container.contentRenderRevisionForTesting
        let replacedDescriptor = WITab(
            id: "custom",
            title: "Custom",
            systemImage: "circle",
            viewControllerProvider: { _ in secondController }
        )
        container.setTabs([replacedDescriptor])
        await waitForRender(on: observers.render, after: renderBaseline)

        let replacedVisible = try? #require(container.visibleContentViewControllerForTesting as? MarkerViewController)
        #expect(replacedVisible?.marker == "second")
    }

    @Test
    func duplicateIdentifierTabsUseDistinctCachedContentControllers() async {
        let controller = WISessionController()
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

        let container = WIContainerViewController(
            controller,
            webView: nil,
            tabs: [firstDescriptor, secondDescriptor]
        )
        let observers = attachTestObservers(to: container)
        let window = mountInWindow(container)
        defer {
            disposeWindow(window, containing: container)
        }

        let initialVisible = try? #require(container.visibleContentViewControllerForTesting as? MarkerViewController)
        #expect(initialVisible?.marker == "first")
        #expect(tabPicker(in: window)?.selectedSegment == 0)

        await selectTabViaPicker(index: 1, in: window, container: container, renderEvents: observers.render)

        let switchedVisible = try? #require(container.visibleContentViewControllerForTesting as? MarkerViewController)
        #expect(switchedVisible?.marker == "second")
        #expect(initialVisible !== switchedVisible)
        #expect(controller.selectedPanelConfiguration?.identifier == secondDescriptor.identifier)
        #expect(tabPicker(in: window)?.selectedSegment == 1)
    }

    @Test
    func appKitSplitViewsUseStableAutosaveNamesAcrossTabSwitches() async {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WIContainerViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let observers = attachTestObservers(to: container)
        let window = mountInWindow(container)
        defer {
            disposeWindow(window, containing: container)
        }

        let domController = try? #require(container.visibleContentViewControllerForTesting as? WIDOMViewController)
        #expect(domController?.splitView.autosaveName == "WebInspectorKit.DOMSplitView")

        await selectTabViaPicker(index: 1, in: window, container: container, renderEvents: observers.render)
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

    private func mountInWindow(_ container: WIContainerViewController) -> NSWindow {
        let window = NSWindow(contentViewController: container)
        container.loadViewIfNeeded()
        container.viewWillAppear()
        return window
    }

    private func disposeWindow(_ window: NSWindow, containing container: WIContainerViewController) {
        container.viewDidDisappear()
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
    }

    private func tabPicker(in window: NSWindow) -> NSSegmentedControl? {
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
        window.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? []
    }

    private func tabPickerToolbarItem(in window: NSWindow) -> NSToolbarItem? {
        window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == tabPickerIdentifierRaw })
    }

    private func networkFilterToolbarItem(in window: NSWindow) -> NSMenuToolbarItem? {
        window.toolbar?.items
            .first(where: { $0.itemIdentifier.rawValue == networkFilterIdentifierRaw }) as? NSMenuToolbarItem
    }

    private func attachTestObservers(
        to container: WIContainerViewController
    ) -> (render: AsyncValueQueue<UInt64>, toolbar: AsyncValueQueue<UInt64>) {
        let render = AsyncValueQueue<UInt64>()
        let toolbar = AsyncValueQueue<UInt64>()
        container.onContentRenderedForTesting = { revision in
            Task {
                await render.push(revision)
            }
        }
        container.onToolbarStateUpdatedForTesting = { revision in
            Task {
                await toolbar.push(revision)
            }
        }
        return (render, toolbar)
    }

    private func waitForRender(
        on renderEvents: AsyncValueQueue<UInt64>,
        after baseline: UInt64
    ) async {
        _ = await renderEvents.next(where: { $0 > baseline })
    }

    private func waitForToolbarState(
        on toolbarEvents: AsyncValueQueue<UInt64>,
        after baseline: UInt64
    ) async {
        _ = await toolbarEvents.next(where: { $0 > baseline })
    }

    private func selectTabViaPicker(
        index: Int,
        in window: NSWindow,
        container: WIContainerViewController,
        renderEvents: AsyncValueQueue<UInt64>
    ) async {
        guard
            let picker = tabPicker(in: window),
            let action = picker.action
        else {
            Issue.record("Expected toolbar tab picker")
            return
        }
        let renderBaseline = container.contentRenderRevisionForTesting
        picker.selectedSegment = index
        picker.sendAction(action, to: picker.target)
        await waitForRender(on: renderEvents, after: renderBaseline)
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
