import WebKit
import ObservationsCompat

#if canImport(UIKit)
import UIKit

@MainActor
public final class WIContainerViewController: UITabBarController, UITabBarControllerDelegate {
    public private(set) var inspectorController: WISessionController

    private weak var pageWebView: WKWebView?
    private var tabDescriptors: [WIPaneDescriptor]
    private var canonicalIdentifierByUITabIdentifier: [String: WIPaneDescriptor.ID] = [:]
    private var primaryUITabIdentifierByCanonicalIdentifier: [WIPaneDescriptor.ID: String] = [:]
    private var uiTabByIdentifier: [String: UITab] = [:]
    private var orderedUITabIdentifiers: [String] = []
    private var isApplyingSelectionFromController = false

    public init(
        _ inspectorController: WISessionController,
        webView: WKWebView?,
        tabs: [WIPaneDescriptor] = [.dom(), .element(), .network()]
    ) {
        self.inspectorController = inspectorController
        self.pageWebView = webView
        self.tabDescriptors = tabs
        super.init(nibName: nil, bundle: nil)
        self.view.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public func setPageWebView(_ webView: WKWebView?) {
        pageWebView = webView
        if isViewLoaded {
            inspectorController.connect(to: webView)
        }
    }

    public func setInspectorController(_ inspectorController: WISessionController) {
        guard self.inspectorController !== inspectorController else {
            return
        }
        let previousController = self.inspectorController
        previousController.onSelectedTabIDChange = nil
        previousController.disconnect()
        self.inspectorController = inspectorController
        bindSelectionCallback()
        if isViewLoaded {
            rebuildTabs()
            inspectorController.connect(to: pageWebView)
        }
    }

    public func setTabs(_ tabs: [WIPaneDescriptor]) {
        tabDescriptors = tabs
        inspectorController.configureTabs(tabDescriptors)
        if isViewLoaded {
            rebuildTabs()
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        tabBar.scrollEdgeAppearance = tabBar.standardAppearance

        bindSelectionCallback()
        rebuildTabs()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        inspectorController.connect(to: pageWebView)
        syncNativeSelection(with: inspectorController.selectedTabID)
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if view.window == nil {
            inspectorController.suspend()
        }
    }

    private func rebuildTabs() {
        inspectorController.configureTabs(tabDescriptors)
        let context = WIPaneContext(controller: inspectorController)
        var usedUITabIdentifiers = Set<String>()
        var builtTabs: [UITab] = []
        builtTabs.reserveCapacity(tabDescriptors.count)

        canonicalIdentifierByUITabIdentifier = [:]
        primaryUITabIdentifierByCanonicalIdentifier = [:]
        uiTabByIdentifier = [:]
        orderedUITabIdentifiers = []
        orderedUITabIdentifiers.reserveCapacity(tabDescriptors.count)

        for (index, descriptor) in tabDescriptors.enumerated() {
            let viewController = descriptor.makeViewController(context: context)
            let uiIdentifier = makeUniqueUITabIdentifier(
                for: descriptor.id,
                index: index,
                used: &usedUITabIdentifiers
            )
            let tab = UITab(
                title: descriptor.title,
                image: UIImage(systemName: descriptor.systemImage),
                identifier: uiIdentifier
            ) { _ in
                viewController
            }
            canonicalIdentifierByUITabIdentifier[uiIdentifier] = descriptor.id
            if primaryUITabIdentifierByCanonicalIdentifier[descriptor.id] == nil {
                primaryUITabIdentifierByCanonicalIdentifier[descriptor.id] = uiIdentifier
            }
            uiTabByIdentifier[uiIdentifier] = tab
            orderedUITabIdentifiers.append(uiIdentifier)
            builtTabs.append(tab)
        }

        setTabs(builtTabs, animated: false)
        syncNativeSelection(with: inspectorController.selectedTabID)
    }

    private func bindSelectionCallback() {
        inspectorController.onSelectedTabIDChange = { [weak self] tabID in
            guard let self else { return }
            self.syncNativeSelection(with: tabID)
        }
    }

    private func syncNativeSelection(with tabID: WIPaneDescriptor.ID?) {
        guard orderedUITabIdentifiers.isEmpty == false else {
            return
        }

        if let tabID,
           let uiIdentifier = primaryUITabIdentifierByCanonicalIdentifier[tabID] {
            selectTabIfNeeded(withUIIdentifier: uiIdentifier)
            return
        }

        let resolvedUIIdentifier: String
        if let currentlySelectedUIIdentifier = selectedTab?.identifier,
           canonicalIdentifierByUITabIdentifier[currentlySelectedUIIdentifier] != nil {
            resolvedUIIdentifier = currentlySelectedUIIdentifier
        } else {
            resolvedUIIdentifier = orderedUITabIdentifiers[0]
        }

        selectTabIfNeeded(withUIIdentifier: resolvedUIIdentifier)
        if let canonicalTabID = canonicalIdentifierByUITabIdentifier[resolvedUIIdentifier] {
            inspectorController.synchronizeSelectedTabFromNativeUI(canonicalTabID)
        }
    }

    private func selectTabIfNeeded(withUIIdentifier uiIdentifier: String) {
        guard
            selectedTab?.identifier != uiIdentifier,
            let tab = uiTabByIdentifier[uiIdentifier]
        else {
            return
        }

        isApplyingSelectionFromController = true
        selectedTab = tab
        isApplyingSelectionFromController = false
    }

    private func makeUniqueUITabIdentifier(
        for canonicalIdentifier: WIPaneDescriptor.ID,
        index: Int,
        used: inout Set<String>
    ) -> String {
        let base = canonicalIdentifier.isEmpty ? "tab_\(index)" : canonicalIdentifier
        if used.insert(base).inserted {
            return base
        }

        var suffix = 2
        while true {
            let candidate = "\(base)__\(suffix)"
            if used.insert(candidate).inserted {
                return candidate
            }
            suffix += 1
        }
    }

    public func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        canonicalIdentifierByUITabIdentifier[tab.identifier] != nil
    }

    public func tabBarController(
        _ tabBarController: UITabBarController,
        didSelectTab selectedTab: UITab,
        previousTab: UITab?
    ) {
        guard isApplyingSelectionFromController == false else {
            return
        }

        guard let canonicalTabID = canonicalIdentifierByUITabIdentifier[selectedTab.identifier] else {
            return
        }
        guard inspectorController.selectedTabID != canonicalTabID else {
            return
        }
        inspectorController.synchronizeSelectedTabFromNativeUI(canonicalTabID)
    }
}

#elseif canImport(AppKit)
import AppKit

@MainActor
public final class WIContainerViewController: NSTabViewController {
    private struct AppKitToolbarObservedState: Sendable, Equatable {
        let selectedTabID: WIPaneDescriptor.ID?
        let domHasPageWebView: Bool
        let domIsSelectingElement: Bool
        let networkCanFetchBodies: Bool
    }

    private static let toolbarIdentifier = NSToolbar.Identifier("WIContainerToolbar")
    private static let domTabID = "wi_dom"
    private static let networkTabID = "wi_network"

    public private(set) var inspectorController: WISessionController

    private weak var pageWebView: WKWebView?
    private var tabDescriptors: [WIPaneDescriptor]
    private weak var appKitToolbar: NSToolbar?
    private weak var tabPickerControl: NSSegmentedControl?
    private var toolbarObservationTask: Task<Void, Never>?
    private var isApplyingPickerSelection = false

    public init(
        _ inspectorController: WISessionController,
        webView: WKWebView?,
        tabs: [WIPaneDescriptor] = [.dom(), .network()]
    ) {
        self.inspectorController = inspectorController
        self.pageWebView = webView
        self.tabDescriptors = Self.normalizeAppKitTabs(tabs)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        toolbarObservationTask?.cancel()
    }

    public func setPageWebView(_ webView: WKWebView?) {
        pageWebView = webView
        if isViewLoaded {
            inspectorController.connect(to: webView)
        }
    }

    public func setInspectorController(_ inspectorController: WISessionController) {
        guard self.inspectorController !== inspectorController else {
            return
        }
        let previousController = self.inspectorController
        previousController.onSelectedTabIDChange = nil
        previousController.disconnect()
        self.inspectorController = inspectorController
        bindSelectionCallback()
        stopObservingToolbarState()
        if isViewLoaded {
            rebuildTabs()
            inspectorController.connect(to: pageWebView)
            if view.window != nil {
                startObservingToolbarStateIfNeeded()
            }
            updateToolbarState()
        }
    }

    public func setTabs(_ tabs: [WIPaneDescriptor]) {
        tabDescriptors = Self.normalizeAppKitTabs(tabs)
        inspectorController.configureTabs(tabDescriptors)
        if isViewLoaded {
            rebuildTabs()
            updateToolbarState()
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .unspecified
        tabView.tabViewType = .noTabsNoBorder

        bindSelectionCallback()
        rebuildTabs()
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
        stopObservingToolbarState()
        if view.window == nil {
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
        inspectorController.configureTabs(tabDescriptors)
        let context = WIPaneContext(controller: inspectorController)
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
            self.updateToolbarState()
        }
    }

    private func syncNativeSelection(with tabID: WIPaneDescriptor.ID?) {
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
        guard let window = view.window else {
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
        guard toolbarObservationTask == nil else {
            return
        }

        let inspectorController = self.inspectorController
        toolbarObservationTask = Task { @MainActor [weak self] in
            let stream = makeObservationsCompatStream {
                AppKitToolbarObservedState(
                    selectedTabID: inspectorController.selectedTabID,
                    domHasPageWebView: inspectorController.dom.hasPageWebView,
                    domIsSelectingElement: inspectorController.dom.isSelectingElement,
                    networkCanFetchBodies: Self.canFetchSelectedBodies(in: inspectorController.network)
                )
            }
            for await _ in stream {
                guard !Task.isCancelled else {
                    break
                }
                self?.updateToolbarState()
            }
        }
    }

    private func stopObservingToolbarState() {
        toolbarObservationTask?.cancel()
        toolbarObservationTask = nil
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
            desiredIdentifiers = [.wiTabPicker, .flexibleSpace, .wiNetworkFetchBody]
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

    private static func canFetchSelectedBodies(in networkInspector: WINetworkPaneViewModel) -> Bool {
        guard
            let selectedEntryID = networkInspector.selectedEntryID,
            let entry = networkInspector.store.entry(forEntryID: selectedEntryID)
        else {
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
            guard
                let selectedEntryID = inspectorController.network.selectedEntryID,
                let entry = inspectorController.network.store.entry(forEntryID: selectedEntryID)
            else {
                return
            }

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
        [.wiTabPicker, .wiDOMPick, .wiDOMReload, .wiNetworkFetchBody, .flexibleSpace]
    }

    public override func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.wiTabPicker, .flexibleSpace, .wiDOMPick, .wiDOMReload]
    }

    public override func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.target = self
        item.isBordered = true

        switch itemIdentifier {
        case .wiTabPicker:
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
        case .wiDOMPick:
            item.label = wiLocalized("dom.controls.pick")
            item.paletteLabel = item.label
            item.toolTip = item.label
            item.image = Self.pickToolbarImage(isSelecting: inspectorController.dom.isSelectingElement)
            item.action = #selector(handleDOMPickToolbarAction(_:))
            return item
        case .wiDOMReload:
            item.label = wiLocalized("reload")
            item.paletteLabel = item.label
            item.toolTip = item.label
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: item.label)
            item.action = #selector(handleDOMReloadToolbarAction(_:))
            return item
        case .wiNetworkFetchBody:
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

    private static func normalizeAppKitTabs(_ tabs: [WIPaneDescriptor]) -> [WIPaneDescriptor] {
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
    static let wiNetworkFetchBody = NSToolbarItem.Identifier("WIContainerToolbar.NetworkFetchBody")
}

#endif
