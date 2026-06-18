#if canImport(UIKit)
import WebInspectorCore
import ObservationBridge
import UIHostingMenu
import UIKit

@MainActor
package final class NetworkListViewController: UICollectionViewController, UISearchResultsUpdating {
    package typealias RequestSelectionAction = @MainActor (NetworkRequest?) -> Void

    private enum SectionIdentifier: Hashable {
        case main
    }

    private enum SnapshotApplyMode {
        case apply
        case reloadData
    }

    private struct PendingSnapshotUpdate {
        var rows: NetworkListViewController.SnapshotRows
        var reconfiguredIDs: Set<NetworkRequest.ID>
        var mode: SnapshotApplyMode
    }

    private static let snapshotThrottleInterval: Duration = .milliseconds(80)

    private let model: NetworkPanelModel
    private var requestSelectionAction: RequestSelectionAction
    private var displayRowsObservation: PortableObservationTracking.Token?
    private var searchTextObservation: PortableObservationTracking.Token?
    private var resourceFilterObservation: PortableObservationTracking.Token?
    private var selectedRequestObservation: PortableObservationTracking.Token?
    private let displayRowsReloadScheduler = MainActorDelayScheduler()
    private var pendingThrottledDisplayRows: [NetworkRequest.Display.Projection]?

    private var needsSnapshotReloadOnNextAppearance = false
    private var pendingSnapshotUpdate: PendingSnapshotUpdate?
    private var snapshotState = NetworkListViewController.SnapshotState()
    private var isApplyingSearchPresentation = false
    private var activeSearchController: UISearchController?
#if DEBUG
    private var deinitHandlerForTesting: (@MainActor () -> Void)?
    private var snapshotUpdateCompletionWaitersForTesting: [CheckedContinuation<Void, Never>] = []
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
            menu: makeFilterMenu()
        )
        item.accessibilityIdentifier = "WebInspector.Network.FilterButton"
        item.isSelected = model.effectiveResourceFilters.isEmpty == false
        return item
    }()
    private lazy var dataSource = makeDataSource()

    package init(model: NetworkPanelModel) {
        self.model = model
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
        displayRowsObservation?.cancel()
        searchTextObservation?.cancel()
        resourceFilterObservation?.cancel()
        selectedRequestObservation?.cancel()
        displayRowsReloadScheduler.cancel()
        detachSearchPresentation()
#if DEBUG
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
        reloadDataFromModel()
    }

    override package func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureNavigationItem()
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override package func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        flushPendingSnapshotUpdateIfNeeded()
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
        displayRowsObservation?.cancel()
        displayRowsObservation = withPortableContinuousObservation { [weak self] event in
            guard let self else { return }
            let projectionInput = model.displayRowsProjectionInput()
            let displayRows = model.displayRows
            guard isViewLoaded else {
                model.scheduleDisplayRowsProjection(input: projectionInput)
                needsSnapshotReloadOnNextAppearance = true
                return
            }
            if event.kind == .initial {
                model.scheduleDisplayRowsProjection(input: projectionInput)
                reloadDataFromModel(displayRows: displayRows)
            } else {
                model.scheduleDisplayRowsProjection(input: projectionInput)
                scheduleThrottledDisplayRowsReload(displayRows)
            }
        }

        searchTextObservation?.cancel()
        searchTextObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }
            renderSearchText(model.searchText)
        }

        resourceFilterObservation?.cancel()
        resourceFilterObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }
            resourceFilterSelectionDidChange(effectiveResourceFilters: model.effectiveResourceFilters)
        }

        selectedRequestObservation?.cancel()
        selectedRequestObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }
            renderSelectedRequestID(model.selectedRequestID)
        }
    }

    private func scheduleThrottledDisplayRowsReload(_ displayRows: [NetworkRequest.Display.Projection]) {
        pendingThrottledDisplayRows = displayRows
        guard displayRowsReloadScheduler.hasScheduledDelay == false else {
            return
        }

        displayRowsReloadScheduler.schedule(after: Self.snapshotThrottleInterval) { [weak self] in
            self?.flushThrottledDisplayRowsReload()
        }
    }

    private func flushThrottledDisplayRowsReload() {
        guard let displayRows = pendingThrottledDisplayRows else {
            return
        }
        pendingThrottledDisplayRows = nil
        reloadDataFromModel(displayRows: displayRows)
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
        searchController.searchBar.placeholder = String(localized: "network.search.placeholder", bundle: .module)
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

    private func renderFilterItem(effectiveResourceFilters: Set<NetworkRequest.Display.ResourceFilter>) {
        guard isViewLoaded else {
            return
        }
        filterItem.isSelected = effectiveResourceFilters.isEmpty == false
    }

    private func resourceFilterSelectionDidChange(effectiveResourceFilters: Set<NetworkRequest.Display.ResourceFilter>) {
        renderFilterItem(effectiveResourceFilters: effectiveResourceFilters)
    }

    private func makeFilterMenu() -> UIMenu {
        (try? filterHostingMenu.menu()) ?? UIMenu()
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
            guard let projection = self?.projectionForVisibleRow(id) else {
                return
            }
            cell.bind(projection: projection)
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

    private func projectionForVisibleRow(_ id: NetworkRequest.ID) -> NetworkRequest.Display.Projection? {
        snapshotState.projection(for: id) ?? model.displayProjection(for: id)
    }

    private func makeSnapshot(
        requestIDs: [NetworkRequest.ID],
        reconfiguredIDs: Set<NetworkRequest.ID>
    ) -> NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkRequest.ID> {
        precondition(
            requestIDs.count == Set(requestIDs).count,
            "Duplicate row IDs detected in NetworkListViewController"
        )

        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkRequest.ID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(requestIDs, toSection: .main)
        let reconfiguredItems = requestIDs.filter { reconfiguredIDs.contains($0) }
        if reconfiguredItems.isEmpty == false {
            snapshot.reconfigureItems(reconfiguredItems)
        }
        return snapshot
    }

    private var isCollectionViewVisible: Bool {
        isViewLoaded && view.window != nil
    }

    private func requestSnapshotUpdate(displayRows: [NetworkRequest.Display.Projection]) {
        let rows = NetworkListViewController.SnapshotRows(displayRows: displayRows)
        let reconfiguredIDs = snapshotState.reconfiguredIDs(comparedTo: rows)
        requestSnapshotUpdate(
            rows: rows,
            reconfiguredIDs: reconfiguredIDs
        )
    }

    private func requestSnapshotUpdate(
        rows: NetworkListViewController.SnapshotRows,
        reconfiguredIDs: Set<NetworkRequest.ID>
    ) {
        var effectiveReconfiguredIDs = reconfiguredIDs
        if let applyingRows = snapshotState.applyingRows {
            if applyingRows.requestIDs == rows.requestIDs && effectiveReconfiguredIDs.isEmpty {
                effectiveReconfiguredIDs = snapshotState.reconfiguredIDsAgainstApplyingRows(rows)
            }
            if applyingRows.requestIDs == rows.requestIDs && effectiveReconfiguredIDs.isEmpty {
                pendingSnapshotUpdate = nil
                return
            }
        } else if dataSource.snapshot().itemIdentifiers == rows.requestIDs && effectiveReconfiguredIDs.isEmpty {
            pendingSnapshotUpdate = nil
            return
        }
        guard isCollectionViewVisible else {
            needsSnapshotReloadOnNextAppearance = true
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        enqueueSnapshotUpdate(
            rows: rows,
            reconfiguredIDs: effectiveReconfiguredIDs,
            mode: .apply
        )
    }

    private func flushPendingSnapshotUpdateIfNeeded() {
        guard needsSnapshotReloadOnNextAppearance, isCollectionViewVisible else {
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        let displayRows = model.displayRows
        enqueueSnapshotUpdate(
            rows: NetworkListViewController.SnapshotRows(displayRows: displayRows),
            reconfiguredIDs: [],
            mode: .reloadData
        )
    }

    private func enqueueSnapshotUpdate(
        rows: NetworkListViewController.SnapshotRows,
        reconfiguredIDs: Set<NetworkRequest.ID>,
        mode: SnapshotApplyMode
    ) {
        if let pendingSnapshotUpdate, pendingSnapshotUpdate.rows.requestIDs == rows.requestIDs {
            self.pendingSnapshotUpdate = PendingSnapshotUpdate(
                rows: rows,
                reconfiguredIDs: pendingSnapshotUpdate.reconfiguredIDs.union(reconfiguredIDs),
                mode: pendingSnapshotUpdate.mode == .reloadData || mode == .reloadData ? .reloadData : .apply
            )
            return
        }
        guard snapshotState.isApplying
            || dataSource.snapshot().itemIdentifiers != rows.requestIDs
            || reconfiguredIDs.isEmpty == false
            || mode == .reloadData else {
            return
        }
        pendingSnapshotUpdate = PendingSnapshotUpdate(
            rows: rows,
            reconfiguredIDs: reconfiguredIDs,
            mode: mode
        )
        applyPendingSnapshotUpdateIfNeeded()
    }

    private func applyPendingSnapshotUpdateIfNeeded() {
        guard !snapshotState.isApplying, let update = pendingSnapshotUpdate else {
            return
        }
        pendingSnapshotUpdate = nil
        snapshotState.beginApplying(update.rows)

        let snapshot = makeSnapshot(
            requestIDs: update.rows.requestIDs,
            reconfiguredIDs: update.mode == .reloadData ? [] : update.reconfiguredIDs
        )
        let completion: () -> Void = { [weak self] in
            self?.snapshotUpdateDidFinish(appliedRows: update.rows)
        }
        switch update.mode {
        case .apply:
            dataSource.apply(snapshot, animatingDifferences: false, completion: completion)
        case .reloadData:
            dataSource.applySnapshotUsingReloadData(snapshot, completion: completion)
        }
    }

    private func snapshotUpdateDidFinish(
        appliedRows: NetworkListViewController.SnapshotRows
    ) {
        snapshotState.finishApplying(appliedRows)
        renderSelectedRequestID(model.selectedRequestID)
        applyPendingSnapshotUpdateIfNeeded()
#if DEBUG
        resumeSnapshotUpdateCompletionWaitersForTesting()
#endif
    }

    private func reloadDataFromModel(displayRows: [NetworkRequest.Display.Projection]? = nil) {
        let resolvedDisplayRows = displayRows ?? model.displayRows
        requestSnapshotUpdate(displayRows: resolvedDisplayRows)
        renderEmptyState(isEmpty: resolvedDisplayRows.isEmpty)
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
            let title = String(localized: "network.empty.title", bundle: .module)
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

    package var displayRowsObservationDeliveryForTesting: PortableObservationTracking.Token? {
        displayRowsObservation
    }

    package var selectedRequestObservationDeliveryForTesting: PortableObservationTracking.Token? {
        selectedRequestObservation
    }

    package func flushThrottledDisplayRowsReloadForTesting() async {
        displayRowsReloadScheduler.cancel()
        flushThrottledDisplayRowsReload()
        await waitForSnapshotUpdateCompletionForTesting()
    }

    private func waitForSnapshotUpdateCompletionForTesting() async {
        guard snapshotState.isApplying || pendingSnapshotUpdate != nil else {
            return
        }
        await withCheckedContinuation { continuation in
            snapshotUpdateCompletionWaitersForTesting.append(continuation)
        }
    }

    private func resumeSnapshotUpdateCompletionWaitersForTesting() {
        guard snapshotState.isApplying == false, pendingSnapshotUpdate == nil else {
            return
        }
        let waiters = snapshotUpdateCompletionWaitersForTesting
        snapshotUpdateCompletionWaitersForTesting.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
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
