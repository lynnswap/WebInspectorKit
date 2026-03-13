#if canImport(AppKit)
import AppKit
import WebInspectorKit

@MainActor
final class BrowserRootViewController: NSViewController, NSToolbarDelegate, NSToolbarItemValidation {
    private enum ToolbarItemIdentifier {
        static let navigation = NSToolbarItem.Identifier("MiniBrowser.Toolbar.Navigation")
        static let inspector = NSToolbarItem.Identifier("MiniBrowser.Toolbar.Inspector")
    }

    let store: BrowserStore
    let sessionController: WISessionController
    let launchConfiguration: BrowserLaunchConfiguration

    private let inspectorCoordinator = BrowserInspectorCoordinator()
    private let hostedContentViewController: NSViewController
    private let pageViewController: BrowserPageViewController?
    private var storeObserverID: UUID?
    private weak var installedToolbar: NSToolbar?
    private weak var navigationItemGroup: NSToolbarItemGroup?

    private(set) var toolbarInstallationCountForTesting = 0

    init(
        store: BrowserStore? = nil,
        sessionController: WISessionController? = nil,
        launchConfiguration: BrowserLaunchConfiguration,
        contentViewController: NSViewController? = nil
    ) {
        let resolvedStore = store ?? BrowserStore(url: launchConfiguration.initialURL)
        let resolvedSessionController = sessionController ?? WISessionController()
        let resolvedContentViewController = contentViewController
            ?? BrowserPageViewController(
                store: resolvedStore,
                sessionController: resolvedSessionController,
                launchConfiguration: launchConfiguration
            )

        self.store = resolvedStore
        self.sessionController = resolvedSessionController
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
        if let storeObserverID {
            store.removeStateObserver(storeObserverID)
        }
        sessionController.disconnect()
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

        storeObserverID = store.addStateObserver { [weak self] in
            self?.updateWindowChrome()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        handleWindowAttachmentIfNeeded()
    }

    @objc
    private func handleOpenInspectorAction(_ sender: Any?) {
        _ = sender
        _ = inspectorCoordinator.present(
            from: view.window,
            browserStore: store,
            sessionController: sessionController,
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
            return true
        default:
            return true
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
                selectionMode: NSToolbarItemGroup.SelectionMode.momentary,
                labels: nil,
                target: self,
                action: #selector(handleNavigationSegment(_:))
            )
            item.controlRepresentation = NSToolbarItemGroup.ControlRepresentation.expanded
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

        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("MiniBrowser.Toolbar"))
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
        installToolbarIfNeeded(in: window)
        updateWindowChrome()
        pageViewController?.handleHostWindowDidAttach()
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
