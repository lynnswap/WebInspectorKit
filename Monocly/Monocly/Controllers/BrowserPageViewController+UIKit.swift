#if canImport(UIKit)
import OSLog
import UIKit
import WebInspectorKit
import WKViewport

@MainActor
final class BrowserPageViewController: UIViewController {
    private enum ChromePlacement {
        case compactToolbar
        case regularNavigationBar
    }

    private let store: BrowserStore
    private let inspectorController: WIInspectorController
    private let launchConfiguration: BrowserLaunchConfiguration
    private let inspectorCoordinator = BrowserInspectorCoordinator()
    private let logger = Logger(subsystem: "Monocly", category: "BrowserPageViewController")

    private let progressView = UIProgressView(progressViewStyle: .bar)

    private let compactInspectorButtonItem = UIBarButtonItem(
        image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"),
        style: .plain,
        target: nil,
        action: nil
    )
    private let compactBackButtonItem = UIBarButtonItem(
        image: UIImage(systemName: "chevron.left"),
        style: .plain,
        target: nil,
        action: nil
    )
    private let compactForwardButtonItem = UIBarButtonItem(
        image: UIImage(systemName: "chevron.right"),
        style: .plain,
        target: nil,
        action: nil
    )
    private let regularInspectorButtonItem = UIBarButtonItem(
        image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"),
        style: .plain,
        target: nil,
        action: nil
    )
    private let regularBackButtonItem = UIBarButtonItem(
        image: UIImage(systemName: "chevron.left"),
        style: .plain,
        target: nil,
        action: nil
    )
    private let regularForwardButtonItem = UIBarButtonItem(
        image: UIImage(systemName: "chevron.right"),
        style: .plain,
        target: nil,
        action: nil
    )
    private lazy var compactBackButton = makeNavigationHistoryButton(
        systemImageName: "chevron.left",
        accessibilityIdentifier: "Monocly.navigation.back.compact"
    ) { [weak self] in
        self?.store.goBack()
    }
    private lazy var compactForwardButton = makeNavigationHistoryButton(
        systemImageName: "chevron.right",
        accessibilityIdentifier: "Monocly.navigation.forward.compact"
    ) { [weak self] in
        self?.store.goForward()
    }
    private lazy var regularBackButton = makeNavigationHistoryButton(
        systemImageName: "chevron.left",
        accessibilityIdentifier: "Monocly.navigation.back.regular"
    ) { [weak self] in
        self?.store.goBack()
    }
    private lazy var regularForwardButton = makeNavigationHistoryButton(
        systemImageName: "chevron.right",
        accessibilityIdentifier: "Monocly.navigation.forward.regular"
    ) { [weak self] in
        self?.store.goForward()
    }
    private lazy var regularNavigationButtonGroup = UIBarButtonItemGroup(
        barButtonItems: [regularBackButtonItem, regularForwardButtonItem],
        representativeItem: nil
    )
    private lazy var regularInspectorButtonGroup = UIBarButtonItemGroup(
        barButtonItems: [regularInspectorButtonItem],
        representativeItem: nil
    )
    private lazy var diagnosticsPanel = BrowserDiagnosticsOverlayView()

    private var viewportCoordinator: ViewportCoordinator?
    private var storeObserverID: UUID?
    private var inspectorWindowObserverID: UUID?
    private var didAutoPresentInspector = false
    private var didAutoStartSelection = false
    private var progressHeightConstraint: NSLayoutConstraint?
    private var currentChromePlacement: ChromePlacement?
    private var supportsMultipleScenesOverrideForTesting: Bool?

    init(
        store: BrowserStore,
        inspectorController: WIInspectorController,
        launchConfiguration: BrowserLaunchConfiguration
    ) {
        self.store = store
        self.inspectorController = inspectorController
        self.launchConfiguration = launchConfiguration
        super.init(nibName: nil, bundle: nil)
        inspectorCoordinator.onPresentationStateChange = { [weak self] in
            self?.syncNavigationButtonStates()
            self?.refreshInspectorButtonConfigurations()
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
        if let inspectorWindowObserverID {
            BrowserInspectorCoordinator.removeInspectorWindowObservation(inspectorWindowObserverID)
        }
        inspectorCoordinator.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViewHierarchy()
        configureChrome()
        viewportCoordinator = ViewportCoordinator(webView: store.webView)

        storeObserverID = store.addStateObserver { [weak self] in
            self?.renderState()
            self?.maybeAutoPresentInspectorIfNeeded()
        }
        inspectorWindowObserverID = BrowserInspectorCoordinator.observeInspectorWindowPresentation { [weak self] _ in
            self?.syncNavigationButtonStates()
            self?.refreshInspectorButtonConfigurations()
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
        syncNavigationButtonStates()
        refreshNavigationHistoryMenus()
        refreshInspectorButtonConfigurations()
        store.loadInitialRequestIfNeeded()
        maybeAutoPresentInspectorIfNeeded()
    }

    @objc
    private func handleBackAction(_ sender: Any?) {
        _ = sender
        store.goBack()
    }

    @objc
    private func handleForwardAction(_ sender: Any?) {
        _ = sender
        store.goForward()
    }

    @objc
    private func handleOpenInspectorAction(_ sender: Any?) {
        _ = sender
        _ = openInspectorAsSheet(tabs: [.dom(), .network()])
    }

    private func configureViewHierarchy() {
        view.backgroundColor = .systemBackground

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

        if launchConfiguration.shouldShowDiagnostics {
            diagnosticsPanel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(diagnosticsPanel)
            constraints.append(contentsOf: [
                diagnosticsPanel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
                diagnosticsPanel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
            ])
        }

        NSLayoutConstraint.activate(constraints)
    }

    private func configureChrome() {
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItems = nil
        navigationItem.rightBarButtonItems = nil

        configureNavigationButtonItem(
            compactInspectorButtonItem,
            action: #selector(handleOpenInspectorAction(_:)),
            accessibilityIdentifier: "Monocly.openInspectorButton.compact"
        )
        configureNavigationHistoryButtonItem(
            compactBackButtonItem,
            button: compactBackButton,
            accessibilityIdentifier: "Monocly.navigation.back.compact"
        )
        configureNavigationHistoryButtonItem(
            compactForwardButtonItem,
            button: compactForwardButton,
            accessibilityIdentifier: "Monocly.navigation.forward.compact"
        )
        configureNavigationButtonItem(
            regularInspectorButtonItem,
            accessibilityIdentifier: "Monocly.openInspectorButton.regular"
        )
        configureNavigationHistoryButtonItem(
            regularBackButtonItem,
            button: regularBackButton,
            accessibilityIdentifier: "Monocly.navigation.back.regular"
        )
        configureNavigationHistoryButtonItem(
            regularForwardButtonItem,
            button: regularForwardButton,
            accessibilityIdentifier: "Monocly.navigation.forward.regular"
        )
        refreshNavigationHistoryMenus()
        refreshInspectorButtonConfigurations()

        applyChromePlacement(force: true)
    }

    private func makeNavigationHistoryButton(
        systemImageName: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: systemImageName)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)

        let button = UIButton(type: .system)
        button.configuration = configuration
        button.bounds.size = CGSize(width: 32, height: 32)
        button.accessibilityIdentifier = accessibilityIdentifier
        button.showsMenuAsPrimaryAction = false
        button.preferredMenuElementOrder = .fixed
        button.addAction(
            UIAction { _ in
                action()
            },
            for: .primaryActionTriggered
        )
        return button
    }

    private func configureNavigationButtonItem(
        _ item: UIBarButtonItem,
        accessibilityIdentifier: String
    ) {
        item.accessibilityIdentifier = accessibilityIdentifier
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
        button: UIButton,
        accessibilityIdentifier: String
    ) {
        item.target = nil
        item.action = nil
        item.primaryAction = nil
        item.menu = nil
        item.customView = button
        item.accessibilityIdentifier = accessibilityIdentifier
    }

    private func refreshNavigationHistoryMenus() {
        compactBackButton.menu = makeHistoryMenu(direction: .back, placement: .compactToolbar)
        regularBackButton.menu = makeHistoryMenu(direction: .back, placement: .regularNavigationBar)
        compactForwardButton.menu = makeHistoryMenu(direction: .forward, placement: .compactToolbar)
        regularForwardButton.menu = makeHistoryMenu(direction: .forward, placement: .regularNavigationBar)
    }

    private func makeHistoryMenu(
        direction: BrowserHistoryDirection,
        placement: ChromePlacement
    ) -> UIMenu? {
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

    @discardableResult
    private func triggerHistorySelection(direction: BrowserHistoryDirection, index: Int) -> Bool {
        let historyItems = displayedHistoryMenuItems(
            direction: direction,
            placement: currentChromePlacement ?? resolvedChromePlacement()
        )
        guard historyItems.indices.contains(index) else {
            return false
        }
        store.go(to: historyItems[index].backForwardListItem)
        return true
    }

    private var supportsMultipleScenesForInspectorMenu: Bool {
        supportsMultipleScenesOverrideForTesting ?? UIApplication.shared.supportsMultipleScenes
    }

    private func refreshInspectorButtonConfigurations() {
        configureInspectorButtonItem(compactInspectorButtonItem)
        configureInspectorButtonItem(regularInspectorButtonItem)
    }

    private func configureInspectorButtonItem(_ item: UIBarButtonItem) {
        if supportsMultipleScenesForInspectorMenu {
            item.target = nil
            item.action = nil
            item.primaryAction = makeInspectorPrimaryAction()
            item.preferredMenuElementOrder = .fixed
            item.menu = makeInspectorMenu()
            return
        }

        item.primaryAction = nil
        item.menu = nil
        item.target = self
        item.action = #selector(handleOpenInspectorAction(_:))
    }

    private func makeInspectorPrimaryAction() -> UIAction {
        UIAction(
            title: "",
            image: UIImage(systemName: "chevron.left.forwardslash.chevron.right")
        ) { [weak self] _ in
            guard let self else {
                return
            }
            _ = self.openInspectorAsSheet(tabs: [.dom(), .network()])
        }
    }

    private func makeInspectorMenu() -> UIMenu {
        let isInspectorOpen = inspectorCoordinator.isPresentingInspector(presenter: navigationController ?? self)
        let openAsSheetAttributes: UIMenuElement.Attributes = isInspectorOpen ? [.disabled] : []
        let openInWindowAttributes: UIMenuElement.Attributes = isInspectorOpen ? [.disabled] : []

        let openAsSheet = UIAction(
            title: "Open as Sheet",
            image: UIImage(systemName: "rectangle.bottomthird.inset.filled"),
            attributes: openAsSheetAttributes
        ) { [weak self] _ in
            guard let self else {
                return
            }
            _ = self.openInspectorAsSheet(tabs: [.dom(), .network()])
        }
        let openInWindow = UIAction(
            title: "Open in New Window",
            image: UIImage(systemName: "macwindow.on.rectangle"),
            attributes: openInWindowAttributes
        ) { [weak self] _ in
            guard let self else {
                return
            }
            _ = self.openInspectorInNewWindow(tabs: [.dom(), .network()])
        }

        return UIMenu(title: "", children: [openAsSheet, openInWindow])
    }

    private func applyChromePlacement(force: Bool = false) {
        let placement = resolvedChromePlacement()
        guard force || currentChromePlacement != placement else {
            return
        }

        currentChromePlacement = placement

        switch placement {
        case .compactToolbar:
            navigationItem.leadingItemGroups = []
            navigationItem.trailingItemGroups = []
            toolbarItems = [
                compactBackButtonItem,
                compactForwardButtonItem,
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                compactInspectorButtonItem
            ]
            navigationController?.setToolbarHidden(false, animated: false)
        case .regularNavigationBar:
            toolbarItems = nil
            navigationItem.leadingItemGroups = [regularNavigationButtonGroup]
            navigationItem.trailingItemGroups = [regularInspectorButtonGroup]
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

        compactBackButtonItem.isEnabled = canGoBack
        regularBackButtonItem.isEnabled = canGoBack
        compactForwardButtonItem.isEnabled = canGoForward
        regularForwardButtonItem.isEnabled = canGoForward
        compactBackButton.isEnabled = canGoBack
        regularBackButton.isEnabled = canGoBack
        compactForwardButton.isEnabled = canGoForward
        regularForwardButton.isEnabled = canGoForward
        compactInspectorButtonItem.isEnabled = canOpenInspector
        regularInspectorButtonItem.isEnabled = canOpenInspector
    }

    private func renderState() {
        guard isViewLoaded else {
            return
        }

        navigationItem.title = store.displayTitle
        refreshNavigationHistoryMenus()
        syncNavigationButtonStates()

        let progressIsVisible = store.isShowingProgress
        progressView.progress = Float(store.estimatedProgress)
        progressView.isHidden = progressIsVisible == false
        progressHeightConstraint?.constant = progressIsVisible ? 2 : 0

        view.backgroundColor = store.underPageBackgroundColor ?? .systemBackground

        if launchConfiguration.shouldShowDiagnostics {
            diagnosticsPanel.update(with: store)
        }
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

        let didPresent = openInspectorAsSheet(tabs: launchConfiguration.autoOpenInspectorTabs)
        didAutoPresentInspector = didPresent
        maybeAutoStartSelectionIfNeeded(didPresent: didPresent)
    }

    private func openInspectorAsSheet(tabs: [WITab]) -> Bool {
        inspectorCoordinator.presentSheet(
            from: navigationController ?? self,
            browserStore: store,
            inspectorController: inspectorController,
            tabs: tabs
        )
    }

    private func openInspectorInNewWindow(tabs: [WITab]) -> Bool {
        guard supportsMultipleScenesForInspectorMenu else {
            return false
        }

        return inspectorCoordinator.presentWindow(
            from: navigationController ?? self,
            browserStore: store,
            inspectorController: inspectorController,
            tabs: tabs
        )
    }

    private func maybeAutoStartSelectionIfNeeded(didPresent: Bool) {
        guard didPresent else {
            return
        }
        guard launchConfiguration.shouldAutoStartDOMSelection else {
            return
        }
        guard didAutoStartSelection == false else {
            return
        }

        didAutoStartSelection = true

        Task.immediateIfAvailable { [self] in
            var didCompleteAutoStart = false
            defer {
                if didCompleteAutoStart == false {
                    self.didAutoStartSelection = false
                }
            }
            self.logger.notice("auto-starting DOM selection mode for diagnostics")
            for _ in 0..<100 {
                if self.inspectorController.dom.hasPageWebView {
                    do {
                        let result = try await self.inspectorController.dom.beginSelectionMode()
                        didCompleteAutoStart = !result.cancelled
                        if didCompleteAutoStart {
                            return
                        }
                    } catch {
                        // Keep retrying until the page bridge is ready or we time out.
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            self.logger.error("auto-starting DOM selection mode timed out before page web view became available")
        }
    }

    var chromePlacementForTesting: String {
        switch currentChromePlacement ?? resolvedChromePlacement() {
        case .compactToolbar:
            return "compactToolbar"
        case .regularNavigationBar:
            return "regularNavigationBar"
        }
    }

    var compactBackButtonItemForTesting: UIBarButtonItem {
        compactBackButtonItem
    }

    var compactBackButtonForTesting: UIButton {
        compactBackButton
    }

    var compactForwardButtonItemForTesting: UIBarButtonItem {
        compactForwardButtonItem
    }

    var compactForwardButtonForTesting: UIButton {
        compactForwardButton
    }

    var compactInspectorButtonItemForTesting: UIBarButtonItem {
        compactInspectorButtonItem
    }

    var compactBackMenuActionTitlesForTesting: [String] {
        compactBackButton.menu?.children.compactMap { ($0 as? UIAction)?.title } ?? []
    }

    var compactBackMenuActionSubtitlesForTesting: [String?] {
        compactBackButton.menu?.children.compactMap { ($0 as? UIAction)?.subtitle } ?? []
    }

    var compactForwardMenuActionTitlesForTesting: [String] {
        compactForwardButton.menu?.children.compactMap { ($0 as? UIAction)?.title } ?? []
    }

    var compactForwardMenuActionSubtitlesForTesting: [String?] {
        compactForwardButton.menu?.children.compactMap { ($0 as? UIAction)?.subtitle } ?? []
    }

    var compactInspectorMenuActionTitlesForTesting: [String] {
        compactInspectorButtonItem.menu?.children.compactMap { ($0 as? UIAction)?.title } ?? []
    }

    var compactInspectorHasPrimaryActionForTesting: Bool {
        compactInspectorButtonItem.primaryAction != nil
    }

    var regularBackButtonItemForTesting: UIBarButtonItem {
        regularBackButtonItem
    }

    var regularBackButtonForTesting: UIButton {
        regularBackButton
    }

    var regularForwardButtonItemForTesting: UIBarButtonItem {
        regularForwardButtonItem
    }

    var regularForwardButtonForTesting: UIButton {
        regularForwardButton
    }

    var regularInspectorButtonItemForTesting: UIBarButtonItem {
        regularInspectorButtonItem
    }

    var regularInspectorMenuActionTitlesForTesting: [String] {
        regularInspectorButtonItem.menu?.children.compactMap { ($0 as? UIAction)?.title } ?? []
    }

    var regularInspectorHasPrimaryActionForTesting: Bool {
        regularInspectorButtonItem.primaryAction != nil
    }

    @discardableResult
    func triggerRegularInspectorPrimaryActionForTesting() -> Bool {
        openInspectorAsSheet(tabs: [.dom(), .network()])
    }

    @discardableResult
    func triggerBackHistorySelectionForTesting(index: Int) -> Bool {
        triggerHistorySelection(direction: .back, index: index)
    }

    @discardableResult
    func triggerForwardHistorySelectionForTesting(index: Int) -> Bool {
        triggerHistorySelection(direction: .forward, index: index)
    }

    @discardableResult
    func triggerRegularInspectorWindowActionForTesting() -> Bool {
        openInspectorInNewWindow(tabs: [.dom(), .network()])
    }

    func refreshInspectorControlsForTesting() {
        syncNavigationButtonStates()
        refreshInspectorButtonConfigurations()
    }

    var hasInspectorWindowForTesting: Bool {
        inspectorCoordinator.hasInspectorWindowForTesting
    }

    func dismissInspectorWindowForTesting() {
        inspectorCoordinator.dismissInspectorWindow()
    }

    func setSceneActivationRequesterForTesting(_ requester: BrowserInspectorSceneActivationRequester) {
        inspectorCoordinator.setSceneActivationRequesterForTesting(requester)
    }

    func setSupportsMultipleScenesForTesting(_ value: Bool?) {
        supportsMultipleScenesOverrideForTesting = value
        refreshInspectorButtonConfigurations()
        syncNavigationButtonStates()
    }
}

private final class BrowserDiagnosticsOverlayView: UIVisualEffectView {
    private let terminationCountLabel = UILabel()
    private let didFinishCountLabel = UILabel()
    private let currentURLLabel = UILabel()
    private let lastErrorLabel = UILabel()

    init() {
        super.init(effect: UIBlurEffect(style: .systemThinMaterial))
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 10
        clipsToBounds = true
        accessibilityIdentifier = "Monocly.diagnostics.panel"

        let stackView = UIStackView(arrangedSubviews: [
            terminationCountLabel,
            didFinishCountLabel,
            currentURLLabel,
            lastErrorLabel
        ])
        stackView.axis = .vertical
        stackView.alignment = .leading
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)

        for label in [terminationCountLabel, didFinishCountLabel, currentURLLabel, lastErrorLabel] {
            label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            label.numberOfLines = 2
        }

        terminationCountLabel.accessibilityIdentifier = "Monocly.diagnostics.terminationCount"
        didFinishCountLabel.accessibilityIdentifier = "Monocly.diagnostics.didFinishCount"
        currentURLLabel.accessibilityIdentifier = "Monocly.diagnostics.currentURL"
        lastErrorLabel.accessibilityIdentifier = "Monocly.diagnostics.lastNavigationError"

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(with store: BrowserStore) {
        terminationCountLabel.text = "terminationCount=\(store.webContentTerminationCount)"
        didFinishCountLabel.text = "didFinishCount=\(store.didFinishNavigationCount)"
        currentURLLabel.text = "currentURL=\(store.currentURL?.absoluteString ?? "n/a")"
        lastErrorLabel.text = "lastError=\(store.lastNavigationErrorDescription ?? "n/a")"
    }
}
#endif
