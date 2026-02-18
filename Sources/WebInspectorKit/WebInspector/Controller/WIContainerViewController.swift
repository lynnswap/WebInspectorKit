import WebKit

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
    public private(set) var inspectorController: WISessionController

    private weak var pageWebView: WKWebView?
    private var tabDescriptors: [WIPaneDescriptor]

    public init(
        _ inspectorController: WISessionController,
        webView: WKWebView?,
        tabs: [WIPaneDescriptor] = [.dom(), .element(), .network()]
    ) {
        self.inspectorController = inspectorController
        self.pageWebView = webView
        self.tabDescriptors = tabs
        super.init(nibName: nil, bundle: nil)
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
        tabStyle = .segmentedControlOnTop

        bindSelectionCallback()
        rebuildTabs()
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        inspectorController.connect(to: pageWebView)
        syncNativeSelection(with: inspectorController.selectedTabID)
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
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
    }

    private func bindSelectionCallback() {
        inspectorController.onSelectedTabIDChange = { [weak self] tabID in
            guard let self else { return }
            self.syncNativeSelection(with: tabID)
        }
    }

    private func syncNativeSelection(with tabID: WIPaneDescriptor.ID?) {
        guard tabDescriptors.isEmpty == false else {
            return
        }

        if let tabID,
           let index = tabDescriptors.firstIndex(where: { $0.id == tabID }) {
            if selectedTabViewItemIndex != index {
                selectedTabViewItemIndex = index
            }
            return
        }

        let resolvedIndex = tabDescriptors.indices.contains(selectedTabViewItemIndex) ? selectedTabViewItemIndex : 0
        if selectedTabViewItemIndex != resolvedIndex {
            selectedTabViewItemIndex = resolvedIndex
        }
        inspectorController.synchronizeSelectedTabFromNativeUI(tabDescriptors[resolvedIndex].id)
    }
}

#endif
