import Foundation
import ObservationBridge
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(UIKit)
import UIHostingMenu
import UIKit

@MainActor
class V2_NetworkListViewController: UICollectionViewController, UISearchResultsUpdating {
    typealias EntrySelectionAction = @MainActor (NetworkEntry?) -> Void

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

    private let inspector: WINetworkModel
    private var entrySelectionAction: EntrySelectionAction
    private var observationHandles: Set<ObservationHandle> = []

    private var needsSnapshotReloadOnNextAppearance = false
    private var isApplyingSearchPresentation = false
    private var activeSearchController: UISearchController?
    private lazy var filterHostingMenu = UIHostingMenu(
        rootView: V2_NetworkListFilterMenuView(inspector: inspector)
    )
    private lazy var overflowHostingMenu = UIHostingMenu(
        rootView: V2_NetworkListOverflowMenuView(inspector: inspector)
    )
    private lazy var filterItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease"),
            menu: makeFilterMenu()
        )
        item.accessibilityIdentifier = "WI.Network.FilterButton"
        item.isSelected = inspector.effectiveResourceFilters.isEmpty == false
        return item
    }()
    private lazy var dataSource = makeDataSource()

    init(inspector: WINetworkModel) {
        self.inspector = inspector
        entrySelectionAction = { [inspector] entry in
            inspector.selectEntry(entry)
        }
        super.init(collectionViewLayout: Self.makeListLayout())
        startObservingInspector()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationHandles.removeAll()
        detachSearchPresentation()
    }

    func setEntrySelectionAction(_ action: @escaping EntrySelectionAction) {
        entrySelectionAction = action
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        view.accessibilityIdentifier = "V2.Network.ListPane"

        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "V2.Network.List"

        configureNavigationItem()
        reloadDataFromInspector()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureNavigationItem()
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        flushPendingSnapshotUpdateIfNeeded()
    }

    override func willMove(toParent parent: UIViewController?) {
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

    private func startObservingInspector() {
        inspector.observe(\.displayEntries, options: Self.snapshotObservationOptions) { [weak self] displayEntries in
            self?.reloadDataFromInspector(displayEntries: displayEntries)
        }
        .store(in: &observationHandles)

        inspector.observe(\.searchText) { [weak self] searchText in
            self?.renderSearchText(searchText)
        }
        .store(in: &observationHandles)

        inspector.observe(\.effectiveResourceFilters) { [weak self] _ in
            self?.resourceFilterSelectionDidChange()
        }
        .store(in: &observationHandles)
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
            )
        ]
        navigationItem.additionalOverflowItems = makeOverflowMenuElement()

        renderSearchText(inspector.searchText)
        renderFilterItem()
    }

    func updateSearchResults(for searchController: UISearchController) {
        guard
            isApplyingSearchPresentation == false,
            searchController === activeSearchController
        else {
            return
        }
        let searchText = searchController.searchBar.text ?? ""
        guard searchText != inspector.searchText else {
            return
        }
        inspector.setSearchText(searchText)
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
        searchController.searchBar.placeholder = wiLocalized("network.search.placeholder")
        searchController.searchBar.text = inspector.searchText
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
        filterItem.isSelected = inspector.effectiveResourceFilters.isEmpty == false
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

    private func makeDataSource() -> UICollectionViewDiffableDataSource<SectionIdentifier, NetworkEntry> {
        let listCellRegistration = UICollectionView.CellRegistration<V2_NetworkListCell, NetworkEntry> { cell, _, item in
            cell.bind(item: item)
        }
        return UICollectionViewDiffableDataSource<SectionIdentifier, NetworkEntry>(
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
        displayEntries: [NetworkEntry]
    ) -> NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkEntry> {
        precondition(
            displayEntries.count == Set(displayEntries.map(\.id)).count,
            "Duplicate row IDs detected in V2_NetworkListViewController"
        )

        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkEntry>()
        snapshot.appendSections([.main])
        snapshot.appendItems(displayEntries, toSection: .main)
        return snapshot
    }

    private var isCollectionViewVisible: Bool {
        isViewLoaded && view.window != nil
    }

    private func requestSnapshotUpdate(displayEntries: [NetworkEntry]) {
        guard isCollectionViewVisible else {
            needsSnapshotReloadOnNextAppearance = true
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        Task {
            let snapshot = self.makeSnapshot(displayEntries: displayEntries)
            await self.dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    private func flushPendingSnapshotUpdateIfNeeded() {
        guard needsSnapshotReloadOnNextAppearance, isCollectionViewVisible else {
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        Task {
            let snapshot = self.makeSnapshot(displayEntries: self.inspector.displayEntries)
            await self.dataSource.applySnapshotUsingReloadData(snapshot)
        }
    }

    private func reloadDataFromInspector(displayEntries: [NetworkEntry]? = nil) {
        let resolvedDisplayEntries = displayEntries ?? inspector.displayEntries
        requestSnapshotUpdate(displayEntries: resolvedDisplayEntries)
        overflowHostingMenu.requestUpdate()

        let shouldShowEmptyState = resolvedDisplayEntries.isEmpty
        collectionView.isHidden = shouldShowEmptyState
        if shouldShowEmptyState {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = wiLocalized("network.empty.title")
            configuration.secondaryText = wiLocalized("network.empty.description")
            configuration.image = UIImage(systemName: "waveform.path.ecg.rectangle")
            contentUnavailableConfiguration = configuration
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let entry = dataSource.itemIdentifier(for: indexPath) else {
            entrySelectionAction(nil)
            return
        }
        entrySelectionAction(entry)
    }
}

#if DEBUG
extension V2_NetworkListViewController {
    var collectionViewForTesting: UICollectionView {
        collectionView
    }

    var searchControllerForTesting: UISearchController {
        loadViewIfNeeded()
        configureNavigationItem()
        guard let activeSearchController else {
            fatalError("Expected V2_NetworkListViewController to have an active search controller")
        }
        return activeSearchController
    }

    var filterItemForTesting: UIBarButtonItem {
        filterItem
    }

    var filterMenuForTesting: UIMenu {
        materializedMenuForTesting(filterHostingMenu)
    }

    var overflowMenuForTesting: UIMenu {
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
    WIUIKitPreviewContainer {
        UINavigationController(
            rootViewController: V2_NetworkListViewController(
                inspector: WINetworkPreviewFixtures.makeInspector(mode: .root)
            )
        )
    }
}
#endif
#endif
