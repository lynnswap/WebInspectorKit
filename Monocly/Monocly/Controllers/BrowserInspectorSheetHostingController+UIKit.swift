#if canImport(UIKit)
import OSLog
import UIKit
import WebKit
@_spi(Monocly) import WebInspectorKit

private let inspectorHarnessLogger = Logger(subsystem: "Monocly", category: "InspectorHarness")
@MainActor
final class BrowserInspectorSheetHostingController: UIViewController {
    private struct RemoteTapTargetDiagnostics {
        let normalizedTap: CGVector
        let summary: String
    }

    private let browserStore: BrowserStore
    private let inspectorController: WIInspectorController
    private let launchConfiguration: BrowserLaunchConfiguration
    private let tabs: [WITab]
    private let inspectorContainer: WITabViewController
#if DEBUG
    private var harnessPanel: BrowserInspectorUITestHarnessPanel?
#else
    private let harnessPanel: UIView? = nil
#endif

    private var pollTask: Task<Void, Never>?
    private var latestRemoteTapTargetDiagnostics: RemoteTapTargetDiagnostics?

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
        super.init(nibName: nil, bundle: nil)
        #if DEBUG
        if launchConfiguration.uiTestScenario?.showsInspectorHarnessPanel == true {
            self.harnessPanel = BrowserInspectorUITestHarnessPanel(
                fixturePages: launchConfiguration.uiTestFixturePages,
                onBeginNativeSelection: { [weak inspectorController] in
                    Task { @MainActor in
                        do {
                            try await inspectorController?.dom.beginSelectionMode()
                        } catch {
                            inspectorHarnessLogger.error(
                                "beginNativeSelection failed error=\(error.localizedDescription, privacy: .public)"
                            )
                        }
                    }
                },
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
                },
                onFocusRemoteTapTarget: { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.focusPreferredRemoteTapTargetForTesting()
                    }
                }
            )
        } else {
            self.harnessPanel = nil
        }
        #endif
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
        view.backgroundColor = .clear
        installInspectorContainer()
        installHarnessPanelIfNeeded()
        startPollingHarnessStateIfNeeded()
        Task { @MainActor [weak self] in
            await self?.updateHarnessState()
        }
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
#if DEBUG
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
#endif
    }

    private func startPollingHarnessStateIfNeeded() {
#if DEBUG
        guard harnessPanel != nil else {
            return
        }
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await self.updateHarnessState()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
#endif
    }

    private func updateHarnessState() async {
#if DEBUG
        guard let harnessPanel else {
            return
        }

        let treeDiagnostics = await currentDOMTreeDiagnostics()
        let visibleNodes = inspectorController.dom.visibleNodeSummariesForDiagnostics(limit: 40).joined(separator: "\n")

        harnessPanel.apply(
            state: .init(
                browserURL: browserStore.currentURL?.absoluteString ?? "n/a",
                domDocumentURL: inspectorController.dom.currentDocumentURLForDiagnostics() ?? "n/a",
                domContextID: inspectorController.dom.currentContextIDForDiagnostics().map(String.init) ?? "n/a",
                domIsSelecting: inspectorController.dom.isSelectingElement,
                domSelectedPreview: inspectorController.dom.currentSelectedNodePreviewForDiagnostics() ?? "n/a",
                domSelectedSelector: inspectorController.dom.currentSelectedNodeSelectorForDiagnostics() ?? "n/a",
                domTreeSelectedPreview: treeDiagnostics.preview,
                domTreeSelectedLineage: treeDiagnostics.lineage,
                domTreeSelectedVisible: treeDiagnostics.isVisible,
                domSelectionDebug: inspectorController.dom.lastSelectionDiagnosticForDiagnostics() ?? "n/a",
                domVisibleNodes: visibleNodes,
                domNativeSelectionState: inspectorController.dom.nativeInspectorInteractionStateForDiagnostics() ?? "n/a",
                domRootReady: inspectorController.dom.document.rootNode != nil,
                domError: inspectorController.dom.document.errorMessage ?? "n/a",
                remoteTapTargetSummary: latestRemoteTapTargetDiagnostics?.summary ?? "n/a",
                remoteTapPoint: latestRemoteTapTargetDiagnostics.map {
                    String(format: "%.4f,%.4f", $0.normalizedTap.dx, $0.normalizedTap.dy)
                } ?? "n/a",
                canGoBack: browserStore.canGoBack,
                canGoForward: browserStore.canGoForward
            )
        )
#endif
    }

#if DEBUG
    private func currentDOMTreeDiagnostics() async -> (preview: String, lineage: String, isVisible: Bool?) {
        guard let domViewController = findDOMViewController(in: inspectorContainer) else {
            return ("n/a", "n/a", nil)
        }
        let preview = await domViewController.selectedTreeNodePreviewForDiagnostics() ?? "n/a"
        let lineage = await domViewController.selectedTreeNodeLineageForDiagnostics() ?? "n/a"
        let isVisible = await domViewController.selectedTreeNodeIsVisibleForDiagnostics()
        return (preview, lineage, isVisible)
    }

    private func findDOMViewController(in viewController: UIViewController) -> WIDOMViewController? {
        if let domViewController = viewController as? WIDOMViewController {
            return domViewController
        }
        for child in viewController.children {
            if let domViewController = findDOMViewController(in: child) {
                return domViewController
            }
        }
        if let presentedViewController = viewController.presentedViewController {
            return findDOMViewController(in: presentedViewController)
        }
        return nil
    }

    private func focusPreferredRemoteTapTargetForTesting() async {
        do {
            latestRemoteTapTargetDiagnostics = try await resolvePreferredRemoteTapTargetForTesting()
            if let latestRemoteTapTargetDiagnostics {
                inspectorHarnessLogger.notice(
                    "focusRemoteTapTarget resolved summary=\(latestRemoteTapTargetDiagnostics.summary, privacy: .public) tap=\(String(format: "%.4f,%.4f", latestRemoteTapTargetDiagnostics.normalizedTap.dx, latestRemoteTapTargetDiagnostics.normalizedTap.dy), privacy: .public)"
                )
            } else {
                inspectorHarnessLogger.notice("focusRemoteTapTarget resolved no candidate")
            }
        } catch {
            latestRemoteTapTargetDiagnostics = nil
            inspectorHarnessLogger.error(
                "focusRemoteTapTarget failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
        await updateHarnessState()
    }

    private func resolvePreferredRemoteTapTargetForTesting() async throws -> RemoteTapTargetDiagnostics? {
        let desiredNormalizedY = preferredRemoteTapNormalizedYInPageViewport()
        let rawValue = try await browserStore.webView.callAsyncJavaScriptCompat(
            """
            return (function(desiredNormalizedY) {
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
                const desiredCenterY = viewportHeight * desiredNormalizedY;
                const currentCenterY = rect.top + (rect.height / 2);
                const deltaY = currentCenterY - desiredCenterY;
                if (Math.abs(deltaY) > 8) {
                    window.scrollBy(0, deltaY);
                    rect = element.getBoundingClientRect();
                }

                const tapPoint = hitTestPointForIframe(element, rect, viewportWidth, viewportHeight);

                return {
                    summary: `${candidate.summary} hit=${tapPoint.hitSummary}`,
                    candidateCount: candidates.length,
                    viewportX: clamp(tapPoint.x, viewportWidth * 0.10, viewportWidth * 0.90),
                    viewportY: clamp(tapPoint.y, viewportHeight * 0.10, viewportHeight * 0.90),
                    width: rect.width,
                    height: rect.height,
                };
            })(desiredNormalizedY);
            """,
            arguments: [
                "desiredNormalizedY": desiredNormalizedY
            ],
            in: nil,
            contentWorld: .page
        )

        guard let payload = rawValue as? NSDictionary else {
            return nil
        }
        guard let viewportX = (payload["viewportX"] as? NSNumber)?.doubleValue,
              let viewportY = (payload["viewportY"] as? NSNumber)?.doubleValue,
              let window = browserStore.webView.window else {
            return nil
        }
        let tapPointInWindow = browserStore.webView.convert(
            CGPoint(x: viewportX, y: viewportY),
            to: window
        )
        let normalizedX = tapPointInWindow.x / max(window.bounds.width, 1)
        let normalizedY = tapPointInWindow.y / max(window.bounds.height, 1)
        let summary = (payload["summary"] as? String) ?? "<iframe>"
        return RemoteTapTargetDiagnostics(
            normalizedTap: CGVector(dx: normalizedX, dy: normalizedY),
            summary: summary
        )
    }

    private func preferredRemoteTapNormalizedYInPageViewport() -> Double {
        guard let window = browserStore.webView.window ?? view.window else {
            return 0.22
        }

        let webViewFrameInWindow = browserStore.webView.convert(browserStore.webView.bounds, to: window)
        let sheetFrameInWindow = view.convert(view.bounds, to: window)
        let exposedBottom = min(webViewFrameInWindow.maxY, sheetFrameInWindow.minY) - 24
        guard exposedBottom > webViewFrameInWindow.minY else {
            return 0.22
        }

        let targetWindowY = webViewFrameInWindow.minY + ((exposedBottom - webViewFrameInWindow.minY) * 0.72)
        let targetPointInWebView = browserStore.webView.convert(
            CGPoint(x: webViewFrameInWindow.midX, y: targetWindowY),
            from: window
        )
        let normalizedY = targetPointInWebView.y / max(browserStore.webView.bounds.height, 1)
        return min(max(normalizedY, 0.12), 0.40)
    }
#endif
}

#if DEBUG
private struct BrowserInspectorUITestHarnessState {
    let browserURL: String
    let domDocumentURL: String
    let domContextID: String
    let domIsSelecting: Bool
    let domSelectedPreview: String
    let domSelectedSelector: String
    let domTreeSelectedPreview: String
    let domTreeSelectedLineage: String
    let domTreeSelectedVisible: Bool?
    let domSelectionDebug: String
    let domVisibleNodes: String
    let domNativeSelectionState: String
    let domRootReady: Bool
    let domError: String
    let remoteTapTargetSummary: String
    let remoteTapPoint: String
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
    private let domTreeSelectedPreviewLabel = UILabel()
    private let domTreeSelectedLineageLabel = UILabel()
    private let domTreeSelectedVisibleLabel = UILabel()
    private let domSelectionDebugLabel = UILabel()
    private let domVisibleNodesLabel = UILabel()
    private let domNativeSelectionStateLabel = UILabel()
    private let domRootStateLabel = UILabel()
    private let domErrorLabel = UILabel()
    private let remoteTapTargetSummaryLabel = UILabel()
    private let remoteTapPointLabel = UILabel()
    private let focusRemoteTapTargetButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private var pageButtons: [UIButton] = []
    private var selectionButtons: [UIButton] = []
    private lazy var diagnosticLabels: [UILabel] = [
        browserURLLabel,
        domDocumentURLLabel,
        domContextIDLabel,
        domIsSelectingLabel,
        domSelectedPreviewLabel,
        domSelectedSelectorLabel,
        domTreeSelectedPreviewLabel,
        domTreeSelectedLineageLabel,
        domTreeSelectedVisibleLabel,
        domSelectionDebugLabel,
        domVisibleNodesLabel,
        domNativeSelectionStateLabel,
        domRootStateLabel,
        domErrorLabel,
        remoteTapTargetSummaryLabel,
        remoteTapPointLabel,
    ]

    init(
        fixturePages: [BrowserUITestFixturePage],
        onBeginNativeSelection: @escaping () -> Void,
        onLoadPage: @escaping (BrowserUITestFixturePage) -> Void,
        onSelectNode: @escaping (BrowserUITestSelectionTarget) -> Void,
        onGoBack: @escaping () -> Void,
        onGoForward: @escaping () -> Void,
        onFocusRemoteTapTarget: @escaping () -> Void
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

        let nativeSelectionButton = UIButton(type: .system)
        nativeSelectionButton.configuration = .tinted()
        nativeSelectionButton.configuration?.title = "Native Pick"
        nativeSelectionButton.accessibilityIdentifier = "Monocly.inspectorHarness.beginNativeSelection"
        nativeSelectionButton.addAction(
            UIAction { _ in
                onBeginNativeSelection()
            },
            for: .primaryActionTriggered
        )
        selectionButtonStack.addArrangedSubview(nativeSelectionButton)

        focusRemoteTapTargetButton.configuration = .tinted()
        focusRemoteTapTargetButton.configuration?.title = "Focus Iframe"
        focusRemoteTapTargetButton.accessibilityIdentifier = "Monocly.inspectorHarness.focusRemoteTapTarget"
        focusRemoteTapTargetButton.addAction(
            UIAction { _ in
                onFocusRemoteTapTarget()
            },
            for: .primaryActionTriggered
        )
        selectionButtonStack.addArrangedSubview(focusRemoteTapTargetButton)

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

        let rootStack = UIStackView(arrangedSubviews: [
            pageButtonStack,
            selectionButtonStack,
            navigationButtonStack
        ])
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)

        for label in diagnosticLabels {
            configureHiddenDiagnosticLabel(label)
        }

        browserURLLabel.accessibilityIdentifier = "Monocly.inspectorHarness.browserURL"
        domDocumentURLLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domDocumentURL"
        domContextIDLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domContextID"
        domIsSelectingLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domIsSelecting"
        domSelectedPreviewLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domSelectedPreview"
        domSelectedSelectorLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domSelectedSelector"
        domTreeSelectedPreviewLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domTreeSelectedPreview"
        domTreeSelectedLineageLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domTreeSelectedLineage"
        domTreeSelectedVisibleLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domTreeSelectedVisible"
        domSelectionDebugLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domSelectionDebug"
        domVisibleNodesLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domVisibleNodes"
        domNativeSelectionStateLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domNativeSelectionState"
        domRootStateLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domRootState"
        domErrorLabel.accessibilityIdentifier = "Monocly.inspectorHarness.domError"
        remoteTapTargetSummaryLabel.accessibilityIdentifier = "Monocly.inspectorHarness.remoteTapTargetSummary"
        remoteTapPointLabel.accessibilityIdentifier = "Monocly.inspectorHarness.remoteTapPoint"

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

    private func configureHiddenDiagnosticLabel(_ label: UILabel) {
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

    func apply(state: BrowserInspectorUITestHarnessState) {
        browserURLLabel.text = "browserURL=\(state.browserURL)"
        domDocumentURLLabel.text = "domDocumentURL=\(state.domDocumentURL)"
        domContextIDLabel.text = "domContextID=\(state.domContextID)"
        domIsSelectingLabel.text = "domIsSelecting=\(state.domIsSelecting ? 1 : 0)"
        domSelectedPreviewLabel.text = "domSelectedPreview=\(state.domSelectedPreview)"
        domSelectedSelectorLabel.text = "domSelectedSelector=\(state.domSelectedSelector)"
        domTreeSelectedPreviewLabel.text = "domTreeSelectedPreview=\(state.domTreeSelectedPreview)"
        domTreeSelectedLineageLabel.text = "domTreeSelectedLineage=\(state.domTreeSelectedLineage)"
        domTreeSelectedVisibleLabel.text = "domTreeSelectedVisible=\(state.domTreeSelectedVisible == true ? 1 : 0)"
        domSelectionDebugLabel.text = "domSelectionDebug=\(state.domSelectionDebug)"
        domVisibleNodesLabel.text = "domVisibleNodes=\(state.domVisibleNodes.isEmpty ? "n/a" : state.domVisibleNodes)"
        domNativeSelectionStateLabel.text = "domNativeSelectionState=\(state.domNativeSelectionState)"
        domRootStateLabel.text = "domRootReady=\(state.domRootReady ? 1 : 0)"
        domErrorLabel.text = "domError=\(state.domError)"
        remoteTapTargetSummaryLabel.text = "remoteTapTargetSummary=\(state.remoteTapTargetSummary)"
        remoteTapPointLabel.text = "remoteTapPoint=\(state.remoteTapPoint)"
        backButton.isEnabled = state.canGoBack
        forwardButton.isEnabled = state.canGoForward
    }
}
#endif
#endif
