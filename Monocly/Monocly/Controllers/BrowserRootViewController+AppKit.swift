#if canImport(AppKit)
import AppKit
@_spi(Monocly) import WebInspectorKit

@MainActor
final class BrowserRootViewController: NSViewController, NSToolbarDelegate, NSToolbarItemValidation {
    private enum InspectorSessionState {
        case connected
        case suspended
        case disconnected
    }

    private enum ToolbarItemIdentifier {
        static let navigation = NSToolbarItem.Identifier("Monocly.Toolbar.Navigation")
        static let inspector = NSToolbarItem.Identifier("Monocly.Toolbar.Inspector")
    }

    let store: BrowserStore
    let inspectorController: WIInspectorController
    let launchConfiguration: BrowserLaunchConfiguration

    private let hostedContentViewController: NSViewController
    private let pageViewController: BrowserPageViewController?
    private var storeObserverID: UUID?
    private var pendingWindowAttachmentTask: Task<Void, Never>?
    private var inspectorLifecycleTask: Task<Void, Never>?
    private var pendingInspectorSessionState: InspectorSessionState?
    private var isFinalizingInspectorSession = false
    private var transfersInspectorControllerLifecycleOnDeinit = false
    private weak var installedToolbar: NSToolbar?
    private weak var navigationItemGroup: NSToolbarItemGroup?

    private(set) var toolbarInstallationCountForTesting = 0

    init(
        store: BrowserStore? = nil,
        inspectorController: WIInspectorController? = nil,
        launchConfiguration: BrowserLaunchConfiguration,
        contentViewController: NSViewController? = nil
    ) {
        let resolvedStore = store ?? BrowserStore(url: launchConfiguration.initialURL)
        let resolvedInspectorController = inspectorController ?? WIInspectorController()
        let resolvedContentViewController = contentViewController
            ?? BrowserPageViewController(
                store: resolvedStore,
                inspectorController: resolvedInspectorController,
                launchConfiguration: launchConfiguration
            )

        self.store = resolvedStore
        self.inspectorController = resolvedInspectorController
        self.launchConfiguration = launchConfiguration
        self.hostedContentViewController = resolvedContentViewController
        self.pageViewController = resolvedContentViewController as? BrowserPageViewController

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        pendingWindowAttachmentTask?.cancel()
        inspectorLifecycleTask?.cancel()
        tearDownWindowIntegration()
        if transfersInspectorControllerLifecycleOnDeinit == false {
            inspectorController.tearDownForDeinit()
        }
    }

    override func loadView() {
        view = BrowserRootContainerView { [weak self] in
            self?.handleWindowAttachmentIfNeeded()
        }
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(hostedContentViewController)
        hostedContentViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostedContentViewController.view)
        NSLayoutConstraint.activate([
            hostedContentViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostedContentViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostedContentViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostedContentViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        startObservingStoreIfNeeded()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startObservingStoreIfNeeded()
        handleWindowAttachmentIfNeeded()
        requestInspectorSessionState(.connected)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        requestInspectorSessionState(.suspended)
        if view.window == nil {
            tearDownWindowIntegration()
        }
    }

    func finalizeInspectorSession() {
        guard isFinalizingInspectorSession == false else {
            return
        }
        isFinalizingInspectorSession = true
        tearDownWindowIntegration()
        requestInspectorSessionState(.disconnected)
    }

    func prepareForWindowClosurePreservingInspectorSession() {
        guard transfersInspectorControllerLifecycleOnDeinit == false else {
            return
        }
        transfersInspectorControllerLifecycleOnDeinit = true
        tearDownWindowIntegration()
        let inspectorController = inspectorController
        let store = store
        Task { @MainActor in
            await inspectorController.applyHostState(
                pageWebView: store.webView,
                visibility: .hidden
            )
        }
    }

    func finalizeInspectorSessionForWindowClosure() {
        guard isFinalizingInspectorSession == false else {
            return
        }
        isFinalizingInspectorSession = true
        transfersInspectorControllerLifecycleOnDeinit = true
        tearDownWindowIntegration()
        let inspectorController = inspectorController
        Task { @MainActor in
            await inspectorController.finalize()
        }
    }

    @objc
    private func handleOpenInspectorAction(_ sender: Any?) {
        _ = sender
        _ = BrowserInspectorCoordinator.present(
            from: view.window,
            browserStore: store,
            inspectorController: inspectorController,
            tabs: [.dom(), .network()]
        )
    }

    @objc
    private func handleNavigationSegment(_ sender: Any?) {
        guard let itemGroup = sender as? NSToolbarItemGroup else {
            return
        }

        defer {
            itemGroup.selectedIndex = -1
        }

        switch itemGroup.selectedIndex {
        case 0:
            store.goBack()
        case 1:
            store.goForward()
        default:
            break
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case ToolbarItemIdentifier.inspector:
            true
        default:
            true
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarItemIdentifier.navigation,
            .flexibleSpace,
            ToolbarItemIdentifier.inspector
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarItemIdentifier.navigation,
            .flexibleSpace,
            ToolbarItemIdentifier.inspector
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        _ = flag

        switch itemIdentifier {
        case ToolbarItemIdentifier.navigation:
            let item = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: [
                    NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back") ?? NSImage(),
                    NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward") ?? NSImage()
                ],
                selectionMode: .momentary,
                labels: nil,
                target: self,
                action: #selector(handleNavigationSegment(_:))
            )
            item.controlRepresentation = .expanded
            item.isNavigational = true
            item.label = "Navigation"
            item.paletteLabel = "Navigation"
            item.toolTip = "Navigate"
            item.selectedIndex = -1
            if item.subitems.count >= 2 {
                item.subitems[0].isEnabled = store.canGoBack
                item.subitems[1].isEnabled = store.canGoForward
            }
            navigationItemGroup = item
            return item
        case ToolbarItemIdentifier.inspector:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Inspector"
            item.paletteLabel = "Inspector"
            item.toolTip = "Open Web Inspector"
            item.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: "Inspector")
            item.target = self
            item.action = #selector(handleOpenInspectorAction(_:))
            return item
        default:
            return nil
        }
    }

    private func installToolbarIfNeeded(in window: NSWindow) {
        if let installedToolbar, installedToolbar === window.toolbar {
            return
        }

        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("Monocly.Toolbar"))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        if #available(macOS 13.0, *) {
            toolbar.centeredItemIdentifiers = []
        }

        window.toolbar = toolbar
        window.toolbarStyle = .unified

        installedToolbar = toolbar
        toolbarInstallationCountForTesting += 1
    }

    private func handleWindowAttachmentIfNeeded() {
        guard let window = view.window else {
            return
        }
        pendingWindowAttachmentTask?.cancel()
        pendingWindowAttachmentTask = Task.immediateIfAvailable { [weak self, weak window] in
            await Task.yield()
            guard let self, let window, self.view.window === window else {
                return
            }
            self.installToolbarIfNeeded(in: window)
            self.updateWindowChrome()
            self.pageViewController?.handleHostWindowDidAttach()
            self.pendingWindowAttachmentTask = nil
        }
    }

    func forceWindowAttachmentForTesting(in window: NSWindow) {
        loadViewIfNeeded()
        installToolbarIfNeeded(in: window)
        window.title = store.displayTitle
    }

    private func updateWindowChrome() {
        guard isViewLoaded else {
            return
        }

        view.layer?.backgroundColor = (store.underPageBackgroundColor ?? .windowBackgroundColor).cgColor
        view.window?.title = store.displayTitle
        if let navigationItemGroup, navigationItemGroup.subitems.count >= 2 {
            navigationItemGroup.subitems[0].isEnabled = store.canGoBack
            navigationItemGroup.subitems[1].isEnabled = store.canGoForward
        }
        view.window?.toolbar?.validateVisibleItems()
    }

    private func startObservingStoreIfNeeded() {
        guard storeObserverID == nil else {
            return
        }

        storeObserverID = store.addStateObserver { [weak self] in
            self?.updateWindowChrome()
        }
    }

    private func tearDownStoreObserverIfNeeded() {
        guard let storeObserverID else {
            return
        }
        store.removeStateObserver(storeObserverID)
        self.storeObserverID = nil
    }

    private func requestInspectorSessionState(_ state: InspectorSessionState) {
        if isFinalizingInspectorSession, state != .disconnected {
            return
        }
        pendingInspectorSessionState = state
        guard inspectorLifecycleTask == nil else {
            return
        }

        let inspectorController = inspectorController
        let store = store
        inspectorLifecycleTask = Task { [weak self, inspectorController, store] in
            guard let self else {
                return
            }
            defer {
                self.inspectorLifecycleTask = nil
            }

            while let desiredState = self.pendingInspectorSessionState {
                self.pendingInspectorSessionState = nil

                switch desiredState {
                case .connected:
                    await inspectorController.applyHostState(pageWebView: store.webView, visibility: .visible)
                case .suspended:
                    await inspectorController.applyHostState(pageWebView: store.webView, visibility: .hidden)
                case .disconnected:
                    await inspectorController.finalize()
                }
            }
        }
    }

    private func tearDownWindowIntegration() {
        pendingWindowAttachmentTask?.cancel()
        pendingWindowAttachmentTask = nil
        tearDownStoreObserverIfNeeded()
        installedToolbar?.delegate = nil
        installedToolbar = nil
        navigationItemGroup = nil
    }
}

private final class BrowserRootContainerView: NSView {
    var onWindowDidChange: () -> Void

    init(onWindowDidChange: @escaping () -> Void) {
        self.onWindowDidChange = onWindowDidChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowDidChange()
    }
}
#endif
