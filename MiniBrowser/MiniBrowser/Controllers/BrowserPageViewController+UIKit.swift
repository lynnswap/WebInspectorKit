#if canImport(UIKit)
import OSLog
import UIKit
import WebInspectorKit

@MainActor
final class BrowserPageViewController: UIViewController {
    private enum ChromePlacement {
        case compactToolbar
        case regularNavigationBar
    }

    private let store: BrowserStore
    private let inspectorController: WIModel
    private let launchConfiguration: BrowserLaunchConfiguration
    private let inspectorCoordinator = BrowserInspectorCoordinator()
    private let logger = Logger(subsystem: "MiniBrowser", category: "BrowserPageViewController")

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
    private lazy var regularNavigationButtonGroup = UIBarButtonItemGroup(
        barButtonItems: [regularBackButtonItem, regularForwardButtonItem],
        representativeItem: nil
    )
    private lazy var regularInspectorButtonGroup = UIBarButtonItemGroup(
        barButtonItems: [regularInspectorButtonItem],
        representativeItem: nil
    )
    private lazy var diagnosticsPanel = BrowserDiagnosticsOverlayView()

    private var viewportCoordinator: BrowserViewportStateCoordinator?
    private var storeObserverID: UUID?
    private var didAutoPresentInspector = false
    private var didAutoStartSelection = false
    private var progressHeightConstraint: NSLayoutConstraint?
    private var currentChromePlacement: ChromePlacement?

    init(
        store: BrowserStore,
        inspectorController: WIModel,
        launchConfiguration: BrowserLaunchConfiguration
    ) {
        self.store = store
        self.inspectorController = inspectorController
        self.launchConfiguration = launchConfiguration
        super.init(nibName: nil, bundle: nil)
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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViewHierarchy()
        configureChrome()
        viewportCoordinator = BrowserViewportStateCoordinator(
            hostViewController: self,
            webView: store.webView
        )

        storeObserverID = store.addStateObserver { [weak self] in
            self?.renderState()
            self?.maybeAutoPresentInspectorIfNeeded()
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
        _ = openInspector(tabs: [.dom(), .network()])
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
            accessibilityIdentifier: "MiniBrowser.openInspectorButton.compact"
        )
        configureNavigationButtonItem(
            compactBackButtonItem,
            action: #selector(handleBackAction(_:)),
            accessibilityIdentifier: "MiniBrowser.navigation.back.compact"
        )
        configureNavigationButtonItem(
            compactForwardButtonItem,
            action: #selector(handleForwardAction(_:)),
            accessibilityIdentifier: "MiniBrowser.navigation.forward.compact"
        )
        configureNavigationButtonItem(
            regularInspectorButtonItem,
            action: #selector(handleOpenInspectorAction(_:)),
            accessibilityIdentifier: "MiniBrowser.openInspectorButton.regular"
        )
        configureNavigationButtonItem(
            regularBackButtonItem,
            action: #selector(handleBackAction(_:)),
            accessibilityIdentifier: "MiniBrowser.navigation.back.regular"
        )
        configureNavigationButtonItem(
            regularForwardButtonItem,
            action: #selector(handleForwardAction(_:)),
            accessibilityIdentifier: "MiniBrowser.navigation.forward.regular"
        )

        applyChromePlacement(force: true)
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

        viewportCoordinator?.updateChromeState()
    }

    private func resolvedChromePlacement() -> ChromePlacement {
        traitCollection.horizontalSizeClass == .regular ? .regularNavigationBar : .compactToolbar
    }

    private func syncNavigationButtonStates() {
        let canGoBack = store.canGoBack
        let canGoForward = store.canGoForward

        compactBackButtonItem.isEnabled = canGoBack
        regularBackButtonItem.isEnabled = canGoBack
        compactForwardButtonItem.isEnabled = canGoForward
        regularForwardButtonItem.isEnabled = canGoForward
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

        let didPresent = openInspector(tabs: launchConfiguration.autoOpenInspectorTabs)
        didAutoPresentInspector = didPresent
        maybeAutoStartSelectionIfNeeded(didPresent: didPresent)
    }

    private func openInspector(tabs: [WITab]) -> Bool {
        inspectorCoordinator.present(
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

        Task { @MainActor in
            logger.notice("auto-starting DOM selection mode for diagnostics")
            for _ in 0..<100 {
                if inspectorController.dom.hasPageWebView {
                    inspectorController.dom.toggleSelectionMode()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            logger.error("auto-starting DOM selection mode timed out before page web view became available")
            didAutoStartSelection = false
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

    var compactForwardButtonItemForTesting: UIBarButtonItem {
        compactForwardButtonItem
    }

    var compactInspectorButtonItemForTesting: UIBarButtonItem {
        compactInspectorButtonItem
    }

    var regularBackButtonItemForTesting: UIBarButtonItem {
        regularBackButtonItem
    }

    var regularForwardButtonItemForTesting: UIBarButtonItem {
        regularForwardButtonItem
    }

    var regularInspectorButtonItemForTesting: UIBarButtonItem {
        regularInspectorButtonItem
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
        accessibilityIdentifier = "MiniBrowser.diagnostics.panel"

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

        terminationCountLabel.accessibilityIdentifier = "MiniBrowser.diagnostics.terminationCount"
        didFinishCountLabel.accessibilityIdentifier = "MiniBrowser.diagnostics.didFinishCount"
        currentURLLabel.accessibilityIdentifier = "MiniBrowser.diagnostics.currentURL"
        lastErrorLabel.accessibilityIdentifier = "MiniBrowser.diagnostics.lastNavigationError"

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
