import Testing
import WebKit
@testable import WebInspectorUI
@testable import WebInspectorRuntime
import WebInspectorEngine

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
    private let networkFetchIdentifierRaw = "WIContainerToolbar.NetworkFetchBody"

    @Test
    func loadViewIfNeededRendersInitialContentAndSelection() {
        let controller = WIModel()
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
    func toolbarContainsTabPickerAndUsesDescriptorTitles() {
        let controller = WIModel()
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
    func pickerSelectionUpdatesVisibleContentAndModelSelectionWhenConnected() {
        let controller = WIModel()
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
        let controller = WIModel()
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
        let controller = WIModel()
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
        let controller = WIModel()
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
        let controller = WIModel()
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
            NSToolbarItem.Identifier.flexibleSpace.rawValue,
            networkFetchIdentifierRaw
        ])
    }

    @Test
    func networkSearchToolbarFieldUpdatesSearchText() {
        let controller = WIModel()
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
        let controller = WIModel()
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
        let controller = WIModel()
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
        return window
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

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
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
