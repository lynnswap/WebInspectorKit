#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import ObservationBridge
import UIHostingMenu
import UIKit

@MainActor
package final class NetworkListViewController: UICollectionViewController, UISearchResultsUpdating {
    package typealias EntrySelectionAction = @MainActor (NetworkListEntry.ID?) -> Void

    @MainActor
    private final class ListProjectionDisplayLinkTarget: NSObject {
        private let action: (CADisplayLink) -> Void

        init(action: @escaping (CADisplayLink) -> Void) {
            self.action = action
        }

        @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
            action(displayLink)
        }
    }

    private enum SectionIdentifier: Hashable, Sendable {
        case main
    }

    private struct PendingSnapshotUpdate {
        var rows: NetworkListViewController.SnapshotRows
        var snapshot: NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkListEntry.ID>
    }

    private struct PendingListProjection {
        var latestRevision: UInt64

        mutating func merge(_ transaction: NetworkPanelListTransaction) {
            precondition(
                transaction.revision > latestRevision,
                "Network list transactions must be delivered in revision order."
            )
            latestRevision = transaction.revision
        }
    }

    private struct PendingListSnapshotBuild {
        var entryIDs: [NetworkListEntry.ID]
        var revision: UInt64
    }

    private struct SnapshotCoordinator {
        var isRenderingActive = false
        var needsReloadOnNextAppearance = true
        var pendingUpdate: PendingSnapshotUpdate?
        var state = NetworkListViewController.SnapshotState()

        mutating func resumeRendering() {
            isRenderingActive = true
        }

        mutating func suspendRendering() {
            isRenderingActive = false
            if pendingUpdate != nil {
                needsReloadOnNextAppearance = true
            }
            pendingUpdate = nil
        }

        mutating func markNeedsReloadOnNextAppearance() {
            needsReloadOnNextAppearance = true
        }

        var needsReloadForActiveRendering: Bool {
            isRenderingActive && needsReloadOnNextAppearance
        }
    }

    private let model: NetworkPanelModel
    private var entrySelectionAction: EntrySelectionAction
    private var listTransactionTask: Task<Void, Never>?
    private var searchTextObservation: PortableObservationTracking.Token?
    private var resourceFilterObservation: PortableObservationTracking.Token?
    private var selectedEntryObservation: PortableObservationTracking.Token?

    private var snapshotCoordinator = SnapshotCoordinator()
    private var pendingListProjection: PendingListProjection?
    private lazy var listProjectionDisplayLinkTarget = ListProjectionDisplayLinkTarget { [weak self] displayLink in
        displayLink.isPaused = true
        self?.flushPendingListProjectionIfNeeded()
    }
    private var listProjectionDisplayLink: CADisplayLink?
    private var isListProjectionFlushScheduled = false
    private var latestListTransactionRevision: UInt64 = 0
    private var listSnapshotBuildGeneration: UInt64 = 0
    private var listSnapshotBuildTask: Task<Void, Never>?
    private var pendingListSnapshotBuild: PendingListSnapshotBuild?
    private var isApplyingSearchPresentation = false
    private var activeSearchController: UISearchController?
#if DEBUG
    private struct FetchedResultsTransactionDeliveryWaiter {
        var id: Int
        var targetCount: Int
        var continuation: CheckedContinuation<Bool, Never>
        var timeoutTask: Task<Void, Never>
    }

    private var deinitHandlerForTesting: (@MainActor () -> Void)?
    private var snapshotUpdateCompletionWaitersForTesting: [CheckedContinuation<Void, Never>] = []
    private var fetchedResultsTransactionDeliveryWaitersForTesting: [FetchedResultsTransactionDeliveryWaiter] = []
    private var fetchedResultsTransactionDeliveryWaiterIDStorageForTesting = 0
    private var fetchedResultsTransactionDeliveryCountStorageForTesting = 0
    private var displayRequestIDsEvaluationCountStorageForTesting = 0
    private var snapshotApplyCountStorageForTesting = 0
    private var listProjectionFlushCountStorageForTesting = 0
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
        listProjectionDisplayLink?.invalidate()
        listSnapshotBuildTask?.cancel()
        listTransactionTask?.cancel()
        searchTextObservation?.cancel()
        resourceFilterObservation?.cancel()
        selectedEntryObservation?.cancel()
        detachSearchPresentation()
#if DEBUG
        resolveFetchedResultsTransactionDeliveryWaitersForTesting(result: false)
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
        startObservingListTransactions()

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

    private func startObservingListTransactions() {
        listTransactionTask?.cancel()
        let transactions = model.listTransactions
        listTransactionTask = Task { @MainActor [weak self] in
            for await transaction in transactions {
                self?.listTransactionDidPublish(transaction)
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
            reloadDataFromModel()
        }
    }

    private func suspendRendering() {
        guard snapshotCoordinator.isRenderingActive else {
            return
        }
        invalidateListProjectionDisplayLink()
        let discardedSnapshotBuild = cancelListSnapshotBuild()
        if pendingListProjection != nil || discardedSnapshotBuild {
            snapshotCoordinator.markNeedsReloadOnNextAppearance()
            pendingListProjection = nil
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

    private func makeDataSource() -> UICollectionViewDiffableDataSource<SectionIdentifier, NetworkListEntry.ID> {
        let listCellRegistration = UICollectionView.CellRegistration<NetworkListCell, NetworkListEntry.ID> { [weak self] cell, _, id in
            guard let entry = self?.model.entry(for: id) else {
                cell.unbind()
                return
            }
            cell.bind(entry: entry, renderingActive: self?.snapshotCoordinator.isRenderingActive == true)
        }
        return UICollectionViewDiffableDataSource<SectionIdentifier, NetworkListEntry.ID>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(
                using: listCellRegistration,
                for: indexPath,
                item: item
            )
        }
    }

    nonisolated private static func makeSnapshot(
        entryIDs: [NetworkListEntry.ID]
    ) -> NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkListEntry.ID> {
        precondition(
            entryIDs.count == Set(entryIDs).count,
            "Duplicate row IDs detected in NetworkListViewController"
        )

        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkListEntry.ID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(entryIDs, toSection: .main)
        return snapshot
    }

    private var isCollectionViewVisible: Bool {
        snapshotCoordinator.isRenderingActive && isViewLoaded
    }

    private func requestSnapshotUpdate(entryIDs: [NetworkListEntry.ID]) {
        let rows = NetworkListViewController.SnapshotRows(entryIDs: entryIDs)
        requestSnapshotUpdate(snapshot: Self.makeSnapshot(entryIDs: entryIDs), rows: rows)
    }

    private func requestSnapshotUpdate(
        snapshot: NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkListEntry.ID>,
        rows: NetworkListViewController.SnapshotRows
    ) {
        guard isCollectionViewVisible else {
            snapshotCoordinator.markNeedsReloadOnNextAppearance()
            return
        }
        snapshotCoordinator.needsReloadOnNextAppearance = false
        if let applyingRows = snapshotCoordinator.state.applyingRows {
            if applyingRows.entryIDs == rows.entryIDs {
                snapshotCoordinator.pendingUpdate = nil
                return
            }
        } else if dataSource.snapshot().itemIdentifiers == rows.entryIDs {
            snapshotCoordinator.pendingUpdate = nil
            return
        }
        enqueueSnapshotUpdate(snapshot: snapshot, rows: rows)
    }

    private func enqueueSnapshotUpdate(
        snapshot: NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkListEntry.ID>,
        rows: NetworkListViewController.SnapshotRows
    ) {
        if let pendingSnapshotUpdate = snapshotCoordinator.pendingUpdate,
           pendingSnapshotUpdate.rows.entryIDs == rows.entryIDs {
            return
        }
        guard snapshotCoordinator.state.isApplying
            || dataSource.snapshot().itemIdentifiers != rows.entryIDs else {
            return
        }
        snapshotCoordinator.pendingUpdate = PendingSnapshotUpdate(
            rows: rows,
            snapshot: snapshot
        )
        applyPendingSnapshotUpdateIfNeeded()
    }

    private func applyPendingSnapshotUpdateIfNeeded() {
        guard snapshotCoordinator.isRenderingActive else {
            if snapshotCoordinator.pendingUpdate != nil {
                snapshotCoordinator.pendingUpdate = nil
                snapshotCoordinator.markNeedsReloadOnNextAppearance()
            }
            return
        }
        guard !snapshotCoordinator.state.isApplying,
              let update = snapshotCoordinator.pendingUpdate else {
            return
        }
        snapshotCoordinator.pendingUpdate = nil
        snapshotCoordinator.state.beginApplying(update.rows)

        let completion: () -> Void = { [weak self] in
            self?.snapshotUpdateDidFinish(appliedRows: update.rows)
        }
#if DEBUG
        snapshotApplyCountStorageForTesting += 1
#endif
        dataSource.apply(update.snapshot, animatingDifferences: false, completion: completion)
    }

    private func snapshotUpdateDidFinish(
        appliedRows: NetworkListViewController.SnapshotRows
    ) {
#if DEBUG
        defer {
            resumeSnapshotUpdateCompletionWaitersForTesting()
        }
#endif
        snapshotCoordinator.state.finishApplying(appliedRows)
        guard snapshotCoordinator.isRenderingActive else {
            if snapshotCoordinator.pendingUpdate != nil {
                snapshotCoordinator.pendingUpdate = nil
                snapshotCoordinator.markNeedsReloadOnNextAppearance()
            }
            return
        }
        renderSelectedEntryID(model.selectedEntryID)
        applyPendingSnapshotUpdateIfNeeded()
    }

    private func listTransactionDidPublish(_ transaction: NetworkPanelListTransaction) {
#if DEBUG
        recordFetchedResultsTransactionDeliveryForTesting()
#endif
        precondition(
            transaction.revision > latestListTransactionRevision,
            "Network list transactions must be delivered in revision order."
        )
        latestListTransactionRevision = transaction.revision
        guard snapshotCoordinator.isRenderingActive else {
            snapshotCoordinator.markNeedsReloadOnNextAppearance()
            return
        }
        if var pendingListProjection {
            pendingListProjection.merge(transaction)
            self.pendingListProjection = pendingListProjection
        } else {
            pendingListProjection = PendingListProjection(
                latestRevision: transaction.revision
            )
        }
        scheduleListProjectionFlushIfNeeded()
    }

    private func scheduleListProjectionFlushIfNeeded() {
        guard isListProjectionFlushScheduled == false,
              pendingListProjection != nil else {
            return
        }
        isListProjectionFlushScheduled = true
        let displayLink: CADisplayLink
        if let listProjectionDisplayLink {
            displayLink = listProjectionDisplayLink
        } else {
            displayLink = CADisplayLink(
                target: listProjectionDisplayLinkTarget,
                selector: #selector(ListProjectionDisplayLinkTarget.displayLinkDidFire(_:))
            )
            displayLink.isPaused = true
            displayLink.add(to: .main, forMode: .common)
            listProjectionDisplayLink = displayLink
        }
        displayLink.isPaused = false
    }

    private func cancelScheduledListProjectionFlush() {
        isListProjectionFlushScheduled = false
        listProjectionDisplayLink?.isPaused = true
    }

    private func invalidateListProjectionDisplayLink() {
        cancelScheduledListProjectionFlush()
        listProjectionDisplayLink?.invalidate()
        listProjectionDisplayLink = nil
    }

    private func flushPendingListProjectionIfNeeded() {
        cancelScheduledListProjectionFlush()
        guard snapshotCoordinator.isRenderingActive else {
            if pendingListProjection != nil {
                pendingListProjection = nil
                snapshotCoordinator.markNeedsReloadOnNextAppearance()
            }
            return
        }
        guard let projection = pendingListProjection else {
            return
        }
        pendingListProjection = nil
#if DEBUG
        listProjectionFlushCountStorageForTesting += 1
#endif
        applyListProjection(projection, entryIDs: model.displayEntryIDs)
    }

    private func applyListProjection(
        _ projection: PendingListProjection,
        entryIDs: [NetworkListEntry.ID]
    ) {
        renderEmptyState(isEmpty: entryIDs.isEmpty)
        requestListSnapshotBuild(entryIDs: entryIDs, revision: projection.latestRevision)
    }

    private func requestListSnapshotBuild(
        entryIDs: [NetworkListEntry.ID],
        revision: UInt64
    ) {
        pendingListSnapshotBuild = PendingListSnapshotBuild(
            entryIDs: entryIDs,
            revision: revision
        )
        startNextListSnapshotBuildIfNeeded()
    }

    private func startNextListSnapshotBuildIfNeeded() {
        guard snapshotCoordinator.isRenderingActive,
              listSnapshotBuildTask == nil,
              let build = pendingListSnapshotBuild else {
            return
        }
        pendingListSnapshotBuild = nil
        guard build.revision == latestListTransactionRevision else {
            return
        }
        let generation = takeNextListSnapshotBuildGeneration()
        listSnapshotBuildTask = Task.detached(priority: .userInitiated) { [weak self] in
            let snapshot = Self.makeSnapshot(entryIDs: build.entryIDs)
            guard Task.isCancelled == false else {
                return
            }
            await self?.listSnapshotDidBuild(
                snapshot,
                entryIDs: build.entryIDs,
                revision: build.revision,
                generation: generation
            )
        }
    }

    private func listSnapshotDidBuild(
        _ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkListEntry.ID>,
        entryIDs: [NetworkListEntry.ID],
        revision: UInt64,
        generation: UInt64
    ) {
        guard generation == listSnapshotBuildGeneration else {
            return
        }
        listSnapshotBuildTask = nil
        defer {
            startNextListSnapshotBuildIfNeeded()
        }
        guard snapshotCoordinator.isRenderingActive,
              revision == latestListTransactionRevision,
              entryIDs == model.displayEntryIDs else {
            return
        }
        requestSnapshotUpdate(
            snapshot: snapshot,
            rows: NetworkListViewController.SnapshotRows(entryIDs: entryIDs)
        )
    }

    @discardableResult
    private func cancelListSnapshotBuild() -> Bool {
        let discardedBuild = listSnapshotBuildTask != nil || pendingListSnapshotBuild != nil
        pendingListSnapshotBuild = nil
        guard let task = listSnapshotBuildTask else {
            return discardedBuild
        }
        task.cancel()
        listSnapshotBuildTask = nil
        _ = takeNextListSnapshotBuildGeneration()
        return true
    }

    private func takeNextListSnapshotBuildGeneration() -> UInt64 {
        precondition(
            listSnapshotBuildGeneration < UInt64.max,
            "Network list snapshot build generation overflowed."
        )
        listSnapshotBuildGeneration += 1
        return listSnapshotBuildGeneration
    }

    private func reloadDataFromModel() {
        guard snapshotCoordinator.isRenderingActive else {
            snapshotCoordinator.markNeedsReloadOnNextAppearance()
            return
        }
        let entryIDs = displayEntryIDsFromModel()
        requestSnapshotUpdate(entryIDs: entryIDs)
        renderEmptyState(isEmpty: entryIDs.isEmpty)
    }

    private func renderInitialEmptyStateIfNeeded() {
        guard dataSource.snapshot().itemIdentifiers.isEmpty,
              model.isEmpty else {
            return
        }
        renderEmptyState(isEmpty: true)
    }

    private func displayEntryIDsFromModel() -> [NetworkListEntry.ID] {
#if DEBUG
        displayRequestIDsEvaluationCountStorageForTesting += 1
#endif
        return model.displayEntryIDs
    }

    private func renderSelectedEntryID(_ selectedEntryID: NetworkListEntry.ID?) {
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
        entrySelectionAction(dataSource.itemIdentifier(for: indexPath))
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

    package var selectedRequestObservationDeliveryForTesting: PortableObservationTracking.Token? {
        selectedEntryObservation
    }

    package var displayRequestIDsEvaluationCountForTesting: Int {
        displayRequestIDsEvaluationCountStorageForTesting
    }

    package var snapshotApplyCountForTesting: Int {
        snapshotApplyCountStorageForTesting
    }

    package var listProjectionFlushCountForTesting: Int {
        listProjectionFlushCountStorageForTesting
    }

    package var fetchedResultsTransactionDeliveryCountForTesting: Int {
        fetchedResultsTransactionDeliveryCountStorageForTesting
    }

    package var filterMenuBuildCountForTesting: Int {
        filterMenuBuildCountStorageForTesting
    }

    package var displayedRequestIDsForTesting: [NetworkRequest.ID] {
        dataSource.snapshot().itemIdentifiers.compactMap {
            model.entry(for: $0)?.representativeRequest.id
        }
    }

    package var displayedEntryIDsForTesting: [NetworkListEntry.ID] {
        dataSource.snapshot().itemIdentifiers
    }

    package func networkListCellForTesting(at indexPath: IndexPath) -> NetworkListCell? {
        collectionView.cellForItem(at: indexPath) as? NetworkListCell
    }

    package var hasPendingSnapshotUpdateForTesting: Bool {
        snapshotCoordinator.pendingUpdate != nil
    }

    package var hasActiveListSnapshotBuildForTesting: Bool {
        listSnapshotBuildTask != nil
    }

    package func beginSnapshotApplyForTesting(requestIDs: [NetworkRequest.ID]) {
        snapshotCoordinator.state.beginApplying(
            NetworkListViewController.SnapshotRows(entryIDs: entryIDsForTesting(requestIDs: requestIDs))
        )
    }

    package func queueSnapshotUpdateForTesting(requestIDs: [NetworkRequest.ID]) {
        requestSnapshotUpdate(entryIDs: entryIDsForTesting(requestIDs: requestIDs))
    }

    package func finishSnapshotApplyForTesting(requestIDs: [NetworkRequest.ID]) {
        snapshotUpdateDidFinish(
            appliedRows: NetworkListViewController.SnapshotRows(
                entryIDs: entryIDsForTesting(requestIDs: requestIDs)
            )
        )
    }

    private func entryIDsForTesting(requestIDs: [NetworkRequest.ID]) -> [NetworkListEntry.ID] {
        requestIDs.compactMap { model.entryID(containing: $0) }
    }

    package func suspendRenderingForTesting() {
        suspendRendering()
    }

    package func resumeRenderingForTesting() {
        resumeRendering()
    }

    package func flushPendingSnapshotUpdateForTesting() async {
        while true {
            flushPendingListProjectionIfNeeded()
            startNextListSnapshotBuildIfNeeded()
            guard let snapshotBuildTask = listSnapshotBuildTask else {
                break
            }
            await snapshotBuildTask.value
        }
        if snapshotCoordinator.needsReloadForActiveRendering {
            reloadDataFromModel()
        }
        applyPendingSnapshotUpdateIfNeeded()
        await waitForSnapshotUpdateCompletionForTesting()
    }

    package func flushPendingListProjectionForTesting() {
        flushPendingListProjectionIfNeeded()
    }

    package func waitForFetchedResultsTransactionDeliveryForTesting(
        after baselineCount: Int,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        precondition(baselineCount < Int.max, "Network list transaction delivery count overflowed.")
        return await waitForFetchedResultsTransactionDeliveryCountForTesting(
            baselineCount + 1,
            timeout: timeout
        )
    }

    package func waitForFetchedResultsTransactionDeliveryCountForTesting(
        _ targetCount: Int,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        guard fetchedResultsTransactionDeliveryCountStorageForTesting < targetCount else {
            return true
        }
        return await withCheckedContinuation { continuation in
            let waiterID = fetchedResultsTransactionDeliveryWaiterIDStorageForTesting
            fetchedResultsTransactionDeliveryWaiterIDStorageForTesting &+= 1
            let timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolveFetchedResultsTransactionDeliveryWaiterForTesting(
                    id: waiterID,
                    result: false
                )
            }
            fetchedResultsTransactionDeliveryWaitersForTesting.append(
                FetchedResultsTransactionDeliveryWaiter(
                    id: waiterID,
                    targetCount: targetCount,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            )
        }
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

    private func recordFetchedResultsTransactionDeliveryForTesting() {
        fetchedResultsTransactionDeliveryCountStorageForTesting &+= 1
        resolveFetchedResultsTransactionDeliveryWaitersForTesting(result: true)
    }

    private func resolveFetchedResultsTransactionDeliveryWaitersForTesting(result: Bool) {
        let waiterIDs = fetchedResultsTransactionDeliveryWaitersForTesting.compactMap { waiter in
            if result == false || fetchedResultsTransactionDeliveryCountStorageForTesting >= waiter.targetCount {
                return waiter.id
            }
            return nil
        }
        for waiterID in waiterIDs {
            resolveFetchedResultsTransactionDeliveryWaiterForTesting(id: waiterID, result: result)
        }
    }

    private func resolveFetchedResultsTransactionDeliveryWaiterForTesting(id: Int, result: Bool) {
        guard let index = fetchedResultsTransactionDeliveryWaitersForTesting.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = fetchedResultsTransactionDeliveryWaitersForTesting.remove(at: index)
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: result)
    }

    package func setDeinitHandlerForTesting(_ handler: @escaping @MainActor () -> Void) {
        deinitHandlerForTesting = handler
    }
}
#endif

#Preview("Network List") {
    UINavigationController(
        rootViewController: NetworkListViewController(
            model: NetworkPreviewFixtures.makePanelModel(mode: .root)
        )
    )
}

#Preview("Network List Long Title") {
    UINavigationController(
        rootViewController: NetworkListViewController(
            model: NetworkPreviewFixtures.makePanelModel(mode: .rootLongTitle)
        )
    )
}
#endif
