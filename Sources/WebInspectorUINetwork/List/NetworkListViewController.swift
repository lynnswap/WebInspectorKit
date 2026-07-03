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
    }

    private struct SnapshotCoordinator {
        var isRenderingActive = false
        var needsReloadOnNextAppearance = true
        var pendingUpdate: PendingSnapshotUpdate?
        var state = NetworkListViewController.SnapshotState()

        mutating func resumeRendering() {
            isRenderingActive = true
        }

        mutating func suspendRendering(hasPendingThrottledReload: Bool) {
            isRenderingActive = false
            if hasPendingThrottledReload || pendingUpdate != nil {
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

    private static let snapshotThrottleInterval: Duration = .milliseconds(80)

    private let model: NetworkPanelModel
    private var requestSelectionAction: RequestSelectionAction
    private var displayRowsObservation: PortableObservationTracking.Token?
    private var searchTextObservation: PortableObservationTracking.Token?
    private var resourceFilterObservation: PortableObservationTracking.Token?
    private var selectedRequestObservation: PortableObservationTracking.Token?
    private let displayRowsReloadScheduler = MainActorDelayScheduler()
    private var hasPendingThrottledDisplayRowsReload = false

    private var snapshotCoordinator = SnapshotCoordinator()
    private var isApplyingSearchPresentation = false
    private var activeSearchController: UISearchController?
#if DEBUG
    private var deinitHandlerForTesting: (@MainActor () -> Void)?
    private var snapshotUpdateCompletionWaitersForTesting: [CheckedContinuation<Void, Never>] = []
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
    }

    override package func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureNavigationItem()
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override package func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
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
        displayRowsObservation?.cancel()
        displayRowsObservation = withPortableContinuousObservation { [weak self] event in
            guard let self else { return }
            _ = model.displayRowsInvalidationRevision
            guard snapshotCoordinator.isRenderingActive else {
                snapshotCoordinator.markNeedsReloadOnNextAppearance()
                return
            }
            if event.kind == .initial {
                reloadDataFromModel()
            } else {
                scheduleThrottledDisplayRowsReload()
            }
        }

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

    private func resumeRendering() {
        snapshotCoordinator.resumeRendering()
        setVisibleCellRenderingActive(true)
        renderSearchText(model.searchText)
        resourceFilterSelectionDidChange(effectiveResourceFilters: model.effectiveResourceFilters)
        renderSelectedRequestID(model.selectedRequestID)
        renderInitialEmptyStateIfNeeded()
        if snapshotCoordinator.needsReloadForActiveRendering {
            scheduleThrottledDisplayRowsReload()
        }
    }

    private func suspendRendering() {
        guard snapshotCoordinator.isRenderingActive else {
            return
        }
        snapshotCoordinator.suspendRendering(hasPendingThrottledReload: hasPendingThrottledDisplayRowsReload)
        hasPendingThrottledDisplayRowsReload = false
        displayRowsReloadScheduler.cancel()
        setVisibleCellRenderingActive(false)
    }

    private func scheduleThrottledDisplayRowsReload() {
        guard snapshotCoordinator.isRenderingActive else {
            snapshotCoordinator.markNeedsReloadOnNextAppearance()
            return
        }
        hasPendingThrottledDisplayRowsReload = true
        guard displayRowsReloadScheduler.hasScheduledDelay == false else {
            return
        }

        displayRowsReloadScheduler.schedule(after: Self.snapshotThrottleInterval) { [weak self] in
            self?.flushThrottledDisplayRowsReload()
        }
    }

    private func flushThrottledDisplayRowsReload() {
        guard hasPendingThrottledDisplayRowsReload else {
            return
        }
        guard snapshotCoordinator.isRenderingActive else {
            hasPendingThrottledDisplayRowsReload = false
            snapshotCoordinator.markNeedsReloadOnNextAppearance()
            return
        }
        hasPendingThrottledDisplayRowsReload = false
        reloadDataFromModel()
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
        requestSnapshotUpdate(rows: NetworkListViewController.SnapshotRows(requestIDs: requestIDs))
    }

    private func requestSnapshotUpdate(
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
        enqueueSnapshotUpdate(rows: rows)
    }

    private func enqueueSnapshotUpdate(
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
        snapshotCoordinator.pendingUpdate = PendingSnapshotUpdate(rows: rows)
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

        let snapshot = makeSnapshot(
            requestIDs: update.rows.requestIDs
        )
        let completion: () -> Void = { [weak self] in
            self?.snapshotUpdateDidFinish(appliedRows: update.rows)
        }
#if DEBUG
        snapshotApplyCountStorageForTesting += 1
#endif
        dataSource.apply(snapshot, animatingDifferences: false, completion: completion)
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

    package var displayRequestIDsEvaluationCountForTesting: Int {
        displayRequestIDsEvaluationCountStorageForTesting
    }

    package var snapshotApplyCountForTesting: Int {
        snapshotApplyCountStorageForTesting
    }

    package var hasScheduledDisplayRowsReloadForTesting: Bool {
        hasPendingThrottledDisplayRowsReload || displayRowsReloadScheduler.hasScheduledDelay
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

    package func flushPendingSnapshotUpdateForTesting() async {
        if snapshotCoordinator.needsReloadForActiveRendering {
            scheduleThrottledDisplayRowsReload()
        }
        displayRowsReloadScheduler.cancel()
        flushThrottledDisplayRowsReload()
        applyPendingSnapshotUpdateIfNeeded()
        await waitForSnapshotUpdateCompletionForTesting()
    }

    package func flushThrottledDisplayRowsReloadForTesting() async {
        if snapshotCoordinator.needsReloadForActiveRendering {
            scheduleThrottledDisplayRowsReload()
        }
        displayRowsReloadScheduler.cancel()
        flushThrottledDisplayRowsReload()
        await waitForSnapshotUpdateCompletionForTesting()
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
