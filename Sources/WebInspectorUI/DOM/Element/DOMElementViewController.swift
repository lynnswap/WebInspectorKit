#if canImport(UIKit)
import WebInspectorCore
import ObservationBridge
import UIKit

@MainActor
package final class DOMElementViewController: UICollectionViewController {
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
    private let selectedNodeStyleObservationScope = ObservationScope()
    private weak var observedNodeStyles: CSSNodeStyles?
    private var expandedUnusedVariableSectionIDs = Set<CSSStyleSectionIdentifier>()
    private var displayedNodeStyles: CSSNodeStyles?

#if DEBUG
    package private(set) var lastSnapshotAnimatedForTesting = false
    private var elementStylesObservationDelivery: ObservationDelivery?
    private var selectedNodeStyleObservationDelivery: ObservationDelivery?
#endif

    private lazy var dataSource = makeDataSource()

    package init(inspection: AttachedInspection) {
        self.inspection = inspection
        super.init(collectionViewLayout: Self.makeLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        inspection.dom.setSelectedNodeStyleHydrationActive(false)
        observationScope.cancelAll()
        selectedNodeStyleObservationScope.cancelAll()
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        applyBackgroundFromTraits()
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "WebInspector.DOM.Element.StylesList"
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { viewController in
                viewController.applyBackgroundFromTraits()
            }
        }
        startObservingState()
    }

    override package func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        inspection.dom.setSelectedNodeStyleHydrationActive(true)
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
        let delivery = observationScope.observe(inspection.dom.elementStyles, tracking: { elementStyles in
            _ = elementStyles.selectedNodeStyles
        }) { [weak self] _, elementStyles in
            self?.bindSelectedNodeStyles(
                elementStyles.selectedNodeStyles,
                unavailableState: elementStyles.selectedState
            )
        }
#if DEBUG
        elementStylesObservationDelivery = delivery
#endif
    }

    private func bindSelectedNodeStyles(_ nodeStyles: CSSNodeStyles?, unavailableState: CSSNodeStylesState) {
        guard let nodeStyles else {
            observedNodeStyles = nil
            selectedNodeStyleObservationScope.cancelAll()
#if DEBUG
            selectedNodeStyleObservationDelivery = nil
#endif
            render(unavailableState)
            return
        }

        guard observedNodeStyles !== nodeStyles else {
            return
        }
        observedNodeStyles = nodeStyles
        selectedNodeStyleObservationScope.cancelAll()
        let delivery = selectedNodeStyleObservationScope.observe(nodeStyles) { [weak self] _, nodeStyles in
            guard self?.observedNodeStyles === nodeStyles else {
                return
            }
            self?.render(nodeStyles)
        }
#if DEBUG
        selectedNodeStyleObservationDelivery = delivery
#endif
    }

    private func render(_ nodeStyles: CSSNodeStyles) {
        switch nodeStyles.state {
        case .loaded:
            displayedNodeStyles = nodeStyles
            renderStyles(nodeStyles)
        case .loading, .needsRefresh:
            renderPendingStyles()
        case .unavailable, .failed:
            render(nodeStyles.state)
        }
    }

    private func render(_ state: CSSNodeStylesState) {
        switch state {
        case .loaded:
            return
        case .loading, .needsRefresh:
            renderPendingStyles()
        case .unavailable, .failed:
            displayedNodeStyles = nil
            renderUnavailableStyles()
        }
    }

    private func renderUnavailableStyles() {
        if let configuration = contentUnavailableConfiguration as? UIContentUnavailableConfiguration,
           configuration.text == String(localized: "dom.element.styles.empty.title", bundle: .module) {
            applyEmptySnapshot()
            return
        }
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.text = String(localized: "dom.element.styles.empty.title", bundle: .module)
        configuration.textProperties.color = .secondaryLabel
        contentUnavailableConfiguration = configuration
        applyEmptySnapshot()
    }

    private func renderPendingStyles() {
        guard displayedNodeStyles != nil else {
            renderUnavailableStyles()
            return
        }
        if contentUnavailableConfiguration != nil {
            contentUnavailableConfiguration = nil
        }
    }

    private func renderStyles(_ nodeStyles: CSSNodeStyles) {
        if contentUnavailableConfiguration != nil {
            contentUnavailableConfiguration = nil
        }
        applySnapshot(for: nodeStyles)
    }

    private func applyEmptySnapshot() {
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
        return { [weak inspection] propertyID, enabled in
            inspection?.dom.requestSetCSSProperty(propertyID, enabled: enabled) ?? false
        }
    }

#if DEBUG
    package var elementStylesObservationDeliveryForTesting: ObservationDelivery? {
        elementStylesObservationDelivery
    }

    package var selectedNodeStyleObservationDeliveryForTesting: ObservationDelivery? {
        selectedNodeStyleObservationDelivery
    }
#endif
}
#endif
