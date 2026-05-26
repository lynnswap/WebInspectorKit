#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorCore
import WebInspectorRuntime

@MainActor
package final class DOMElementViewController: UIViewController {
    private struct ItemIdentifier: Hashable {
        enum Kind: Hashable {
            case property(propertyID: CSSPropertyIdentifier?, propertyIndex: Int)
            case hiddenUnusedVariables(count: Int)
        }

        var sectionID: CSSStyleSectionIdentifier
        var kind: Kind
    }

    package let dom: DOMSession
    package let css: CSSSession

    private weak var session: InspectorSession?
    private let observationScope = ObservationScope()
    private var expandedUnusedVariableSectionIDs = Set<CSSStyleSectionIdentifier>()

#if DEBUG
    package private(set) var lastSnapshotAnimatedForTesting = false
#endif

    private lazy var collectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: Self.makeLayout()
    )
    private lazy var dataSource = makeDataSource()

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        session?.setSelectedNodeStyleHydrationActive(false)
        observationScope.cancelAll()
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureCollectionView()
        startObservingState()
        render()
    }

    override package func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        session?.setSelectedNodeStyleHydrationActive(true)
        render()
    }

    override package func viewDidDisappear(_ animated: Bool) {
        session?.setSelectedNodeStyleHydrationActive(false)
        super.viewDidDisappear(animated)
    }

    private static func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.headerMode = .supplementary
            configuration.showsSeparators = true

            let section = NSCollectionLayoutSection.list(
                using: configuration,
                layoutEnvironment: environment
            )
            var contentInsets = section.contentInsets
            contentInsets.top = 0
            section.contentInsets = contentInsets
            return section
        }
    }

    private func configureCollectionView() {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "WebInspector.DOM.Element.StylesList"

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<CSSStyleSectionIdentifier, ItemIdentifier> {
        let propertyRegistration = UICollectionView.CellRegistration<DOMElementStylePropertyCollectionCell, ItemIdentifier> { [weak self] cell, _, item in
            guard let self,
                  let section = section(for: item.sectionID),
                  let property = property(for: item, in: section) else {
                cell.clear()
                return
            }
            cell.bind(property: property, onToggle: toggleAction())
        }
        let hiddenVariablesRegistration = UICollectionView.CellRegistration<DOMElementStyleHiddenVariablesCollectionCell, ItemIdentifier> { [weak self] cell, _, item in
            guard let self,
                  section(for: item.sectionID) != nil else {
                cell.clear()
                return
            }
            guard case let .hiddenUnusedVariables(hiddenVariableCount) = item.kind,
                  hiddenVariableCount > 0 else {
                cell.clear()
                return
            }
            cell.bind(hiddenVariableCount: hiddenVariableCount) { [weak self] in
                self?.showHiddenUnusedVariables(in: item.sectionID)
            }
        }

        let dataSource = UICollectionViewDiffableDataSource<CSSStyleSectionIdentifier, ItemIdentifier>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            switch item.kind {
            case .property:
                collectionView.dequeueConfiguredReusableCell(
                    using: propertyRegistration,
                    for: indexPath,
                    item: item
                )
            case .hiddenUnusedVariables:
                collectionView.dequeueConfiguredReusableCell(
                    using: hiddenVariablesRegistration,
                    for: indexPath,
                    item: item
                )
            }
        }

        let headerRegistration = UICollectionView.SupplementaryRegistration<DOMElementStyleSectionHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self, weak dataSource] header, _, indexPath in
            guard let self,
                  let dataSource,
                  dataSource.snapshot().sectionIdentifiers.indices.contains(indexPath.section) else {
                header.bind(nil)
                return
            }
            let sectionID = dataSource.snapshot().sectionIdentifiers[indexPath.section]
            guard let section = section(for: sectionID) else {
                header.bind(nil)
                return
            }
            header.bind(section)
        }

        dataSource.supplementaryViewProvider = { collectionView, elementKind, indexPath in
            guard elementKind == UICollectionView.elementKindSectionHeader else {
                return nil
            }
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration,
                for: indexPath
            )
        }
        return dataSource
    }

    private func startObservingState() {
        observationScope.observe(dom) { [weak self] _, _ in
            self?.render()
        }

        observationScope.observe(css) { [weak self] _, _ in
            self?.render()
        }

        if let session {
            observationScope.observe(session) { [weak self] _, session in
                self?.render(session: session)
            }
        }
    }

    private func render() {
        render(session: session)
    }

    private func render(session: InspectorSession?) {
        guard isViewLoaded else {
            return
        }

        guard session?.isAttached != false else {
            showPlaceholder(
                text: webInspectorLocalized("dom.element.loading.title", default: "Loading DOM..."),
                secondaryText: nil,
                imageName: "arrow.clockwise"
            )
            return
        }

        guard dom.currentPageRootNode != nil else {
            showPlaceholder(
                text: webInspectorLocalized("dom.element.loading.title", default: "Loading DOM..."),
                secondaryText: nil,
                imageName: "arrow.clockwise"
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
            showEmptyStyleList()
            return
        }

        switch nodeStyles.state {
        case .loading:
            showStyleList(nodeStyles)
        case .loaded:
            showLoadedStyles(nodeStyles)
        case .needsRefresh:
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
                imageName: "exclamationmark.triangle"
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
                imageName: "curlybraces"
            )
            return
        }

        showStyleList(nodeStyles)
    }

    private func showStyleList(_ nodeStyles: CSSNodeStyles) {
        showCollectionView()
        applySnapshot(for: nodeStyles)
    }

    private func showEmptyStyleList() {
        showCollectionView()
        applyEmptySnapshot()
    }

    private func showCollectionView() {
        if contentUnavailableConfiguration != nil {
            contentUnavailableConfiguration = nil
        }
        if collectionView.isHidden {
            collectionView.isHidden = false
        }
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
                imageName: "scope"
            )
        case .nonElementNode:
            showPlaceholder(
                text: webInspectorLocalized("dom.element.styles.unavailable.title", default: "Styles unavailable"),
                secondaryText: webInspectorLocalized(
                    "dom.element.styles.non_element.description",
                    default: "CSS styles are only available for element nodes."
                ),
                imageName: "curlybraces"
            )
        case .staleNode:
            showPlaceholder(
                text: webInspectorLocalized("dom.element.styles.unavailable.title", default: "Styles unavailable"),
                secondaryText: webInspectorLocalized(
                    "dom.element.styles.stale.description",
                    default: "The selected node is no longer available."
                ),
                imageName: "curlybraces"
            )
        case .cssUnavailableForTarget:
            showPlaceholder(
                text: webInspectorLocalized("dom.element.styles.unavailable.title", default: "Styles unavailable"),
                secondaryText: webInspectorLocalized(
                    "dom.element.styles.target_unavailable.description",
                    default: "This target does not expose CSS styles."
                ),
                imageName: "curlybraces"
            )
        }
    }

    private func showPlaceholder(text: String, secondaryText: String?, imageName: String?) {
        if collectionView.isHidden,
           let configuration = contentUnavailableConfiguration as? UIContentUnavailableConfiguration,
           configuration.text == text,
           configuration.secondaryText == secondaryText {
            return
        }
        applyEmptySnapshot()
        if collectionView.isHidden == false {
            collectionView.isHidden = true
        }
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.text = text
        configuration.secondaryText = secondaryText
        configuration.image = imageName.flatMap(UIImage.init(systemName:))
        contentUnavailableConfiguration = configuration
    }

    private func applyEmptySnapshot() {
        guard dataSource.snapshot().numberOfItems != 0 || dataSource.snapshot().numberOfSections != 0 else {
            return
        }
        expandedUnusedVariableSectionIDs.removeAll()
        let snapshot = NSDiffableDataSourceSnapshot<CSSStyleSectionIdentifier, ItemIdentifier>()
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func applySnapshot(for nodeStyles: CSSNodeStyles, animatingDifferences: Bool = false) {
        var snapshot = NSDiffableDataSourceSnapshot<CSSStyleSectionIdentifier, ItemIdentifier>()
        let usedCSSVariables = DOMElementStyleVariableVisibility.usedCSSVariableNames(in: nodeStyles)
        let currentSectionIDs = Set(nodeStyles.sections.map(\.id))
        expandedUnusedVariableSectionIDs.formIntersection(currentSectionIDs)

        for section in nodeStyles.sections where !section.style.cssProperties.isEmpty {
            let hiddenVariableIndices = DOMElementStyleVariableVisibility.hiddenUnusedVariableIndices(
                in: section,
                usedCSSVariables: usedCSSVariables
            )
            let showsHiddenVariables = expandedUnusedVariableSectionIDs.contains(section.id)
            let propertyItems = section.style.cssProperties.enumerated().compactMap { index, property -> ItemIdentifier? in
                guard showsHiddenVariables || !hiddenVariableIndices.contains(index) else {
                    return nil
                }
                return ItemIdentifier(
                    sectionID: section.id,
                    kind: .property(propertyID: property.id, propertyIndex: index)
                )
            }
            guard !propertyItems.isEmpty || !hiddenVariableIndices.isEmpty else {
                continue
            }

            snapshot.appendSections([section.id])
            snapshot.appendItems(propertyItems, toSection: section.id)
            if !hiddenVariableIndices.isEmpty && !showsHiddenVariables {
                snapshot.appendItems(
                    [ItemIdentifier(sectionID: section.id, kind: .hiddenUnusedVariables(count: hiddenVariableIndices.count))],
                    toSection: section.id
                )
            }
        }
        let currentSnapshot = dataSource.snapshot()
        guard currentSnapshot.sectionIdentifiers != snapshot.sectionIdentifiers
            || currentSnapshot.itemIdentifiers != snapshot.itemIdentifiers else {
            return
        }
#if DEBUG
        lastSnapshotAnimatedForTesting = animatingDifferences
#endif
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    private func section(for sectionID: CSSStyleSectionIdentifier) -> CSSStyleSection? {
        css.selectedNodeStyles?.sections.first { $0.id == sectionID }
    }

    private func property(for item: ItemIdentifier, in section: CSSStyleSection) -> CSSProperty? {
        guard case let .property(propertyID, propertyIndex) = item.kind else {
            return nil
        }
        if let propertyID {
            return section.style.cssProperties.first { $0.id == propertyID }
        }
        guard section.style.cssProperties.indices.contains(propertyIndex) else {
            return nil
        }
        return section.style.cssProperties[propertyIndex]
    }

    private func showHiddenUnusedVariables(in sectionID: CSSStyleSectionIdentifier) {
        guard let nodeStyles = css.selectedNodeStyles else {
            return
        }
        expandedUnusedVariableSectionIDs.insert(sectionID)
        applySnapshot(for: nodeStyles, animatingDifferences: true)
    }

    private func toggleAction() -> DOMElementStylePropertyView.ToggleAction? {
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
    package var collectionViewForTesting: UICollectionView {
        collectionView
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
