#if canImport(UIKit)
import ObservationBridge
import UIHostingMenu
import UIKit
import V2_WebInspectorCore

@MainActor
package final class V2_NetworkListViewController: UICollectionViewController, UISearchResultsUpdating {
    package typealias RequestSelectionAction = @MainActor (NetworkRequest?) -> Void

    private enum SectionIdentifier: Hashable {
        case main
    }

    private static let snapshotObservationOptions = ObservationOptions.rateLimit(
        .throttle(
            ObservationThrottle(
                interval: .milliseconds(80),
                mode: .latest
            )
        )
    )

    private let model: V2_NetworkListModel
    private var requestSelectionAction: RequestSelectionAction
    private let observationScope = ObservationScope()

    private var needsSnapshotReloadOnNextAppearance = false
    private var isApplyingSearchPresentation = false
    private var activeSearchController: UISearchController?
    private lazy var filterHostingMenu = UIHostingMenu(
        rootView: V2_NetworkListFilterMenuView(model: model)
    )
    private lazy var overflowHostingMenu = UIHostingMenu(
        rootView: V2_NetworkListOverflowMenuView(model: model)
    )
    private lazy var filterItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease"),
            menu: makeFilterMenu()
        )
        item.accessibilityIdentifier = "WI.Network.FilterButton"
        item.isSelected = model.effectiveResourceFilters.isEmpty == false
        return item
    }()
    private lazy var dataSource = makeDataSource()

    package init(model: V2_NetworkListModel) {
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
        model.observe(\.displayRequests, options: Self.snapshotObservationOptions) { [weak self] displayRequests in
            self?.reloadDataFromModel(displayRequests: displayRequests)
        }
        .store(in: observationScope)

        model.observe(\.searchText) { [weak self] searchText in
            self?.renderSearchText(searchText)
        }
        .store(in: observationScope)

        model.observe(\.effectiveResourceFilters) { [weak self] _ in
            self?.resourceFilterSelectionDidChange()
        }
        .store(in: observationScope)
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
        renderFilterItem()
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
        searchController.searchBar.placeholder = v2WILocalized("network.search.placeholder", default: "Search requests")
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

    private func renderFilterItem() {
        guard isViewLoaded else {
            return
        }
        filterItem.isSelected = model.effectiveResourceFilters.isEmpty == false
    }

    private func resourceFilterSelectionDidChange() {
        if isViewLoaded {
            filterHostingMenu.setNeedsUpdate()
        }
        renderFilterItem()
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
        let listCellRegistration = UICollectionView.CellRegistration<V2_NetworkListCell, NetworkRequest.ID> { [weak model] cell, _, id in
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
        displayRequests: [NetworkRequest]
    ) -> NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkRequest.ID> {
        let requestIDs = displayRequests.map(\.id)
        precondition(
            requestIDs.count == Set(requestIDs).count,
            "Duplicate row IDs detected in V2_NetworkListViewController"
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
        guard isCollectionViewVisible else {
            needsSnapshotReloadOnNextAppearance = true
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        Task {
            let snapshot = self.makeSnapshot(displayRequests: displayRequests)
            await self.dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    private func flushPendingSnapshotUpdateIfNeeded() {
        guard needsSnapshotReloadOnNextAppearance, isCollectionViewVisible else {
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        Task {
            let snapshot = self.makeSnapshot(displayRequests: self.model.displayRequests)
            await self.dataSource.applySnapshotUsingReloadData(snapshot)
        }
    }

    private func reloadDataFromModel(displayRequests: [NetworkRequest]? = nil) {
        let resolvedDisplayRequests = displayRequests ?? model.displayRequests
        requestSnapshotUpdate(displayRequests: resolvedDisplayRequests)
        overflowHostingMenu.requestUpdate()

        let shouldShowEmptyState = resolvedDisplayRequests.isEmpty
        collectionView.isHidden = shouldShowEmptyState
        if shouldShowEmptyState {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = v2WILocalized("network.empty.title", default: "No requests yet")
            configuration.secondaryText = v2WILocalized(
                "network.empty.description",
                default: "Trigger a network request to see activity."
            )
            configuration.image = UIImage(systemName: "waveform.path.ecg.rectangle")
            contentUnavailableConfiguration = configuration
        } else {
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
extension V2_NetworkListViewController {
    package var collectionViewForTesting: UICollectionView {
        collectionView
    }

    package var searchControllerForTesting: UISearchController {
        loadViewIfNeeded()
        configureNavigationItem()
        guard let activeSearchController else {
            fatalError("Expected V2_NetworkListViewController to have an active search controller")
        }
        return activeSearchController
    }

    package var filterItemForTesting: UIBarButtonItem {
        filterItem
    }

    package var filterMenuForTesting: UIMenu {
        materializedMenuForTesting(filterHostingMenu)
    }

    package var overflowMenuForTesting: UIMenu {
        materializedMenuForTesting(overflowHostingMenu)
    }

    private func materializedMenuForTesting<Content>(_ hostingMenu: UIHostingMenu<Content>) -> UIMenu {
        if let cachedMenu = hostingMenu.cachedMenu {
            return cachedMenu
        }
        _ = try? hostingMenu.menu()
        return hostingMenu.cachedMenu ?? UIMenu()
    }
}
#endif

#if DEBUG && canImport(SwiftUI)
import SwiftUI

#Preview("V2 Network List") {
    UINavigationController(
        rootViewController: V2_NetworkListViewController(
            model: V2_NetworkPreviewFixtures.makeListModel(mode: .root)
        )
    )
}

#Preview("V2 Network List Long Title") {
    UINavigationController(
        rootViewController: V2_NetworkListViewController(
            model: V2_NetworkPreviewFixtures.makeListModel(mode: .rootLongTitle)
        )
    )
}
#endif
#endif
