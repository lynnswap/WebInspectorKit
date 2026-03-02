import WebKit
import ObservationsCompat
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(AppKit)
import AppKit
import WebInspectorBridge

@MainActor
public final class WITabViewController: NSTabViewController {
    private static let toolbarIdentifier = NSToolbar.Identifier("WITabToolbar")

    public private(set) var inspectorController: WIModel

    private var networkQueryModel: WINetworkQueryModel
    private weak var appKitToolbar: NSToolbar?
    private weak var tabPickerControl: NSSegmentedControl?
    private weak var networkSearchField: NSSearchField?
    private var hasStartedObservingToolbarState = false
    private var toolbarObservationHandles: [ObservationHandle] = []
    private let toolbarUpdateCoalescer = UIUpdateCoalescer()
    private var isApplyingPickerSelection = false
    private var isApplyingSelectionFromController = false
    private var isRebuildingTabs = false
    private var sessionTabsObservationHandle: ObservationHandle?
    private var sessionSelectionObservationHandle: ObservationHandle?

    public init(
        _ inspectorController: WIModel,
        webView: WKWebView?,
        tabs: [WITab] = [.dom(), .network()]
    ) {
        self.inspectorController = inspectorController
        self.networkQueryModel = WINetworkQueryModel(inspector: inspectorController.network)
        super.init(nibName: nil, bundle: nil)
        if let webView {
            inspectorController.setPageWebViewFromUI(webView)
        }
        inspectorController.setTabs(tabs)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        sessionTabsObservationHandle?.cancel()
        sessionSelectionObservationHandle?.cancel()
        stopObservingToolbarState()
    }

    public func setPageWebView(_ webView: WKWebView?) {
        inspectorController.setPageWebViewFromUI(webView)
        if isViewLoaded {
            inspectorController.activateFromUIIfPossible()
        }
    }

    public func setInspectorController(_ inspectorController: WIModel) {
        guard self.inspectorController !== inspectorController else {
            return
        }
        let currentTabs = self.inspectorController.tabs
        let currentSelectedTab = self.inspectorController.selectedTab
        let currentPageWebView = self.inspectorController.pageWebViewForUI
        let previousController = self.inspectorController
        previousController.disconnect()
        self.inspectorController = inspectorController
        self.networkQueryModel = WINetworkQueryModel(inspector: inspectorController.network)
        inspectorController.setPageWebViewFromUI(currentPageWebView)
        resetCachedContentViewControllers(for: currentTabs)
        inspectorController.setTabs(currentTabs)
        inspectorController.setSelectedTabFromUI(currentSelectedTab)
        stopObservingToolbarState()
        if isViewLoaded {
            bindSessionTabs()
            rebuildTabs()
            inspectorController.activateFromUIIfPossible()
            startObservingToolbarStateIfNeeded()
            updateToolbarState()
        }
    }

    public func setTabs(_ tabs: [WITab]) {
        inspectorController.setTabs(tabs)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .unspecified
        tabView.tabViewType = .noTabsNoBorder

        bindSessionTabs()
        rebuildTabs()
        startObservingToolbarStateIfNeeded()
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        inspectorController.activateFromUIIfPossible()
        syncNativeSelection(with: inspectorController.selectedTab)
        installToolbarIfNeeded()
        startObservingToolbarStateIfNeeded()
        updateToolbarState()
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
        if Self.window(for: view) == nil {
            inspectorController.suspend()
        }
    }

    public override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard isApplyingSelectionFromController == false, isRebuildingTabs == false else {
            return
        }
        // Tab headers are hidden and selection is driven by the toolbar picker.
        // Ignore native tab callbacks that can arrive during internal sync.
        guard tabView.tabViewType != .noTabsNoBorder else {
            return
        }
        guard
            let identifier = tabViewItem?.identifier as? String,
            let selectedTab = tabForIdentifier(identifier)
        else {
            return
        }
        applyUserTabSelection(selectedTab)
    }

    private func rebuildTabs() {
        isRebuildingTabs = true
        defer {
            isRebuildingTabs = false
        }
        let tabs = inspectorController.tabs
        tabViewItems = tabs.map { tab in
            let viewController = makeTabRootViewController(for: tab) ?? NSViewController()
            let item = NSTabViewItem(viewController: viewController)
            item.identifier = tab.identifier
            item.label = tab.title
            item.image = tab.image
            return item
        }
        syncNativeSelection(with: inspectorController.selectedTab)
        refreshTabPickerState()
    }

    private func bindSessionTabs() {
        sessionTabsObservationHandle?.cancel()
        sessionSelectionObservationHandle?.cancel()

        sessionTabsObservationHandle = inspectorController.observe(\.tabs) { [weak self] _ in
            self?.handleObservedTabsChange()
        }
        sessionSelectionObservationHandle = inspectorController.observe(\.selectedTab) { [weak self] _ in
            self?.handleObservedSelectionChange()
        }
    }

    private func handleObservedTabsChange() {
        rebuildTabs()
        applyObservedTabStateSideEffects()
    }

    private func handleObservedSelectionChange() {
        syncNativeSelection(with: inspectorController.selectedTab)
        applyObservedTabStateSideEffects()
    }

    private func applyObservedTabStateSideEffects() {
        updateToolbarState()
    }

    private func syncNativeSelection(with tab: WITab?) {
        let tabs = inspectorController.tabs
        guard tabs.isEmpty == false else {
            refreshTabPickerState()
            return
        }
        // During rebuild, selection callbacks can arrive before NSTabViewItem creation.
        // Avoid touching selectedTabViewItemIndex while no tab items exist.
        let availableTabCount = min(tabs.count, tabViewItems.count)
        guard availableTabCount > 0 else {
            return
        }

        let resolvedIndex = resolvedSelectionIndex(for: tab, in: tabs)
        guard resolvedIndex < availableTabCount else {
            return
        }
        applySelectionIndexFromControllerIfNeeded(resolvedIndex)
        refreshTabPickerState()
    }

    private func installToolbarIfNeeded() {
        guard let window = Self.window(for: view) else {
            return
        }

        if window.toolbar?.identifier != Self.toolbarIdentifier {
            let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            window.toolbar = toolbar
        }

        appKitToolbar = window.toolbar
        updateToolbarLayout()
    }

    private func startObservingToolbarStateIfNeeded() {
        guard hasStartedObservingToolbarState == false else {
            return
        }
        hasStartedObservingToolbarState = true

        toolbarObservationHandles.append(
            inspectorController.dom.observe(
                \.hasPageWebView,
                options: [.removeDuplicates]
            ) { [weak self] _ in
                self?.scheduleToolbarStateUpdate()
            }
        )
        toolbarObservationHandles.append(
            inspectorController.dom.observe(
                \.isSelectingElement,
                options: [.removeDuplicates]
            ) { [weak self] _ in
                self?.scheduleToolbarStateUpdate()
            }
        )
        toolbarObservationHandles.append(
            inspectorController.network.observeTask(
                [\.canFetchSelectedBodies]
            ) { [weak self] in
                self?.scheduleToolbarStateUpdate()
            }
        )
        toolbarObservationHandles.append(
            inspectorController.network.store.observeTask(
                [\.entries]
            ) { [weak self] in
                self?.scheduleToolbarStateUpdate()
            }
        )
        toolbarObservationHandles.append(
            networkQueryModel.observe(
                \.searchText,
                options: [.removeDuplicates]
            ) { [weak self] _ in
                self?.scheduleToolbarStateUpdate()
            }
        )
        toolbarObservationHandles.append(
            networkQueryModel.observe(
                \.activeFilters,
                options: [.removeDuplicates]
            ) { [weak self] _ in
                self?.scheduleToolbarStateUpdate()
            }
        )
        toolbarObservationHandles.append(
            networkQueryModel.observe(
                \.effectiveFilters,
                options: [.removeDuplicates]
            ) { [weak self] _ in
                self?.scheduleToolbarStateUpdate()
            }
        )
    }

    private func stopObservingToolbarState() {
        hasStartedObservingToolbarState = false

        for handle in toolbarObservationHandles {
            handle.cancel()
        }
        toolbarObservationHandles.removeAll()
    }

    private func scheduleToolbarStateUpdate() {
        toolbarUpdateCoalescer.schedule { [weak self] in
            self?.updateToolbarState()
        }
    }

    private func updateToolbarLayout() {
        guard let toolbar = appKitToolbar else {
            return
        }

        let desiredIdentifiers: [NSToolbarItem.Identifier]
        switch inspectorController.selectedTab?.identifier {
        case WITab.domTabID:
            desiredIdentifiers = [.wiTabPicker, .flexibleSpace, .wiDOMPick, .wiDOMReload]
        case WITab.networkTabID:
            desiredIdentifiers = [
                .wiTabPicker,
                .wiNetworkFilter,
                .wiNetworkClear,
                .wiNetworkSearch,
                .flexibleSpace,
                .wiNetworkFetchBody
            ]
        default:
            desiredIdentifiers = [.wiTabPicker]
        }

        let currentIdentifiers = toolbar.items.map(\.itemIdentifier)
        guard currentIdentifiers != desiredIdentifiers else {
            return
        }

        for index in stride(from: toolbar.items.count - 1, through: 0, by: -1) {
            toolbar.removeItem(at: index)
        }
        for (index, identifier) in desiredIdentifiers.enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
    }

    private func updateToolbarState() {
        updateToolbarLayout()
        refreshTabPickerState()
        guard let toolbar = appKitToolbar else {
            return
        }

        if let pickItem = toolbar.items.first(where: { $0.itemIdentifier == .wiDOMPick }) {
            pickItem.isEnabled = inspectorController.dom.hasPageWebView
            pickItem.image = Self.pickToolbarImage(isSelecting: inspectorController.dom.isSelectingElement)
        }

        if let reloadItem = toolbar.items.first(where: { $0.itemIdentifier == .wiDOMReload }) {
            reloadItem.isEnabled = inspectorController.dom.hasPageWebView
        }

        if let fetchBodyItem = toolbar.items.first(where: { $0.itemIdentifier == .wiNetworkFetchBody }) {
            fetchBodyItem.isEnabled = inspectorController.network.canFetchSelectedBodies
        }

        if let filterItem = toolbar.items.first(where: { $0.itemIdentifier == .wiNetworkFilter }) as? NSMenuToolbarItem {
            let isFiltering = !networkQueryModel.effectiveFilters.isEmpty
            filterItem.menu = makeNetworkFilterMenu()
            let didApplyButtonStyle = Self.applyNetworkFilterToolbarAppearance(
                to: filterItem,
                isFiltering: isFiltering
            )
            filterItem.image = Self.networkFilterToolbarImage(
                isFiltering: didApplyButtonStyle ? false : isFiltering,
                preserveTemplate: didApplyButtonStyle
            )
        }

        if let clearItem = toolbar.items.first(where: { $0.itemIdentifier == .wiNetworkClear }) {
            let canClear = !inspectorController.network.store.entries.isEmpty
            clearItem.isEnabled = canClear
            if let clearButton = clearItem.view as? NSButton {
                clearButton.isEnabled = canClear
            }
        }

        if let searchField = networkSearchField {
            let currentSearchText = networkQueryModel.searchText
            if searchField.stringValue != currentSearchText {
                searchField.stringValue = currentSearchText
            }
        }
    }

    private func refreshTabPickerState() {
        guard let tabPickerControl else {
            return
        }

        let tabs = inspectorController.tabs
        let titles = tabs.map(\.title)
        if tabPickerControl.segmentCount != titles.count {
            tabPickerControl.segmentCount = titles.count
        }
        for (index, title) in titles.enumerated() {
            tabPickerControl.setLabel(title, forSegment: index)
            tabPickerControl.setWidth(0, forSegment: index)
        }

        guard titles.isEmpty == false else {
            tabPickerControl.selectedSegment = -1
            tabPickerControl.isEnabled = false
            return
        }

        tabPickerControl.isEnabled = true
        let selectedIndex = resolvedTabPickerSelectionIndex()
        if tabPickerControl.selectedSegment != selectedIndex {
            isApplyingPickerSelection = true
            tabPickerControl.selectedSegment = selectedIndex
            isApplyingPickerSelection = false
        }
    }

    private func resolvedTabPickerSelectionIndex() -> Int {
        resolvedSelectionIndex(for: inspectorController.selectedTab, in: inspectorController.tabs)
    }

    private static func pickToolbarImage(isSelecting: Bool) -> NSImage? {
        guard let baseImage = NSImage(systemSymbolName: "scope", accessibilityDescription: wiLocalized("dom.controls.pick")) else {
            return nil
        }
        let color = isSelecting ? NSColor.controlAccentColor : NSColor.labelColor
        let configuration = NSImage.SymbolConfiguration(hierarchicalColor: color)
        return baseImage.withSymbolConfiguration(configuration)
    }

    private static func networkFilterToolbarImage(isFiltering: Bool, preserveTemplate: Bool = false) -> NSImage? {
        let title = wiLocalized("network.controls.filter", default: "Filter")
        guard let baseImage = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: title) else {
            return nil
        }
        if preserveTemplate {
            return baseImage
        }
        let color = isFiltering ? NSColor.controlAccentColor : NSColor.labelColor
        let configuration = NSImage.SymbolConfiguration(hierarchicalColor: color)
        return baseImage.withSymbolConfiguration(configuration)
    }

    private static func applyNetworkFilterToolbarAppearance(
        to item: NSMenuToolbarItem,
        isFiltering: Bool
    ) -> Bool {
        if #available(macOS 26.0, *) {
            item.style = isFiltering ? .prominent : .plain
            item.backgroundTintColor = isFiltering ? .controlAccentColor : nil
            return true
        }

        guard let control = menuToolbarControl(from: item) else {
            return false
        }

        if let segmentedControl = control as? NSSegmentedControl {
            for index in 0..<segmentedControl.segmentCount {
                segmentedControl.setSelected(isFiltering, forSegment: index)
            }
            segmentedControl.selectedSegment = isFiltering ? 0 : -1
            segmentedControl.selectedSegmentBezelColor = isFiltering ? .controlAccentColor : nil
            segmentedControl.needsDisplay = true
            return true
        }

        if let button = control as? NSButton {
            button.state = isFiltering ? .on : .off
            button.bezelColor = isFiltering ? .controlAccentColor : nil
            button.contentTintColor = isFiltering ? .white : nil
            button.needsDisplay = true
            return true
        }

        return false
    }

    private static func menuToolbarControl(from item: NSMenuToolbarItem) -> NSView? {
        WIAppKitBridge.menuToolbarControl(from: item)
    }

    private static func window(for view: NSView) -> NSWindow? {
        WIAppKitBridge.window(for: view)
    }

    private func makeNetworkFilterMenu() -> NSMenu {
        let menu = NSMenu(title: wiLocalized("network.controls.filter", default: "Filter"))

        let allItem = NSMenuItem(
            title: NetworkResourceFilter.all.localizedTitle,
            action: #selector(handleNetworkFilterMenuAction(_:)),
            keyEquivalent: ""
        )
        allItem.target = self
        allItem.representedObject = NetworkResourceFilter.all.rawValue
        allItem.state = networkQueryModel.effectiveFilters.isEmpty ? .on : .off
        menu.addItem(allItem)
        menu.addItem(.separator())

        for filter in NetworkResourceFilter.pickerCases {
            let item = NSMenuItem(
                title: filter.localizedTitle,
                action: #selector(handleNetworkFilterMenuAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = filter.rawValue
            item.state = networkQueryModel.activeFilters.contains(filter) ? .on : .off
            menu.addItem(item)
        }

        return menu
    }

    @objc
    private func handleDOMPickToolbarAction(_ sender: Any?) {
        inspectorController.dom.toggleSelectionMode()
        updateToolbarState()
    }

    @objc
    private func handleDOMReloadToolbarAction(_ sender: Any?) {
        Task {
            await inspectorController.dom.reloadInspector()
        }
    }

    @objc
    private func handleNetworkFetchBodyToolbarAction(_ sender: Any?) {
        inspectorController.network.requestFetchSelectedBodies(force: true)
        updateToolbarState()
    }

    @objc
    private func handleNetworkFilterMenuAction(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let filter = NetworkResourceFilter(rawValue: rawValue)
        else {
            return
        }

        if filter == .all {
            networkQueryModel.setFilter(.all, enabled: true)
            updateToolbarState()
            return
        }

        networkQueryModel.toggleFilter(filter)
        updateToolbarState()
    }

    @objc
    private func handleNetworkClearToolbarAction(_ sender: Any?) {
        inspectorController.network.clear()
        updateToolbarState()
    }

    @objc
    private func handleNetworkSearchToolbarAction(_ sender: NSSearchField) {
        networkQueryModel.setSearchText(sender.stringValue)
    }

    @objc
    private func handleTabPickerSelectionChanged(_ sender: NSSegmentedControl) {
        guard isApplyingPickerSelection == false else {
            return
        }
        let selectedIndex = sender.selectedSegment
        guard selectedIndex >= 0 else {
            return
        }
        let tabs = inspectorController.tabs
        guard selectedIndex < tabs.count, selectedIndex < tabViewItems.count else {
            refreshTabPickerState()
            return
        }

        let selectedTab = tabs[selectedIndex]
        applySelectionIndexFromControllerIfNeeded(selectedIndex)
        applyUserTabSelection(selectedTab)
    }

    private func applySelectionIndexFromControllerIfNeeded(_ index: Int) {
        guard index >= 0, index < tabViewItems.count else {
            return
        }

        let expectedIdentifier = tabViewItems[index].identifier as? String
        let currentIdentifier = tabView.selectedTabViewItem?.identifier as? String
        let shouldApplySelection = selectedTabViewItemIndex != index || currentIdentifier != expectedIdentifier
        guard shouldApplySelection else {
            return
        }

        isApplyingSelectionFromController = true
        defer { isApplyingSelectionFromController = false }
        tabView.selectTabViewItem(at: index)
        selectedTabViewItemIndex = index
        tabViewItems[index].viewController?.loadViewIfNeeded()
    }

    public override func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .wiTabPicker,
            .wiDOMPick,
            .wiDOMReload,
            .wiNetworkFilter,
            .wiNetworkClear,
            .wiNetworkSearch,
            .wiNetworkFetchBody,
            .flexibleSpace
        ]
    }

    public override func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.wiTabPicker, .flexibleSpace, .wiDOMPick, .wiDOMReload]
    }

    public override func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .wiTabPicker:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.target = self
            item.isBordered = true
            let labels = inspectorController.tabs.map(\.title)
            let picker = NSSegmentedControl(
                labels: labels,
                trackingMode: .selectOne,
                target: self,
                action: #selector(handleTabPickerSelectionChanged(_:))
            )
            picker.segmentStyle = .texturedRounded
            picker.setContentHuggingPriority(.required, for: .horizontal)
            tabPickerControl = picker
            refreshTabPickerState()

            item.label = wiLocalized("inspector.tabs", default: "Tabs")
            item.paletteLabel = item.label
            item.toolTip = item.label
            item.isNavigational = true
            item.view = picker
            return item
        case .wiNetworkFilter:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = wiLocalized("network.controls.filter", default: "Filter")
            item.paletteLabel = item.label
            item.toolTip = item.label
            item.title = item.label
            item.isBordered = true
            item.image = Self.networkFilterToolbarImage(
                isFiltering: !networkQueryModel.effectiveFilters.isEmpty
            )
            item.menu = makeNetworkFilterMenu()
            item.showsIndicator = true
            return item
        case .wiNetworkClear:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let clearTitle = wiLocalized("network.controls.clear", default: "Clear")
            let clearButton = NSButton(title: clearTitle, target: self, action: #selector(handleNetworkClearToolbarAction(_:)))
            clearButton.bezelStyle = .rounded
            clearButton.setContentHuggingPriority(.required, for: .horizontal)
            item.label = clearTitle
            item.paletteLabel = clearTitle
            item.toolTip = clearTitle
            item.view = clearButton
            return item
        case .wiNetworkSearch:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            let placeholder = wiLocalized("network.search.placeholder", default: "Search requests")
            item.label = wiLocalized("network.controls.search", default: "Search")
            item.paletteLabel = item.label
            item.toolTip = placeholder
            item.preferredWidthForSearchField = 280
            let searchField = item.searchField
            searchField.placeholderString = placeholder
            searchField.target = self
            searchField.action = #selector(handleNetworkSearchToolbarAction(_:))
            searchField.sendsSearchStringImmediately = true
            searchField.sendsWholeSearchString = false
            searchField.stringValue = networkQueryModel.searchText
            networkSearchField = searchField
            return item
        case .wiDOMPick:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.target = self
            item.isBordered = true
            item.label = wiLocalized("dom.controls.pick")
            item.paletteLabel = item.label
            item.toolTip = item.label
            item.image = Self.pickToolbarImage(isSelecting: inspectorController.dom.isSelectingElement)
            item.action = #selector(handleDOMPickToolbarAction(_:))
            return item
        case .wiDOMReload:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.target = self
            item.isBordered = true
            item.label = wiLocalized("reload")
            item.paletteLabel = item.label
            item.toolTip = item.label
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: item.label)
            item.action = #selector(handleDOMReloadToolbarAction(_:))
            return item
        case .wiNetworkFetchBody:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.target = self
            item.isBordered = true
            item.label = wiLocalized("network.body.fetch", default: "Fetch Body")
            item.paletteLabel = item.label
            item.toolTip = item.label
            item.image = NSImage(systemSymbolName: "arrow.down.document", accessibilityDescription: item.label)
            item.action = #selector(handleNetworkFetchBodyToolbarAction(_:))
            return item
        default:
            return nil
        }
    }

    private func applyUserTabSelection(_ tab: WITab) {
        inspectorController.setSelectedTabFromUI(tab)
        syncNativeSelection(with: inspectorController.selectedTab)
        updateToolbarState()
    }

    private func tabForIdentifier(_ identifier: String) -> WITab? {
        inspectorController.tabs.first(where: { $0.identifier == identifier })
    }

    private func resolvedSelectionIndex(for selectedTab: WITab?, in tabs: [WITab]) -> Int {
        guard tabs.isEmpty == false else {
            return 0
        }
        guard let selectedTab else {
            return 0
        }
        if let exactMatch = tabs.firstIndex(where: { $0 === selectedTab }) {
            return exactMatch
        }
        return tabs.firstIndex(where: { $0.identifier == selectedTab.identifier }) ?? 0
    }

    private func resetCachedContentViewControllers(for tabs: [WITab]) {
        for tab in tabs {
            tab.resetCachedContentViewController()
        }
    }

    private func makeTabRootViewController(for tab: WITab) -> NSViewController? {
        if let cached = tab.cachedContentViewController {
            return cached
        }

        let viewController: NSViewController?
        if let customViewController = tab.viewControllerProvider?(tab) {
            viewController = customViewController
        } else {
            switch tab.identifier {
            case WITab.domTabID:
                viewController = WIDOMViewController(inspector: inspectorController.dom)
            case WITab.networkTabID:
                viewController = WINetworkViewController(
                    inspector: inspectorController.network,
                    queryModel: networkQueryModel
                )
            default:
                viewController = nil
            }
        }

        guard let viewController else {
            return nil
        }
        tab.cachedContentViewController = viewController
        return viewController
    }
}

private extension NSToolbarItem.Identifier {
    static let wiTabPicker = NSToolbarItem.Identifier("WIContainerToolbar.TabPicker")
    static let wiDOMPick = NSToolbarItem.Identifier("WIContainerToolbar.DOMPick")
    static let wiDOMReload = NSToolbarItem.Identifier("WIContainerToolbar.DOMReload")
    static let wiNetworkFilter = NSToolbarItem.Identifier("WIContainerToolbar.NetworkFilter")
    static let wiNetworkClear = NSToolbarItem.Identifier("WIContainerToolbar.NetworkClear")
    static let wiNetworkSearch = NSToolbarItem.Identifier("WIContainerToolbar.NetworkSearch")
    static let wiNetworkFetchBody = NSToolbarItem.Identifier("WIContainerToolbar.NetworkFetchBody")
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("Tab Container (AppKit)") {
    WIAppKitPreviewContainer {
        let session = WIModel()
        WIDOMPreviewFixtures.applySampleSelection(to: session.dom, mode: .selected)
        let previewWebView = WIDOMPreviewFixtures.bootstrapDOMTreeForPreview(session.dom)
        WINetworkPreviewFixtures.applySampleData(to: session.network, mode: .detail)
        return WITabViewController(
            session,
            webView: previewWebView,
            tabs: [.dom(), .network()]
        )
    }
}
#endif


#endif
