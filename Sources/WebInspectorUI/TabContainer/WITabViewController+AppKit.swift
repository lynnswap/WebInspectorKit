import WebKit
import ObservationBridge
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(AppKit)
import AppKit
import WebInspectorBridge

@MainActor
public final class WITabViewController: NSViewController, NSToolbarDelegate {
    private static let toolbarIdentifier = NSToolbar.Identifier("WITabToolbar")
    private final class ControllerSwapRequest {}

    public private(set) var inspectorController: WIInspectorController
    private var requestedTabs: [WITab]
    private var requestedPageWebView: WKWebView?
    private let synthesizedAppKitDOMTab = WITab.dom()

    private var networkQueryModel: WINetworkQueryModel
    private weak var appKitToolbar: NSToolbar?
    private weak var tabPickerControl: NSSegmentedControl?
    private weak var networkSearchField: NSSearchField?
    private var hasStartedObservingToolbarState = false
    private var isDOMSelectionActionPending = false
    private var controllerSwapTask: Task<Void, Never>?
    private var activeControllerSwapRequest: ControllerSwapRequest?
    private var uiStateApplyTask: Task<Void, Never>?
    private var runtimeStateSyncPending = false
    private var needsRuntimeStateSyncAfterSwap = false
    private var shouldDriveRuntimeStateFromUI = false
    private var toolbarObservationHandles: Set<ObservationHandle> = []
    // Keep coalescing because toolbar updates can be triggered by many state sources in quick bursts.
    private let toolbarUpdateCoalescer = UIUpdateCoalescer()
    private var isApplyingPickerSelection = false
    private var sessionObservationHandles: Set<ObservationHandle> = []

    private let contentContainerView = NSView(frame: .zero)
    private var visibleContentViewController: NSViewController?
    private var visibleContentTabObjectID: ObjectIdentifier?
    private var visibleContentTabIdentifier: String?
    private var contentViewControllerByTabObjectID: [ObjectIdentifier: NSViewController] = [:]
    private var model: WIModel { inspectorController.model }

    public init(
        _ inspectorController: WIInspectorController,
        webView: WKWebView?,
        tabs: [WITab] = [.dom(), .network()]
    ) {
        self.inspectorController = inspectorController
        self.requestedTabs = tabs
        self.requestedPageWebView = webView
        self.networkQueryModel = WINetworkQueryModel(inspector: inspectorController.network)
        super.init(nibName: nil, bundle: nil)
        inspectorController.model.setTabsFromUI(tabs)
    }

    public convenience init(
        _ model: WIModel,
        webView: WKWebView?,
        tabs: [WITab] = [.dom(), .network()]
    ) {
        self.init(WIInspectorController(model: model), webView: webView, tabs: tabs)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        controllerSwapTask?.cancel()
        uiStateApplyTask?.cancel()
        sessionObservationHandles.removeAll()
        stopObservingToolbarState()
    }

    public override func loadView() {
        let rootView = NSView(frame: .zero)
        rootView.translatesAutoresizingMaskIntoConstraints = false

        contentContainerView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(contentContainerView)

        NSLayoutConstraint.activate([
            contentContainerView.topAnchor.constraint(equalTo: rootView.topAnchor),
            contentContainerView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            contentContainerView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            contentContainerView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        view = rootView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        bindSessionTabs()
        startObservingToolbarStateIfNeeded()
        render()
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        shouldDriveRuntimeStateFromUI = true
        scheduleRuntimeStateSync()
        installToolbarIfNeeded()
        startObservingToolbarStateIfNeeded()
        render()
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
        guard Self.window(for: view) == nil else {
            return
        }
        shouldDriveRuntimeStateFromUI = false
        scheduleRuntimeStateSync()
        tearDownToolbarStateIfNeeded()
    }

    public func setPageWebView(_ webView: WKWebView?) {
        requestedPageWebView = webView
        if isViewLoaded {
            scheduleRuntimeStateSync()
        }
    }

    public func setInspectorController(_ inspectorController: WIInspectorController) {
        guard self.inspectorController !== inspectorController else {
            return
        }

        let previousController = self.inspectorController
        // Keep the shared reference so later swap requests still chain behind
        // any host-state apply task that was already in flight.
        let activeUIStateApplyTask = uiStateApplyTask
        runtimeStateSyncPending = false
        controllerSwapTask?.cancel()
        invalidatePresentationStateForControllerSwap()
        let request = ControllerSwapRequest()
        activeControllerSwapRequest = request
        controllerSwapTask = Task { [weak self, request] in
            defer {
                if let self, self.activeControllerSwapRequest === request {
                    self.controllerSwapTask = nil
                    self.activeControllerSwapRequest = nil
                    if self.needsRuntimeStateSyncAfterSwap {
                        self.needsRuntimeStateSyncAfterSwap = false
                        self.scheduleRuntimeStateSync()
                    }
                }
            }
            await activeUIStateApplyTask?.value
            await previousController.finalize()
            guard
                let self,
                Task.isCancelled == false,
                self.activeControllerSwapRequest === request,
                self.inspectorController === previousController
            else {
                return
            }
            let currentRequestedTabs = self.requestedTabs
            let currentPageWebView = self.requestedPageWebView
            let currentSelectedTab = previousController.model.selectedTab
            let currentHasExplicitTabsConfiguration = previousController.model.hasExplicitTabsConfiguration
            self.applyInspectorController(
                inspectorController,
                requestedTabs: currentRequestedTabs,
                tabsExplicitlyConfigured: currentHasExplicitTabsConfiguration,
                selectedTab: currentSelectedTab,
                pageWebView: currentPageWebView,
                syncRuntimeState: false
            )
            await inspectorController.applyHostState(
                pageWebView: currentPageWebView,
                visibility: self.shouldDriveRuntimeStateFromUI ? .visible : .hidden
            )
        }
    }

    private func invalidatePresentationStateForControllerSwap() {
        setVisibleContentViewController(nil, for: nil)
        contentViewControllerByTabObjectID.removeAll()
        stopObservingToolbarState()
    }

    public func setInspectorController(_ model: WIModel) {
        setInspectorController(WIInspectorController(model: model))
    }

    public func setTabs(_ tabs: [WITab]) {
        requestedTabs = tabs
        model.setTabsFromUI(tabs)
        scheduleRuntimeStateSync()
        if isViewLoaded {
            render()
        }
    }

    var displayedTabIDsForTesting: [String] {
        displayTabsForCurrentState().map(\.identifier)
    }

    var selectedTabIdentifierForTesting: String? {
        resolvedDisplayedSelection(in: displayTabsForCurrentState())?.identifier
    }

    var visibleContentTabIDForTesting: String? {
        visibleContentTabIdentifier
    }

    var hasVisibleContentForTesting: Bool {
        visibleContentViewController != nil
    }

    var visibleContentViewControllerForTesting: NSViewController? {
        visibleContentViewController
    }

    private func bindSessionTabs() {
        sessionObservationHandles.removeAll()

        model.observe(\.tabs) { [weak self] _ in
            self?.render()
        }
        .store(in: &sessionObservationHandles)

        model.observe(\.selectedTab) { [weak self] _ in
            self?.render()
            self?.scheduleRuntimeStateSync()
        }
        .store(in: &sessionObservationHandles)
    }

    private func render() {
        normalizeModelSelectionForHiddenElementIfNeeded()
        let displayTabs = displayTabsForCurrentState()
        pruneContentControllerCache(for: displayTabs)
        renderSelectedContent(displayTabs: displayTabs)
        updateToolbarState()
    }

    private func renderSelectedContent(displayTabs: [WITab]) {
        guard displayTabs.isEmpty == false else {
            setVisibleContentViewController(nil, for: nil)
            return
        }

        guard let selectedTab = resolvedDisplayedSelection(in: displayTabs) else {
            assertionFailure("tabs is not empty but resolved selected tab is nil")
            setVisibleContentViewController(nil, for: nil)
            return
        }

        guard let rootViewController = makeTabRootViewController(for: selectedTab) else {
            assertionFailure("No content view controller for selected tab: \(selectedTab.identifier)")
            setVisibleContentViewController(nil, for: nil)
            return
        }

        rootViewController.loadViewIfNeeded()
        setVisibleContentViewController(rootViewController, for: selectedTab)
    }

    private func displayTabsForCurrentState() -> [WITab] {
        let tabs = model.tabs
        let hasDOMTab = tabs.contains(where: { $0.identifier == WITab.domTabID })
        var didInsertSyntheticDOM = false
        var displayTabs: [WITab] = []
        displayTabs.reserveCapacity(tabs.count)

        for tab in tabs {
            guard tab.identifier == WITab.elementTabID else {
                displayTabs.append(tab)
                continue
            }

            if hasDOMTab {
                continue
            }

            if didInsertSyntheticDOM == false {
                displayTabs.append(synthesizedAppKitDOMTab)
                didInsertSyntheticDOM = true
            }
        }

        return displayTabs
    }

    private func normalizeModelSelectionForHiddenElementIfNeeded() {
        guard model.selectedTab?.identifier == WITab.elementTabID else {
            return
        }
        guard let domTab = model.tabs.first(where: { $0.identifier == WITab.domTabID }) else {
            return
        }
        model.setSelectedTabFromUI(domTab)
        scheduleRuntimeStateSync()
    }

    private func resolvedDisplayedSelection(in displayTabs: [WITab]) -> WITab? {
        guard displayTabs.isEmpty == false else {
            return nil
        }

        if let selectedTab = model.selectedTab {
            if let exactMatch = displayTabs.first(where: { $0 === selectedTab }) {
                return exactMatch
            }

            if selectedTab.identifier == WITab.elementTabID,
               let domDisplayTab = displayTabs.first(where: { $0.identifier == WITab.domTabID }) {
                return domDisplayTab
            }

            if let identifierMatch = displayTabs.first(where: { $0.identifier == selectedTab.identifier }) {
                return identifierMatch
            }
        }

        guard let fallback = displayTabs.first else {
            return nil
        }
        if let fallbackModelTab = resolvedModelTab(forDisplayedTab: fallback) {
            model.setSelectedTabFromUI(fallbackModelTab)
            scheduleRuntimeStateSync()
        }
        return fallback
    }

    private func resolvedModelTab(forDisplayedTab displayedTab: WITab) -> WITab? {
        if displayedTab === synthesizedAppKitDOMTab {
            if let domTab = model.tabs.first(where: { $0.identifier == WITab.domTabID }) {
                return domTab
            }
            return model.tabs.first(where: { $0.identifier == WITab.elementTabID })
        }

        if model.tabs.contains(where: { $0 === displayedTab }) {
            return displayedTab
        }
        return model.tabs.first(where: { $0.identifier == displayedTab.identifier })
    }

    private func setVisibleContentViewController(_ nextViewController: NSViewController?, for tab: WITab?) {
        let nextTabObjectID = tab.map(ObjectIdentifier.init)
        let nextTabIdentifier = tab?.identifier
        if visibleContentViewController === nextViewController {
            visibleContentTabObjectID = nextTabObjectID
            visibleContentTabIdentifier = nextTabIdentifier
            return
        }

        if let current = visibleContentViewController {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }

        visibleContentViewController = nextViewController
        visibleContentTabObjectID = nextTabObjectID
        visibleContentTabIdentifier = nextTabIdentifier

        guard let nextViewController else {
            return
        }

        addChild(nextViewController)
        let hostedView = nextViewController.view
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        contentContainerView.addSubview(hostedView)

        NSLayoutConstraint.activate([
            hostedView.topAnchor.constraint(equalTo: contentContainerView.topAnchor),
            hostedView.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor),
            hostedView.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor)
        ])
    }

    private func pruneContentControllerCache(for tabs: [WITab]) {
        let activeTabObjectIDs = Set(tabs.map(ObjectIdentifier.init))
        if let visibleContentTabObjectID,
           activeTabObjectIDs.contains(visibleContentTabObjectID) == false {
            setVisibleContentViewController(nil, for: nil)
        }
        contentViewControllerByTabObjectID = contentViewControllerByTabObjectID.filter { activeTabObjectIDs.contains($0.key) }
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

        inspectorController.dom.observe(
            \.hasPageWebView,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleToolbarStateUpdate()
        }
        .store(in: &toolbarObservationHandles)
        inspectorController.dom.observe(
            \.isSelectingElement,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleToolbarStateUpdate()
        }
        .store(in: &toolbarObservationHandles)
        inspectorController.network.store.observe(
            [\.entries]
        ) { [weak self] in
            self?.scheduleToolbarStateUpdate()
        }
        .store(in: &toolbarObservationHandles)
        networkQueryModel.observe(
            \.searchText,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleToolbarStateUpdate()
        }
        .store(in: &toolbarObservationHandles)
        networkQueryModel.observe(
            \.activeFilters,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleToolbarStateUpdate()
        }
        .store(in: &toolbarObservationHandles)
        networkQueryModel.observe(
            \.effectiveFilters,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleToolbarStateUpdate()
        }
        .store(in: &toolbarObservationHandles)
    }

    private func stopObservingToolbarState() {
        hasStartedObservingToolbarState = false
        toolbarObservationHandles.removeAll()
    }

    private func tearDownToolbarStateIfNeeded() {
        toolbarUpdateCoalescer.cancel()
        stopObservingToolbarState()
        appKitToolbar?.delegate = nil
        appKitToolbar = nil
        tabPickerControl = nil
        networkSearchField = nil
    }

    private func scheduleToolbarStateUpdate() {
        toolbarUpdateCoalescer.schedule { [weak self] in
            self?.updateToolbarState()
        }
    }

    private func updateToolbarLayout() {
        guard Self.window(for: view) != nil else {
            return
        }
        guard let toolbar = appKitToolbar else {
            return
        }

        let selectedDisplayTab = resolvedDisplayedSelection(in: displayTabsForCurrentState())
        let desiredIdentifiers: [NSToolbarItem.Identifier]
        switch selectedDisplayTab?.identifier {
        case WITab.domTabID:
            desiredIdentifiers = [.wiTabPicker, .flexibleSpace, .wiDOMPick, .wiDOMReload]
        case WITab.networkTabID:
            desiredIdentifiers = [
                .wiTabPicker,
                .wiNetworkFilter,
                .wiNetworkClear,
                .wiNetworkSearch,
                .flexibleSpace
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
        guard Self.window(for: view) != nil else {
            return
        }
        updateToolbarLayout()
        refreshTabPickerState()
        guard let toolbar = appKitToolbar else {
            return
        }

        if let pickItem = toolbar.items.first(where: { $0.itemIdentifier == .wiDOMPick }) {
            pickItem.isEnabled = inspectorController.dom.hasPageWebView && !isDOMSelectionActionPending
            pickItem.image = Self.pickToolbarImage(
                isSelecting: inspectorController.dom.isSelectingElement || isDOMSelectionActionPending
            )
        }

        if let reloadItem = toolbar.items.first(where: { $0.itemIdentifier == .wiDOMReload }) {
            reloadItem.isEnabled = inspectorController.dom.hasPageWebView
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

        let displayTabs = displayTabsForCurrentState()
        let titles = displayTabs.map(\.title)
        if tabPickerControl.segmentCount != titles.count {
            tabPickerControl.segmentCount = titles.count
        }
        for (index, title) in titles.enumerated() {
            tabPickerControl.setLabel(title, forSegment: index)
            tabPickerControl.setWidth(0, forSegment: index)
        }

        guard titles.isEmpty == false else {
            isApplyingPickerSelection = true
            tabPickerControl.selectedSegment = -1
            isApplyingPickerSelection = false
            tabPickerControl.isEnabled = false
            return
        }

        tabPickerControl.isEnabled = true

        let selectedIndex = resolvedTabPickerSelectionIndex(in: displayTabs)
        if tabPickerControl.selectedSegment != selectedIndex {
            isApplyingPickerSelection = true
            tabPickerControl.selectedSegment = selectedIndex
            isApplyingPickerSelection = false
        }
    }

    private func resolvedTabPickerSelectionIndex(in displayTabs: [WITab]) -> Int {
        guard displayTabs.isEmpty == false else {
            return -1
        }
        if let selectedDisplayTab = resolvedDisplayedSelection(in: displayTabs) {
            if let identityIndex = displayTabs.firstIndex(where: { $0 === selectedDisplayTab }) {
                return identityIndex
            }
            if let identifierIndex = displayTabs.firstIndex(where: { $0.identifier == selectedDisplayTab.identifier }) {
                return identifierIndex
            }
        }
        return 0
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

    private func applyInspectorController(
        _ inspectorController: WIInspectorController,
        requestedTabs: [WITab],
        tabsExplicitlyConfigured: Bool,
        selectedTab: WITab?,
        pageWebView: WKWebView?,
        syncRuntimeState: Bool
    ) {
        self.inspectorController = inspectorController
        self.requestedTabs = requestedTabs
        self.requestedPageWebView = pageWebView
        self.networkQueryModel = WINetworkQueryModel(inspector: inspectorController.network)
        let model = inspectorController.model
        model.setTabsFromUI(
            requestedTabs,
            marksExplicitConfiguration: tabsExplicitlyConfigured
        )
        if let selectedTab {
            _ = model.projectSelectedTabFromUI(selectedTab)
        }

        setVisibleContentViewController(nil, for: nil)
        contentViewControllerByTabObjectID.removeAll()

        stopObservingToolbarState()
        guard isViewLoaded else {
            return
        }

        bindSessionTabs()
        startObservingToolbarStateIfNeeded()
        render()
        _ = syncRuntimeState
    }

    private func scheduleRuntimeStateSync() {
        guard controllerSwapTask == nil else {
            needsRuntimeStateSyncAfterSwap = true
            return
        }
        runtimeStateSyncPending = true
        guard uiStateApplyTask == nil else {
            return
        }
        var applyTask: Task<Void, Never>?
        applyTask = Task.immediateIfAvailable { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.uiStateApplyTask = nil
                if self.runtimeStateSyncPending {
                    self.scheduleRuntimeStateSync()
                }
            }
            while self.runtimeStateSyncPending {
                self.runtimeStateSyncPending = false
                let inspectorController = self.inspectorController
                await inspectorController.applyHostState(
                    pageWebView: self.requestedPageWebView,
                    visibility: self.shouldDriveRuntimeStateFromUI ? .visible : .hidden
                )
            }
        }
        uiStateApplyTask = applyTask
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
        guard isDOMSelectionActionPending == false else {
            return
        }

        isDOMSelectionActionPending = true
        updateToolbarState()

        Task.immediateIfAvailable { [weak self, inspectorController] in
            defer {
                if let self {
                    self.isDOMSelectionActionPending = false
                    self.updateToolbarState()
                }
            }
            if inspectorController.dom.isSelectingElement {
                await inspectorController.dom.cancelSelectionMode()
            } else {
                _ = try? await inspectorController.dom.beginSelectionMode()
            }
        }
    }

    @objc
    private func handleDOMReloadToolbarAction(_ sender: Any?) {
        Task {
            await inspectorController.dom.reloadInspector()
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
        Task.immediateIfAvailable { [inspectorController] in
            await inspectorController.network.clear()
        }
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

        let displayTabs = displayTabsForCurrentState()
        guard selectedIndex < displayTabs.count else {
            refreshTabPickerState()
            return
        }

        let selectedDisplayTab = displayTabs[selectedIndex]
        if let selectedModelTab = resolvedModelTab(forDisplayedTab: selectedDisplayTab) {
            model.setSelectedTabFromUI(selectedModelTab)
            scheduleRuntimeStateSync()
        }
        render()
    }

    private func makeTabRootViewController(for tab: WITab) -> NSViewController? {
        let tabObjectID = ObjectIdentifier(tab)
        if let cached = contentViewControllerByTabObjectID[tabObjectID] {
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
                viewController = WIPlaceholderTabContentViewController()
            }
        }

        guard let viewController else {
            return nil
        }

        contentViewControllerByTabObjectID[tabObjectID] = viewController
        return viewController
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .wiTabPicker,
            .wiDOMPick,
            .wiDOMReload,
            .wiNetworkFilter,
            .wiNetworkClear,
            .wiNetworkSearch,
            .flexibleSpace
        ]
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.wiTabPicker, .flexibleSpace, .wiDOMPick, .wiDOMReload]
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .wiTabPicker:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.target = self
            item.isBordered = true
            let labels = displayTabsForCurrentState().map(\.title)
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
        default:
            return nil
        }
    }
}

@MainActor
private final class WIPlaceholderTabContentViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: .zero)
    }
}

private extension NSToolbarItem.Identifier {
    static let wiTabPicker = NSToolbarItem.Identifier("WIContainerToolbar.TabPicker")
    static let wiDOMPick = NSToolbarItem.Identifier("WIContainerToolbar.DOMPick")
    static let wiDOMReload = NSToolbarItem.Identifier("WIContainerToolbar.DOMReload")
    static let wiNetworkFilter = NSToolbarItem.Identifier("WIContainerToolbar.NetworkFilter")
    static let wiNetworkClear = NSToolbarItem.Identifier("WIContainerToolbar.NetworkClear")
    static let wiNetworkSearch = NSToolbarItem.Identifier("WIContainerToolbar.NetworkSearch")
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI

extension WITabViewController {
    func waitForRuntimeStateSyncForTesting() async {
        await controllerSwapTask?.value
        await uiStateApplyTask?.value
    }
}

#Preview("Tab Container (AppKit)") {
    WIAppKitPreviewContainer {
        let session = WIInspectorController()
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
