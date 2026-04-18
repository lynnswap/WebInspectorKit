#if canImport(UIKit)
import OSLog
import UIKit
@_spi(Monocly) import WebInspectorKit

private let inspectorHarnessLogger = Logger(subsystem: "Monocly", category: "InspectorHarness")
@MainActor
final class BrowserInspectorSheetHostingController: UIViewController {
    private let browserStore: BrowserStore
    private let inspectorController: WIInspectorController
    private let launchConfiguration: BrowserLaunchConfiguration
    private let tabs: [WITab]
    private let inspectorContainer: WITabViewController
    private let harnessPanel: BrowserInspectorUITestHarnessPanel?

    private var pollTask: Task<Void, Never>?

    init(
        browserStore: BrowserStore,
        inspectorController: WIInspectorController,
        launchConfiguration: BrowserLaunchConfiguration,
        tabs: [WITab]
    ) {
        self.browserStore = browserStore
        self.inspectorController = inspectorController
        self.launchConfiguration = launchConfiguration
        self.tabs = tabs
        self.inspectorContainer = WITabViewController(
            inspectorController,
            webView: browserStore.webView,
            tabs: tabs
        )
        if launchConfiguration.uiTestScenario?.showsInspectorHarnessPanel == true {
            self.harnessPanel = BrowserInspectorUITestHarnessPanel(
                fixturePages: launchConfiguration.uiTestFixturePages,
                onLoadPage: { [weak browserStore] page in
                    browserStore?.load(url: page.url)
                },
                onSelectNode: { [weak inspectorController] target in
                    Task { @MainActor in
                        inspectorHarnessLogger.notice("selectNode tapped selector=\(target.selector, privacy: .public)")
                        do {
                            try await inspectorController?.dom.selectNodeForTesting(
                                preview: target.expectedPreview,
                                selectorPath: target.expectedSelector
                            )
                        } catch {
                            inspectorHarnessLogger.error("selectNode failed selector=\(target.selector, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                        }
                        if let dom = inspectorController?.dom {
                            inspectorHarnessLogger.notice(
                                "selectNode finished selector=\(target.selector, privacy: .public) selectedPreview=\(dom.currentSelectedNodePreviewForDiagnostics() ?? "nil", privacy: .public) selectedSelector=\(dom.currentSelectedNodeSelectorForDiagnostics() ?? "nil", privacy: .public) error=\(dom.document.errorMessage ?? "nil", privacy: .public)"
                            )
                        }
                    }
                },
                onGoBack: { [weak browserStore] in
                    browserStore?.goBack()
                },
                onGoForward: { [weak browserStore] in
                    browserStore?.goForward()
                }
            )
        } else {
            self.harnessPanel = nil
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        pollTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        installInspectorContainer()
        installHarnessPanelIfNeeded()
        startPollingHarnessStateIfNeeded()
        updateHarnessState()
    }

    private func installInspectorContainer() {
        addChild(inspectorContainer)
        inspectorContainer.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inspectorContainer.view)
        NSLayoutConstraint.activate([
            inspectorContainer.view.topAnchor.constraint(equalTo: view.topAnchor),
            inspectorContainer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inspectorContainer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inspectorContainer.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        inspectorContainer.didMove(toParent: self)
    }

    private func installHarnessPanelIfNeeded() {
        guard let harnessPanel else {
            return
        }
        harnessPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(harnessPanel)
        NSLayoutConstraint.activate([
            harnessPanel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            harnessPanel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            harnessPanel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    private func startPollingHarnessStateIfNeeded() {
        guard harnessPanel != nil else {
            return
        }
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                self.updateHarnessState()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func updateHarnessState() {
        guard let harnessPanel else {
            return
        }

        harnessPanel.apply(
            state: .init(
                browserURL: browserStore.currentURL?.absoluteString ?? "n/a",
                domDocumentURL: inspectorController.dom.currentDocumentURLForDiagnostics() ?? "n/a",
                domContextID: inspectorController.dom.currentContextIDForDiagnostics().map(String.init) ?? "n/a",
                domIsSelecting: inspectorController.dom.isSelectingElement,
                domSelectedPreview: inspectorController.dom.currentSelectedNodePreviewForDiagnostics() ?? "n/a",
                domSelectedSelector: inspectorController.dom.currentSelectedNodeSelectorForDiagnostics() ?? "n/a",
                domSelectionDebug: inspectorController.dom.lastSelectionDiagnosticForDiagnostics() ?? "n/a",
                domRootReady: inspectorController.dom.document.rootNode != nil,
                domError: inspectorController.dom.document.errorMessage ?? "n/a",
                canGoBack: browserStore.canGoBack,
                canGoForward: browserStore.canGoForward
            )
        )
    }
}

private struct BrowserInspectorUITestHarnessState {
    let browserURL: String
    let domDocumentURL: String
    let domContextID: String
    let domIsSelecting: Bool
    let domSelectedPreview: String
    let domSelectedSelector: String
    let domSelectionDebug: String
    let domRootReady: Bool
    let domError: String
    let canGoBack: Bool
    let canGoForward: Bool
}

private final class BrowserInspectorUITestHarnessPanel: UIVisualEffectView {
    private let browserURLLabel = UILabel()
    private let domDocumentURLLabel = UILabel()
    private let domContextIDLabel = UILabel()
    private let domIsSelectingLabel = UILabel()
    private let domSelectedPreviewLabel = UILabel()
    private let domSelectedSelectorLabel = UILabel()
    private let domSelectionDebugLabel = UILabel()
    private let domRootStateLabel = UILabel()
    private let domErrorLabel = UILabel()
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private var pageButtons: [UIButton] = []
    private var selectionButtons: [UIButton] = []

    init(
        fixturePages: [BrowserUITestFixturePage],
        onLoadPage: @escaping (BrowserUITestFixturePage) -> Void,
        onSelectNode: @escaping (BrowserUITestSelectionTarget) -> Void,
        onGoBack: @escaping () -> Void,
        onGoForward: @escaping () -> Void
    ) {
        super.init(effect: UIBlurEffect(style: .systemThinMaterial))
        accessibilityIdentifier = "Monocly.inspectorHarness.panel"
        layer.cornerRadius = 12
        clipsToBounds = true

        let pageButtonStack = UIStackView()
        pageButtonStack.axis = .horizontal
        pageButtonStack.alignment = .fill
        pageButtonStack.distribution = .fillEqually
        pageButtonStack.spacing = 8

        for (index, page) in fixturePages.enumerated() {
            let button = UIButton(type: .system)
            button.configuration = .tinted()
            button.configuration?.title = "Page \(index + 1)"
            button.accessibilityIdentifier = "Monocly.inspectorHarness.loadPage\(index + 1)"
            button.addAction(
                UIAction { _ in
                    onLoadPage(page)
                },
                for: .primaryActionTriggered
            )
            pageButtons.append(button)
            pageButtonStack.addArrangedSubview(button)
        }

        let selectionButtonStack = UIStackView()
        selectionButtonStack.axis = .horizontal
        selectionButtonStack.alignment = .fill
        selectionButtonStack.distribution = .fillEqually
        selectionButtonStack.spacing = 8

        let selectionTargets = fixturePages.flatMap(\.selectionTargets)
        for (index, target) in selectionTargets.enumerated() {
            let button = UIButton(type: .system)
            button.configuration = .tinted()
            button.configuration?.title = "Select \(index + 1)"
            button.accessibilityIdentifier = "Monocly.inspectorHarness.selectNode\(index + 1)"
            button.addAction(
                UIAction { _ in
                    onSelectNode(target)
                },
                for: .primaryActionTriggered
            )
            selectionButtons.append(button)
            selectionButtonStack.addArrangedSubview(button)
        }

        backButton.configuration = .tinted()
        backButton.configuration?.title = "Back"
        backButton.accessibilityIdentifier = "Monocly.inspectorHarness.goBack"
        backButton.addAction(
            UIAction { _ in
                onGoBack()
            },
            for: .primaryActionTriggered
        )

        forwardButton.configuration = .tinted()
        forwardButton.configuration?.title = "Forward"
        forwardButton.accessibilityIdentifier = "Monocly.inspectorHarness.goForward"
        forwardButton.addAction(
            UIAction { _ in
                onGoForward()
            },
            for: .primaryActionTriggered
        )

        let navigationButtonStack = UIStackView(arrangedSubviews: [backButton, forwardButton])
        navigationButtonStack.axis = .horizontal
        navigationButtonStack.alignment = .fill
        navigationButtonStack.distribution = .fillEqually
        navigationButtonStack.spacing = 8

        let labelStack = UIStackView(arrangedSubviews: [
            browserURLLabel,
            domDocumentURLLabel,
            domContextIDLabel,
            domIsSelectingLabel,
            domSelectedPreviewLabel,
            domSelectedSelectorLabel,
            domSelectionDebugLabel,
            domRootStateLabel,
            domErrorLabel
        ])
        labelStack.axis = .vertical
        labelStack.alignment = .fill
        labelStack.spacing = 4

        let rootStack = UIStackView(arrangedSubviews: [
            pageButtonStack,
            selectionButtonStack,
            navigationButtonStack,
            labelStack
        ])
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)

        for label in [browserURLLabel, domDocumentURLLabel, domContextIDLabel, domIsSelectingLabel, domSelectedPreviewLabel, domSelectedSelectorLabel, domSelectionDebugLabel, domRootStateLabel, domErrorLabel] {
            label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            label.numberOfLines = 2
            label.textColor = .label
        }
        domSelectionDebugLabel.numberOfLines = 5

        browserURLLabel.accessibilityIdentifier = "Monocly.inspectorHarness.browserURL"
        domDocumentURLLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domDocumentURL"
        domContextIDLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domContextID"
        domIsSelectingLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domIsSelecting"
        domSelectedPreviewLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domSelectedPreview"
        domSelectedSelectorLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domSelectedSelector"
        domSelectionDebugLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domSelectionDebug"
        domRootStateLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domRootState"
        domErrorLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domError"

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            rootStack.widthAnchor.constraint(lessThanOrEqualToConstant: 340)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func apply(state: BrowserInspectorUITestHarnessState) {
        browserURLLabel.text = "browserURL=\(state.browserURL)"
        domDocumentURLLabel.text = "domDocumentURL=\(state.domDocumentURL)"
        domContextIDLabel.text = "domContextID=\(state.domContextID)"
        domIsSelectingLabel.text = "domIsSelecting=\(state.domIsSelecting ? 1 : 0)"
        domSelectedPreviewLabel.text = "domSelectedPreview=\(state.domSelectedPreview)"
        domSelectedSelectorLabel.text = "domSelectedSelector=\(state.domSelectedSelector)"
        domSelectionDebugLabel.text = "domSelectionDebug=\(state.domSelectionDebug)"
        domRootStateLabel.text = "domRootReady=\(state.domRootReady ? 1 : 0)"
        domErrorLabel.text = "domError=\(state.domError)"
        backButton.isEnabled = state.canGoBack
        forwardButton.isEnabled = state.canGoForward
    }
}
#endif
