#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import ObservationBridge
import UIHostingMenu
import UIKit

@MainActor
package final class NetworkListViewController: UICollectionViewController, UISearchResultsUpdating {
    package typealias EntrySelectionAction = @MainActor (NetworkEntry.ID?) -> Void

    private enum SectionIdentifier: Hashable {
        case main
    }

    private struct PendingSnapshotUpdate {
        var snapshot: NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkEntry.ID>
        var reconfigureEntryIDs: Set<NetworkEntry.ID>
        var requiresFullReconfigure: Bool

        mutating func merge(
            snapshot: NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkEntry.ID>,
            reconfigureEntryIDs: Set<NetworkEntry.ID>,
            requiresFullReconfigure: Bool
        ) {
            self.snapshot = snapshot
            self.reconfigureEntryIDs.formUnion(reconfigureEntryIDs)
            self.requiresFullReconfigure = self.requiresFullReconfigure || requiresFullReconfigure
        }
    }

    private struct SnapshotCoordinator {
        var isRenderingActive = false
        var needsReloadOnNextAppearance = true
        var pendingUpdate: PendingSnapshotUpdate?
        var projectedSnapshot: NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkEntry.ID>?
        var projectedRevision: WebInspectorFetchedResultsRevision?
        var state = NetworkListViewController.SnapshotState()

        mutating func resumeRendering() {
            isRenderingActive = true
        }

        mutating func suspendRendering() {
            isRenderingActive = false
        }

        mutating func invalidateProjectionForHiddenUpdate() {
            needsReloadOnNextAppearance = true
            pendingUpdate = nil
            projectedSnapshot = nil
            projectedRevision = nil
        }

        var needsReloadForActiveRendering: Bool {
            isRenderingActive && needsReloadOnNextAppearance
        }
    }

    private let model: NetworkPanelModel
    private let fetchedResults: WebInspectorFetchedResultsController<NetworkEntry>
    private var entrySelectionAction: EntrySelectionAction
    private var fetchedResultsUpdateTask: Task<Void, Never>?
    private var searchTextObservation: PortableObservationTracking.Token?
    private var resourceFilterObservation: PortableObservationTracking.Token?
    private var selectedEntryObservation: PortableObservationTracking.Token?

    private var snapshotCoordinator = SnapshotCoordinator()
    private var isApplyingSearchPresentation = false
    private var activeSearchController: UISearchController?
#if DEBUG
    private struct FetchedResultsUpdateDeliveryWaiter {
        var id: Int
        var baselineCount: Int
        var continuation: CheckedContinuation<Bool, Never>
        var timeoutTask: Task<Void, Never>
    }

    private var deinitHandlerForTesting: (@MainActor () -> Void)?
    private var snapshotUpdateCompletionWaitersForTesting: [CheckedContinuation<Void, Never>] = []
    private var fetchedResultsUpdateDeliveryWaitersForTesting: [FetchedResultsUpdateDeliveryWaiter] = []
    private var fetchedResultsUpdateDeliveryWaiterIDStorageForTesting = 0
    private var fetchedResultsUpdateDeliveryCountStorageForTesting = 0
    private var lastFetchedResultsUpdateRevisionStorageForTesting:
        WebInspectorFetchedResultsRevision?
    private var entryIDsEvaluationCountStorageForTesting = 0
    private var snapshotApplyCountStorageForTesting = 0
    private var cellReconfigureCountStorageForTesting = 0
    private var lastAppliedReconfigureEntryIDsStorageForTesting: Set<NetworkEntry.ID> = []
    private var filterMenuBuildCountStorageForTesting = 0
#endif
    private lazy var filterHostingMenu = UIHostingMenu(
        rootView: NetworkListFilterMenuView(model: model)
    )
    private lazy var overflowHostingMenu = UIHostingMenu(
        rootView: NetworkListOverflowMenuView(model: model)
    )
    private lazy var filterItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease"),
            menu: UIMenu(children: [makeFilterMenuElement()])
        )
        item.accessibilityIdentifier = "WebInspector.Network.FilterButton"
        item.isSelected = model.effectiveResourceFilters.isEmpty == false
        return item
    }()
    private lazy var dataSource = makeDataSource()

    package init(model: NetworkPanelModel) {
        self.model = model
        fetchedResults = model.entries
        entrySelectionAction = { [model] entryID in
            model.selectEntry(entryID)
        }
        super.init(collectionViewLayout: Self.makeListLayout())
        startObservingModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        fetchedResultsUpdateTask?.cancel()
        searchTextObservation?.cancel()
        resourceFilterObservation?.cancel()
        selectedEntryObservation?.cancel()
        detachSearchPresentation()
#if DEBUG
        resolveFetchedResultsUpdateDeliveryWaitersForTesting(result: false)
        deinitHandlerForTesting?()
#endif
    }

    package func setEntrySelectionAction(_ action: @escaping EntrySelectionAction) {
        entrySelectionAction = action
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        view.accessibilityIdentifier = "WebInspector.Network.ListPane"
        applyBackgroundFromTraits()
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { viewController in
                viewController.applyBackgroundFromTraits()
            }
        }

        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "WebInspector.Network.List"
        applyBackgroundFromTraits()

        configureNavigationItem()
    }

    override package func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureNavigationItem()
        navigationController?.setNavigationBarHidden(false, animated: animated)
        resumeRendering()
    }

    override package func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        suspendRendering()
    }

    override package func willMove(toParent parent: UIViewController?) {
        if parent == nil {
            detachSearchPresentation()
        }
        super.willMove(toParent: parent)
    }

    private static func makeListLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
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

    private func startObservingModel() {
        startObservingFetchedResultsUpdates()

        searchTextObservation?.cancel()
        searchTextObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }
            let searchText = model.searchText
            guard snapshotCoordinator.isRenderingActive else { return }
            renderSearchText(searchText)
        }

        resourceFilterObservation?.cancel()
        resourceFilterObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }
            let effectiveResourceFilters = model.effectiveResourceFilters
            guard snapshotCoordinator.isRenderingActive else { return }
            resourceFilterSelectionDidChange(effectiveResourceFilters: effectiveResourceFilters)
        }

        selectedEntryObservation?.cancel()
        selectedEntryObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }
            let selectedEntryID = model.selectedEntryID
            guard snapshotCoordinator.isRenderingActive else { return }
            renderSelectedEntryID(selectedEntryID)
        }
    }

    private func startObservingFetchedResultsUpdates() {
        fetchedResultsUpdateTask?.cancel()
        let updates = fetchedResults.updates
        fetchedResultsUpdateTask = Task { @MainActor [weak self] in
            for await update in updates {
                guard Task.isCancelled == false else { return }
                self?.fetchedResultsDidPublish(update)
            }
        }

    }

    private func resumeRendering() {
        snapshotCoordinator.resumeRendering()
        setVisibleCellRenderingActive(true)
        renderSearchText(model.searchText)
        resourceFilterSelectionDidChange(effectiveResourceFilters: model.effectiveResourceFilters)
        renderSelectedEntryID(model.selectedEntryID)
        renderInitialEmptyStateIfNeeded()
        if snapshotCoordinator.needsReloadForActiveRendering {
            reloadDataFromModel(reconfigureAllSurvivingEntries: true)
        } else {
            applyPendingSnapshotUpdateIfNeeded()
        }
    }

    private func suspendRendering() {
        guard snapshotCoordinator.isRenderingActive else {
            return
        }
        snapshotCoordinator.suspendRendering()
        setVisibleCellRenderingActive(false)
    }

    private func configureNavigationItem() {
        navigationItem.style = .browser
        if activeSearchController == nil || navigationItem.searchController !== activeSearchController {
            attachSearchPresentation()
        }
        navigationItem.preferredSearchBarPlacement = .stacked
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.trailingItemGroups = [
            UIBarButtonItemGroup(
                barButtonItems: [filterItem],
                representativeItem: nil
            ),
        ]
        navigationItem.additionalOverflowItems = makeOverflowMenuElement()

        renderSearchText(model.searchText)
        resourceFilterSelectionDidChange(effectiveResourceFilters: model.effectiveResourceFilters)
    }

    private func applyBackgroundFromTraits() {
        webInspectorConfigureScrollEdgeObservedScrollView(
            collectionView,
            backgroundColor: webInspectorBackgroundPolicy.backgroundColor,
            traitCollection: traitCollection
        )
    }

    package func updateSearchResults(for searchController: UISearchController) {
        guard
            isApplyingSearchPresentation == false,
            searchController === activeSearchController
        else {
            return
        }
        let searchText = searchController.searchBar.text ?? ""
        guard searchText != model.searchText else {
            return
        }
        model.setSearchText(searchText)
    }

    private func attachSearchPresentation() {
        let searchController = makeSearchController()
        isApplyingSearchPresentation = true
        defer {
            isApplyingSearchPresentation = false
        }

        activeSearchController?.searchResultsUpdater = nil
        activeSearchController = searchController
        navigationItem.searchController = searchController
    }

    private func detachSearchPresentation() {
        guard activeSearchController != nil || navigationItem.searchController != nil else {
            return
        }

        isApplyingSearchPresentation = true
        defer {
            isApplyingSearchPresentation = false
        }

        activeSearchController?.searchResultsUpdater = nil
        activeSearchController = nil
        navigationItem.searchController = nil
    }

    private func makeSearchController() -> UISearchController {
        let searchController = UISearchController(searchResultsController: nil)
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = String(localized: "network.search.placeholder", bundle: WebInspectorUILocalization.bundle)
        searchController.searchBar.text = model.searchText
        searchController.searchResultsUpdater = self
        return searchController
    }

    private func renderSearchText(_ text: String) {
        guard
            isViewLoaded,
            let activeSearchController,
            activeSearchController.searchBar.text != text
        else {
            return
        }
        isApplyingSearchPresentation = true
        defer {
            isApplyingSearchPresentation = false
        }
        activeSearchController.searchBar.text = text
    }

    private func renderFilterItem(effectiveResourceFilters: Set<NetworkDisplay.ResourceFilter>) {
        guard isViewLoaded else {
            return
        }
        filterItem.isSelected = effectiveResourceFilters.isEmpty == false
    }

    private func resourceFilterSelectionDidChange(effectiveResourceFilters: Set<NetworkDisplay.ResourceFilter>) {
        renderFilterItem(effectiveResourceFilters: effectiveResourceFilters)
    }

    private func makeFilterMenuElement() -> UIDeferredMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            completion((self?.makeFilterMenu() ?? UIMenu()).children)
        }
    }

    private func makeFilterMenu() -> UIMenu {
#if DEBUG
        filterMenuBuildCountStorageForTesting += 1
#endif
        return (try? filterHostingMenu.menu()) ?? UIMenu()
    }

    private func makeOverflowMenuElement() -> UIDeferredMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            completion((self?.makeOverflowMenu() ?? UIMenu()).children)
        }
    }

    private func makeOverflowMenu() -> UIMenu {
        (try? overflowHostingMenu.menu()) ?? UIMenu()
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<SectionIdentifier, NetworkEntry.ID> {
        let listCellRegistration = UICollectionView.CellRegistration<NetworkListCell, NetworkEntry.ID> { [weak self] cell, _, id in
            self?.bind(cell, to: id)
        }
        return UICollectionViewDiffableDataSource<SectionIdentifier, NetworkEntry.ID>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(
                using: listCellRegistration,
                for: indexPath,
                item: item
            )
        }
    }

    private func makeSnapshot(
        entryIDs: [NetworkEntry.ID]
    ) -> NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkEntry.ID> {
        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkEntry.ID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(entryIDs, toSection: .main)
        return snapshot
    }

    private var isCollectionViewVisible: Bool {
        snapshotCoordinator.isRenderingActive && isViewLoaded
    }

    private func requestSnapshotUpdate(
        entryIDs: [NetworkEntry.ID],
        projectionRevision: WebInspectorFetchedResultsRevision,
        reconfigureEntryIDs: Set<NetworkEntry.ID> = [],
        requiresFullReconfigure: Bool = false
    ) {
        requestSnapshotUpdate(
            snapshot: makeSnapshot(entryIDs: entryIDs),
            projectionRevision: projectionRevision,
            reconfigureEntryIDs: reconfigureEntryIDs,
            requiresFullReconfigure: requiresFullReconfigure
        )
    }

    private func requestSnapshotUpdate(
        snapshot: NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkEntry.ID>,
        projectionRevision: WebInspectorFetchedResultsRevision,
        reconfigureEntryIDs: Set<NetworkEntry.ID>,
        requiresFullReconfigure: Bool
    ) {
        guard isCollectionViewVisible else {
            snapshotCoordinator.invalidateProjectionForHiddenUpdate()
            return
        }
        snapshotCoordinator.needsReloadOnNextAppearance = false
        enqueueSnapshotUpdate(
            snapshot: snapshot,
            projectionRevision: projectionRevision,
            reconfigureEntryIDs: reconfigureEntryIDs,
            requiresFullReconfigure: requiresFullReconfigure
        )
    }

    private func enqueueSnapshotUpdate(
        snapshot: NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkEntry.ID>,
        projectionRevision: WebInspectorFetchedResultsRevision,
        reconfigureEntryIDs: Set<NetworkEntry.ID>,
        requiresFullReconfigure: Bool
    ) {
        var update = snapshotCoordinator.pendingUpdate ?? PendingSnapshotUpdate(
            snapshot: snapshot,
            reconfigureEntryIDs: [],
            requiresFullReconfigure: false
        )
        update.merge(
            snapshot: snapshot,
            reconfigureEntryIDs: reconfigureEntryIDs,
            requiresFullReconfigure: requiresFullReconfigure
        )
        snapshotCoordinator.projectedSnapshot = snapshot
        snapshotCoordinator.projectedRevision = projectionRevision

        snapshotCoordinator.pendingUpdate = update
        applyPendingSnapshotUpdateIfNeeded()
    }

    private func applyPendingSnapshotUpdateIfNeeded() {
        guard snapshotCoordinator.isRenderingActive else {
            return
        }
        guard !snapshotCoordinator.state.isApplying,
              let update = snapshotCoordinator.pendingUpdate else {
            return
        }
        snapshotCoordinator.pendingUpdate = nil

        let currentSnapshot = dataSource.snapshot()
        if currentSnapshot.sectionIdentifiers == update.snapshot.sectionIdentifiers,
           currentSnapshot.itemIdentifiers == update.snapshot.itemIdentifiers {
            let entryIDsToRebind = update.requiresFullReconfigure
                ? Set(update.snapshot.itemIdentifiers)
                : update.reconfigureEntryIDs
            let reboundEntryIDs = rebindVisibleCells(entryIDs: entryIDsToRebind)
#if DEBUG
            lastAppliedReconfigureEntryIDsStorageForTesting = reboundEntryIDs
            if reboundEntryIDs.isEmpty == false {
                cellReconfigureCountStorageForTesting += 1
            }
#endif
#if DEBUG
            resumeSnapshotUpdateCompletionWaitersForTesting()
#endif
            return
        }

        let reconfigureEntryIDs: [NetworkEntry.ID]
        if update.requiresFullReconfigure {
            reconfigureEntryIDs = update.snapshot.itemIdentifiers.filter { entryID in
                currentSnapshot.indexOfItem(entryID) != nil
            }
        } else {
            reconfigureEntryIDs = update.reconfigureEntryIDs.filter { entryID in
                currentSnapshot.indexOfItem(entryID) != nil
                    && update.snapshot.indexOfItem(entryID) != nil
            }
        }
        var snapshot = update.snapshot
        if reconfigureEntryIDs.isEmpty == false {
            snapshot.reconfigureItems(reconfigureEntryIDs)
        }
#if DEBUG
        lastAppliedReconfigureEntryIDsStorageForTesting = Set(reconfigureEntryIDs)
#endif
        guard let generation = snapshotCoordinator.state.beginApplying() else {
            snapshotCoordinator.pendingUpdate = update
            return
        }

        let completion: () -> Void = { [weak self] in
            self?.snapshotUpdateDidFinish(generation: generation)
        }
#if DEBUG
        snapshotApplyCountStorageForTesting += 1
#endif
        dataSource.apply(snapshot, animatingDifferences: false, completion: completion)
    }

    private func rebindVisibleCells(
        entryIDs: Set<NetworkEntry.ID>
    ) -> Set<NetworkEntry.ID> {
        var reboundEntryIDs: Set<NetworkEntry.ID> = []
        for entryID in entryIDs {
            guard let indexPath = dataSource.indexPath(for: entryID),
                  let cell = collectionView.cellForItem(at: indexPath) as? NetworkListCell else {
                continue
            }
            bind(cell, to: entryID)
            reboundEntryIDs.insert(entryID)
        }
        return reboundEntryIDs
    }

    private func bind(
        _ cell: NetworkListCell,
        to entryID: NetworkEntry.ID
    ) {
        guard let entry = model.context.model(for: entryID) else {
            cell.unbind()
            return
        }
        cell.bind(
            entry: entry,
            renderingActive: snapshotCoordinator.isRenderingActive
        )
    }

    private func snapshotUpdateDidFinish(
        generation: UInt64
    ) {
#if DEBUG
        defer {
            resumeSnapshotUpdateCompletionWaitersForTesting()
        }
#endif
        guard snapshotCoordinator.state.finishApplying(generation: generation)
        else {
            return
        }
        guard snapshotCoordinator.isRenderingActive else {
            return
        }
        renderSelectedEntryID(model.selectedEntryID)
        applyPendingSnapshotUpdateIfNeeded()
    }

    private func fetchedResultsDidPublish(
        _ update: WebInspectorFetchedResultsUpdate<NetworkEntry.ID>
    ) {
        switch update {
        case let .initial(revision, snapshot),
             let .reset(revision, snapshot):
#if DEBUG
            recordFetchedResultsUpdateDeliveryForTesting(revision: revision)
#endif
            if let projectedRevision = snapshotCoordinator.projectedRevision,
               revision <= projectedRevision {
                return
            }
            guard snapshotCoordinator.isRenderingActive else {
                snapshotCoordinator.invalidateProjectionForHiddenUpdate()
                return
            }
            let entryIDs = snapshot.itemIDs
            requestSnapshotUpdate(
                entryIDs: entryIDs,
                projectionRevision: revision,
                requiresFullReconfigure: true
            )
            renderEmptyState(isEmpty: entryIDs.isEmpty)

        case let .changes(
            fromRevision,
            toRevision,
            itemChanges,
            updatedItemIDs
        ):
#if DEBUG
            recordFetchedResultsUpdateDeliveryForTesting(revision: toRevision)
#endif
            if let projectedRevision = snapshotCoordinator.projectedRevision,
               toRevision <= projectedRevision {
                return
            }
            guard snapshotCoordinator.isRenderingActive else {
                snapshotCoordinator.invalidateProjectionForHiddenUpdate()
                return
            }
            guard snapshotCoordinator.projectedRevision == fromRevision else {
                reloadDataFromModel(reconfigureAllSurvivingEntries: true)
                return
            }
            applyIncrementalChanges(
                itemChanges,
                updatedItemIDs: updatedItemIDs,
                revision: toRevision
            )
        }
    }

    private func applyIncrementalChanges(
        _ changes: [WebInspectorFetchedResultsItemChange<NetworkEntry.ID>],
        updatedItemIDs: Set<NetworkEntry.ID>,
        revision: WebInspectorFetchedResultsRevision
    ) {
        guard var snapshot = snapshotCoordinator.projectedSnapshot else {
            reloadDataFromModel(reconfigureAllSurvivingEntries: true)
            return
        }

        let removedIDs = changes.compactMap { change -> NetworkEntry.ID? in
            switch change {
            case let .delete(itemID, _), let .move(itemID, _, _):
                itemID
            case .insert:
                nil
            }
        }
        snapshot.deleteItems(removedIDs.filter { snapshot.indexOfItem($0) != nil })

        let placements = changes.compactMap { change -> (NetworkEntry.ID, Int)? in
            switch change {
            case let .insert(itemID, index), let .move(itemID, _, index):
                return (itemID, index)
            case .delete:
                return nil
            }
        }
        for (entryID, targetIndex) in placements.sorted(by: { $0.1 < $1.1 }) {
            if targetIndex < snapshot.numberOfItems(inSection: .main) {
                let successor = snapshot.itemIdentifiers(inSection: .main)[targetIndex]
                snapshot.insertItems([entryID], beforeItem: successor)
            } else {
                guard targetIndex == snapshot.numberOfItems(inSection: .main)
                else {
                    reloadDataFromModel(reconfigureAllSurvivingEntries: true)
                    return
                }
                snapshot.appendItems([entryID], toSection: .main)
            }
        }

        requestSnapshotUpdate(
            snapshot: snapshot,
            projectionRevision: revision,
            reconfigureEntryIDs: updatedItemIDs,
            requiresFullReconfigure: false
        )
        renderEmptyState(isEmpty: snapshot.itemIdentifiers.isEmpty)
    }

    private func reloadDataFromModel(reconfigureAllSurvivingEntries: Bool = false) {
        guard snapshotCoordinator.isRenderingActive else {
            snapshotCoordinator.invalidateProjectionForHiddenUpdate()
            return
        }
        guard let revision = fetchedResults.revision else {
            renderEmptyState(isEmpty: true)
            return
        }
        let entryIDs = entryIDsFromModel()
        requestSnapshotUpdate(
            entryIDs: entryIDs,
            projectionRevision: revision,
            requiresFullReconfigure: reconfigureAllSurvivingEntries
        )
        renderEmptyState(isEmpty: entryIDs.isEmpty)
    }

    private func renderInitialEmptyStateIfNeeded() {
        guard dataSource.snapshot().itemIdentifiers.isEmpty,
              model.isEmpty else {
            return
        }
        renderEmptyState(isEmpty: true)
    }

    private func entryIDsFromModel() -> [NetworkEntry.ID] {
#if DEBUG
        entryIDsEvaluationCountStorageForTesting += 1
#endif
        return fetchedResults.snapshot?.itemIDs ?? []
    }

    private func renderSelectedEntryID(_ selectedEntryID: NetworkEntry.ID?) {
        guard isViewLoaded else {
            return
        }

        let selectedIndexPaths = collectionView.indexPathsForSelectedItems ?? []
        let targetIndexPath = selectedEntryID.flatMap { dataSource.indexPath(for: $0) }
        for indexPath in selectedIndexPaths where indexPath != targetIndexPath {
            collectionView.deselectItem(at: indexPath, animated: false)
        }
        guard let targetIndexPath, selectedIndexPaths.contains(targetIndexPath) == false else {
            return
        }
        collectionView.selectItem(at: targetIndexPath, animated: false, scrollPosition: [])
    }

    private func renderEmptyState(isEmpty: Bool) {
        if collectionView.isHidden != isEmpty {
            collectionView.isHidden = isEmpty
        }
        if isEmpty {
            let title = String(localized: "network.empty.title", bundle: WebInspectorUILocalization.bundle)
            if let configuration = contentUnavailableConfiguration as? UIContentUnavailableConfiguration,
               configuration.text == title,
               configuration.secondaryText == nil,
               configuration.image == nil,
               configuration.textProperties.color == .secondaryLabel {
                return
            }
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = title
            configuration.textProperties.color = .secondaryLabel
            contentUnavailableConfiguration = configuration
        } else if contentUnavailableConfiguration != nil {
            contentUnavailableConfiguration = nil
        }
    }

    private func setVisibleCellRenderingActive(_ isActive: Bool) {
        guard isViewLoaded else {
            return
        }
        for cell in collectionView.visibleCells {
            (cell as? NetworkListCell)?.setRenderingActive(isActive)
        }
    }

    override package func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let entryID = dataSource.itemIdentifier(for: indexPath) else {
            entrySelectionAction(nil)
            return
        }
        entrySelectionAction(entryID)
    }
}

#if DEBUG
extension NetworkListViewController {
    package var collectionViewForTesting: UICollectionView {
        collectionView
    }

    package var searchControllerForTesting: UISearchController {
        loadViewIfNeeded()
        configureNavigationItem()
        guard let activeSearchController else {
            fatalError("Expected NetworkListViewController to have an active search controller")
        }
        return activeSearchController
    }

    package var filterItemForTesting: UIBarButtonItem {
        filterItem
    }

    package var selectedEntryObservationDeliveryForTesting: PortableObservationTracking.Token? {
        selectedEntryObservation
    }

    package var entryIDsEvaluationCountForTesting: Int {
        entryIDsEvaluationCountStorageForTesting
    }

    package var snapshotApplyCountForTesting: Int {
        snapshotApplyCountStorageForTesting
    }

    package var cellReconfigureCountForTesting: Int {
        cellReconfigureCountStorageForTesting
    }

    package var filterMenuBuildCountForTesting: Int {
        filterMenuBuildCountStorageForTesting
    }

    package var displayedEntryIDsForTesting: [NetworkEntry.ID] {
        dataSource.snapshot().itemIdentifiers
    }

    package var displayedUIKitSectionCountForTesting: Int {
        dataSource.snapshot().sectionIdentifiers.count
    }

    package var lastAppliedReconfigureEntryIDsForTesting: Set<NetworkEntry.ID> {
        lastAppliedReconfigureEntryIDsStorageForTesting
    }

    package func networkListCellForTesting(at indexPath: IndexPath) -> NetworkListCell? {
        collectionView.cellForItem(at: indexPath) as? NetworkListCell
    }

    package var hasPendingSnapshotUpdateForTesting: Bool {
        snapshotCoordinator.pendingUpdate != nil
    }

    package var pendingReconfigureEntryIDsForTesting: Set<NetworkEntry.ID> {
        snapshotCoordinator.pendingUpdate?.reconfigureEntryIDs ?? []
    }

    package var pendingRowsForTesting: [NetworkEntry.ID]? {
        snapshotCoordinator.pendingUpdate?.snapshot.itemIdentifiers
    }

    package var pendingRequiresFullReconfigureForTesting: Bool {
        snapshotCoordinator.pendingUpdate?.requiresFullReconfigure ?? false
    }

    package func beginSnapshotApplyForTesting() {
        _ = snapshotCoordinator.state.beginApplying()
    }

    package func queueSnapshotUpdateForTesting(
        entryIDs: [NetworkEntry.ID],
        projectionRevision: WebInspectorFetchedResultsRevision,
        reconfigureEntryIDs: Set<NetworkEntry.ID> = [],
        requiresFullReconfigure: Bool = false
    ) {
        requestSnapshotUpdate(
            entryIDs: entryIDs,
            projectionRevision: projectionRevision,
            reconfigureEntryIDs: reconfigureEntryIDs,
            requiresFullReconfigure: requiresFullReconfigure
        )
    }

    package func finishSnapshotApplyForTesting() {
        guard let generation = snapshotCoordinator.state.applyingGeneration else {
            return
        }
        snapshotUpdateDidFinish(generation: generation)
    }

    package func suspendRenderingForTesting() {
        suspendRendering()
    }

    package func resumeRenderingForTesting() {
        resumeRendering()
    }

    package func flushPendingSnapshotUpdateForTesting() async {
        guard snapshotCoordinator.isRenderingActive else {
            return
        }
        if snapshotCoordinator.needsReloadForActiveRendering {
            reloadDataFromModel(reconfigureAllSurvivingEntries: true)
        }
        applyPendingSnapshotUpdateIfNeeded()
        await waitForSnapshotUpdateCompletionForTesting()
    }

    private func waitForFetchedResultsUpdateDeliveryForTesting(
        after baselineCount: Int,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        guard fetchedResultsUpdateDeliveryCountStorageForTesting <= baselineCount else {
            return true
        }
        return await withCheckedContinuation { continuation in
            let waiterID = fetchedResultsUpdateDeliveryWaiterIDStorageForTesting
            fetchedResultsUpdateDeliveryWaiterIDStorageForTesting &+= 1
            let timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolveFetchedResultsUpdateDeliveryWaiterForTesting(
                    id: waiterID,
                    result: false
                )
            }
            fetchedResultsUpdateDeliveryWaitersForTesting.append(
                FetchedResultsUpdateDeliveryWaiter(
                    id: waiterID,
                    baselineCount: baselineCount,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            )
        }
    }

    package func waitForFetchedResultsRevisionForTesting(
        _ revision: UInt64,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        let revision = WebInspectorFetchedResultsRevision(rawValue: revision)
        while lastFetchedResultsUpdateRevisionStorageForTesting.map({ $0 >= revision }) != true {
            let baselineCount = fetchedResultsUpdateDeliveryCountStorageForTesting
            guard await waitForFetchedResultsUpdateDeliveryForTesting(
                after: baselineCount,
                timeout: timeout
            ) else {
                return false
            }
        }
        return true
    }

    private func waitForSnapshotUpdateCompletionForTesting() async {
        guard snapshotCoordinator.state.isApplying || snapshotCoordinator.pendingUpdate != nil else {
            return
        }
        await withCheckedContinuation { continuation in
            snapshotUpdateCompletionWaitersForTesting.append(continuation)
        }
    }

    private func resumeSnapshotUpdateCompletionWaitersForTesting() {
        guard snapshotCoordinator.state.isApplying == false,
              snapshotCoordinator.pendingUpdate == nil else {
            return
        }
        let waiters = snapshotUpdateCompletionWaitersForTesting
        snapshotUpdateCompletionWaitersForTesting.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func recordFetchedResultsUpdateDeliveryForTesting(
        revision: WebInspectorFetchedResultsRevision
    ) {
        lastFetchedResultsUpdateRevisionStorageForTesting = revision
        fetchedResultsUpdateDeliveryCountStorageForTesting &+= 1
        resolveFetchedResultsUpdateDeliveryWaitersForTesting(result: true)
    }

    private func resolveFetchedResultsUpdateDeliveryWaitersForTesting(result: Bool) {
        let waiterIDs = fetchedResultsUpdateDeliveryWaitersForTesting.compactMap { waiter in
            if result == false || fetchedResultsUpdateDeliveryCountStorageForTesting > waiter.baselineCount {
                return waiter.id
            }
            return nil
        }
        for waiterID in waiterIDs {
            resolveFetchedResultsUpdateDeliveryWaiterForTesting(id: waiterID, result: result)
        }
    }

    private func resolveFetchedResultsUpdateDeliveryWaiterForTesting(id: Int, result: Bool) {
        guard let index = fetchedResultsUpdateDeliveryWaitersForTesting.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = fetchedResultsUpdateDeliveryWaitersForTesting.remove(at: index)
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: result)
    }

    package func setDeinitHandlerForTesting(_ handler: @escaping @MainActor () -> Void) {
        deinitHandlerForTesting = handler
    }
}
#endif

#endif
