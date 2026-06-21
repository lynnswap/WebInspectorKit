#if canImport(UIKit)
import WebInspectorCore
import ObservationBridge
import UIKit

@MainActor
package final class DOMElementViewController: UICollectionViewController {
    private let inspection: AttachedInspection
    private var elementStylesObservation: PortableObservationTracking.Token?
    private var selectedNodeStyleObservation: PortableObservationTracking.Token?
    private var observedNodeStylesID: ObjectIdentifier?
    private let stylePresentationState = DOMElementStylePresentationState()

#if DEBUG
    private struct StyleRenderWaiter {
        var continuation: CheckedContinuation<Bool, Never>
        var timeoutTask: Task<Void, Never>
    }

    package var disablesSnapshotAnimationsForTesting = false
    package private(set) var lastSnapshotAnimatedForTesting = false
    package private(set) var styleSnapshotApplyCountForTesting = 0
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

    private func makeDataSource() -> UICollectionViewDiffableDataSource<
        CSSStyle.Section.ID,
        DOMElementStylePresentationItemIdentifier
    > {
        let propertyRegistration = UICollectionView.CellRegistration<
            DOMElementStylePropertyCollectionCell,
            DOMElementStylePresentationItemIdentifier
        > { [weak self] cell, _, item in
            guard let self,
                  let section = section(for: item.sectionID),
                  let property = property(for: item, in: section) else {
                cell.clear()
                return
            }
            cell.bind(property: property, onToggle: toggleAction())
        }
        let hiddenVariablesRegistration = UICollectionView.CellRegistration<
            DOMElementStyleHiddenVariablesCollectionCell,
            DOMElementStylePresentationItemIdentifier
        > { [weak self] cell, _, item in
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

        let dataSource = UICollectionViewDiffableDataSource<
            CSSStyle.Section.ID,
            DOMElementStylePresentationItemIdentifier
        >(
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
            observedNodeStylesID = nil
            selectedNodeStyleObservation?.cancel()
            selectedNodeStyleObservation = nil
            render(unavailableState)
            return
        }

        let nodeStylesID = ObjectIdentifier(nodeStyles)
        guard observedNodeStylesID != nodeStylesID else {
            return
        }
        observedNodeStylesID = nodeStylesID
        selectedNodeStyleObservation?.cancel()
        let token = withPortableContinuousObservation { [weak self, weak nodeStyles, nodeStylesID] _ in
            guard let self,
                  let nodeStyles,
                  self.observedNodeStylesID == nodeStylesID else {
                return
            }
            self.render(nodeStyles)
        }
        selectedNodeStyleObservation = token
    }

    private func render(_ nodeStyles: CSSNodeStyles) {
        let animatesDifferences = stylePresentationState.displayedNodeStylesID == nodeStyles.id
        render(
            stylePresentationState.render(nodeStyles),
            animatingDifferences: animatesDifferences
        )
    }

    private func render(_ state: CSSNodeStyles.Phase) {
        render(stylePresentationState.render(state))
    }

    private func render(
        _ result: DOMElementStylePresentationState.RenderResult,
        animatingDifferences: Bool = false
    ) {
        switch result {
        case let .loaded(render):
            renderStyles(render, animatingDifferences: animatingDifferences)
        case .pending:
            renderPendingStyles()
        case .unavailable:
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
        if contentUnavailableConfiguration != nil {
            contentUnavailableConfiguration = nil
        }
#if DEBUG
        finishStyleRenderForTesting()
#endif
    }

    private func renderStyles(
        _ render: DOMElementStylePresentationRender,
        animatingDifferences: Bool = false
    ) {
        if contentUnavailableConfiguration != nil {
            contentUnavailableConfiguration = nil
        }
        applySnapshot(
            render.snapshot,
            reconfiguredItemIdentifiers: render.reconfiguredItemIdentifiers,
            animatingDifferences: animatingDifferences
        )
    }

    private func applyEmptySnapshot() {
        let snapshot = NSDiffableDataSourceSnapshot<
            CSSStyle.Section.ID,
            DOMElementStylePresentationItemIdentifier
        >()
#if DEBUG
        styleSnapshotApplyCountForTesting += 1
        lastSnapshotAnimatedForTesting = false
#endif
        applySnapshotToDataSource(snapshot, animatingDifferences: false) { [weak self] in
#if DEBUG
            self?.finishStyleRenderForTesting()
#endif
        }
    }

    private func applySnapshot(
        _ snapshot: NSDiffableDataSourceSnapshot<
            CSSStyle.Section.ID,
            DOMElementStylePresentationItemIdentifier
        >,
        reconfiguredItemIdentifiers: [DOMElementStylePresentationItemIdentifier] = [],
        animatingDifferences: Bool = false
    ) {
        let currentSnapshot = dataSource.snapshot()
        let hasStructuralChanges = currentSnapshot.sectionIdentifiers != snapshot.sectionIdentifiers
            || currentSnapshot.itemIdentifiers != snapshot.itemIdentifiers
#if DEBUG
        lastSnapshotAnimatedForTesting = animatingDifferences && hasStructuralChanges
#endif
        guard hasStructuralChanges else {
            let reconfiguredItemIdentifiers = reconfiguredItemIdentifiers.filter { item in
                snapshot.indexOfItem(item) != nil
            }
            guard !reconfiguredItemIdentifiers.isEmpty else {
#if DEBUG
                finishStyleRenderForTesting()
#endif
                return
            }
            var reconfiguredSnapshot = snapshot
            reconfiguredSnapshot.reconfigureItems(reconfiguredItemIdentifiers)
#if DEBUG
            styleSnapshotApplyCountForTesting += 1
#endif
            applySnapshotToDataSource(reconfiguredSnapshot, animatingDifferences: false) { [weak self] in
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
#if DEBUG
        styleSnapshotApplyCountForTesting += 1
#endif
        applySnapshotToDataSource(snapshot, animatingDifferences: shouldAnimateSnapshot) { [weak self] in
#if DEBUG
            self?.finishStyleRenderForTesting()
#endif
        }
    }

    private func applySnapshotToDataSource(
        _ snapshot: NSDiffableDataSourceSnapshot<
            CSSStyle.Section.ID,
            DOMElementStylePresentationItemIdentifier
        >,
        animatingDifferences: Bool,
        completion: @escaping () -> Void
    ) {
        guard !animatingDifferences else {
            dataSource.apply(snapshot, animatingDifferences: true, completion: completion)
            return
        }

        UIView.performWithoutAnimation {
            dataSource.apply(snapshot, animatingDifferences: false, completion: completion)
            collectionView.layoutIfNeeded()
        }
    }

    private func section(for sectionID: CSSStyle.Section.ID) -> CSSStyle.Section? {
        stylePresentationState.section(for: sectionID)
    }

    private func property(
        for item: DOMElementStylePresentationItemIdentifier,
        in section: CSSStyle.Section
    ) -> CSSProperty? {
        stylePresentationState.property(for: item, in: section)
    }

    private func showHiddenUnusedVariables(in sectionID: CSSStyle.Section.ID) {
        guard let render = stylePresentationState.showHiddenUnusedVariables(in: sectionID) else {
            return
        }
        applySnapshot(
            render.snapshot,
            reconfiguredItemIdentifiers: render.reconfiguredItemIdentifiers,
            animatingDifferences: true
        )
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

    package func renderCurrentStylesForTesting() {
        let elementStyles = inspection.dom.elementStyles
        if let selectedNodeStyles = elementStyles.selectedNodeStyles {
            render(selectedNodeStyles)
        } else {
            render(elementStyles.selectedPhase)
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
