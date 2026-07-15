#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import ObservationBridge
import UIKit

@MainActor
package final class DOMElementViewController: UICollectionViewController {
    private let context: WebInspectorModelContext
    private let panelModel: DOMPanelModel
    private var panelSelectionObservation: PortableObservationTracking.Token?
    private var styleHydrationTask: Task<Void, Never>?
    private var styleHydrationGeneration: UInt64 = 0
    private var isStyleHydrationActive = false
    private let selectedStylesResults:
        WebInspectorFetchedResultsController<CSSStyles>
    private var selectedStylesUpdatesTask: Task<Void, Never>?
    private var observedSelectedNodeID: DOMNode.ID?
    private var hasBoundSelectedNode = false
    private let styleSnapshotCoordinator = DOMElementStyleSnapshotCoordinator()

#if DEBUG
    private struct StyleRenderWaiter {
        var continuation: CheckedContinuation<Bool, Never>
        var timeoutTask: Task<Void, Never>
    }

    package var disablesSnapshotAnimationsForTesting = false
    package private(set) var lastSnapshotApplyModeForTesting: DOMElementStyleSnapshotCoordinator.ApplyMode = .none
    package private(set) var styleSnapshotApplyModesForTesting: [DOMElementStyleSnapshotCoordinator.ApplyMode] = []
    package private(set) var styleSnapshotApplyCountForTesting = 0
    private var styleRenderGeneration = 0
    private var nextStyleRenderWaiterID: UInt64 = 0
    private var styleRenderWaiters: [UInt64: StyleRenderWaiter] = [:]
#endif

    private lazy var dataSource = makeDataSource()

    package init(model: DOMPanelModel) {
        let context = model.context
        self.context = context
        panelModel = model
        selectedStylesResults = WebInspectorFetchedResultsController(
            modelContext: context
        )
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
        styleHydrationTask?.cancel()
        selectedStylesUpdatesTask?.cancel()
        panelSelectionObservation?.cancel()
        selectedStylesResults.synchronouslyInvalidateRegistration()
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        _ = dataSource
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
        observeSelectedStylesResults()
    }

    override package func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isStyleHydrationActive = true
        observeSelectedStylesResults()
        renderSelectedStyles(currentSelectedStyles)
        if let selectedNodeID = observedSelectedNodeID {
            hydrateStylesIfNeeded(for: selectedNodeID, retryFailure: true)
        }
    }

    override package func viewDidDisappear(_ animated: Bool) {
        isStyleHydrationActive = false
        cancelStyleHydration()
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
        CSSStyleSection.ID,
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
            CSSStyleSection.ID,
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
            header.bind(section(for: sectionID))
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
        panelSelectionObservation = withPortableContinuousObservation { [weak self, weak panelModel] _ in
            guard let self,
                  let panelModel else {
                return
            }
            _ = panelModel.selectionRevision
            bindSelectedNode(panelModel.selectedNode)
        }
    }

    private func bindSelectedNode(_ node: DOMNode?) {
        let nodeID = node?.id
        guard hasBoundSelectedNode == false || observedSelectedNodeID != nodeID else {
            return
        }
        hasBoundSelectedNode = true
        observedSelectedNodeID = nodeID
        cancelStyleHydration()
        renderSelectedStyles(currentSelectedStyles)
        if isStyleHydrationActive, let nodeID {
            hydrateStylesIfNeeded(for: nodeID, retryFailure: true)
        }
    }

    private func observeSelectedStylesResults() {
        guard selectedStylesUpdatesTask == nil else { return }
        let results = selectedStylesResults
        let updates = results.updates
        selectedStylesUpdatesTask = Task { @MainActor [weak self, results] in
            do {
                try await results.performFetch()
            } catch is CancellationError {
                return
            } catch {
                WebInspectorUIDOMLog.error(
                    "CSS styles query failed: \(String(describing: error))"
                )
                guard let self else { return }
                self.selectedStylesUpdatesTask = nil
                self.renderSelectedStyles(nil)
                return
            }

            var isInitialPublication = true
            for await _ in updates {
                guard Task.isCancelled == false,
                      let self else {
                    return
                }
                guard let nodeID = self.observedSelectedNodeID else { continue }
                self.selectedStylesResultsDidPublish(
                    for: nodeID,
                    retryFailure: isInitialPublication
                )
                isInitialPublication = false
            }
        }
    }

    private func selectedStylesResultsDidPublish(
        for nodeID: DOMNode.ID,
        retryFailure: Bool
    ) {
        guard isStyleHydrationActive else { return }
        renderSelectedStyles(currentSelectedStyles)
        hydrateStylesIfNeeded(for: nodeID, retryFailure: retryFailure)
    }

    private func hydrateStylesIfNeeded(
        for nodeID: DOMNode.ID,
        retryFailure: Bool
    ) {
        guard isStyleHydrationActive,
              observedSelectedNodeID == nodeID,
              selectedStylesResults.revision != nil,
              styleHydrationTask == nil else {
            return
        }

        let operation: @MainActor () async throws -> Void
        switch currentSelectedStyles?.phase {
        case nil, .unavailable:
            operation = { [context] in
                _ = try await context.container.dom.loadStyles(for: nodeID)
            }
        case .failed where retryFailure:
            operation = { [context] in
                _ = try await context.container.dom.loadStyles(for: nodeID)
            }
        case .needsRefresh:
            guard let stylesID = currentSelectedStyles?.id else {
                return
            }
            operation = { [context] in
                try await context.container.dom.refreshStyles(stylesID)
            }
        case .loading, .loaded, .failed:
            return
        }

        styleHydrationGeneration &+= 1
        let generation = styleHydrationGeneration
        styleHydrationTask = Task { @MainActor [weak self] in
            do {
                try await operation()
            } catch is CancellationError {
                // Selection and visibility changes cancel obsolete hydration.
            } catch {
                WebInspectorUIDOMLog.error(
                    "CSS style hydration failed nodeID=\(String(describing: nodeID)): "
                        + String(describing: error)
                )
            }
            guard let self,
                  styleHydrationGeneration == generation else {
                return
            }
            styleHydrationTask = nil
            hydrateStylesIfNeeded(
                for: nodeID,
                retryFailure: false
            )
        }
    }

    private func cancelStyleHydration() {
        styleHydrationTask?.cancel()
        styleHydrationTask = nil
        styleHydrationGeneration &+= 1
    }

    private var currentSelectedStyles: CSSStyles? {
        guard let nodeID = observedSelectedNodeID else { return nil }
        return selectedStylesResults.fetchedObjects?.first { styles in
            styles.id == CSSStyles.ID(nodeID: nodeID)
        }
    }

    /// Renders the styles value accepted by the flat fetched-results owner.
    private func renderSelectedStyles(_ styles: CSSStyles?) {
        guard let styles else {
            applySnapshotUpdate(styleSnapshotCoordinator.updateUnavailable())
            return
        }
        applySnapshotUpdate(styleSnapshotCoordinator.updateSelectedNodeStyles(styles))
    }

    private func applySnapshotUpdate(_ update: DOMElementStyleSnapshotCoordinator.SnapshotUpdate) {
        applyPlaceholder(update.placeholderMode)
        switch update.application {
        case .none:
            applyVisibleBindings(update)
#if DEBUG
            finishStyleRenderForTesting()
#endif
        case let .diff(snapshot, animated):
#if DEBUG
            let applyMode = DOMElementStyleSnapshotCoordinator.ApplyMode.diff(animated: animated)
            lastSnapshotApplyModeForTesting = applyMode
            styleSnapshotApplyModesForTesting.append(applyMode)
            let shouldAnimateSnapshot = animated && !disablesSnapshotAnimationsForTesting
            styleSnapshotApplyCountForTesting += 1
#else
            let shouldAnimateSnapshot = animated
#endif
            dataSource.apply(snapshot, animatingDifferences: shouldAnimateSnapshot) { [weak self] in
                self?.applyVisibleBindings(update)
#if DEBUG
                self?.finishStyleRenderForTesting()
#endif
            }
        }
    }

    private func applyVisibleBindings(
        _ update: DOMElementStyleSnapshotCoordinator.SnapshotUpdate
    ) {
        if update.rebindVisiblePropertyRows {
            rebindVisiblePropertyRows()
        }
        rebindVisibleHeaders(update.updatedSectionIDs)
    }

    private func applyPlaceholder(_ placeholderMode: DOMElementStyleSnapshotCoordinator.PlaceholderMode) {
        switch placeholderMode {
        case .none:
            if contentUnavailableConfiguration != nil {
                contentUnavailableConfiguration = nil
            }
        case .unavailable:
            let title = String(localized: "dom.element.styles.empty.title", bundle: WebInspectorUILocalization.bundle)
            if let configuration = contentUnavailableConfiguration as? UIContentUnavailableConfiguration,
               configuration.text == title {
                return
            }
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = title
            configuration.textProperties.color = .secondaryLabel
            contentUnavailableConfiguration = configuration
        }
    }

    /// Section headers are supplementary views; diffable snapshots never
    /// reconfigure them, so same-identity header content changes are pushed
    /// to the visible header views directly.
    private func rebindVisibleHeaders(_ updatedSectionIDs: Set<CSSStyleSection.ID>) {
        guard updatedSectionIDs.isEmpty == false else {
            return
        }
        let sectionIdentifiers = dataSource.snapshot().sectionIdentifiers
        let indexPaths = collectionView.indexPathsForVisibleSupplementaryElements(
            ofKind: UICollectionView.elementKindSectionHeader
        )
        for indexPath in indexPaths {
            guard sectionIdentifiers.indices.contains(indexPath.section) else {
                continue
            }
            let sectionID = sectionIdentifiers[indexPath.section]
            guard updatedSectionIDs.contains(sectionID),
                  let header = collectionView.supplementaryView(
                      forElementKind: UICollectionView.elementKindSectionHeader,
                      at: indexPath
                  ) as? DOMElementStyleSectionHeaderView else {
                continue
            }
            header.bind(section(for: sectionID))
        }
    }

    private func rebindVisiblePropertyRows() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let item = dataSource.itemIdentifier(for: indexPath),
                  let section = section(for: item.sectionID),
                  let property = property(for: item, in: section),
                  let cell = collectionView.cellForItem(at: indexPath)
                    as? DOMElementStylePropertyCollectionCell else {
                continue
            }
            cell.bind(property: property, onToggle: toggleAction())
        }
    }

    private func section(for sectionID: CSSStyleSection.ID) -> CSSStyleSection? {
        styleSnapshotCoordinator.section(for: sectionID)
    }

    private func property(
        for item: DOMElementStylePresentationItemIdentifier,
        in section: CSSStyleSection
    ) -> CSSStyleProperty? {
        styleSnapshotCoordinator.property(for: item, in: section)
    }

    private func showHiddenUnusedVariables(in sectionID: CSSStyleSection.ID) {
        guard let update = styleSnapshotCoordinator.revealHiddenUnusedVariables(in: sectionID) else {
            return
        }
        applySnapshotUpdate(update)
    }

    private func toggleAction() -> DOMElementStylePropertyView.ToggleAction? {
        return { [weak context] property, enabled in
            guard let context else {
                return false
            }
            do {
                _ = try await context.container.dom.setProperty(
                    property.id,
                    enabled: enabled,
                    undo: .automatic
                )
                return true
            } catch {
                WebInspectorUIDOMLog.error(
                    "CSS property toggle failed name=\(property.name) "
                        + "id=\(property.id.rawValue): \(String(describing: error))"
                )
                return false
            }
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
        renderSelectedStyles(currentSelectedStyles)
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
