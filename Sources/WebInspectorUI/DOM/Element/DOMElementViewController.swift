#if canImport(UIKit)
import WebInspectorCore
import WebInspectorTransport
import ObservationBridge
import UIKit

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

    private let inspection: AttachedInspection
    private let observationScope = ObservationScope()
    private var expandedUnusedVariableSectionIDs = Set<CSSStyleSectionIdentifier>()
    private var displayedNodeStyles: CSSNodeStyles?

#if DEBUG
    package private(set) var lastSnapshotAnimatedForTesting = false
#endif

    private lazy var collectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: Self.makeLayout()
    )
    private lazy var dataSource = makeDataSource()

    package init(inspection: AttachedInspection) {
        self.inspection = inspection
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        inspection.dom.setSelectedNodeStyleHydrationActive(false)
        observationScope.cancelAll()
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        applyBackgroundFromTraits()
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { viewController in
                viewController.applyBackgroundFromTraits()
            }
        }
        configureCollectionView()
        startObservingState()
        render()
    }

    override package func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        inspection.dom.setSelectedNodeStyleHydrationActive(true)
        render()
    }

    override package func viewDidDisappear(_ animated: Bool) {
        inspection.dom.setSelectedNodeStyleHydrationActive(false)
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
        collectionView.backgroundColor = webInspectorBackgroundPolicy.backgroundColor
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

    private func applyBackgroundFromTraits() {
        let backgroundColor = webInspectorBackgroundPolicy.backgroundColor
        view.backgroundColor = backgroundColor
        collectionView.backgroundColor = backgroundColor
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
        observationScope.observe(inspection.dom) { [weak self] _, _ in
            self?.render()
        }
        observationScope.observe(inspection.dom.elementStyles) { [weak self] _, _ in
            self?.render()
        }
    }

    private func render() {
        guard isViewLoaded else {
            return
        }

        render(inspection.dom.selectedNodeStyles)
    }

    private func render(_ nodeStyles: CSSNodeStyles?) {
        guard let nodeStyles else {
            showEmptyStyleList()
            return
        }
        showStyleList(nodeStyles)
    }

    private func showStyleList(_ nodeStyles: CSSNodeStyles) {
        displayedNodeStyles = nodeStyles
        showCollectionView()
        applySnapshot(for: nodeStyles)
    }

    private func showEmptyStyleList() {
        displayedNodeStyles = nil
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
        displayedNodeStyles?.sections.first { $0.id == sectionID }
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
        guard let nodeStyles = displayedNodeStyles else {
            return
        }
        expandedUnusedVariableSectionIDs.insert(sectionID)
        applySnapshot(for: nodeStyles, animatingDifferences: true)
    }

    private func toggleAction() -> DOMElementStylePropertyView.ToggleAction? {
        { [weak inspection] propertyID, enabled in
            inspection?.dom.requestSetCSSProperty(propertyID, enabled: enabled) ?? false
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

        let css = dom.elementStyles
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

        let inspection = AttachedInspection(dom: dom)
        return UINavigationController(rootViewController: DOMElementViewController(inspection: inspection))
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
