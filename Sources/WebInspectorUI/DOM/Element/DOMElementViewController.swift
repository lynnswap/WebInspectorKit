#if canImport(UIKit)
import WebInspectorCore
import ObservationBridge
import UIKit

@MainActor
package final class DOMElementViewController: UICollectionViewController {
    private struct ItemIdentifier: Hashable {
        enum Kind: Hashable {
            case property(propertyID: CSSProperty.ID?, propertyIndex: Int)
            case hiddenUnusedVariables(count: Int)
        }

        var sectionID: CSSStyle.Section.ID
        var kind: Kind
    }

    private let inspection: AttachedInspection
    private var elementStylesObservation: PortableObservationTracking.Token?
    private var selectedNodeStyleObservation: PortableObservationTracking.Token?
    private weak var observedNodeStyles: CSSNodeStyles?
    private var expandedUnusedVariableSectionIDs = Set<CSSStyle.Section.ID>()
    private var displayedNodeStyles: CSSNodeStyles?

#if DEBUG
    private struct StyleRenderWaiter {
        var continuation: CheckedContinuation<Bool, Never>
        var timeoutTask: Task<Void, Never>
    }

    package var disablesSnapshotAnimationsForTesting = false
    package private(set) var lastSnapshotAnimatedForTesting = false
    private var styleRenderGeneration = 0
    private var nextStyleRenderWaiterID: UInt64 = 0
    private var styleRenderWaiters: [UInt64: StyleRenderWaiter] = [:]
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
#if DEBUG
        resolveStyleRenderWaitersForTesting(result: false)
#endif
        inspection.dom.setSelectedNodeStyleHydrationActive(false)
        elementStylesObservation?.cancel()
        selectedNodeStyleObservation?.cancel()
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

    private func makeDataSource() -> UICollectionViewDiffableDataSource<CSSStyle.Section.ID, ItemIdentifier> {
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

        let dataSource = UICollectionViewDiffableDataSource<CSSStyle.Section.ID, ItemIdentifier>(
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
        let elementStyles = inspection.dom.elementStyles
        let token = withPortableContinuousObservation { [weak self, elementStyles] _ in
            let selectedNodeStyles = elementStyles.selectedNodeStyles
            let selectedPhase = elementStyles.selectedPhase
            self?.bindSelectedNodeStyles(
                selectedNodeStyles,
                unavailableState: selectedPhase
            )
        }
        elementStylesObservation = token
    }

    private func bindSelectedNodeStyles(_ nodeStyles: CSSNodeStyles?, unavailableState: CSSNodeStyles.Phase) {
        guard let nodeStyles else {
            observedNodeStyles = nil
            selectedNodeStyleObservation?.cancel()
            selectedNodeStyleObservation = nil
            render(unavailableState)
            return
        }

        guard observedNodeStyles !== nodeStyles else {
            return
        }
        observedNodeStyles = nodeStyles
        selectedNodeStyleObservation?.cancel()
        let token = withPortableContinuousObservation { [weak self, weak nodeStyles] _ in
            guard let nodeStyles,
                  self?.observedNodeStyles === nodeStyles else {
                return
            }
            self?.render(nodeStyles)
        }
        selectedNodeStyleObservation = token
    }

    private func render(_ nodeStyles: CSSNodeStyles) {
        switch nodeStyles.phase {
        case .loaded:
            displayedNodeStyles = nodeStyles
            renderStyles(nodeStyles)
        case .loading, .needsRefresh:
            renderPendingStyles()
        case .unavailable, .failed:
            render(nodeStyles.phase)
        }
    }

    private func render(_ state: CSSNodeStyles.Phase) {
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
#if DEBUG
        finishStyleRenderForTesting()
#endif
    }

    private func renderStyles(_ nodeStyles: CSSNodeStyles) {
        if contentUnavailableConfiguration != nil {
            contentUnavailableConfiguration = nil
        }
        applySnapshot(for: nodeStyles)
    }

    private func applyEmptySnapshot() {
        expandedUnusedVariableSectionIDs.removeAll()
        let snapshot = NSDiffableDataSourceSnapshot<CSSStyle.Section.ID, ItemIdentifier>()
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
#if DEBUG
            self?.finishStyleRenderForTesting()
#endif
        }
    }

    private func applySnapshot(for nodeStyles: CSSNodeStyles, animatingDifferences: Bool = false) {
        var snapshot = NSDiffableDataSourceSnapshot<CSSStyle.Section.ID, ItemIdentifier>()
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
#if DEBUG
        lastSnapshotAnimatedForTesting = animatingDifferences
#endif
        guard currentSnapshot.sectionIdentifiers != snapshot.sectionIdentifiers
            || currentSnapshot.itemIdentifiers != snapshot.itemIdentifiers else {
            var reconfiguredSnapshot = snapshot
            reconfiguredSnapshot.reconfigureItems(snapshot.itemIdentifiers)
            dataSource.apply(reconfiguredSnapshot, animatingDifferences: false) { [weak self] in
#if DEBUG
                self?.finishStyleRenderForTesting()
#endif
            }
            return
        }
#if DEBUG
        let shouldAnimateSnapshot = animatingDifferences && !disablesSnapshotAnimationsForTesting
#else
        let shouldAnimateSnapshot = animatingDifferences
#endif
        dataSource.apply(snapshot, animatingDifferences: shouldAnimateSnapshot) { [weak self] in
#if DEBUG
            self?.finishStyleRenderForTesting()
#endif
        }
    }

    private func section(for sectionID: CSSStyle.Section.ID) -> CSSStyle.Section? {
        displayedNodeStyles?.sections.first { $0.id == sectionID }
    }

    private func property(for item: ItemIdentifier, in section: CSSStyle.Section) -> CSSProperty? {
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

    private func showHiddenUnusedVariables(in sectionID: CSSStyle.Section.ID) {
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
    package var styleRenderGenerationForTesting: Int {
        styleRenderGeneration
    }

    package func waitForStyleRenderForTesting(
        after generation: Int,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        if styleRenderGeneration > generation {
            return true
        }

        return await withCheckedContinuation { continuation in
            nextStyleRenderWaiterID &+= 1
            let waiterID = nextStyleRenderWaiterID
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self?.resolveStyleRenderWaiterForTesting(id: waiterID, result: false)
            }
            styleRenderWaiters[waiterID] = StyleRenderWaiter(
                continuation: continuation,
                timeoutTask: timeoutTask
            )

            if styleRenderGeneration > generation {
                resolveStyleRenderWaiterForTesting(id: waiterID, result: true)
            }
        }
    }

    private func finishStyleRenderForTesting() {
        styleRenderGeneration += 1
        resolveStyleRenderWaitersForTesting(result: true)
    }

    private func resolveStyleRenderWaitersForTesting(result: Bool) {
        for waiterID in Array(styleRenderWaiters.keys) {
            resolveStyleRenderWaiterForTesting(id: waiterID, result: result)
        }
    }

    private func resolveStyleRenderWaiterForTesting(id: UInt64, result: Bool) {
        guard let waiter = styleRenderWaiters.removeValue(forKey: id) else {
            return
        }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: result)
    }
#endif
}
#endif
