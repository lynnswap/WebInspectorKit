import Testing
import WebKit
@testable import WebInspectorKit
import WebInspectorKitCore

#if canImport(AppKit)
import AppKit

@MainActor
struct ContainerViewControllerAppKitTabTests {
    private let tabPickerIdentifierRaw = "WIContainerToolbar.TabPicker"
    private let domPickIdentifierRaw = "WIContainerToolbar.DOMPick"
    private let domReloadIdentifierRaw = "WIContainerToolbar.DOMReload"
    private let networkFilterIdentifierRaw = "WIContainerToolbar.NetworkFilter"
    private let networkClearIdentifierRaw = "WIContainerToolbar.NetworkClear"
    private let networkSearchIdentifierRaw = "WIContainerToolbar.NetworkSearch"
    private let networkFetchIdentifierRaw = "WIContainerToolbar.NetworkFetchBody"

    @Test
    func loadViewIfNeededDoesNotCrashWhenSelectionCallbackArrivesBeforeTabItemsExist() {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "tab_a", title: "A"),
            makeDescriptor(id: "tab_b", title: "B")
        ]
        let container = WIContainerViewController(controller, webView: nil, tabs: descriptors)

        container.loadViewIfNeeded()

        #expect(container.tabViewItems.count == 2)
        #expect(container.selectedTabViewItemIndex == 0)
        #expect(controller.selectedTabID == "tab_a")
        #expect(container.tabStyle == .unspecified)
        #expect(container.tabView.tabViewType == .noTabsNoBorder)
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
    }

    @Test
    func pickerSelectionUpdatesTabAndControllerSelectionWhenConnected() {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WIContainerViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        guard let picker = tabPicker(in: window) else {
            Issue.record("Expected toolbar tab picker")
            return
        }

        picker.selectedSegment = 1
        guard let action = picker.action else {
            Issue.record("Expected picker action")
            return
        }
        picker.sendAction(action, to: picker.target)

        #expect(container.selectedTabViewItemIndex == 1)
        #expect(controller.selectedTabID == "wi_network")
    }

    @Test
    func externalSelectionChangesUpdatePickerSelection() {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WIContainerViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        guard let initialPicker = tabPicker(in: window) else {
            Issue.record("Expected toolbar tab picker")
            return
        }

        controller.selectedTabID = "wi_network"
        #expect(initialPicker.selectedSegment == 1)
        controller.selectedTabID = "wi_dom"
        guard let updatedPicker = tabPicker(in: window) else {
            Issue.record("Expected toolbar tab picker after tab switch")
            return
        }
        #expect(updatedPicker.selectedSegment == 0)
    }

    @Test
    func toolbarLayoutTracksSelectedTab() {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WIContainerViewController(controller, webView: makeTestWebView(), tabs: descriptors)
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

        controller.selectedTabID = "wi_network"

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
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WIContainerViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        controller.selectedTabID = "wi_network"
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
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "wi_dom", title: "DOM"),
            makeDescriptor(id: "wi_network", title: "Network")
        ]
        let container = WIContainerViewController(controller, webView: makeTestWebView(), tabs: descriptors)
        let window = mountInWindow(container)
        defer {
            container.viewDidDisappear()
            _ = window
        }

        controller.selectedTabID = "wi_network"
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

    private func makeDescriptor(id: String, title: String) -> WITabDescriptor {
        WITabDescriptor(
            id: id,
            title: title,
            systemImage: "circle"
        ) { _ in
            NSViewController()
        }
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}
#endif
