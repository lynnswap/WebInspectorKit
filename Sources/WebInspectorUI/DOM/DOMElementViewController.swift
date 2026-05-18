#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorCore
import WebInspectorRuntime

@MainActor
package final class DOMElementViewController: UIViewController {
    package let dom: DOMSession
    package let css: CSSSession

    private weak var session: InspectorSession?
    private let observationScope = ObservationScope()
    private let selectedStylesObservationScope = ObservationScope()
    private let stylesTextView = DOMElementStylesTextView()

    package convenience init(session: InspectorSession) {
        self.init(
            dom: session.dom,
            css: session.css,
            session: session
        )
    }

    package convenience init(dom: DOMSession) {
        self.init(
            dom: dom,
            css: CSSSession()
        )
    }

    package convenience init(
        dom: DOMSession,
        css: CSSSession
    ) {
        self.init(
            dom: dom,
            css: css,
            session: nil
        )
    }

    package init(
        dom: DOMSession,
        css: CSSSession,
        session: InspectorSession?
    ) {
        self.dom = dom
        self.css = css
        self.session = session
        super.init(nibName: nil, bundle: nil)
        startObservingState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationScope.cancelAll()
        selectedStylesObservationScope.cancelAll()
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureStylesTextView()
        render()
    }

    override package func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        render()
    }

    private func configureStylesTextView() {
        stylesTextView.translatesAutoresizingMaskIntoConstraints = false
        stylesTextView.isHidden = true

        view.addSubview(stylesTextView)
        NSLayoutConstraint.activate([
            stylesTextView.topAnchor.constraint(equalTo: view.topAnchor),
            stylesTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stylesTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stylesTextView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func startObservingState() {
        dom.observe([\.treeRevision, \.selectionRevision]) { [weak self] in
            self?.render()
        }
        .store(in: observationScope)

        css.observe([\.selectedNodeStyles, \.selectedState]) { [weak self] in
            self?.observeSelectedNodeStyles()
            self?.render()
        }
        .store(in: observationScope)

        session?.observe(\.isAttached) { [weak self] _ in
            self?.render()
        }
        .store(in: observationScope)

        observeSelectedNodeStyles()
    }

    private func observeSelectedNodeStyles() {
        selectedStylesObservationScope.update {
            guard let selectedNodeStyles = css.selectedNodeStyles else {
                return
            }

            selectedNodeStyles.observe([\.state, \.sections]) { [weak self] in
                self?.render()
            }
            .store(in: selectedStylesObservationScope)
        }
    }

    private func render() {
        guard isViewLoaded else {
            return
        }

        guard dom.currentPageRootNode != nil else {
            showPlaceholder(
                text: webInspectorLocalized("dom.element.loading.title", default: "Loading DOM..."),
                secondaryText: nil,
                image: UIImage(systemName: "arrow.clockwise")
            )
            return
        }

        switch dom.selectedCSSNodeStyleIdentity() {
        case let .success(identity):
            renderStyles(for: identity)
        case let .failure(reason):
            showUnavailable(reason)
        }
    }

    private func renderStyles(for identity: CSSNodeStyleIdentity) {
        guard let nodeStyles = css.selectedNodeStyles,
              nodeStyles.identity == identity else {
            requestStylesRefresh()
            showEmptyStyleList()
            return
        }

        switch nodeStyles.state {
        case .loading:
            showStyleList(nodeStyles)
        case .loaded:
            showLoadedStyles(nodeStyles)
        case .needsRefresh:
            requestStylesRefresh()
            if nodeStyles.sections.isEmpty {
                showEmptyStyleList()
            } else {
                showLoadedStyles(nodeStyles)
            }
        case let .unavailable(reason):
            showUnavailable(reason)
        case let .failed(message):
            showPlaceholder(
                text: webInspectorLocalized("dom.element.styles.failed.title", default: "Couldn’t load styles"),
                secondaryText: message,
                image: UIImage(systemName: "exclamationmark.triangle")
            )
        }
    }

    private func showLoadedStyles(_ nodeStyles: CSSNodeStyles) {
        let hasVisibleProperties = nodeStyles.sections.contains { !$0.style.cssProperties.isEmpty }
        guard hasVisibleProperties else {
            showPlaceholder(
                text: webInspectorLocalized("dom.element.styles.empty.title", default: "No styles"),
                secondaryText: webInspectorLocalized(
                    "dom.element.styles.empty.description",
                    default: "This element has no editable or matched CSS declarations."
                ),
                image: UIImage(systemName: "curlybraces")
            )
            return
        }

        showStyleList(nodeStyles)
    }

    private func showStyleList(_ nodeStyles: CSSNodeStyles) {
        contentUnavailableConfiguration = nil
        stylesTextView.isHidden = false
        stylesTextView.bind(
            nodeStyles: nodeStyles,
            onToggle: toggleAction()
        )
    }

    private func showEmptyStyleList() {
        contentUnavailableConfiguration = nil
        stylesTextView.isHidden = false
        stylesTextView.clear()
    }

    private func showUnavailable(_ reason: CSSNodeStylesUnavailableReason) {
        switch reason {
        case .noSelection:
            showPlaceholder(
                text: webInspectorLocalized("dom.element.no_selection.title", default: "Select an element"),
                secondaryText: webInspectorLocalized(
                    "dom.element.no_selection.description",
                    default: "Choose an element in the DOM tree to inspect its styles."
                ),
                image: UIImage(systemName: "scope")
            )
        case .nonElementNode:
            showPlaceholder(
                text: webInspectorLocalized("dom.element.styles.unavailable.title", default: "Styles unavailable"),
                secondaryText: webInspectorLocalized(
                    "dom.element.styles.non_element.description",
                    default: "CSS styles are only available for element nodes."
                ),
                image: UIImage(systemName: "curlybraces")
            )
        case .staleNode:
            showPlaceholder(
                text: webInspectorLocalized("dom.element.styles.unavailable.title", default: "Styles unavailable"),
                secondaryText: webInspectorLocalized(
                    "dom.element.styles.stale.description",
                    default: "The selected node is no longer available."
                ),
                image: UIImage(systemName: "curlybraces")
            )
        case .cssUnavailableForTarget:
            showPlaceholder(
                text: webInspectorLocalized("dom.element.styles.unavailable.title", default: "Styles unavailable"),
                secondaryText: webInspectorLocalized(
                    "dom.element.styles.target_unavailable.description",
                    default: "This target does not expose CSS styles."
                ),
                image: UIImage(systemName: "curlybraces")
            )
        }
    }

    private func showPlaceholder(text: String, secondaryText: String?, image: UIImage?) {
        stylesTextView.clear()
        stylesTextView.isHidden = true
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.text = text
        configuration.secondaryText = secondaryText
        configuration.image = image
        contentUnavailableConfiguration = configuration
    }

    private func requestStylesRefresh() {
        session?.requestRefreshStylesForSelectedNode()
    }

    private func toggleAction() -> DOMElementStylesTextView.ToggleAction? {
        guard let session else {
            return nil
        }
        return { propertyID, enabled in
            session.requestSetCSSProperty(propertyID, enabled: enabled)
        }
    }
}

#if DEBUG
extension DOMElementViewController {
    package var stylesTextViewForTesting: DOMElementStylesTextView {
        stylesTextView
    }
}
#endif

#Preview("DOM Element") {
    DOMElementViewControllerPreview.makeViewController()
}

@MainActor
private enum DOMElementViewControllerPreview {
    static func makeViewController() -> UINavigationController {
        let dom = DOMPreviewFixtures.makeDOMSession()
        dom.applyTargetCreated(
            ProtocolTargetRecord(
                id: ProtocolTargetIdentifier("preview-page"),
                kind: .page,
                frameID: DOMFrameIdentifier("preview-frame"),
                capabilities: .pageDefault
            ),
            makeCurrentMainPage: true
        )
        if let body = firstElement(named: "body", in: dom) {
            dom.selectNode(body.id)
        }

        let css = CSSSession()
        if case let .success(identity) = dom.selectedCSSNodeStyleIdentity(),
           let token = css.beginRefresh(identity: identity) {
            css.applyRefresh(
                token: token,
                matched: CSSMatchedStylesPayload(
                    matchedRules: [
                        CSSRuleMatchPayload(
                            rule: CSSRulePayload(
                                id: CSSRuleIdentifier(styleSheetID: CSSStyleSheetIdentifier("preview"), ordinal: 0),
                                selectorList: CSSSelectorList(selectors: [CSSSelector(text: "body")], text: "body"),
                                sourceURL: "preview.css",
                                sourceLine: 1,
                                origin: .author,
                                style: CSSStylePayload(
                                    id: CSSStyleIdentifier(styleSheetID: CSSStyleSheetIdentifier("preview"), ordinal: 0),
                                    cssProperties: [
                                        CSSPropertyPayload(name: "margin", value: "0", text: "margin: 0;", status: .active),
                                        CSSPropertyPayload(name: "box-sizing", value: "border-box", text: "box-sizing: border-box;", status: .active),
                                        CSSPropertyPayload(name: "font-size", value: "12px", text: "font-size: 12px;", status: .inactive),
                                    ],
                                    cssText: "margin: 0;\nbox-sizing: border-box;\nfont-size: 12px;"
                                )
                            ),
                            matchingSelectors: [0]
                        ),
                    ]
                ),
                inline: CSSInlineStylesPayload(),
                computed: []
            )
        }

        return UINavigationController(rootViewController: DOMElementViewController(dom: dom, css: css))
    }

    private static func firstElement(named localName: String, in dom: DOMSession) -> DOMNode? {
        guard let rootNode = dom.currentPageRootNode else {
            return nil
        }
        var stack = [rootNode]
        while let node = stack.popLast() {
            if node.localName == localName {
                return node
            }
            stack.append(contentsOf: dom.visibleDOMTreeChildren(of: node).reversed())
        }
        return nil
    }
}
#endif
