#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import WebInspectorProxyKit
import ObservationBridge
import UIKit

@MainActor
package final class DOMElementViewController: UICollectionViewController {
    private let context: WebInspectorModelContext
    private var statusTask: Task<Void, Never>?
    private var styleHydrationTask: Task<Void, Never>?
    private var styleHydrationGeneration: UInt64 = 0
    private var isStyleHydrationActive = false
    private var selectedStylesObservation: PortableObservationTracking.Token?
    private var observedSelectedNodeObjectID: ObjectIdentifier?
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

    package init(context: WebInspectorModelContext) {
        self.context = context
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
        statusTask?.cancel()
        selectedStylesObservation?.cancel()
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
    }

    override package func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isStyleHydrationActive = true
        if let selectedNode = try? context.selectedDOMNode {
            hydrateStylesIfNeeded(for: selectedNode, retryFailure: true)
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
        bindSelectedNode(try? context.selectedDOMNode)
        statusTask = Task { @MainActor [weak self, context] in
            for await status in context.statusUpdates {
                guard let self else {
                    return
                }
                bindSelectedNode(status.selectedNodeID.flatMap { try? context.domNode(id: $0) })
            }
        }
    }

    private func bindSelectedNode(_ node: DOMNode?) {
        let nodeObjectID = node.map(ObjectIdentifier.init)
        guard hasBoundSelectedNode == false || observedSelectedNodeObjectID != nodeObjectID else {
            return
        }
        hasBoundSelectedNode = true
        observedSelectedNodeObjectID = nodeObjectID
        cancelStyleHydration()
        selectedStylesObservation?.cancel()
        guard let node else {
            selectedStylesObservation = nil
            renderSelectedStyles(nil)
            return
        }
        let token = withPortableContinuousObservation { [weak self, weak node, nodeObjectID] _ in
            guard let self,
                  self.observedSelectedNodeObjectID == nodeObjectID else {
                return
            }
            guard let node else {
                self.renderSelectedStyles(nil)
                return
            }
            self.renderSelectedStyles(node.elementStyles)
            if node.elementStyles?.phase == .needsRefresh {
                self.hydrateStylesIfNeeded(for: node, retryFailure: false)
            }
        }
        selectedStylesObservation = token
        hydrateStylesIfNeeded(for: node, retryFailure: true)
    }

    private func hydrateStylesIfNeeded(
        for node: DOMNode,
        retryFailure: Bool
    ) {
        guard isStyleHydrationActive,
              styleHydrationTask == nil else {
            return
        }

        let operation: @MainActor () async throws -> Void
        switch node.elementStyles?.phase {
        case nil, .unavailable:
            operation = { [context] in
                _ = try await context.cssStyles(for: node)
            }
        case .failed where retryFailure:
            operation = { [context] in
                _ = try await context.cssStyles(for: node)
            }
        case .needsRefresh:
            operation = { [context] in
                try await context.refreshCSSStyles(for: node)
            }
        case .loading, .loaded, .failed:
            return
        }

        precondition(
            styleHydrationGeneration < UInt64.max,
            "DOM style hydration generation overflowed."
        )
        styleHydrationGeneration += 1
        let generation = styleHydrationGeneration
        styleHydrationTask = Task { @MainActor [weak self] in
            do {
                try await operation()
            } catch {
                // CSSStyles owns and publishes the failed phase.
            }
            guard let self,
                  styleHydrationGeneration == generation else {
                return
            }
            styleHydrationTask = nil
        }
    }

    private func cancelStyleHydration() {
        styleHydrationTask?.cancel()
        styleHydrationTask = nil
        precondition(
            styleHydrationGeneration < UInt64.max,
            "DOM style hydration generation overflowed."
        )
        styleHydrationGeneration += 1
    }

    /// Renders the selected node's styles. Runs inside the observation
    /// closure so the coordinator's reads of `phase`/`sections` register
    /// Observation tracking on the `CSSStyles` model.
    private func renderSelectedStyles(_ styles: CSSStyles?) {
        guard let styles else {
            applySnapshotUpdate(styleSnapshotCoordinator.updateUnavailable())
            return
        }
        applySnapshotUpdate(styleSnapshotCoordinator.updateSelectedNodeStyles(styles))
    }

    private func applySnapshotUpdate(_ update: DOMElementStyleSnapshotCoordinator.SnapshotUpdate) {
        applyPlaceholder(update.placeholderMode)
        switch update.applyMode {
        case .none:
            applyVisibleBindings(update)
#if DEBUG
            finishStyleRenderForTesting()
#endif
        case let .diff(animated):
            guard let snapshot = update.snapshot else {
                preconditionFailure("A CSS structural diff requires a snapshot.")
            }
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
                _ = try await context.setCSSProperty(
                    property,
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
        renderSelectedStyles((try? context.selectedDOMNode)?.elementStyles)
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
