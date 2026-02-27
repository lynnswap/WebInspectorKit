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
    private static let domTabID = "wi_dom"
    private static let networkTabID = "wi_network"

    public private(set) var inspectorController: WISession

    private weak var pageWebView: WKWebView?
    private var tabDescriptors: [WITabDescriptor]
    private var networkQueryModel: WINetworkQueryModel
    private weak var appKitToolbar: NSToolbar?
    private weak var tabPickerControl: NSSegmentedControl?
    private weak var networkSearchField: NSSearchField?
    private var hasStartedObservingToolbarState = false
    private var toolbarObservationHandles: [ObservationHandle] = []
    private var selectedEntryObservationHandles: [ObservationHandle] = []
    private var selectedEntryBodyFetchStateHandles: [ObservationHandle] = []
    private var selectedEntryBodyObservedEntryID: UUID?
    private let toolbarUpdateCoalescer = UIUpdateCoalescer()
    private var isApplyingPickerSelection = false

    public init(
        _ inspectorController: WISession,
        webView: WKWebView?,
        tabs: [WITabDescriptor] = [.dom(), .network()]
    ) {
        self.inspectorController = inspectorController
        self.pageWebView = webView
        self.tabDescriptors = Self.normalizeAppKitTabs(tabs)
        self.networkQueryModel = WINetworkQueryModel(inspector: inspectorController.network)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        stopObservingToolbarState()
    }

    public func setPageWebView(_ webView: WKWebView?) {
        pageWebView = webView
        if isViewLoaded {
            inspectorController.connect(to: webView)
        }
    }

    public func setInspectorController(_ inspectorController: WISession) {
        guard self.inspectorController !== inspectorController else {
            return
        }
        let previousController = self.inspectorController
        previousController.onSelectedTabIDChange = nil
        previousController.disconnect()
        self.inspectorController = inspectorController
        self.networkQueryModel = WINetworkQueryModel(inspector: inspectorController.network)
        self.inspectorController.enableUICommandRouting()
        bindSelectionCallback()
        stopObservingToolbarState()
        if isViewLoaded {
            rebuildTabs()
            inspectorController.connect(to: pageWebView)
            startObservingToolbarStateIfNeeded()
            updateToolbarState()
        }
    }

    public func setTabs(_ tabs: [WITabDescriptor]) {
        tabDescriptors = Self.normalizeAppKitTabs(tabs)
        inspectorController.configureTabs(tabDescriptors.map(\.sessionTabDefinition))
        if isViewLoaded {
            rebuildTabs()
            updateToolbarState()
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .unspecified
        tabView.tabViewType = .noTabsNoBorder

        inspectorController.enableUICommandRouting()
        bindSelectionCallback()
        rebuildTabs()
        startObservingToolbarStateIfNeeded()
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        inspectorController.connect(to: pageWebView)
        syncNativeSelection(with: inspectorController.selectedTabID)
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
        guard
            let identifier = tabViewItem?.identifier as? String
        else {
            return
        }
        inspectorController.synchronizeSelectedTabFromNativeUI(identifier)
        updateToolbarState()
    }

    private func rebuildTabs() {
        inspectorController.configureTabs(tabDescriptors.map(\.sessionTabDefinition))
        let context = WITabContext(
            controller: inspectorController,
            networkQueryModel: networkQueryModel
        )
        tabViewItems = tabDescriptors.map { descriptor in
            let viewController = descriptor.makeViewController(context: context)
            let item = NSTabViewItem(viewController: viewController)
            item.identifier = descriptor.id
            item.label = descriptor.title
            item.image = NSImage(systemSymbolName: descriptor.systemImage, accessibilityDescription: descriptor.title)
            return item
        }
        syncNativeSelection(with: inspectorController.selectedTabID)
        refreshTabPickerState()
    }

    private func bindSelectionCallback() {
        inspectorController.onSelectedTabIDChange = { [weak self] tabID in
            guard let self else { return }
            self.syncNativeSelection(with: tabID)
            self.synchronizeSelectedEntryObservation()
            self.scheduleToolbarStateUpdate()
        }
    }

    private func syncNativeSelection(with tabID: WITabDescriptor.ID?) {
        guard tabDescriptors.isEmpty == false else {
            refreshTabPickerState()
            return
        }
        // During rebuild, selection callbacks can arrive before NSTabViewItem creation.
        // Avoid touching selectedTabViewItemIndex while no tab items exist.
        let availableTabCount = min(tabDescriptors.count, tabViewItems.count)
        guard availableTabCount > 0 else {
            return
        }

        if let tabID,
           let index = tabDescriptors.firstIndex(where: { $0.id == tabID }),
           index < availableTabCount {
            if selectedTabViewItemIndex != index {
                selectedTabViewItemIndex = index
            }
            refreshTabPickerState()
            return
        }

        let resolvedIndex = (0..<availableTabCount).contains(selectedTabViewItemIndex) ? selectedTabViewItemIndex : 0
        if selectedTabViewItemIndex != resolvedIndex {
            selectedTabViewItemIndex = resolvedIndex
        }
        inspectorController.synchronizeSelectedTabFromNativeUI(tabDescriptors[resolvedIndex].id)
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
            inspectorController.observe(
                \.selectedTabID,
                options: [.removeDuplicates]
            ) { [weak self] _ in
                self?.scheduleToolbarStateUpdate()
            }
        )
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
                [\.selectedEntry]
            ) { [weak self] in
                self?.synchronizeSelectedEntryObservation()
                self?.scheduleToolbarStateUpdate()
            }
        )
        toolbarObservationHandles.append(
            inspectorController.network.store.observeTask(
                [\.entries]
            ) { [weak self] in
                self?.synchronizeSelectedEntryObservation()
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
        synchronizeSelectedEntryObservation()
    }

    private func stopObservingToolbarState() {
        hasStartedObservingToolbarState = false
        selectedEntryBodyObservedEntryID = nil

        for handle in toolbarObservationHandles {
            handle.cancel()
        }
        toolbarObservationHandles.removeAll()

        for handle in selectedEntryObservationHandles {
            handle.cancel()
        }
        selectedEntryObservationHandles.removeAll()

        for handle in selectedEntryBodyFetchStateHandles {
            handle.cancel()
        }
        selectedEntryBodyFetchStateHandles.removeAll()
    }

    private func scheduleToolbarStateUpdate() {
        toolbarUpdateCoalescer.schedule { [weak self] in
            self?.updateToolbarState()
        }
    }

    private func synchronizeSelectedEntryObservation() {
        let selectedEntry = inspectorController.network.selectedEntry
        let selectedEntryID = selectedEntry?.id
        guard selectedEntryBodyObservedEntryID != selectedEntryID else {
            return
        }
        selectedEntryBodyObservedEntryID = selectedEntryID

        for handle in selectedEntryObservationHandles {
            handle.cancel()
        }
        selectedEntryObservationHandles.removeAll()
        for handle in selectedEntryBodyFetchStateHandles {
            handle.cancel()
        }
        selectedEntryBodyFetchStateHandles.removeAll()

        guard let selectedEntry else {
            return
        }

        selectedEntryObservationHandles.append(
            selectedEntry.observeTask(
                [\.requestBody]
            ) { [weak self, weak selectedEntry] in
                guard let self else { return }
                self.scheduleToolbarStateUpdate()
                guard let selectedEntry else { return }
                self.synchronizeSelectedEntryBodyFetchStateObservation(for: selectedEntry)
            }
        )
        selectedEntryObservationHandles.append(
            selectedEntry.observeTask(
                [\.responseBody]
            ) { [weak self, weak selectedEntry] in
                guard let self else { return }
                self.scheduleToolbarStateUpdate()
                guard let selectedEntry else { return }
                self.synchronizeSelectedEntryBodyFetchStateObservation(for: selectedEntry)
            }
        )
        synchronizeSelectedEntryBodyFetchStateObservation(for: selectedEntry)
    }

    private func synchronizeSelectedEntryBodyFetchStateObservation(for selectedEntry: NetworkEntry) {
        for handle in selectedEntryBodyFetchStateHandles {
            handle.cancel()
        }
        selectedEntryBodyFetchStateHandles.removeAll()

        if let requestBody = selectedEntry.requestBody {
            selectedEntryBodyFetchStateHandles.append(
                requestBody.observeTask(
                    [\.fetchState]
                ) { [weak self] in
                    self?.scheduleToolbarStateUpdate()
                }
            )
        }

        if let responseBody = selectedEntry.responseBody {
            selectedEntryBodyFetchStateHandles.append(
                responseBody.observeTask(
                    [\.fetchState]
                ) { [weak self] in
                    self?.scheduleToolbarStateUpdate()
                }
            )
        }
    }

    private func updateToolbarLayout() {
        guard let toolbar = appKitToolbar else {
            return
        }

        let desiredIdentifiers: [NSToolbarItem.Identifier]
        switch inspectorController.selectedTabID {
        case Self.domTabID:
            desiredIdentifiers = [.wiTabPicker, .flexibleSpace, .wiDOMPick, .wiDOMReload]
        case Self.networkTabID:
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
            fetchBodyItem.isEnabled = Self.canFetchSelectedBodies(in: inspectorController.network)
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

        let titles = tabDescriptors.map(\.title)
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
        if let selectedTabID = inspectorController.selectedTabID,
           let index = tabDescriptors.firstIndex(where: { $0.id == selectedTabID }) {
            return index
        }
        if (0..<tabDescriptors.count).contains(selectedTabViewItemIndex) {
            return selectedTabViewItemIndex
        }
        return 0
    }

    private static func canFetchSelectedBodies(in networkInspector: WINetworkModel) -> Bool {
        guard let entry = networkInspector.selectedEntry else {
            return false
        }

        if let requestBody = entry.requestBody, requestBody.canFetchBody {
            return true
        }
        if let responseBody = entry.responseBody, responseBody.canFetchBody {
            return true
        }
        return false
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
        Task {
            guard let entry = inspectorController.network.selectedEntry else { return }

            if let requestBody = entry.requestBody {
                await inspectorController.network.fetchBodyIfNeeded(for: entry, body: requestBody, force: true)
            }
            if let responseBody = entry.responseBody {
                await inspectorController.network.fetchBodyIfNeeded(for: entry, body: responseBody, force: true)
            }
            guard !Task.isCancelled else {
                return
            }
            updateToolbarState()
        }
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
        guard selectedIndex < tabDescriptors.count, selectedIndex < tabViewItems.count else {
            refreshTabPickerState()
            return
        }

        let selectedTabID = tabDescriptors[selectedIndex].id
        if selectedTabViewItemIndex != selectedIndex {
            selectedTabViewItemIndex = selectedIndex
        }
        inspectorController.synchronizeSelectedTabFromNativeUI(selectedTabID)
        updateToolbarState()
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
            let labels = tabDescriptors.map(\.title)
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

    private static func normalizeAppKitTabs(_ tabs: [WITabDescriptor]) -> [WITabDescriptor] {
        let hasDOMTab = tabs.contains(where: { $0.id == "wi_dom" })
        guard hasDOMTab else {
            return tabs
        }
        return tabs.filter { $0.id != "wi_element" }
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
        let session = WISession()
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
