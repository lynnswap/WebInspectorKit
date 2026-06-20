#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebKit
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

    private enum ProgressIndicator {
        static let height: CGFloat = 2
        static let showAnimationDuration: TimeInterval = 0.12
        static let progressAnimationDuration: TimeInterval = 0.18
        static let completionHoldDuration: UInt64 = 120_000_000
        static let hideAnimationDuration: TimeInterval = 0.18
        static let animationOptions: UIView.AnimationOptions = [
            .allowUserInteraction,
            .beginFromCurrentState,
            .curveEaseInOut,
        ]
    }

    private let browserWindow: BrowserWindow
    private let inspectorSession: WebInspectorSession
    private let launchConfiguration: BrowserLaunchConfiguration
    private let inspectorCoordinator = BrowserInspectorCoordinator()
    private var browserWindowObservation: PortableObservationTracking.Token?
    private var selectedTabObservation: PortableObservationTracking.Token?
    private var inspectorPresentationObservation: PortableObservationTracking.Token?
    private weak var observedTab: BrowserTab?
    private var hasBoundSelectedTab = false

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
        self?.browserWindow.goBack()
    }
    private lazy var forwardNavigationAction = UIAction { [weak self] _ in
        self?.browserWindow.goForward()
    }
    private var hostedWebView: WKWebView?
    private var hostedWebViewConstraints: [NSLayoutConstraint] = []
    private var viewportCoordinator: BrowserViewportCoordinator?
    private var inspectorWindowObserverID: UUID?
    private var didAutoPresentInspector = false
    private var progressHeightConstraint: NSLayoutConstraint?
    private let progressHideScheduler: MainActorDelayScheduling
    private var isProgressHideAnimationInFlight = false
    private var isInspectorPresenting = false
    private var currentChromePlacement: ChromePlacement?
    var onSelectedWebViewInstalled: ((WKWebView) -> Void)?

    init(
        browserWindow: BrowserWindow,
        inspectorSession: WebInspectorSession,
        launchConfiguration: BrowserLaunchConfiguration,
        progressHideScheduler: MainActorDelayScheduling = MainActorDelayScheduler()
    ) {
        self.browserWindow = browserWindow
        self.inspectorSession = inspectorSession
        self.launchConfiguration = launchConfiguration
        self.progressHideScheduler = progressHideScheduler
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        progressHideScheduler.cancel()
        viewportCoordinator?.invalidate()
        browserWindowObservation?.cancel()
        selectedTabObservation?.cancel()
        inspectorPresentationObservation?.cancel()
        if let inspectorWindowObserverID {
            BrowserInspectorCoordinator.removeInspectorWindowObservation(inspectorWindowObserverID)
        }
        inspectorCoordinator.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViewHierarchy()
        installSelectedWebViewIfNeeded()
        configureChrome()

        startObservingBrowserWindow()
        startObservingInspectorPresentation()
        inspectorWindowObserverID = BrowserInspectorCoordinator.observeInspectorWindowPresentation { [weak self] _ in
            guard let self else {
                return
            }
            inspectorCoordinator.refreshPresentationState(presenter: navigationController ?? self)
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
        viewportCoordinator?.webViewHierarchyDidChange()
        viewportCoordinator?.hostViewDidAppear()
        refreshChromeControls()
        browserWindow.loadInitialRequestIfNeeded()
        maybeAutoPresentInspectorIfNeeded()
    }

    private func startObservingBrowserWindow() {
        browserWindowObservation?.cancel()
        browserWindowObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self else {
                return
            }
            scheduleSelectedTabBinding(browserWindow.selectedTab)
        }
    }

    private func scheduleSelectedTabBinding(_ tab: BrowserTab?) {
        let tabID = tab?.id
        Task { @MainActor [weak self, tab] in
            guard let self else {
                return
            }
            guard self.browserWindow.selectedTab?.id == tabID else {
                return
            }
            self.bindSelectedTab(tab)
        }
    }

    private func startObservingInspectorPresentation() {
        inspectorPresentationObservation?.cancel()
        inspectorPresentationObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self else {
                return
            }
            renderChromeControls(isInspectorPresenting: inspectorCoordinator.presentationState.isPresenting)
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        viewportCoordinator?.webViewSafeAreaInsetsDidChange()
    }

    @objc
    private func handleOpenInspectorAction(_ sender: Any?) {
        _ = openInspectorAsSheet()
    }

    private func configureViewHierarchy() {
        view.backgroundColor = browserWindow.selectedTab?.underPageBackgroundColor ?? .clear

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.trackTintColor = .clear
        progressView.isHidden = true
        progressView.alpha = 0
        view.addSubview(progressView)
        progressHeightConstraint = progressView.heightAnchor.constraint(equalToConstant: 0)

        var constraints = [
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ]

        if let progressHeightConstraint {
            constraints.append(progressHeightConstraint)
        }

        NSLayoutConstraint.activate(constraints)
    }

    private func installSelectedWebViewIfNeeded() {
        installWebViewIfNeeded(browserWindow.webView)
    }

    private func installWebViewIfNeeded(_ webView: WKWebView) {
        guard hostedWebView !== webView else {
            return
        }

        if let hostedWebView {
            (hostedWebView as? BrowserViewportWebView)?.viewportCoordinator = nil
            viewportCoordinator?.invalidate()
            NSLayoutConstraint.deactivate(hostedWebViewConstraints)
            hostedWebView.removeFromSuperview()
        }

        hostedWebView = webView
        hostedWebViewConstraints = [
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ]

        webView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(webView, at: 0)
        NSLayoutConstraint.activate(hostedWebViewConstraints)

        let viewportCoordinator = BrowserViewportCoordinator(webView: webView)
        viewportCoordinator.hostViewController = self
        self.viewportCoordinator = viewportCoordinator
        (webView as? BrowserViewportWebView)?.viewportCoordinator = viewportCoordinator
        viewportCoordinator.webViewHierarchyDidChange()
        if view.window != nil {
            viewportCoordinator.hostViewDidAppear()
        }
        onSelectedWebViewInstalled?(webView)
    }

    private func configureChrome() {
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItems = nil
        navigationItem.rightBarButtonItems = nil

        configureNavigationHistoryButtonItem(
            backButtonItem,
            direction: .back,
            action: backNavigationAction
        )
        configureNavigationHistoryButtonItem(
            forwardButtonItem,
            direction: .forward,
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
        direction: BrowserTab.HistoryDirection,
        action: UIAction
    ) {
        item.target = nil
        item.action = nil
        item.primaryAction = action
        item.menu = makeDeferredHistoryMenu(direction: direction)
        item.customView = nil
        item.preferredMenuElementOrder = .fixed
        item.accessibilityIdentifier = nil
    }

    private func refreshChromeControls() {
        inspectorCoordinator.refreshPresentationState(presenter: navigationController ?? self)
        renderChromeControls(isInspectorPresenting: inspectorCoordinator.presentationState.isPresenting)
    }

    private func renderChromeControls(isInspectorPresenting: Bool) {
        self.isInspectorPresenting = isInspectorPresenting
        let placement = currentChromePlacement ?? resolvedChromePlacement()
        applyAccessibilityIdentifiers(for: placement)
        refreshInspectorButtonConfiguration(for: placement)
        syncNavigationButtonStates(
            tab: observedTab ?? browserWindow.selectedTab,
            isInspectorPresenting: isInspectorPresenting
        )
    }

    private func applyAccessibilityIdentifiers(for placement: ChromePlacement) {
        let suffix = placement == .compactToolbar ? "compact" : "regular"

        let backIdentifier = "Monocly.navigation.back.\(suffix)"
        backButtonItem.accessibilityIdentifier = backIdentifier

        let forwardIdentifier = "Monocly.navigation.forward.\(suffix)"
        forwardButtonItem.accessibilityIdentifier = forwardIdentifier

        inspectorButtonItem.accessibilityIdentifier = "Monocly.openInspectorButton.\(suffix)"
    }

    private func makeDeferredHistoryMenu(direction: BrowserTab.HistoryDirection) -> UIMenu {
        UIMenu(
            title: "",
            children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    guard let self else {
                        completion([])
                        return
                    }
                    let placement = self.currentChromePlacement ?? self.resolvedChromePlacement()
                    completion(self.makeHistoryMenu(direction: direction, placement: placement).children)
                },
            ]
        )
    }

    private func makeHistoryMenu(direction: BrowserTab.HistoryDirection, placement: ChromePlacement) -> UIMenu {
        let historyItems = displayedHistoryMenuItems(direction: direction, placement: placement)

        let actions = historyItems.map { historyItem in
            UIAction(
                title: historyItem.title,
                subtitle: historyItem.subtitle
            ) { [weak self] _ in
                self?.browserWindow.go(to: historyItem.backForwardListItem)
            }
        }
        return UIMenu(title: "", children: actions)
    }

    private func historyMenuItems(direction: BrowserTab.HistoryDirection) -> [BrowserTab.HistoryMenuItem] {
        switch direction {
        case .back:
            browserWindow.backHistoryItems()
        case .forward:
            browserWindow.forwardHistoryItems()
        }
    }

    private func displayedHistoryMenuItems(
        direction: BrowserTab.HistoryDirection,
        placement: ChromePlacement
    ) -> [BrowserTab.HistoryMenuItem] {
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
            if inspectorButtonItem.primaryAction == nil {
                inspectorButtonItem.primaryAction = makeInspectorPrimaryAction()
            }
            inspectorButtonItem.preferredMenuElementOrder = .fixed
            if inspectorButtonItem.menu == nil {
                inspectorButtonItem.menu = makeDeferredInspectorMenu()
            }
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

    private func makeDeferredInspectorMenu() -> UIMenu {
        UIMenu(
            title: "",
            children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    guard let self else {
                        completion([])
                        return
                    }
                    let placement = self.currentChromePlacement ?? self.resolvedChromePlacement()
                    completion(self.makeInspectorMenu(for: placement).children)
                },
            ]
        )
    }

    private func makeInspectorMenu(for placement: ChromePlacement) -> UIMenu {
        inspectorCoordinator.refreshPresentationState(presenter: navigationController ?? self)
        let isInspectorOpen = inspectorCoordinator.presentationState.isPresenting
        let disableMenuActions = placement == .compactToolbar ? false : isInspectorOpen
        let openAsSheetAttributes: UIMenuElement.Attributes = disableMenuActions ? [.disabled] : []
        let openInWindowAttributes: UIMenuElement.Attributes = disableMenuActions ? [.disabled] : []

        let openAsSheet = UIAction(
            title: String(localized: "monocly.inspector.open_as_sheet", bundle: .main),
            image: UIImage(systemName: "rectangle.bottomthird.inset.filled"),
            attributes: openAsSheetAttributes
        ) { [weak self] _ in
            guard let self else {
                return
            }
            _ = self.openInspectorAsSheet()
        }
        let openInWindow = UIAction(
            title: String(localized: "monocly.inspector.open_in_new_window", bundle: .main),
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

    private func syncNavigationButtonStates(
        tab: BrowserTab?,
        isInspectorPresenting: Bool
    ) {
        let canGoBack = tab?.canGoBack ?? false
        let canGoForward = tab?.canGoForward ?? false
        let canOpenInspector = isInspectorPresenting == false

        backButtonItem.isEnabled = canGoBack
        forwardButtonItem.isEnabled = canGoForward
        inspectorButtonItem.isEnabled = canOpenInspector
    }

    private func bindSelectedTab(_ tab: BrowserTab?) {
        if hasBoundSelectedTab, observedTab === tab {
            return
        }

        hasBoundSelectedTab = true
        selectedTabObservation?.cancel()
        selectedTabObservation = nil
        observedTab = tab

        guard let tab else {
            return
        }

        installWebViewIfNeeded(tab.webView)
        renderSelectedTab(tab)
        selectedTabObservation = withPortableContinuousObservation { [weak self, weak tab] _ in
            guard let self, let tab, self.observedTab === tab else {
                return
            }
            renderSelectedTab(tab)
            maybeAutoPresentInspectorIfNeeded()
        }
    }

    private func renderSelectedTab(_ tab: BrowserTab) {
        guard isViewLoaded else {
            return
        }

        navigationItem.title = tab.displayTitle
        syncNavigationButtonStates(
            tab: tab,
            isInspectorPresenting: isInspectorPresenting
        )

        renderProgressIndicator(
            isVisible: tab.isShowingProgress,
            progress: tab.estimatedProgress
        )

        view.backgroundColor = tab.underPageBackgroundColor ?? .clear
    }

    private func renderProgressIndicator(isVisible: Bool, progress: Double) {
        let progress = normalizedProgress(progress)

        if isVisible {
            showProgressIndicator()
            setProgressIndicatorProgress(progress)
            return
        }

        if progressView.isHidden == false {
            setProgressIndicatorProgress(progress)
        }
        scheduleProgressIndicatorHide()
    }

    private func showProgressIndicator() {
        progressHideScheduler.cancel()
        isProgressHideAnimationInFlight = false
        progressView.layer.removeAllAnimations()

        let wasHidden = progressView.isHidden
        if wasHidden {
            progressView.isHidden = false
            progressView.alpha = 0
        }
        progressHeightConstraint?.constant = ProgressIndicator.height

        guard progressView.alpha < 1 else {
            return
        }

        UIView.animate(
            withDuration: ProgressIndicator.showAnimationDuration,
            delay: 0,
            options: ProgressIndicator.animationOptions
        ) {
            self.progressView.alpha = 1
        }
    }

    private func scheduleProgressIndicatorHide() {
        guard progressView.isHidden == false || progressView.alpha > 0 else {
            return
        }
        guard progressHideScheduler.hasScheduledDelay == false,
              isProgressHideAnimationInFlight == false else {
            return
        }

        progressHideScheduler.schedule(nanoseconds: ProgressIndicator.completionHoldDuration) { [weak self] in
            guard let self,
                  self.observedTab?.isShowingProgress == false else {
                return
            }

            self.isProgressHideAnimationInFlight = true
            UIView.animate(
                withDuration: ProgressIndicator.hideAnimationDuration,
                delay: 0,
                options: ProgressIndicator.animationOptions
            ) {
                self.progressView.alpha = 0
            } completion: { [weak self] finished in
                guard let self else {
                    return
                }
                self.isProgressHideAnimationInFlight = false
                guard finished, self.observedTab?.isShowingProgress == false else {
                    return
                }

                self.progressView.isHidden = true
                self.progressHeightConstraint?.constant = 0
                self.progressView.setProgress(0, animated: false)
            }
        }
    }

    private func setProgressIndicatorProgress(_ progress: Float) {
        let currentProgress = progressView.progress
        guard currentProgress != progress else {
            return
        }

        guard progressView.isHidden == false,
              progressView.alpha > 0,
              progress > currentProgress else {
            progressView.setProgress(progress, animated: false)
            return
        }

        UIView.animate(
            withDuration: ProgressIndicator.progressAnimationDuration,
            delay: 0,
            options: ProgressIndicator.animationOptions
        ) {
            self.progressView.setProgress(progress, animated: true)
        }
    }

    private func normalizedProgress(_ progress: Double) -> Float {
        Float(min(1, max(0, progress)))
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
        guard observedTab?.didFinishNavigationCount ?? 0 > 0 else {
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
            browserWindow: browserWindow,
            inspectorSession: inspectorSession
        )
    }

    var isPresentingInspectorForSessionAttachment: Bool {
        inspectorCoordinator.isPresentingInspector(presenter: navigationController ?? self)
    }
}

#if DEBUG
extension BrowserPageViewController {
    var selectedTabObservationIsActiveForTesting: Bool {
        selectedTabObservation != nil
    }

    var hostedWebViewForTesting: WKWebView? {
        hostedWebView
    }

    var progressViewForTesting: UIProgressView {
        progressView
    }

    var backButtonItemForTesting: UIBarButtonItem {
        backButtonItem
    }

    var forwardButtonItemForTesting: UIBarButtonItem {
        forwardButtonItem
    }

    var inspectorButtonItemForTesting: UIBarButtonItem {
        inspectorButtonItem
    }

    var inspectorPresentationObservationIsActiveForTesting: Bool {
        inspectorPresentationObservation != nil
    }

    var presentedInspectorSheetForTesting: WebInspectorViewController? {
        inspectorCoordinator.presentedSheetControllerForTesting as? WebInspectorViewController
    }

    func openInspectorAsSheetForTesting() -> Bool {
        openInspectorAsSheet()
    }
}
#endif
#endif
