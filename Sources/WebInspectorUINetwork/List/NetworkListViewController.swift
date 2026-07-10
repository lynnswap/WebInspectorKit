#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import ObservationBridge
import UIHostingMenu
import UIKit

@MainActor
package final class NetworkListViewController: UICollectionViewController, UISearchResultsUpdating {
    package typealias RequestSelectionAction = @MainActor (NetworkRequest?) -> Void

    private enum SectionIdentifier: Hashable {
        case main
    }

    private struct PendingSnapshotUpdate {
        var rows: NetworkListViewController.SnapshotRows
        var snapshot: NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkRequest.ID>
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
    private let fetchedResults: WebInspectorFetchedResults<NetworkRequest>
    private var requestSelectionAction: RequestSelectionAction
    private var fetchedResultsUpdateTask: Task<Void, Never>?
    private var lastFetchedResultsRevision: UInt64?
    private var searchTextObservation: PortableObservationTracking.Token?
    private var resourceFilterObservation: PortableObservationTracking.Token?
    private var selectedRequestObservation: PortableObservationTracking.Token?

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
    private var displayRequestIDsEvaluationCountStorageForTesting = 0
    private var snapshotApplyCountStorageForTesting = 0
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
        fetchedResults = model.requests
        requestSelectionAction = { [model] request in
            model.selectRequest(request)
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
        selectedRequestObservation?.cancel()
        detachSearchPresentation()
#if DEBUG
        resolveFetchedResultsUpdateDeliveryWaitersForTesting(result: false)
        deinitHandlerForTesting?()
#endif
    }

    package func setRequestSelectionAction(_ action: @escaping RequestSelectionAction) {
        requestSelectionAction = action
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

        selectedRequestObservation?.cancel()
        selectedRequestObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }
            let selectedRequestID = model.selectedRequestID
            guard snapshotCoordinator.isRenderingActive else { return }
            renderSelectedRequestID(selectedRequestID)
        }
    }

    private func startObservingFetchedResultsUpdates() {
        fetchedResultsUpdateTask?.cancel()
        let updates = fetchedResults.updates()
        // Initial appearance synchronously reloads from fetchedResults. Treat
        // the subscription's current revision as the delivery baseline so the
        // queued `.initial` cannot schedule a redundant later reload.
        lastFetchedResultsRevision = fetchedResults.revision
        fetchedResultsUpdateTask = Task { @MainActor [weak self] in
            for await update in updates {
                self?.fetchedResultsDidPublish(update)
            }
        }
    }

    private func resumeRendering() {
        snapshotCoordinator.resumeRendering()
        setVisibleCellRenderingActive(true)
        renderSearchText(model.searchText)
        resourceFilterSelectionDidChange(effectiveResourceFilters: model.effectiveResourceFilters)
        renderSelectedRequestID(model.selectedRequestID)
        renderInitialEmptyStateIfNeeded()
        if snapshotCoordinator.needsReloadForActiveRendering {
            reloadDataFromModel()
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

    private func makeDataSource() -> UICollectionViewDiffableDataSource<SectionIdentifier, NetworkRequest.ID> {
        let listCellRegistration = UICollectionView.CellRegistration<NetworkListCell, NetworkRequest.ID> { [weak self] cell, _, id in
            guard let request = self?.model.request(for: id) else {
                cell.unbind()
                return
            }
            cell.bind(request: request, renderingActive: self?.snapshotCoordinator.isRenderingActive == true)
        }
        return UICollectionViewDiffableDataSource<SectionIdentifier, NetworkRequest.ID>(
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
        requestIDs: [NetworkRequest.ID]
    ) -> NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkRequest.ID> {
        precondition(
            requestIDs.count == Set(requestIDs).count,
            "Duplicate row IDs detected in NetworkListViewController"
        )

        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkRequest.ID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(requestIDs, toSection: .main)
        return snapshot
    }

    private var isCollectionViewVisible: Bool {
        snapshotCoordinator.isRenderingActive && isViewLoaded
    }

    private func requestSnapshotUpdate(requestIDs: [NetworkRequest.ID]) {
        let rows = NetworkListViewController.SnapshotRows(requestIDs: requestIDs)
        requestSnapshotUpdate(snapshot: makeSnapshot(requestIDs: requestIDs), rows: rows)
    }

    private func requestSnapshotUpdate(
        snapshot: NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkRequest.ID>,
        rows: NetworkListViewController.SnapshotRows
    ) {
        guard isCollectionViewVisible else {
            snapshotCoordinator.markNeedsReloadOnNextAppearance()
            return
        }
        snapshotCoordinator.needsReloadOnNextAppearance = false
        if let applyingRows = snapshotCoordinator.state.applyingRows {
            if applyingRows.requestIDs == rows.requestIDs {
                snapshotCoordinator.pendingUpdate = nil
                return
            }
        } else if dataSource.snapshot().itemIdentifiers == rows.requestIDs {
            snapshotCoordinator.pendingUpdate = nil
            return
        }
        enqueueSnapshotUpdate(snapshot: snapshot, rows: rows)
    }

    private func enqueueSnapshotUpdate(
        snapshot: NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkRequest.ID>,
        rows: NetworkListViewController.SnapshotRows
    ) {
        if let pendingSnapshotUpdate = snapshotCoordinator.pendingUpdate,
           pendingSnapshotUpdate.rows.requestIDs == rows.requestIDs {
            return
        }
        guard snapshotCoordinator.state.isApplying
            || dataSource.snapshot().itemIdentifiers != rows.requestIDs else {
            return
        }
        snapshotCoordinator.pendingUpdate = PendingSnapshotUpdate(rows: rows, snapshot: snapshot)
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
        renderSelectedRequestID(model.selectedRequestID)
        applyPendingSnapshotUpdateIfNeeded()
    }

    private func fetchedResultsDidPublish(
        _ update: WebInspectorFetchedResultsUpdate<NetworkRequest.ID>
    ) {
        switch update {
        case .initial(let revision, let snapshot):
            guard lastFetchedResultsRevision != revision else {
                return
            }
            lastFetchedResultsRevision = revision
#if DEBUG
            recordFetchedResultsUpdateDeliveryForTesting()
#endif
            guard snapshotCoordinator.isRenderingActive else {
                if isViewLoaded == false
                    || dataSource.snapshot().itemIdentifiers != snapshot.itemIDs {
                    snapshotCoordinator.markNeedsReloadOnNextAppearance()
                }
                return
            }
            requestSnapshotUpdate(requestIDs: snapshot.itemIDs)
            renderEmptyState(isEmpty: snapshot.itemIDs.isEmpty)

        case .transaction(let revision, let transaction, _):
            // NetworkListCell observes each stable NetworkRequest identity
            // directly, so this consumer only applies collection topology.
            let isContiguous = lastFetchedResultsRevision.map { previousRevision in
                revision == previousRevision &+ 1
            } ?? false
            lastFetchedResultsRevision = revision
#if DEBUG
            recordFetchedResultsUpdateDeliveryForTesting()
#endif
            guard isContiguous else {
                guard snapshotCoordinator.isRenderingActive else {
                    snapshotCoordinator.markNeedsReloadOnNextAppearance()
                    return
                }
                requestSnapshotUpdate(requestIDs: transaction.newSnapshot.itemIDs)
                renderEmptyState(isEmpty: transaction.newSnapshot.itemIDs.isEmpty)
                return
            }
            guard transaction.hasNetworkListTopologyChanges else {
                return
            }
            guard snapshotCoordinator.isRenderingActive else {
                snapshotCoordinator.markNeedsReloadOnNextAppearance()
                return
            }
            applyTopologyTransaction(transaction)
        }
    }

    private func applyTopologyTransaction(
        _ transaction: WebInspectorFetchedResultsTransaction<NetworkRequest.ID>
    ) {
        let requestIDs = transaction.newSnapshot.itemIDs
        let topologyItemChanges = transaction.networkListTopologyItemChanges
        guard transaction.isReset
            || transaction.sectionChanges.isEmpty == false
            || topologyItemChanges.isEmpty == false else {
            return
        }
        guard transaction.isReset == false,
              transaction.sectionChanges.isEmpty,
              snapshotCoordinator.state.isApplying == false else {
            requestSnapshotUpdate(requestIDs: requestIDs)
            renderEmptyState(isEmpty: requestIDs.isEmpty)
            return
        }

        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers == transaction.oldSnapshot.itemIDs else {
            requestSnapshotUpdate(requestIDs: requestIDs)
            renderEmptyState(isEmpty: requestIDs.isEmpty)
            return
        }
        guard applyIncrementalItemChanges(
            topologyItemChanges,
            to: &snapshot,
            targetItemIDs: requestIDs
        ) else {
            requestSnapshotUpdate(requestIDs: requestIDs)
            renderEmptyState(isEmpty: requestIDs.isEmpty)
            return
        }
        requestSnapshotUpdate(
            snapshot: snapshot,
            rows: NetworkListViewController.SnapshotRows(requestIDs: requestIDs)
        )
        renderEmptyState(isEmpty: requestIDs.isEmpty)
    }

    private func applyIncrementalItemChanges(
        _ changes: [WebInspectorFetchedResultsItemChange<NetworkRequest.ID>],
        to snapshot: inout NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkRequest.ID>,
        targetItemIDs: [NetworkRequest.ID]
    ) -> Bool {
        if snapshot.sectionIdentifiers.contains(.main) == false {
            snapshot.appendSections([.main])
        }
        for change in changes {
            if case let .delete(itemID, _) = change,
               snapshot.indexOfItem(itemID) != nil {
                snapshot.deleteItems([itemID])
            }
        }
        for change in changes {
            guard case let .insert(itemID, indexPath) = change else {
                continue
            }
            guard snapshot.indexOfItem(itemID) == nil else {
                continue
            }
            insertItem(
                itemID,
                atTargetIndex: indexPath.item,
                targetItemIDs: targetItemIDs,
                into: &snapshot
            )
        }
        for change in changes {
            guard case let .move(itemID, _, indexPath) = change else {
                continue
            }
            guard snapshot.indexOfItem(itemID) != nil else {
                return false
            }
            moveItem(
                itemID,
                toTargetIndex: indexPath.item,
                targetItemIDs: targetItemIDs,
                in: &snapshot
            )
        }
        return snapshot.itemIdentifiers == targetItemIDs
    }

    private func insertItem(
        _ itemID: NetworkRequest.ID,
        atTargetIndex targetIndex: Int,
        targetItemIDs: [NetworkRequest.ID],
        into snapshot: inout NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkRequest.ID>
    ) {
        if targetIndex > 0 {
            let previousItemID = targetItemIDs[targetIndex - 1]
            if snapshot.indexOfItem(previousItemID) != nil {
                snapshot.insertItems([itemID], afterItem: previousItemID)
                return
            }
        }
        let nextIndex = targetIndex + 1
        if nextIndex < targetItemIDs.count {
            let nextItemID = targetItemIDs[nextIndex]
            if snapshot.indexOfItem(nextItemID) != nil {
                snapshot.insertItems([itemID], beforeItem: nextItemID)
                return
            }
        }
        snapshot.appendItems([itemID], toSection: .main)
    }

    private func moveItem(
        _ itemID: NetworkRequest.ID,
        toTargetIndex targetIndex: Int,
        targetItemIDs: [NetworkRequest.ID],
        in snapshot: inout NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkRequest.ID>
    ) {
        let nextIndex = targetIndex + 1
        if nextIndex < targetItemIDs.count {
            let nextItemID = targetItemIDs[nextIndex]
            if nextItemID != itemID,
               snapshot.indexOfItem(nextItemID) != nil {
                snapshot.moveItem(itemID, beforeItem: nextItemID)
                return
            }
        }
        if targetIndex > 0 {
            let previousItemID = targetItemIDs[targetIndex - 1]
            if previousItemID != itemID,
               snapshot.indexOfItem(previousItemID) != nil {
                snapshot.moveItem(itemID, afterItem: previousItemID)
            }
        }
    }

    private func reloadDataFromModel() {
        guard snapshotCoordinator.isRenderingActive else {
            snapshotCoordinator.markNeedsReloadOnNextAppearance()
            return
        }
        let requestIDs = displayRequestIDsFromModel()
        requestSnapshotUpdate(requestIDs: requestIDs)
        renderEmptyState(isEmpty: requestIDs.isEmpty)
    }

    private func renderInitialEmptyStateIfNeeded() {
        guard dataSource.snapshot().itemIdentifiers.isEmpty,
              model.isEmpty else {
            return
        }
        renderEmptyState(isEmpty: true)
    }

    private func displayRequestIDsFromModel() -> [NetworkRequest.ID] {
#if DEBUG
        displayRequestIDsEvaluationCountStorageForTesting += 1
#endif
        return model.displayRequestIDs
    }

    private func renderSelectedRequestID(_ selectedRequestID: NetworkRequest.ID?) {
        guard isViewLoaded else {
            return
        }

        let selectedIndexPaths = collectionView.indexPathsForSelectedItems ?? []
        let targetIndexPath = selectedRequestID.flatMap { dataSource.indexPath(for: $0) }
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
        guard
            let requestID = dataSource.itemIdentifier(for: indexPath),
            let request = model.request(for: requestID)
        else {
            requestSelectionAction(nil)
            return
        }
        requestSelectionAction(request)
    }
}

private extension WebInspectorFetchedResultsTransaction where ItemID == NetworkRequest.ID {
    var hasNetworkListTopologyChanges: Bool {
        isReset || sectionChanges.isEmpty == false || networkListTopologyItemChanges.isEmpty == false
    }

    var networkListTopologyItemChanges: [WebInspectorFetchedResultsItemChange<NetworkRequest.ID>] {
        itemChanges.filter { change in
            if case .update = change {
                return false
            }
            return true
        }
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
        selectedRequestObservation
    }

    package var displayRequestIDsEvaluationCountForTesting: Int {
        displayRequestIDsEvaluationCountStorageForTesting
    }

    package var snapshotApplyCountForTesting: Int {
        snapshotApplyCountStorageForTesting
    }

    package var fetchedResultsUpdateDeliveryCountForTesting: Int {
        fetchedResultsUpdateDeliveryCountStorageForTesting
    }

    package var filterMenuBuildCountForTesting: Int {
        filterMenuBuildCountStorageForTesting
    }

    package var displayedRequestIDsForTesting: [NetworkRequest.ID] {
        dataSource.snapshot().itemIdentifiers
    }

    package func networkListCellForTesting(at indexPath: IndexPath) -> NetworkListCell? {
        collectionView.cellForItem(at: indexPath) as? NetworkListCell
    }

    package var hasPendingSnapshotUpdateForTesting: Bool {
        snapshotCoordinator.pendingUpdate != nil
    }

    package func beginSnapshotApplyForTesting(requestIDs: [NetworkRequest.ID]) {
        snapshotCoordinator.state.beginApplying(
            NetworkListViewController.SnapshotRows(requestIDs: requestIDs)
        )
    }

    package func queueSnapshotUpdateForTesting(requestIDs: [NetworkRequest.ID]) {
        requestSnapshotUpdate(requestIDs: requestIDs)
    }

    package func finishSnapshotApplyForTesting(requestIDs: [NetworkRequest.ID]) {
        snapshotUpdateDidFinish(
            appliedRows: NetworkListViewController.SnapshotRows(requestIDs: requestIDs)
        )
    }

    package func suspendRenderingForTesting() {
        suspendRendering()
    }

    package func resumeRenderingForTesting() {
        resumeRendering()
    }

    package func flushPendingSnapshotUpdateForTesting() async {
        if snapshotCoordinator.needsReloadForActiveRendering {
            reloadDataFromModel()
        }
        applyPendingSnapshotUpdateIfNeeded()
        await waitForSnapshotUpdateCompletionForTesting()
    }

    package func waitForFetchedResultsUpdateDeliveryForTesting(
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

    private func recordFetchedResultsUpdateDeliveryForTesting() {
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
