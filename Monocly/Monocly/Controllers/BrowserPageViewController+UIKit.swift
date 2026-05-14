#if canImport(UIKit)
import UIKit
import WebInspectorKit
#if os(iOS)
import WKViewportCoordinator
#endif

@MainActor
final class BrowserPageViewController: UIViewController {
    private enum ChromePlacement {
        case compactToolbar
        case regularNavigationBar
    }

    private let store: BrowserStore
    private let inspectorSession: WebInspectorSession
    private let launchConfiguration: BrowserLaunchConfiguration
    private let inspectorCoordinator = BrowserInspectorCoordinator()

    private let progressView = UIProgressView(progressViewStyle: .bar)

    private let inspectorButtonItem = UIBarButtonItem(
        image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"),
        style: .plain,
        target: nil,
        action: nil
    )
    private let backButtonItem = UIBarButtonItem(
        image: UIImage(systemName: "chevron.left"),
        style: .plain,
        target: nil,
        action: nil
    )
    private let forwardButtonItem = UIBarButtonItem(
        image: UIImage(systemName: "chevron.right"),
        style: .plain,
        target: nil,
        action: nil
    )
    private lazy var backNavigationAction = UIAction { [weak self] _ in
        self?.store.goBack()
    }
    private lazy var forwardNavigationAction = UIAction { [weak self] _ in
        self?.store.goForward()
    }
    private var viewportCoordinator: BrowserViewportCoordinator?
    private var storeObserverID: UUID?
    private var historyObserverID: UUID?
    private var inspectorWindowObserverID: UUID?
    private var didAutoPresentInspector = false
    private var progressHeightConstraint: NSLayoutConstraint?
    private var currentChromePlacement: ChromePlacement?

    init(
        store: BrowserStore,
        inspectorSession: WebInspectorSession,
        launchConfiguration: BrowserLaunchConfiguration
    ) {
        self.store = store
        self.inspectorSession = inspectorSession
        self.launchConfiguration = launchConfiguration
        super.init(nibName: nil, bundle: nil)
        inspectorCoordinator.onPresentationStateChange = { [weak self] in
            self?.refreshChromeControls()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        viewportCoordinator?.invalidate()
        if let storeObserverID {
            store.removeStateObserver(storeObserverID)
        }
        if let historyObserverID {
            store.removeHistoryObserver(historyObserverID)
        }
        if let inspectorWindowObserverID {
            BrowserInspectorCoordinator.removeInspectorWindowObservation(inspectorWindowObserverID)
        }
        inspectorCoordinator.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViewHierarchy()
        configureChrome()
        viewportCoordinator = BrowserViewportCoordinator(webView: store.webView)
        viewportCoordinator?.hostViewController = self
        (store.webView as? BrowserViewportWebView)?.viewportCoordinator = viewportCoordinator
        viewportCoordinator?.handleWebViewHierarchyDidChange()

        storeObserverID = store.addStateObserver { [weak self] in
            self?.renderState()
            self?.maybeAutoPresentInspectorIfNeeded()
        }
        historyObserverID = store.addHistoryObserver { [weak self] in
            guard let self else {
                return
            }
            let placement = self.currentChromePlacement ?? self.resolvedChromePlacement()
            self.refreshNavigationHistoryMenus(for: placement)
        }
        inspectorWindowObserverID = BrowserInspectorCoordinator.observeInspectorWindowPresentation { [weak self] _ in
            self?.refreshChromeControls()
        }

        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.applyChromePlacement()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
        applyChromePlacement(force: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        viewportCoordinator?.handleWebViewHierarchyDidChange()
        viewportCoordinator?.handleViewDidAppear()
        refreshChromeControls()
        store.loadInitialRequestIfNeeded()
        maybeAutoPresentInspectorIfNeeded()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        viewportCoordinator?.handleWebViewSafeAreaInsetsDidChange()
    }

    @objc
    private func handleOpenInspectorAction(_ sender: Any?) {
        _ = openInspectorAsSheet()
    }

    private func configureViewHierarchy() {
        view.backgroundColor = store.underPageBackgroundColor ?? .clear

        let webView = store.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.trackTintColor = .clear
        view.addSubview(progressView)
        progressHeightConstraint = progressView.heightAnchor.constraint(equalToConstant: 0)

        var constraints = [
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ]

        if let progressHeightConstraint {
            constraints.append(progressHeightConstraint)
        }

        NSLayoutConstraint.activate(constraints)
    }

    private func configureChrome() {
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItems = nil
        navigationItem.rightBarButtonItems = nil

        configureNavigationHistoryButtonItem(
            backButtonItem,
            action: backNavigationAction
        )
        configureNavigationHistoryButtonItem(
            forwardButtonItem,
            action: forwardNavigationAction
        )
        configureNavigationButtonItem(inspectorButtonItem)
        refreshChromeControls()

        applyChromePlacement(force: true)
    }

    private func configureNavigationButtonItem(
        _ item: UIBarButtonItem
    ) {
        item.accessibilityIdentifier = nil
    }

    private func configureNavigationButtonItem(
        _ item: UIBarButtonItem,
        action: Selector,
        accessibilityIdentifier: String
    ) {
        item.target = self
        item.action = action
        item.accessibilityIdentifier = accessibilityIdentifier
    }

    private func configureNavigationHistoryButtonItem(
        _ item: UIBarButtonItem,
        action: UIAction
    ) {
        item.target = nil
        item.action = nil
        item.primaryAction = action
        item.menu = nil
        item.customView = nil
        item.preferredMenuElementOrder = .fixed
        item.accessibilityIdentifier = nil
    }

    private func refreshChromeControls() {
        let placement = currentChromePlacement ?? resolvedChromePlacement()
        applyAccessibilityIdentifiers(for: placement)
        refreshNavigationHistoryMenus(for: placement)
        refreshInspectorButtonConfiguration(for: placement)
        syncNavigationButtonStates()
    }

    private func applyAccessibilityIdentifiers(for placement: ChromePlacement) {
        let suffix = placement == .compactToolbar ? "compact" : "regular"

        let backIdentifier = "Monocly.navigation.back.\(suffix)"
        backButtonItem.accessibilityIdentifier = backIdentifier

        let forwardIdentifier = "Monocly.navigation.forward.\(suffix)"
        forwardButtonItem.accessibilityIdentifier = forwardIdentifier

        inspectorButtonItem.accessibilityIdentifier = "Monocly.openInspectorButton.\(suffix)"
    }

    private func refreshNavigationHistoryMenus(for placement: ChromePlacement) {
        backButtonItem.menu = makeHistoryMenu(direction: .back, placement: placement)
        forwardButtonItem.menu = makeHistoryMenu(direction: .forward, placement: placement)
    }

    private func makeHistoryMenu(direction: BrowserHistoryDirection, placement: ChromePlacement) -> UIMenu? {
        let historyItems = displayedHistoryMenuItems(direction: direction, placement: placement)
        guard historyItems.isEmpty == false else {
            return nil
        }

        let actions = historyItems.map { historyItem in
            UIAction(
                title: historyItem.title,
                subtitle: historyItem.subtitle
            ) { [weak self] _ in
                self?.store.go(to: historyItem.backForwardListItem)
            }
        }
        return UIMenu(title: "", children: actions)
    }

    private func historyMenuItems(direction: BrowserHistoryDirection) -> [BrowserHistoryMenuItem] {
        switch direction {
        case .back:
            store.backHistoryItems()
        case .forward:
            store.forwardHistoryItems()
        }
    }

    private func displayedHistoryMenuItems(
        direction: BrowserHistoryDirection,
        placement: ChromePlacement
    ) -> [BrowserHistoryMenuItem] {
        let historyItems = historyMenuItems(direction: direction)
        return switch placement {
        case .compactToolbar:
            // Menus for bottom toolbar buttons expand upward, so place the most recent
            // item last to keep it visually closest to the button.
            Array(historyItems.reversed())
        case .regularNavigationBar:
            historyItems
        }
    }

    private var supportsMultipleScenesForInspectorMenu: Bool {
        UIApplication.shared.supportsMultipleScenes
    }

    private func refreshInspectorButtonConfiguration(for placement: ChromePlacement) {
        if supportsMultipleScenesForInspectorMenu {
            inspectorButtonItem.target = nil
            inspectorButtonItem.action = nil
            inspectorButtonItem.primaryAction = makeInspectorPrimaryAction()
            inspectorButtonItem.preferredMenuElementOrder = .fixed
            inspectorButtonItem.menu = makeInspectorMenu(for: placement)
            return
        }

        inspectorButtonItem.primaryAction = nil
        inspectorButtonItem.menu = nil
        inspectorButtonItem.target = self
        inspectorButtonItem.action = #selector(handleOpenInspectorAction(_:))
    }

    private func makeInspectorPrimaryAction() -> UIAction {
        UIAction(
            title: "",
            image: UIImage(systemName: "chevron.left.forwardslash.chevron.right")
        ) { [weak self] _ in
            guard let self else {
                return
            }
            _ = self.openInspectorAsSheet()
        }
    }

    private func makeInspectorMenu(for placement: ChromePlacement) -> UIMenu {
        let isInspectorOpen = inspectorCoordinator.isPresentingInspector(presenter: navigationController ?? self)
        let disableMenuActions = placement == .compactToolbar ? false : isInspectorOpen
        let openAsSheetAttributes: UIMenuElement.Attributes = disableMenuActions ? [.disabled] : []
        let openInWindowAttributes: UIMenuElement.Attributes = disableMenuActions ? [.disabled] : []

        let openAsSheet = UIAction(
            title: "Open as Sheet",
            image: UIImage(systemName: "rectangle.bottomthird.inset.filled"),
            attributes: openAsSheetAttributes
        ) { [weak self] _ in
            guard let self else {
                return
            }
            _ = self.openInspectorAsSheet()
        }
        let openInWindow = UIAction(
            title: "Open in New Window",
            image: UIImage(systemName: "macwindow.on.rectangle"),
            attributes: openInWindowAttributes
        ) { [weak self] _ in
            guard let self else {
                return
            }
            _ = self.openInspectorInNewWindow()
        }

        return UIMenu(title: "", children: [openAsSheet, openInWindow])
    }

    private func applyChromePlacement(force: Bool = false) {
        let placement = resolvedChromePlacement()
        guard force || currentChromePlacement != placement else {
            return
        }

        currentChromePlacement = placement
        refreshChromeControls()

        switch placement {
        case .compactToolbar:
            navigationItem.leadingItemGroups = []
            navigationItem.trailingItemGroups = []
            toolbarItems = [
                backButtonItem,
                forwardButtonItem,
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                inspectorButtonItem
            ]
            navigationController?.setToolbarHidden(false, animated: false)
        case .regularNavigationBar:
            toolbarItems = nil
            navigationItem.leadingItemGroups = [
                UIBarButtonItemGroup(barButtonItems: [backButtonItem, forwardButtonItem], representativeItem: nil)
            ]
            navigationItem.trailingItemGroups = [
                UIBarButtonItemGroup(barButtonItems: [inspectorButtonItem], representativeItem: nil)
            ]
            navigationController?.setToolbarHidden(true, animated: false)
        }

        viewportCoordinator?.updateViewport()
    }

    private func resolvedChromePlacement() -> ChromePlacement {
        traitCollection.horizontalSizeClass == .regular ? .regularNavigationBar : .compactToolbar
    }

    private func syncNavigationButtonStates() {
        let canGoBack = store.canGoBack
        let canGoForward = store.canGoForward
        let canOpenInspector = inspectorCoordinator.isPresentingInspector(presenter: navigationController ?? self) == false

        backButtonItem.isEnabled = canGoBack
        forwardButtonItem.isEnabled = canGoForward
        inspectorButtonItem.isEnabled = canOpenInspector
    }

    private func renderState() {
        guard isViewLoaded else {
            return
        }

        navigationItem.title = store.displayTitle
        syncNavigationButtonStates()

        let progressIsVisible = store.isShowingProgress
        progressView.progress = Float(store.estimatedProgress)
        progressView.isHidden = progressIsVisible == false
        progressHeightConstraint?.constant = progressIsVisible ? 2 : 0

        view.backgroundColor = store.underPageBackgroundColor ?? .clear
    }

    private func maybeAutoPresentInspectorIfNeeded() {
        guard viewIfLoaded?.window != nil else {
            return
        }
        guard didAutoPresentInspector == false else {
            return
        }
        guard launchConfiguration.shouldAutoOpenInspector else {
            return
        }
        guard store.didFinishNavigationCount > 0 else {
            return
        }

        didAutoPresentInspector = openInspectorAsSheet()
    }

    private func openInspectorAsSheet() -> Bool {
        inspectorCoordinator.presentSheet(
            from: navigationController ?? self,
            inspectorSession: inspectorSession
        )
    }

    private func openInspectorInNewWindow() -> Bool {
        guard supportsMultipleScenesForInspectorMenu else {
            return false
        }

        return inspectorCoordinator.presentWindow(
            from: navigationController ?? self,
            browserStore: store,
            inspectorSession: inspectorSession
        )
    }

    var isPresentingInspectorForSessionAttachment: Bool {
        inspectorCoordinator.isPresentingInspector(presenter: navigationController ?? self)
    }
}
#endif
