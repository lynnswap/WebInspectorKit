#if canImport(UIKit)
import OSLog
import UIKit
import WebInspectorKit

@MainActor
final class BrowserPageViewController: UIViewController {
    private let store: BrowserStore
    private let sessionController: WISessionController
    private let launchConfiguration: BrowserLaunchConfiguration
    private let inspectorCoordinator = BrowserInspectorCoordinator()
    private let logger = Logger(subsystem: "MiniBrowser", category: "BrowserPageViewController")

    private let topChromeContainerView = UIView()
    private let bottomChromeContainerView = UIView()
    private let navigationBar = UINavigationBar()
    private let navigationItemModel = UINavigationItem(title: "")
    private let toolbar = UIToolbar()
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
    private lazy var diagnosticsPanel = BrowserDiagnosticsOverlayView()

    private var viewportCoordinator: BrowserViewportStateCoordinator?
    private var storeObserverID: UUID?
    private var didAutoPresentInspector = false
    private var didAutoStartSelection = false
    private var bottomChromeMode: BrowserBottomChromeMode = .normal

    private var progressHeightConstraint: NSLayoutConstraint?
    private var topChromeBottomConstraint: NSLayoutConstraint?
    private var bottomChromeTopConstraint: NSLayoutConstraint?

    init(
        store: BrowserStore,
        sessionController: WISessionController,
        launchConfiguration: BrowserLaunchConfiguration
    ) {
        self.store = store
        self.sessionController = sessionController
        self.launchConfiguration = launchConfiguration
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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViewHierarchy()
        configureChrome()
        viewportCoordinator = BrowserViewportStateCoordinator(hostView: view, webView: store.webView)
        viewportCoordinator?.onInputMetricsChanged = { [weak self] in
            self?.handleViewportInputMetricsChanged()
        }

        storeObserverID = store.addStateObserver { [weak self] in
            self?.renderState()
            self?.maybeAutoPresentInspectorIfNeeded()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyViewportState()
        store.loadInitialRequestIfNeeded()
        maybeAutoPresentInspectorIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyViewportState()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        applyViewportState()
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

        topChromeContainerView.translatesAutoresizingMaskIntoConstraints = false
        topChromeContainerView.backgroundColor = .clear
        topChromeContainerView.clipsToBounds = false
        view.addSubview(topChromeContainerView)

        navigationBar.translatesAutoresizingMaskIntoConstraints = false
        navigationBar.prefersLargeTitles = false
        topChromeContainerView.addSubview(navigationBar)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.trackTintColor = .clear
        topChromeContainerView.addSubview(progressView)

        bottomChromeContainerView.translatesAutoresizingMaskIntoConstraints = false
        bottomChromeContainerView.backgroundColor = .clear
        bottomChromeContainerView.clipsToBounds = false
        view.addSubview(bottomChromeContainerView)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        bottomChromeContainerView.addSubview(toolbar)

        progressHeightConstraint = progressView.heightAnchor.constraint(equalToConstant: 0)
        topChromeBottomConstraint = topChromeContainerView.bottomAnchor.constraint(equalTo: navigationBar.bottomAnchor)
        bottomChromeTopConstraint = bottomChromeContainerView.topAnchor.constraint(equalTo: toolbar.topAnchor)

        var constraints = [
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            topChromeContainerView.topAnchor.constraint(equalTo: view.topAnchor),
            topChromeContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topChromeContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            navigationBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            navigationBar.leadingAnchor.constraint(equalTo: topChromeContainerView.leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: topChromeContainerView.trailingAnchor),

            progressView.bottomAnchor.constraint(equalTo: topChromeContainerView.bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: topChromeContainerView.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: topChromeContainerView.trailingAnchor),

            bottomChromeContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomChromeContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomChromeContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            toolbar.leadingAnchor.constraint(equalTo: bottomChromeContainerView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: bottomChromeContainerView.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ]

        if let topChromeBottomConstraint {
            constraints.append(topChromeBottomConstraint)
        }
        if let bottomChromeTopConstraint {
            constraints.append(bottomChromeTopConstraint)
        }
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
        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithTransparentBackground()
        navigationAppearance.shadowColor = .clear
        navigationAppearance.backgroundColor = .clear
        navigationBar.standardAppearance = navigationAppearance
        navigationBar.scrollEdgeAppearance = navigationAppearance
        navigationBar.compactAppearance = navigationAppearance
        navigationBar.compactScrollEdgeAppearance = navigationAppearance
        navigationBar.isTranslucent = true

        navigationItemModel.title = store.displayTitle
        inspectorButtonItem.target = self
        inspectorButtonItem.action = #selector(handleOpenInspectorAction(_:))
        inspectorButtonItem.accessibilityIdentifier = "MiniBrowser.openInspectorButton"
        navigationItemModel.rightBarButtonItems = [inspectorButtonItem]
        navigationBar.setItems([navigationItemModel], animated: false)

        let toolbarAppearance = UIToolbarAppearance()
        toolbarAppearance.configureWithTransparentBackground()
        toolbarAppearance.shadowColor = .clear
        toolbarAppearance.backgroundColor = .clear
        toolbar.standardAppearance = toolbarAppearance
        toolbar.compactAppearance = toolbarAppearance
        toolbar.scrollEdgeAppearance = toolbarAppearance
        toolbar.isTranslucent = true

        backButtonItem.target = self
        backButtonItem.action = #selector(handleBackAction(_:))

        forwardButtonItem.target = self
        forwardButtonItem.action = #selector(handleForwardAction(_:))

        toolbar.setItems([
            backButtonItem,
            forwardButtonItem,
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        ], animated: false)
    }

    private func renderState() {
        guard isViewLoaded else {
            return
        }

        navigationItemModel.title = store.displayTitle
        backButtonItem.isEnabled = store.canGoBack
        forwardButtonItem.isEnabled = store.canGoForward

        let progressIsVisible = store.isShowingProgress
        progressView.progress = Float(store.estimatedProgress)
        progressView.isHidden = progressIsVisible == false
        progressHeightConstraint?.constant = progressIsVisible ? 2 : 0

        view.backgroundColor = store.underPageBackgroundColor ?? .systemBackground

        if launchConfiguration.shouldShowDiagnostics {
            diagnosticsPanel.update(with: store)
        }

        applyViewportState()
    }

    private func handleViewportInputMetricsChanged() {
        updateBottomChromeMode()
        applyViewportState()
    }

    private func updateBottomChromeMode() {
        let nextMode: BrowserBottomChromeMode
        if (viewportCoordinator?.keyboardOverlapHeight() ?? 0) > 0 {
            nextMode = .hiddenForKeyboard
        } else {
            nextMode = .normal
        }

        guard nextMode != bottomChromeMode else {
            return
        }

        bottomChromeMode = nextMode
        let shouldHideBottomChrome = nextMode == .hiddenForKeyboard
        bottomChromeContainerView.isHidden = shouldHideBottomChrome
        toolbar.isHidden = shouldHideBottomChrome
    }

    private func applyViewportState() {
        guard let viewportCoordinator, isViewLoaded else {
            return
        }

        updateBottomChromeMode()
        view.layoutIfNeeded()

        let topChromeHeight = topChromeContainerView.frame.maxY
        let bottomChromeHeight: CGFloat
        if bottomChromeMode == .normal {
            bottomChromeHeight = max(0, view.bounds.maxY - bottomChromeContainerView.frame.minY)
        } else {
            bottomChromeHeight = 0
        }

        let state = viewportCoordinator.makeViewportState(
            safeAreaInsets: view.safeAreaInsets,
            topChromeHeight: topChromeHeight,
            bottomChromeHeight: bottomChromeHeight,
            bottomChromeMode: bottomChromeMode
        )
        viewportCoordinator.applyViewportState(state)
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
            sessionController: sessionController,
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
                if sessionController.domStore.hasPageWebView {
                    sessionController.domStore.toggleSelectionMode()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            logger.error("auto-starting DOM selection mode timed out before page web view became available")
            didAutoStartSelection = false
        }
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
