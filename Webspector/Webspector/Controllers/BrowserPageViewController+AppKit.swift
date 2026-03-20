#if canImport(AppKit)
import AppKit
import OSLog
import WebInspectorKit

@MainActor
final class BrowserPageViewController: NSViewController {
    private let store: BrowserStore
    private let inspectorController: WIInspectorController
    private let launchConfiguration: BrowserLaunchConfiguration
    private let logger = Logger(subsystem: "Webspector", category: "BrowserPageViewController")

    private let progressIndicator = NSProgressIndicator()
    private lazy var diagnosticsPanel = BrowserDiagnosticsOverlayView()

    private var storeObserverID: UUID?
    private var didAutoPresentInspector = false
    private var didAutoStartSelection = false

    init(
        store: BrowserStore,
        inspectorController: WIInspectorController,
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
        tearDownStoreObserverIfNeeded()
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViewHierarchy()
        startObservingStoreIfNeeded()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startObservingStoreIfNeeded()
        maybeAutoPresentInspectorIfNeeded()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if view.window == nil {
            tearDownStoreObserverIfNeeded()
        }
    }

    func handleHostWindowDidAttach() {
        maybeAutoPresentInspectorIfNeeded()
    }

    private func configureViewHierarchy() {
        let webView = store.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.isIndeterminate = false
        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        view.addSubview(progressIndicator)

        var constraints = [
            progressIndicator.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressIndicator.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            webView.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ]

        if launchConfiguration.shouldShowDiagnostics {
            diagnosticsPanel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(diagnosticsPanel)
            constraints.append(contentsOf: [
                diagnosticsPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                diagnosticsPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
            ])
        }

        NSLayoutConstraint.activate(constraints)
    }

    private func renderState() {
        guard isViewLoaded else {
            return
        }

        title = store.displayTitle
        progressIndicator.doubleValue = store.estimatedProgress
        progressIndicator.isHidden = store.isShowingProgress == false
        view.layer?.backgroundColor = (store.underPageBackgroundColor ?? .windowBackgroundColor).cgColor

        if launchConfiguration.shouldShowDiagnostics {
            diagnosticsPanel.update(with: store)
        }
    }

    private func startObservingStoreIfNeeded() {
        guard storeObserverID == nil else {
            return
        }

        storeObserverID = store.addStateObserver { [weak self] in
            self?.renderState()
            self?.maybeAutoPresentInspectorIfNeeded()
        }
    }

    private func tearDownStoreObserverIfNeeded() {
        guard let storeObserverID else {
            return
        }
        store.removeStateObserver(storeObserverID)
        self.storeObserverID = nil
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

        let didPresent = BrowserInspectorCoordinator.present(
            from: view.window,
            browserStore: store,
            inspectorController: inspectorController,
            tabs: launchConfiguration.autoOpenInspectorTabs
        )
        didAutoPresentInspector = didPresent
        maybeAutoStartSelectionIfNeeded(didPresent: didPresent)
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
}

private final class BrowserDiagnosticsOverlayView: NSVisualEffectView {
    private let terminationCountLabel = NSTextField(labelWithString: "")
    private let didFinishCountLabel = NSTextField(labelWithString: "")
    private let currentURLLabel = NSTextField(labelWithString: "")
    private let lastErrorLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        identifier = NSUserInterfaceItemIdentifier("Webspector.diagnostics.panel")

        let stackView = NSStackView(views: [
            terminationCountLabel,
            didFinishCountLabel,
            currentURLLabel,
            lastErrorLabel
        ])
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false

        for label in [terminationCountLabel, didFinishCountLabel, currentURLLabel, lastErrorLabel] {
            label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 2
        }

        terminationCountLabel.identifier = NSUserInterfaceItemIdentifier("Webspector.diagnostics.terminationCount")
        didFinishCountLabel.identifier = NSUserInterfaceItemIdentifier("Webspector.diagnostics.didFinishCount")
        currentURLLabel.identifier = NSUserInterfaceItemIdentifier("Webspector.diagnostics.currentURL")
        lastErrorLabel.identifier = NSUserInterfaceItemIdentifier("Webspector.diagnostics.lastNavigationError")

        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(with store: BrowserStore) {
        terminationCountLabel.stringValue = "terminationCount=\(store.webContentTerminationCount)"
        didFinishCountLabel.stringValue = "didFinishCount=\(store.didFinishNavigationCount)"
        currentURLLabel.stringValue = "currentURL=\(store.currentURL?.absoluteString ?? "n/a")"
        lastErrorLabel.stringValue = "lastError=\(store.lastNavigationErrorDescription ?? "n/a")"
    }
}
#endif
