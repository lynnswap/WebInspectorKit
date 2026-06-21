#if canImport(UIKit)
import WebInspectorCore
import ObservationBridge
import UIKit

@MainActor
package final class DOMElementViewController: UICollectionViewController {
    private let inspection: AttachedInspection
    private var elementStylesObservation: PortableObservationTracking.Token?
    private var selectedNodeStyleObservation: PortableObservationTracking.Token?
    private var selectedNodeStylesObjectID: ObjectIdentifier?
    private let styleSnapshotCoordinator = DOMElementStyleSnapshotCoordinator()

#if DEBUG
    private struct StyleRenderWaiter {
        var continuation: CheckedContinuation<Bool, Never>
        var timeoutTask: Task<Void, Never>
    }

    package var disablesSnapshotAnimationsForTesting = false
    package private(set) var lastSnapshotApplyModeForTesting: DOMElementStyleSnapshotCoordinator.ApplyMode = .none
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
            unbindSelectedNodeStyles()
            applySnapshotUpdate(styleSnapshotCoordinator.updateUnavailablePhase(unavailableState))
            return
        }

        let nodeStylesObjectID = ObjectIdentifier(nodeStyles)
        guard selectedNodeStylesObjectID != nodeStylesObjectID else {
            return
        }
        selectedNodeStyleObservation?.cancel()
        selectedNodeStylesObjectID = nodeStylesObjectID
        styleSnapshotCoordinator.bindSelectedNodeStyles(nodeStyles)
        let token = withPortableContinuousObservation { [weak self, weak nodeStyles, nodeStylesObjectID] _ in
            guard let self,
                  let nodeStyles,
                  self.selectedNodeStylesObjectID == nodeStylesObjectID else {
                return
            }
            self.applySnapshotUpdate(
                self.styleSnapshotCoordinator.updateSelectedNodeStyles(nodeStyles)
            )
        }
        selectedNodeStyleObservation = token
    }

    private func unbindSelectedNodeStyles() {
        selectedNodeStylesObjectID = nil
        selectedNodeStyleObservation?.cancel()
        selectedNodeStyleObservation = nil
    }

    private func applySnapshotUpdate(_ update: DOMElementStyleSnapshotCoordinator.SnapshotUpdate) {
        applyPlaceholder(update.placeholderMode)
        switch update.applyMode {
        case .none:
#if DEBUG
            finishStyleRenderForTesting()
#endif
        case let .diff(animated):
            guard let snapshot = update.snapshot else {
#if DEBUG
                lastSnapshotApplyModeForTesting = .none
                finishStyleRenderForTesting()
#endif
                return
            }
#if DEBUG
            lastSnapshotApplyModeForTesting = .diff(animated: animated)
            let shouldAnimateSnapshot = animated && !disablesSnapshotAnimationsForTesting
            styleSnapshotApplyCountForTesting += 1
#else
            let shouldAnimateSnapshot = animated
#endif
            dataSource.apply(snapshot, animatingDifferences: shouldAnimateSnapshot) { [weak self] in
#if DEBUG
                self?.finishStyleRenderForTesting()
#endif
            }
        case .reloadData:
            guard let snapshot = update.snapshot else {
#if DEBUG
                lastSnapshotApplyModeForTesting = .none
                finishStyleRenderForTesting()
#endif
                return
            }
#if DEBUG
            lastSnapshotApplyModeForTesting = .reloadData
            styleSnapshotApplyCountForTesting += 1
#endif
            dataSource.applySnapshotUsingReloadData(snapshot) { [weak self] in
#if DEBUG
                self?.finishStyleRenderForTesting()
#endif
            }
        }
    }

    private func applyPlaceholder(_ placeholderMode: DOMElementStyleSnapshotCoordinator.PlaceholderMode) {
        switch placeholderMode {
        case .none:
            if contentUnavailableConfiguration != nil {
                contentUnavailableConfiguration = nil
            }
        case .unavailable:
            let title = String(localized: "dom.element.styles.empty.title", bundle: .module)
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

    private func section(for sectionID: CSSStyle.Section.ID) -> CSSStyle.Section? {
        styleSnapshotCoordinator.section(for: sectionID)
    }

    private func property(
        for item: DOMElementStylePresentationItemIdentifier,
        in section: CSSStyle.Section
    ) -> CSSProperty? {
        styleSnapshotCoordinator.property(for: item, in: section)
    }

    private func showHiddenUnusedVariables(in sectionID: CSSStyle.Section.ID) {
        guard let update = styleSnapshotCoordinator.revealHiddenUnusedVariables(in: sectionID) else {
            return
        }
        applySnapshotUpdate(update)
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
            applySnapshotUpdate(styleSnapshotCoordinator.updateSelectedNodeStyles(selectedNodeStyles))
        } else {
            applySnapshotUpdate(styleSnapshotCoordinator.updateUnavailablePhase(elementStyles.selectedPhase))
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
