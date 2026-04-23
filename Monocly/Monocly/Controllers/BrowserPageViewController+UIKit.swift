#if canImport(UIKit)
import OSLog
import UIKit
import WebKit
@_spi(Monocly) import WebInspectorKit
#if os(iOS)
import WKViewportCoordinator
#endif

@MainActor
final class BrowserPageViewController: UIViewController {
    private enum ChromePlacement {
        case compactToolbar
        case regularNavigationBar
    }

    private struct RemoteTapTargetDiagnostics {
        let normalizedTap: CGVector
        let summary: String
    }

    private let store: BrowserStore
    private let inspectorController: WIInspectorController
    private let launchConfiguration: BrowserLaunchConfiguration
    private let inspectorCoordinator = BrowserInspectorCoordinator()
    private let logger = Logger(subsystem: "Monocly", category: "BrowserPageViewController")

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
    private lazy var diagnosticsPanel = BrowserDiagnosticsOverlayView()

    private var viewportCoordinator: BrowserViewportCoordinator?
    private var storeObserverID: UUID?
    private var historyObserverID: UUID?
    private var inspectorWindowObserverID: UUID?
    private var didAutoPresentInspector = false
    private var didAutoStartSelection = false
    private var progressHeightConstraint: NSLayoutConstraint?
    private var currentChromePlacement: ChromePlacement?
    private var supportsMultipleScenesOverrideForTesting: Bool?
    private var diagnosticsPollTask: Task<Void, Never>?
    private var latestRemoteTapTargetDiagnostics: RemoteTapTargetDiagnostics?

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
            self?.refreshChromeControls()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        diagnosticsPollTask?.cancel()
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
        startDiagnosticsPollingIfNeeded()
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
        _ = sender
        _ = openInspectorAsSheet(tabs: [.dom(), .network()])
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

        if launchConfiguration.shouldShowDiagnostics {
            if launchConfiguration.uiTestScenario != nil {
                diagnosticsPanel.configureInspectorOpenAction { [weak self] in
                    guard let self else {
                        return
                    }
                    _ = self.openInspectorAsSheet(tabs: [.dom()])
                }
                diagnosticsPanel.configureBeginNativeSelectionAction { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else {
                            return
                        }
                        try? await self.inspectorController.dom.beginSelectionMode()
                        self.updateDiagnosticsOverlay()
                    }
                }
                diagnosticsPanel.configureFocusRemoteTapTargetAction { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else {
                            return
                        }
                        self.latestRemoteTapTargetDiagnostics = nil
                        for _ in 0..<50 {
                            if let diagnostics = try? await self.resolvePreferredRemoteTapTargetForTesting() {
                                self.latestRemoteTapTargetDiagnostics = diagnostics
                                break
                            }
                            try? await Task.sleep(nanoseconds: 100_000_000)
                        }
                        self.updateDiagnosticsOverlay()
                    }
                }
            }
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
            _ = self.openInspectorAsSheet(tabs: [.dom(), .network()])
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

        if launchConfiguration.shouldShowDiagnostics {
            updateDiagnosticsOverlay()
        }
    }

    private func startDiagnosticsPollingIfNeeded() {
        guard launchConfiguration.uiTestScenario != nil else {
            return
        }
        diagnosticsPollTask?.cancel()
        diagnosticsPollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                if self.launchConfiguration.uiTestScenario == .domRemoteURL,
                   self.latestRemoteTapTargetDiagnostics == nil {
                    self.latestRemoteTapTargetDiagnostics = try? await self.resolvePreferredRemoteTapTargetForTesting()
                }
                self.updateDiagnosticsOverlay()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func updateDiagnosticsOverlay() {
        diagnosticsPanel.update(
            with: store,
            uiTestState: .init(
                domIsSelecting: inspectorController.dom.isSelectingElement,
                domSelectedPreview: inspectorController.dom.currentSelectedNodePreviewForDiagnostics() ?? "n/a",
                domSelectedLineage: inspectorController.dom.currentSelectedNodeLineageForDiagnostics() ?? "n/a",
                domSelectionDebug: inspectorController.dom.lastSelectionDiagnosticForDiagnostics() ?? "n/a",
                domError: inspectorController.dom.document.errorMessage ?? "n/a",
                remoteTapTargetSummary: latestRemoteTapTargetDiagnostics?.summary ?? "n/a",
                remoteTapPoint: latestRemoteTapTargetDiagnostics.map {
                    String(format: "%.4f,%.4f", $0.normalizedTap.dx, $0.normalizedTap.dy)
                } ?? "n/a"
            )
        )
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
            tabs: tabs,
            launchConfiguration: launchConfiguration
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
                        try await self.inspectorController.dom.beginSelectionMode()
                        didCompleteAutoStart = true
                        return
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

    var backButtonItemForTesting: UIBarButtonItem {
        backButtonItem
    }

    var forwardButtonItemForTesting: UIBarButtonItem {
        forwardButtonItem
    }

    var inspectorButtonItemForTesting: UIBarButtonItem {
        inspectorButtonItem
    }

    var backMenuActionTitlesForTesting: [String] {
        backButtonItem.menu?.children.compactMap { ($0 as? UIAction)?.title } ?? []
    }

    var backMenuForTesting: UIMenu? {
        backButtonItem.menu
    }

    var backMenuActionSubtitlesForTesting: [String?] {
        backButtonItem.menu?.children.compactMap { ($0 as? UIAction)?.subtitle } ?? []
    }

    var forwardMenuActionTitlesForTesting: [String] {
        forwardButtonItem.menu?.children.compactMap { ($0 as? UIAction)?.title } ?? []
    }

    var forwardMenuForTesting: UIMenu? {
        forwardButtonItem.menu
    }

    var forwardMenuActionSubtitlesForTesting: [String?] {
        forwardButtonItem.menu?.children.compactMap { ($0 as? UIAction)?.subtitle } ?? []
    }

    var inspectorMenuActionTitlesForTesting: [String] {
        inspectorButtonItem.menu?.children.compactMap { ($0 as? UIAction)?.title } ?? []
    }

    var inspectorHasPrimaryActionForTesting: Bool {
        inspectorButtonItem.primaryAction != nil
    }

    @discardableResult
    func triggerInspectorPrimaryActionForTesting() -> Bool {
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
    func triggerInspectorWindowActionForTesting() -> Bool {
        openInspectorInNewWindow(tabs: [.dom(), .network()])
    }

    func refreshInspectorControlsForTesting() {
        refreshChromeControls()
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
        inspectorCoordinator.setSupportsMultipleScenesProviderForTesting {
            value ?? UIApplication.shared.supportsMultipleScenes
        }
        refreshChromeControls()
    }

    private func resolvePreferredRemoteTapTargetForTesting() async throws -> RemoteTapTargetDiagnostics? {
        let rawValue = try await store.webView.callAsyncJavaScriptCompat(
            """
            return (function() {
                const clamp = (value, minimum, maximum) => Math.min(maximum, Math.max(minimum, value));
                const hitTestPointForIframe = (element, rect, viewportWidth, viewportHeight) => {
                    const xFractions = [0.5, 0.25, 0.75, 0.12, 0.88];
                    const yFractions = [0.5, 0.35, 0.65, 0.2, 0.8];
                    for (const yFraction of yFractions) {
                        for (const xFraction of xFractions) {
                            const x = clamp(rect.left + (rect.width * xFraction), 1, viewportWidth - 1);
                            const y = clamp(rect.top + (rect.height * yFraction), 1, viewportHeight - 1);
                            const hit = document.elementFromPoint(x, y);
                            if (hit === element)
                                return {x, y, hitSummary: element.tagName.toLowerCase()};
                        }
                    }
                    return {
                        x: clamp(rect.left + (rect.width / 2), 1, viewportWidth - 1),
                        y: clamp(rect.top + (rect.height / 2), 1, viewportHeight - 1),
                        hitSummary: "fallback-center",
                    };
                };
                const viewportWidth = Math.max(window.innerWidth || 0, document.documentElement.clientWidth || 0, 1);
                const viewportHeight = Math.max(window.innerHeight || 0, document.documentElement.clientHeight || 0, 1);
                const utilityPattern = /(__uspapiLocator|__gppLocator|googlefc|google_ads_iframe|google_ads_top_frame|recaptcha|googlefcPresent|googlefcLoaded|googlefcInactive)/i;
                const elements = Array.from(document.querySelectorAll("iframe"));
                const candidates = elements.map((element, index) => {
                    const rect = element.getBoundingClientRect();
                    const style = window.getComputedStyle(element);
                    const summary = `<iframe${element.id ? `#${element.id}` : ""}${element.name ? `[name="${element.name}"]` : ""}>`;
                    const utility = utilityPattern.test(element.id || "")
                        || utilityPattern.test(element.name || "")
                        || utilityPattern.test(element.title || "")
                        || utilityPattern.test(element.getAttribute("src") || "");
                    const visible = style.display !== "none"
                        && style.visibility !== "hidden"
                        && Number.parseFloat(style.opacity || "1") > 0
                        && rect.width >= 80
                        && rect.height >= 40
                        && rect.bottom > 0
                        && rect.right > 0
                        && rect.left < viewportWidth
                        && rect.top < viewportHeight;
                    return {
                        index,
                        summary,
                        utility,
                        visible,
                        area: rect.width * rect.height,
                        centerY: rect.top + (rect.height / 2),
                    };
                }).filter((candidate) => candidate.visible && !candidate.utility);

                candidates.sort((lhs, rhs) => {
                    if (rhs.area !== lhs.area)
                        return rhs.area - lhs.area;
                    return Math.abs(lhs.centerY - (viewportHeight * 0.30)) - Math.abs(rhs.centerY - (viewportHeight * 0.30));
                });

                const candidate = candidates[0];
                if (!candidate)
                    return null;

                const element = elements[candidate.index];
                element.scrollIntoView({block: "center", inline: "center", behavior: "auto"});
                let rect = element.getBoundingClientRect();
                const desiredCenterY = viewportHeight * 0.30;
                const currentCenterY = rect.top + (rect.height / 2);
                const deltaY = currentCenterY - desiredCenterY;
                if (Math.abs(deltaY) > 8) {
                    window.scrollBy(0, deltaY);
                    rect = element.getBoundingClientRect();
                }

                const tapPoint = hitTestPointForIframe(element, rect, viewportWidth, viewportHeight);

                return {
                    summary: `${candidate.summary} hit=${tapPoint.hitSummary}`,
                    viewportX: clamp(tapPoint.x, viewportWidth * 0.10, viewportWidth * 0.90),
                    viewportY: clamp(tapPoint.y, viewportHeight * 0.12, viewportHeight * 0.46),
                };
            })();
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )

        guard let payload = rawValue as? NSDictionary,
              let viewportX = (payload["viewportX"] as? NSNumber)?.doubleValue,
              let viewportY = (payload["viewportY"] as? NSNumber)?.doubleValue,
              let window = store.webView.window else {
            return nil
        }
        let pointInWindow = store.webView.convert(
            CGPoint(x: viewportX, y: viewportY),
            to: window
        )
        let normalizedX = pointInWindow.x / max(window.bounds.width, 1)
        let normalizedY = pointInWindow.y / max(window.bounds.height, 1)
        return RemoteTapTargetDiagnostics(
            normalizedTap: CGVector(dx: normalizedX, dy: normalizedY),
            summary: (payload["summary"] as? String) ?? "<iframe>"
        )
    }
}

private final class BrowserDiagnosticsOverlayView: UIVisualEffectView {
    struct UITestState {
        let domIsSelecting: Bool
        let domSelectedPreview: String
        let domSelectedLineage: String
        let domSelectionDebug: String
        let domError: String
        let remoteTapTargetSummary: String
        let remoteTapPoint: String
    }

    private let terminationCountLabel = UILabel()
    private let didFinishCountLabel = UILabel()
    private let currentURLLabel = UILabel()
    private let lastErrorLabel = UILabel()
    private let openInspectorButton = UIButton(type: .system)
    private let beginNativeSelectionButton = UIButton(type: .system)
    private let focusRemoteTapTargetButton = UIButton(type: .system)
    private let domIsSelectingLabel = UILabel()
    private let domSelectedPreviewLabel = UILabel()
    private let domSelectedLineageLabel = UILabel()
    private let domSelectionDebugLabel = UILabel()
    private let domErrorLabel = UILabel()
    private let remoteTapTargetSummaryLabel = UILabel()
    private let remoteTapPointLabel = UILabel()

    init() {
        super.init(effect: UIBlurEffect(style: .systemThinMaterial))
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 10
        clipsToBounds = true
        accessibilityIdentifier = "Monocly.diagnostics.panel"

        openInspectorButton.configuration = .tinted()
        openInspectorButton.configuration?.title = "Open Inspector"
        openInspectorButton.accessibilityIdentifier = "Monocly.inspectorHarness.openInspector"
        openInspectorButton.isHidden = true

        beginNativeSelectionButton.configuration = .tinted()
        beginNativeSelectionButton.configuration?.title = "Native Pick"
        beginNativeSelectionButton.accessibilityIdentifier = "Monocly.diagnostics.beginNativeSelection"
        beginNativeSelectionButton.isHidden = true

        focusRemoteTapTargetButton.configuration = .tinted()
        focusRemoteTapTargetButton.configuration?.title = "Focus Iframe"
        focusRemoteTapTargetButton.accessibilityIdentifier = "Monocly.diagnostics.focusRemoteTapTarget"
        focusRemoteTapTargetButton.isHidden = true

        let buttonStack = UIStackView(arrangedSubviews: [
            openInspectorButton,
            beginNativeSelectionButton,
            focusRemoteTapTargetButton
        ])
        buttonStack.axis = .horizontal
        buttonStack.alignment = .fill
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 6

        let arrangedSubviews: [UIView] = [
            buttonStack,
            terminationCountLabel,
            didFinishCountLabel,
            currentURLLabel,
            lastErrorLabel
        ]

        let stackView = UIStackView(arrangedSubviews: arrangedSubviews)
        stackView.axis = .vertical
        stackView.alignment = .leading
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)

        for label in [terminationCountLabel, didFinishCountLabel, currentURLLabel, lastErrorLabel] {
            label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            label.numberOfLines = 2
        }

        for label in [
            domIsSelectingLabel,
            domSelectedPreviewLabel,
            domSelectedLineageLabel,
            domSelectionDebugLabel,
            domErrorLabel,
            remoteTapTargetSummaryLabel,
            remoteTapPointLabel,
        ] {
            label.font = .monospacedSystemFont(ofSize: 6, weight: .regular)
            label.numberOfLines = 1
            label.textColor = .clear
            label.alpha = 0.01
            label.isAccessibilityElement = true
            label.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: contentView.topAnchor),
                label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                label.widthAnchor.constraint(equalToConstant: 1),
                label.heightAnchor.constraint(equalToConstant: 1)
            ])
        }

        terminationCountLabel.accessibilityIdentifier = "Monocly.diagnostics.terminationCount"
        didFinishCountLabel.accessibilityIdentifier = "Monocly.diagnostics.didFinishCount"
        currentURLLabel.accessibilityIdentifier = "Monocly.diagnostics.currentURL"
        lastErrorLabel.accessibilityIdentifier = "Monocly.diagnostics.lastNavigationError"
        domIsSelectingLabel.accessibilityIdentifier = "Monocly.diagnostics.domIsSelecting"
        domSelectedPreviewLabel.accessibilityIdentifier = "Monocly.diagnostics.domSelectedPreview"
        domSelectedLineageLabel.accessibilityIdentifier = "Monocly.diagnostics.domSelectedLineage"
        domSelectionDebugLabel.accessibilityIdentifier = "Monocly.diagnostics.domSelectionDebug"
        domErrorLabel.accessibilityIdentifier = "Monocly.diagnostics.domError"
        remoteTapTargetSummaryLabel.accessibilityIdentifier = "Monocly.diagnostics.remoteTapTargetSummary"
        remoteTapPointLabel.accessibilityIdentifier = "Monocly.diagnostics.remoteTapPoint"

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

    func update(with store: BrowserStore, uiTestState: UITestState? = nil) {
        terminationCountLabel.text = "terminationCount=\(store.webContentTerminationCount)"
        didFinishCountLabel.text = "didFinishCount=\(store.didFinishNavigationCount)"
        currentURLLabel.text = "currentURL=\(store.currentURL?.absoluteString ?? "n/a")"
        lastErrorLabel.text = "lastError=\(store.lastNavigationErrorDescription ?? "n/a")"
        domIsSelectingLabel.text = "domIsSelecting=\(uiTestState?.domIsSelecting == true ? 1 : 0)"
        domSelectedPreviewLabel.text = "domSelectedPreview=\(uiTestState?.domSelectedPreview ?? "n/a")"
        domSelectedLineageLabel.text = "domSelectedLineage=\(uiTestState?.domSelectedLineage ?? "n/a")"
        domSelectionDebugLabel.text = "domSelectionDebug=\(uiTestState?.domSelectionDebug ?? "n/a")"
        domErrorLabel.text = "domError=\(uiTestState?.domError ?? "n/a")"
        remoteTapTargetSummaryLabel.text = "remoteTapTargetSummary=\(uiTestState?.remoteTapTargetSummary ?? "n/a")"
        remoteTapPointLabel.text = "remoteTapPoint=\(uiTestState?.remoteTapPoint ?? "n/a")"
    }

    func configureInspectorOpenAction(_ action: @escaping () -> Void) {
        openInspectorButton.isHidden = false
        openInspectorButton.removeTarget(nil, action: nil, for: .primaryActionTriggered)
        openInspectorButton.addAction(
            UIAction { _ in
                action()
            },
            for: .primaryActionTriggered
        )
    }

    func configureBeginNativeSelectionAction(_ action: @escaping () -> Void) {
        beginNativeSelectionButton.isHidden = false
        beginNativeSelectionButton.removeTarget(nil, action: nil, for: .primaryActionTriggered)
        beginNativeSelectionButton.addAction(
            UIAction { _ in
                action()
            },
            for: .primaryActionTriggered
        )
    }

    func configureFocusRemoteTapTargetAction(_ action: @escaping () -> Void) {
        focusRemoteTapTargetButton.isHidden = false
        focusRemoteTapTargetButton.removeTarget(nil, action: nil, for: .primaryActionTriggered)
        focusRemoteTapTargetButton.addAction(
            UIAction { _ in
                action()
            },
            for: .primaryActionTriggered
        )
    }
}
#endif
