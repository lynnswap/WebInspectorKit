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
        var requestIDs: [NetworkRequest.ID]
        var mode: SnapshotApplyMode
    }

    private static let snapshotStreamOptions = ObservationStreamOptions.rateLimit(
        .throttle(
            ObservationThrottle(
                interval: .milliseconds(80),
                mode: .latest
            )
        )
    )

    private let model: NetworkPanelModel
    private var requestSelectionAction: RequestSelectionAction
    private let observationScope = ObservationScope()
    private var displayRequestsObservationTask: Task<Void, Never>?

    private var needsSnapshotReloadOnNextAppearance = false
    private var pendingSnapshotUpdate: PendingSnapshotUpdate?
    private var applyingSnapshotRequestIDs: [NetworkRequest.ID]?
    private var isApplyingSnapshotUpdate = false
    private var isApplyingSearchPresentation = false
    private var activeSearchController: UISearchController?
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
        displayRequestsObservationTask?.cancel()
        observationScope.cancelAll()
        detachSearchPresentation()
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
        displayRequestsObservationTask?.cancel()
        let model = model
        displayRequestsObservationTask = Task { @MainActor [weak self, model] in
            let stream = makeObservationBridgeStream(options: Self.snapshotStreamOptions) {
                model.displayRequests
            }
            for await displayRequests in stream {
                guard let self else {
                    return
                }
                self.reloadDataFromModel(displayRequests: displayRequests)
            }
        }

        observationScope.observe(model) { [weak self] _, model in
            self?.renderSearchText(model.searchText)
        }

        observationScope.observe(model) { [weak self] _, model in
            self?.resourceFilterSelectionDidChange(effectiveResourceFilters: model.effectiveResourceFilters)
        }
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
        collectionView.backgroundColor = webInspectorBackgroundPolicy.backgroundColor
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

    private func renderFilterItem(effectiveResourceFilters: Set<NetworkResourceFilter>) {
        guard isViewLoaded else {
            return
        }
        filterItem.isSelected = effectiveResourceFilters.isEmpty == false
    }

    private func resourceFilterSelectionDidChange(effectiveResourceFilters: Set<NetworkResourceFilter>) {
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
        let listCellRegistration = UICollectionView.CellRegistration<NetworkListCell, NetworkRequest.ID> { [weak model] cell, _, id in
            guard let request = model?.request(for: id) else {
                return
            }
            cell.bind(request: request)
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
        isViewLoaded && view.window != nil
    }

    private func requestSnapshotUpdate(displayRequests: [NetworkRequest]) {
        requestSnapshotUpdate(requestIDs: displayRequests.map(\.id))
    }

    private func requestSnapshotUpdate(requestIDs: [NetworkRequest.ID]) {
        precondition(
            requestIDs.count == Set(requestIDs).count,
            "Duplicate row IDs detected in NetworkListViewController"
        )
        if let applyingSnapshotRequestIDs {
            if applyingSnapshotRequestIDs == requestIDs {
                pendingSnapshotUpdate = nil
                return
            }
        } else if dataSource.snapshot().itemIdentifiers == requestIDs {
            pendingSnapshotUpdate = nil
            return
        }
        guard isCollectionViewVisible else {
            needsSnapshotReloadOnNextAppearance = true
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        enqueueSnapshotUpdate(requestIDs: requestIDs, mode: .apply)
    }

    private func flushPendingSnapshotUpdateIfNeeded() {
        guard needsSnapshotReloadOnNextAppearance, isCollectionViewVisible else {
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        enqueueSnapshotUpdate(requestIDs: model.displayRequests.map(\.id), mode: .reloadData)
    }

    private func enqueueSnapshotUpdate(requestIDs: [NetworkRequest.ID], mode: SnapshotApplyMode) {
        if let pendingSnapshotUpdate, pendingSnapshotUpdate.requestIDs == requestIDs {
            self.pendingSnapshotUpdate = PendingSnapshotUpdate(
                requestIDs: requestIDs,
                mode: pendingSnapshotUpdate.mode == .reloadData || mode == .reloadData ? .reloadData : .apply
            )
            return
        }
        guard applyingSnapshotRequestIDs != nil || dataSource.snapshot().itemIdentifiers != requestIDs || mode == .reloadData else {
            return
        }
        pendingSnapshotUpdate = PendingSnapshotUpdate(requestIDs: requestIDs, mode: mode)
        applyPendingSnapshotUpdateIfNeeded()
    }

    private func applyPendingSnapshotUpdateIfNeeded() {
        guard !isApplyingSnapshotUpdate, let update = pendingSnapshotUpdate else {
            return
        }
        pendingSnapshotUpdate = nil
        isApplyingSnapshotUpdate = true
        applyingSnapshotRequestIDs = update.requestIDs

        let snapshot = makeSnapshot(requestIDs: update.requestIDs)
        let completion: () -> Void = { [weak self] in
            self?.snapshotUpdateDidFinish()
        }
        switch update.mode {
        case .apply:
            dataSource.apply(snapshot, animatingDifferences: false, completion: completion)
        case .reloadData:
            dataSource.applySnapshotUsingReloadData(snapshot, completion: completion)
        }
    }

    private func snapshotUpdateDidFinish() {
        applyingSnapshotRequestIDs = nil
        isApplyingSnapshotUpdate = false
        applyPendingSnapshotUpdateIfNeeded()
    }

    private func reloadDataFromModel(displayRequests: [NetworkRequest]? = nil) {
        let resolvedDisplayRequests = displayRequests ?? model.displayRequests
        requestSnapshotUpdate(displayRequests: resolvedDisplayRequests)
        renderEmptyState(isEmpty: resolvedDisplayRequests.isEmpty)
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
