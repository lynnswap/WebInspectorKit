import Foundation
import ObservationsCompat
import WebInspectorKitCore

#if canImport(UIKit)
import UIKit

private protocol DiffableStableID: Hashable, Sendable {}
private protocol DiffableCellKind: Hashable, Sendable {}

private struct DiffableRenderState<ID: DiffableStableID, Payload> {
    let payloadByID: [ID: Payload]
    let revisionByID: [ID: Int]
}

@MainActor
final class NetworkTabViewController: UISplitViewController, UISplitViewControllerDelegate {
    private let inspector: WINetworkPaneViewModel
    private var observationTask: Task<Void, Never>?

    private let listViewController: NetworkListViewController
    private let detailViewController: NetworkDetailViewController

    init(inspector: WINetworkPaneViewModel) {
        self.inspector = inspector
        self.listViewController = NetworkListViewController(inspector: inspector)
        self.detailViewController = NetworkDetailViewController(inspector: inspector)
        super.init(style: .doubleColumn)
        delegate = self
        preferredDisplayMode = .oneBesideSecondary
        title = nil
        inspector.selectedEntryID = nil

        listViewController.onSelectEntry = { [weak self] entry in
            guard let self else { return }
            self.inspector.selectedEntryID = entry?.id
            self.detailViewController.display(entry, hasEntries: !self.inspector.store.entries.isEmpty)
            guard entry != nil else {
                if self.isCollapsed {
                    self.show(.primary)
                }
                return
            }
            if self.isCollapsed, let secondaryController = self.viewController(for: .secondary) {
                self.showDetailViewController(secondaryController, sender: self)
            }
        }

        let primary = UINavigationController(rootViewController: listViewController)
        let secondary = UINavigationController(rootViewController: detailViewController)
        wiApplyClearNavigationBarStyle(to: primary)
        wiApplyClearNavigationBarStyle(to: secondary)
        setViewController(primary, for: .primary)
        setViewController(secondary, for: .secondary)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        observationTask?.cancel()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startObservingInspectorIfNeeded()
        syncDetailSelection()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopObservingInspector()
    }

    private func syncDetailSelection() {
        let resolvedSelection = NetworkListSelectionPolicy.resolvedSelection(
            current: inspector.selectedEntryID,
            entries: inspector.displayEntries
        )
        if inspector.selectedEntryID != resolvedSelection {
            inspector.selectedEntryID = resolvedSelection
        }
        let entry = inspector.store.entry(forEntryID: inspector.selectedEntryID)
        detailViewController.display(entry, hasEntries: !inspector.store.entries.isEmpty)
        listViewController.selectEntry(with: inspector.selectedEntryID)
        ensurePrimaryColumnIfNeeded()
    }

    private func startObservingInspectorIfNeeded() {
        guard observationTask == nil else {
            return
        }
        observationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            for await _ in NetworkListEventStream.makeDetailStream(inspector: self.inspector) {
                guard !Task.isCancelled else {
                    break
                }
                self.syncDetailSelection()
            }
        }
    }

    private func stopObservingInspector() {
        observationTask?.cancel()
        observationTask = nil
    }

    private func ensurePrimaryColumnIfNeeded() {
        guard isCollapsed, inspector.selectedEntryID == nil else {
            return
        }
        show(.primary)
    }

    func splitViewController(
        _ splitViewController: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        if inspector.selectedEntryID == nil {
            return .primary
        }
        return proposedTopColumn
    }
}

@MainActor
private final class NetworkListViewController: UICollectionViewController, UISearchResultsUpdating {
    private enum SectionIdentifier: Hashable {
        case main
    }

    private enum ItemCellKind: String, DiffableCellKind {
        case list
    }

    private enum ItemStableKey: DiffableStableID {
        case entry(id: UUID)
    }

    private struct ItemStableID: DiffableStableID {
        let key: ItemStableKey
        let cellKind: ItemCellKind
    }

    private struct ItemIdentifier: Hashable, Sendable {
        let stableID: ItemStableID
    }

    fileprivate struct ItemPayload {
        let entryID: UUID
        let displayName: String
        let fileTypeLabel: String
        let statusSeverity: NetworkStatusSeverity
    }

    private let inspector: WINetworkPaneViewModel
    private var observationTask: Task<Void, Never>?

    private var displayedEntries: [NetworkEntry] = []
    private var entryByID: [UUID: NetworkEntry] = [:]
    private var payloadByStableID: [ItemStableID: ItemPayload] = [:]
    private var revisionByStableID: [ItemStableID: Int] = [:]
    private var lastRenderSignature: Int?
    private var needsSnapshotReloadOnNextAppearance = false
    private var pendingReloadDataTask: Task<Void, Never>?
    private var snapshotTaskGeneration: UInt64 = 0
    private lazy var dataSource = makeDataSource()
    private lazy var filterItem: UIBarButtonItem = {
        UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease"),
            menu: makeFilterMenu()
        )
    }()
    private lazy var secondaryActionsItem: UIBarButtonItem = {
        UIBarButtonItem(
            image: UIImage(systemName: wiSecondaryActionSymbolName()),
            menu: makeSecondaryMenu()
        )
    }()
    var onSelectEntry: ((NetworkEntry?) -> Void)?

    init(inspector: WINetworkPaneViewModel) {
        self.inspector = inspector
        super.init(collectionViewLayout: Self.makeListLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        pendingReloadDataTask?.cancel()
        observationTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        navigationItem.title = ""
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag

        let searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = wiLocalized("network.search.placeholder")
        searchController.searchBar.text = inspector.searchText
        navigationItem.searchController = searchController

        navigationItem.rightBarButtonItems = [secondaryActionsItem, filterItem]

    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startObservingInspectorIfNeeded()
        navigationController?.setNavigationBarHidden(false, animated: animated)
        let canDismiss =
            navigationController?.presentingViewController != nil ||
            splitViewController?.presentingViewController != nil ||
            tabBarController?.presentingViewController != nil
        if canDismiss {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "xmark"),
                style: .plain,
                target: self,
                action: #selector(closeInspector)
            )
        } else {
            navigationItem.leftBarButtonItem = nil
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        flushPendingSnapshotUpdateIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopObservingInspector()
    }

    func updateSearchResults(for searchController: UISearchController) {
        inspector.searchText = searchController.searchBar.text ?? ""
    }

    func selectEntry(with id: UUID?) {
        guard let id else {
            guard let selectedIndexPath = collectionView.indexPathsForSelectedItems?.first else {
                return
            }
            collectionView.deselectItem(at: selectedIndexPath, animated: true)
            return
        }
        let item = ItemIdentifier(stableID: ItemStableID(key: .entry(id: id), cellKind: .list))
        guard let indexPath = dataSource.indexPath(for: item) else {
            guard let selectedIndexPath = collectionView.indexPathsForSelectedItems?.first else {
                return
            }
            collectionView.deselectItem(at: selectedIndexPath, animated: true)
            return
        }
        if collectionView.indexPathsForSelectedItems?.contains(indexPath) != true {
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: .centeredVertically)
        }
    }

    @objc
    private func closeInspector() {
        if let container = splitViewController?.tabBarController, container.presentingViewController != nil {
            container.dismiss(animated: true)
            return
        }
        if let split = splitViewController, split.presentingViewController != nil {
            split.dismiss(animated: true)
            return
        }
        if let nav = navigationController, nav.presentingViewController != nil {
            nav.dismiss(animated: true)
        }
    }

    private static func makeListLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.showsSeparators = true
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<SectionIdentifier, ItemIdentifier> {
        let listCellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, ItemIdentifier> { [weak self] cell, _, item in
            self?.configureListCell(cell, item: item)
        }
        let dataSource = UICollectionViewDiffableDataSource<SectionIdentifier, ItemIdentifier>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            guard item.stableID.cellKind == .list else {
                assertionFailure("Unexpected cell kind for network list registration")
                return UICollectionViewCell()
            }
            return collectionView.dequeueConfiguredReusableCell(
                using: listCellRegistration,
                for: indexPath,
                item: item
            )
        }
        return dataSource
    }

    private func applySnapshot() {
        pendingReloadDataTask?.cancel()
        snapshotTaskGeneration &+= 1
        let generation = snapshotTaskGeneration
        let snapshot = makeSnapshot()
        pendingReloadDataTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.snapshotTaskGeneration == generation {
                    self.pendingReloadDataTask = nil
                }
            }
            guard !Task.isCancelled, self.snapshotTaskGeneration == generation else {
                return
            }
            await self.dataSource.apply(snapshot, animatingDifferences: false)
            guard !Task.isCancelled, self.snapshotTaskGeneration == generation else {
                return
            }
            self.selectEntry(with: self.inspector.selectedEntryID)
        }
    }

    private func applySnapshotUsingReloadData() {
        pendingReloadDataTask?.cancel()
        snapshotTaskGeneration &+= 1
        let generation = snapshotTaskGeneration
        let snapshot = makeSnapshot()
        pendingReloadDataTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.snapshotTaskGeneration == generation {
                    self.pendingReloadDataTask = nil
                }
            }
            guard !Task.isCancelled, self.snapshotTaskGeneration == generation else {
                return
            }
            await self.dataSource.applySnapshotUsingReloadData(snapshot)
            guard !Task.isCancelled, self.snapshotTaskGeneration == generation else {
                return
            }
            self.selectEntry(with: self.inspector.selectedEntryID)
        }
    }

    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier> {
        let render = buildRenderState()
        let stableIDs = render.stableIDs
        precondition(
            stableIDs.count == Set(stableIDs).count,
            "Duplicate diffable IDs detected in NetworkListViewController"
        )
        let previousRevisionByStableID = revisionByStableID
        payloadByStableID = render.state.payloadByID
        revisionByStableID = render.state.revisionByID

        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>()
        snapshot.appendSections([.main])
        let identifiers = stableIDs.map { stableID in
            ItemIdentifier(stableID: stableID)
        }
        snapshot.appendItems(identifiers, toSection: .main)

        let reconfigured = stableIDs.compactMap { stableID -> ItemIdentifier? in
            guard
                let previousRevision = previousRevisionByStableID[stableID],
                let nextRevision = render.state.revisionByID[stableID],
                previousRevision != nextRevision
            else {
                return nil
            }
            return ItemIdentifier(stableID: stableID)
        }
        if !reconfigured.isEmpty {
            snapshot.reconfigureItems(reconfigured)
        }
        return snapshot
    }

    private var isCollectionViewVisible: Bool {
        isViewLoaded && view.window != nil
    }

    private func requestSnapshotUpdate() {
        guard isCollectionViewVisible else {
            needsSnapshotReloadOnNextAppearance = true
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        applySnapshot()
    }

    private func flushPendingSnapshotUpdateIfNeeded() {
        guard needsSnapshotReloadOnNextAppearance, isCollectionViewVisible else {
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        applySnapshotUsingReloadData()
    }

    private func reloadDataFromInspector() {
        displayedEntries = inspector.displayEntries
        let resolvedSelection = NetworkListSelectionPolicy.resolvedSelection(
            current: inspector.selectedEntryID,
            entries: displayedEntries
        )
        if inspector.selectedEntryID != resolvedSelection {
            inspector.selectedEntryID = resolvedSelection
        }
        entryByID = Dictionary(uniqueKeysWithValues: displayedEntries.map { ($0.id, $0) })

        let renderSignature = snapshotRenderSignature(for: displayedEntries)
        if renderSignature != lastRenderSignature {
            lastRenderSignature = renderSignature
            requestSnapshotUpdate()
        } else if isCollectionViewVisible {
            selectEntry(with: inspector.selectedEntryID)
        }
        filterItem.menu = makeFilterMenu()
        secondaryActionsItem.menu = makeSecondaryMenu()
        secondaryActionsItem.isEnabled = !inspector.store.entries.isEmpty

        let hasActiveSelectedEntry = inspector.store.entry(forEntryID: inspector.selectedEntryID) != nil
        let shouldShowEmptyState = displayedEntries.isEmpty && !hasActiveSelectedEntry
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

    private func startObservingInspectorIfNeeded() {
        guard observationTask == nil else {
            return
        }
        observationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            for await _ in NetworkListEventStream.makeListStream(inspector: self.inspector) {
                guard !Task.isCancelled else {
                    break
                }
                self.reloadDataFromInspector()
            }
        }
        reloadDataFromInspector()
    }

    private func stopObservingInspector() {
        observationTask?.cancel()
        observationTask = nil
    }

    private func snapshotRenderSignature(for entries: [NetworkEntry]) -> Int {
        var hasher = Hasher()
        hasher.combine(entries.count)
        for entry in entries {
            hasher.combine(entry.id)
            hasher.combine(entry.displayName)
            hasher.combine(entry.fileTypeLabel)
            hasher.combine(entry.statusLabel)
            hasher.combine(entry.statusSeverity)
            hasher.combine(entry.method)
        }
        return hasher.finalize()
    }

    private func configureListCell(_ cell: UICollectionViewListCell, item: ItemIdentifier) {
        guard item.stableID.cellKind == .list else {
            assertionFailure("List registration mismatch in NetworkListViewController")
            cell.contentConfiguration = nil
            cell.accessories = []
            return
        }
        guard
            let payload = payloadByStableID[item.stableID]
        else {
            cell.contentConfiguration = nil
            cell.accessories = []
            return
        }

        var content = UIListContentConfiguration.cell()
        content.text = payload.displayName
        content.secondaryText = nil
        content.textProperties.numberOfLines = 2
        content.textProperties.lineBreakMode = .byTruncatingMiddle
        content.textProperties.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                weight: .semibold
            )
        )
        cell.contentConfiguration = content
        cell.accessories = [
            .customView(configuration: statusIndicatorConfiguration(for: payload.statusSeverity)),
            .label(
                text: payload.fileTypeLabel,
                options: .init(
                    reservedLayoutWidth: .actual,
                    tintColor: .secondaryLabel,
                    font: .preferredFont(forTextStyle: .footnote),
                    adjustsFontForContentSizeCategory: true
                )
            ),
            .disclosureIndicator()
        ]
    }

    private func makeSecondaryMenu() -> UIMenu {
        let hasEntries = !inspector.store.entries.isEmpty
        let clearAction = UIAction(
            title: wiLocalized("network.controls.clear"),
            image: UIImage(systemName: "trash"),
            attributes: hasEntries ? [.destructive] : [.destructive, .disabled]
        ) { [weak self] _ in
            self?.clearEntries()
        }
        return UIMenu(children: [clearAction])
    }

    private func makeFilterMenu() -> UIMenu {
        let keepsPresented: UIMenuElement.Attributes = [.keepsMenuPresented]
        let allIsOn = inspector.effectiveResourceFilters.isEmpty
        let allAction = UIAction(
            title: wiLocalized("network.filter.all"),
            attributes: keepsPresented,
            state: allIsOn ? .on : .off
        ) { [weak self] _ in
            self?.inspector.setResourceFilter(.all, isEnabled: true)
        }

        var resourceActions: [UIAction] = []
        for filter in NetworkResourceFilter.pickerCases {
            let action = UIAction(
                title: localizedTitle(for: filter),
                attributes: keepsPresented,
                state: inspector.activeResourceFilters.contains(filter) ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                let currentlyEnabled = self.inspector.activeResourceFilters.contains(filter)
                self.inspector.setResourceFilter(filter, isEnabled: !currentlyEnabled)
            }
            resourceActions.append(action)
        }

        let resourceSection = UIMenu(options: [.displayInline], children: resourceActions)
        return UIMenu(children: [allAction, resourceSection])
    }

    private func clearEntries() {
        inspector.clear()
    }

    private func localizedTitle(for filter: NetworkResourceFilter) -> String {
        switch filter {
        case .all:
            return wiLocalized("network.filter.all")
        case .document:
            return wiLocalized("network.filter.document")
        case .stylesheet:
            return wiLocalized("network.filter.stylesheet")
        case .image:
            return wiLocalized("network.filter.image")
        case .font:
            return wiLocalized("network.filter.font")
        case .script:
            return wiLocalized("network.filter.script")
        case .xhrFetch:
            return wiLocalized("network.filter.xhr_fetch")
        case .other:
            return wiLocalized("network.filter.other")
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard
            let item = dataSource.itemIdentifier(for: indexPath),
            let payload = payloadByStableID[item.stableID],
            let entry = entryByID[payload.entryID]
        else {
            onSelectEntry?(nil)
            return
        }
        onSelectEntry?(entry)
    }

    private func buildRenderState() -> (stableIDs: [ItemStableID], state: DiffableRenderState<ItemStableID, ItemPayload>) {
        var stableIDs: [ItemStableID] = []
        var payloadByID: [ItemStableID: ItemPayload] = [:]
        var revisionByID: [ItemStableID: Int] = [:]

        for entry in displayedEntries {
            let stableID = ItemStableID(key: .entry(id: entry.id), cellKind: .list)
            let payload = ItemPayload(
                entryID: entry.id,
                displayName: entry.displayName,
                fileTypeLabel: entry.fileTypeLabel,
                statusSeverity: entry.statusSeverity
            )
            stableIDs.append(stableID)
            payloadByID[stableID] = payload
            revisionByID[stableID] = revision(for: payload)
        }
        return (
            stableIDs: stableIDs,
            state: DiffableRenderState(payloadByID: payloadByID, revisionByID: revisionByID)
        )
    }

    private func revision(for payload: ItemPayload) -> Int {
        var hasher = Hasher()
        hasher.combine(payload.entryID)
        hasher.combine(payload.displayName)
        hasher.combine(payload.fileTypeLabel)
        hasher.combine(payload.statusSeverity)
        return hasher.finalize()
    }

    private func statusIndicatorConfiguration(for severity: NetworkStatusSeverity) -> UICellAccessory.CustomViewConfiguration {
        let dotView = UIView(frame: CGRect(origin: .zero, size: CGSize(width: 8, height: 8)))
        dotView.backgroundColor = networkStatusColor(for: severity)
        dotView.layer.cornerRadius = 4
        return .init(
            customView: dotView,
            placement: .leading(),
            reservedLayoutWidth: .custom(8),
            maintainsFixedSize: true
        )
    }
}

@MainActor
final class NetworkDetailViewController: UIViewController, UICollectionViewDelegate {
    private enum BodyKind: String, Hashable, Sendable {
        case request
        case response
    }

    private struct SectionIdentifier: Hashable, Sendable {
        let index: Int
        let title: String
    }

    private enum DetailSectionKind: Hashable, Sendable {
        case overview
        case requestHeaders
        case requestBody
        case responseHeaders
        case responseBody
        case error
    }

    private enum ItemCellKind: String, DiffableCellKind {
        case list
    }

    private enum ItemStableKey: DiffableStableID {
        case summary(entryID: UUID)
        case requestHeader(name: String, ordinal: Int)
        case responseHeader(name: String, ordinal: Int)
        case requestBody(entryID: UUID)
        case responseBody(entryID: UUID)
        case error(entryID: UUID)
    }

    private struct ItemStableID: DiffableStableID {
        let key: ItemStableKey
        let cellKind: ItemCellKind
    }

    private struct ItemIdentifier: Hashable, Sendable {
        let stableID: ItemStableID
    }

    private enum DetailRow {
        case summary(NetworkEntry)
        case header(name: String, value: String)
        case emptyHeader
        case body(entry: NetworkEntry, body: NetworkBody)
        case error(entryID: UUID, message: String)
    }

    private struct DetailSection {
        let kind: DetailSectionKind
        let title: String
        let rows: [DetailRow]
    }

    private enum ItemPayload {
        case summary(entryID: UUID)
        case header(name: String, value: String)
        case emptyHeader
        case body(entryID: UUID, bodyKind: BodyKind)
        case error(message: String)
    }

    private struct RenderSection {
        let sectionIdentifier: SectionIdentifier
        let stableIDs: [ItemStableID]
    }

    private let inspector: WINetworkPaneViewModel

    private var sections: [DetailSection] = []
    private var payloadByStableID: [ItemStableID: ItemPayload] = [:]
    private var revisionByStableID: [ItemStableID: Int] = [:]
    private var needsSnapshotReloadOnNextAppearance = false
    private var pendingReloadDataTask: Task<Void, Never>?
    private var snapshotTaskGeneration: UInt64 = 0
    private lazy var collectionView: UICollectionView = {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        return collectionView
    }()
    private lazy var dataSource = makeDataSource()
    private var entry: NetworkEntry?

    init(inspector: WINetworkPaneViewModel) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        pendingReloadDataTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        display(nil, hasEntries: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        flushPendingSnapshotUpdateIfNeeded()
    }

    func display(_ entry: NetworkEntry?, hasEntries: Bool = false) {
        self.entry = entry
        guard let entry else {
            title = nil
            sections = []
            requestSnapshotUpdate()
            collectionView.isHidden = true
            navigationItem.rightBarButtonItem = nil
            return
        }

        title = entry.displayName
        sections = makeSections(for: entry)
        collectionView.isHidden = false
        requestSnapshotUpdate()
        navigationItem.rightBarButtonItem = makeSecondaryActionsItem(for: entry)
    }

    private func makeLayout() -> UICollectionViewLayout {
        var listConfiguration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        listConfiguration.showsSeparators = true
        listConfiguration.headerMode = .supplementary
        return UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(using: listConfiguration, layoutEnvironment: environment)
            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .estimated(44)
            )
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            header.pinToVisibleBounds = true
            section.boundarySupplementaryItems = [header]
            return section
        }
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<SectionIdentifier, ItemIdentifier> {
        let listCellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, ItemIdentifier> { [weak self] cell, _, item in
            self?.configureListCell(cell, item: item)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            guard
                let self,
                let section = self.dataSource.sectionIdentifier(for: indexPath.section)
            else {
                return
            }
            var configuration = UIListContentConfiguration.header()
            configuration.text = section.title
            header.contentConfiguration = configuration
        }

        let dataSource = UICollectionViewDiffableDataSource<SectionIdentifier, ItemIdentifier>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            guard item.stableID.cellKind == .list else {
                assertionFailure("Unexpected cell kind for network detail list registration")
                return UICollectionViewCell()
            }
            return collectionView.dequeueConfiguredReusableCell(
                using: listCellRegistration,
                for: indexPath,
                item: item
            )
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration,
                for: indexPath
            )
        }
        return dataSource
    }

    private func applySnapshot() {
        pendingReloadDataTask?.cancel()
        snapshotTaskGeneration &+= 1
        let generation = snapshotTaskGeneration
        let snapshot = makeSnapshot()
        pendingReloadDataTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.snapshotTaskGeneration == generation {
                    self.pendingReloadDataTask = nil
                }
            }
            guard !Task.isCancelled, self.snapshotTaskGeneration == generation else {
                return
            }
            await self.dataSource.apply(snapshot, animatingDifferences: false)
            guard !Task.isCancelled, self.snapshotTaskGeneration == generation else {
                return
            }
        }
    }

    private func applySnapshotUsingReloadData() {
        pendingReloadDataTask?.cancel()
        snapshotTaskGeneration &+= 1
        let generation = snapshotTaskGeneration
        let snapshot = makeSnapshot()
        pendingReloadDataTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.snapshotTaskGeneration == generation {
                    self.pendingReloadDataTask = nil
                }
            }
            guard !Task.isCancelled, self.snapshotTaskGeneration == generation else {
                return
            }
            await self.dataSource.applySnapshotUsingReloadData(snapshot)
            guard !Task.isCancelled, self.snapshotTaskGeneration == generation else {
                return
            }
        }
    }

    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier> {
        let renderSections = makeRenderSections()
        let allStableIDs = renderSections.flatMap(\.stableIDs)
        precondition(
            allStableIDs.count == Set(allStableIDs).count,
            "Duplicate diffable IDs detected in NetworkDetailViewController"
        )
        let renderState = makeRenderState(for: renderSections)
        let previousRevisionByStableID = revisionByStableID
        payloadByStableID = renderState.payloadByID
        revisionByStableID = renderState.revisionByID

        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>()
        for renderSection in renderSections {
            snapshot.appendSections([renderSection.sectionIdentifier])
            let identifiers = renderSection.stableIDs.map { stableID in
                ItemIdentifier(stableID: stableID)
            }
            snapshot.appendItems(identifiers, toSection: renderSection.sectionIdentifier)
        }

        let reconfigured = allStableIDs.compactMap { stableID -> ItemIdentifier? in
            guard
                let previousRevision = previousRevisionByStableID[stableID],
                let nextRevision = renderState.revisionByID[stableID],
                previousRevision != nextRevision
            else {
                return nil
            }
            return ItemIdentifier(stableID: stableID)
        }
        if !reconfigured.isEmpty {
            snapshot.reconfigureItems(reconfigured)
        }
        return snapshot
    }

    private var isCollectionViewVisible: Bool {
        isViewLoaded && view.window != nil
    }

    private func requestSnapshotUpdate() {
        guard isCollectionViewVisible else {
            needsSnapshotReloadOnNextAppearance = true
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        applySnapshot()
    }

    private func flushPendingSnapshotUpdateIfNeeded() {
        guard needsSnapshotReloadOnNextAppearance, isCollectionViewVisible else {
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        applySnapshotUsingReloadData()
    }

    private func makeRenderSections() -> [RenderSection] {
        let currentEntryID = entry?.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        return sections.enumerated().map { sectionIndex, section in
            let sectionID = SectionIdentifier(index: sectionIndex, title: section.title)
            var headerOrdinals: [String: Int] = [:]
            let stableIDs = section.rows.map { row in
                itemStableID(
                    for: row,
                    sectionKind: section.kind,
                    currentEntryID: currentEntryID,
                    headerOrdinals: &headerOrdinals
                )
            }
            return RenderSection(sectionIdentifier: sectionID, stableIDs: stableIDs)
        }
    }

    private func makeRenderState(for renderSections: [RenderSection]) -> DiffableRenderState<ItemStableID, ItemPayload> {
        var payloadByID: [ItemStableID: ItemPayload] = [:]
        var revisionByID: [ItemStableID: Int] = [:]

        for (sectionIndex, section) in sections.enumerated() {
            guard sectionIndex < renderSections.count else {
                continue
            }
            let stableIDs = renderSections[sectionIndex].stableIDs
            for (rowIndex, row) in section.rows.enumerated() {
                guard rowIndex < stableIDs.count else {
                    continue
                }
                let stableID = stableIDs[rowIndex]
                let rendered = payloadAndRevision(for: row)
                payloadByID[stableID] = rendered.payload
                revisionByID[stableID] = rendered.revision
            }
        }

        return DiffableRenderState(payloadByID: payloadByID, revisionByID: revisionByID)
    }

    private func itemStableID(
        for row: DetailRow,
        sectionKind: DetailSectionKind,
        currentEntryID: UUID,
        headerOrdinals: inout [String: Int]
    ) -> ItemStableID {
        let key: ItemStableKey
        switch row {
        case let .summary(entry):
            key = .summary(entryID: entry.id)
        case let .header(name, _):
            let ordinal = headerOrdinals[name, default: 0]
            headerOrdinals[name] = ordinal + 1
            switch sectionKind {
            case .requestHeaders:
                key = .requestHeader(name: name, ordinal: ordinal)
            case .responseHeaders:
                key = .responseHeader(name: name, ordinal: ordinal)
            default:
                assertionFailure("Header row placed in non-header section")
                key = .requestHeader(name: name, ordinal: ordinal)
            }
        case .emptyHeader:
            switch sectionKind {
            case .requestHeaders:
                key = .requestHeader(name: "", ordinal: 0)
            case .responseHeaders:
                key = .responseHeader(name: "", ordinal: 0)
            default:
                assertionFailure("Empty header row placed in non-header section")
                key = .requestHeader(name: "", ordinal: 0)
            }
        case let .body(entry, body):
            let bodyKind: BodyKind = body.role == .request ? .request : .response
            key = bodyKind == .request
                ? .requestBody(entryID: entry.id)
                : .responseBody(entryID: entry.id)
        case .error:
            key = .error(entryID: currentEntryID)
        }
        return ItemStableID(key: key, cellKind: .list)
    }

    private func payloadAndRevision(for row: DetailRow) -> (payload: ItemPayload, revision: Int) {
        switch row {
        case let .summary(entry):
            return (
                payload: .summary(entryID: entry.id),
                revision: summaryRenderHash(for: entry)
            )
        case let .header(name, value):
            var hasher = Hasher()
            hasher.combine(name)
            hasher.combine(value)
            return (
                payload: .header(name: name, value: value),
                revision: hasher.finalize()
            )
        case .emptyHeader:
            return (
                payload: .emptyHeader,
                revision: 0
            )
        case let .body(entry, body):
            let bodyKind: BodyKind = body.role == .request ? .request : .response
            return (
                payload: .body(entryID: entry.id, bodyKind: bodyKind),
                revision: bodyRenderHash(entry: entry, body: body)
            )
        case let .error(_, message):
            var hasher = Hasher()
            hasher.combine(message)
            return (
                payload: .error(message: message),
                revision: hasher.finalize()
            )
        }
    }

    private func makeSections(for entry: NetworkEntry) -> [DetailSection] {
        var sections: [DetailSection] = [
            DetailSection(
                kind: .overview,
                title: wiLocalized("network.detail.section.overview", default: "Overview"),
                rows: [.summary(entry)]
            )
        ]

        let requestHeaderRows: [DetailRow]
        if entry.requestHeaders.isEmpty {
            requestHeaderRows = [.emptyHeader]
        } else {
            requestHeaderRows = entry.requestHeaders.fields.map { .header(name: $0.name, value: $0.value) }
        }
        sections.append(DetailSection(
            kind: .requestHeaders,
            title: wiLocalized("network.section.request", default: "Request"),
            rows: requestHeaderRows
        ))

        if let requestBody = entry.requestBody {
            sections.append(DetailSection(
                kind: .requestBody,
                title: wiLocalized("network.section.body.request", default: "Request Body"),
                rows: [.body(entry: entry, body: requestBody)]
            ))
        }

        let responseHeaderRows: [DetailRow]
        if entry.responseHeaders.isEmpty {
            responseHeaderRows = [.emptyHeader]
        } else {
            responseHeaderRows = entry.responseHeaders.fields.map { .header(name: $0.name, value: $0.value) }
        }
        sections.append(DetailSection(
            kind: .responseHeaders,
            title: wiLocalized("network.section.response", default: "Response"),
            rows: responseHeaderRows
        ))

        if let responseBody = entry.responseBody {
            sections.append(DetailSection(
                kind: .responseBody,
                title: wiLocalized("network.section.body.response", default: "Response Body"),
                rows: [.body(entry: entry, body: responseBody)]
            ))
        }

        if let errorDescription = entry.errorDescription, !errorDescription.isEmpty {
            sections.append(DetailSection(
                kind: .error,
                title: wiLocalized("network.section.error", default: "Error"),
                rows: [.error(entryID: entry.id, message: errorDescription)]
            ))
        }

        return sections
    }

    private func makeSecondaryActionsItem(for entry: NetworkEntry) -> UIBarButtonItem? {
        guard canFetchBodies(for: entry) else {
            return nil
        }
        let fetchAction = UIAction(
            title: wiLocalized("network.body.fetch", default: "Fetch Body"),
            image: UIImage(systemName: "arrow.clockwise")
        ) { [weak self] _ in
            self?.fetchBodies(force: true)
        }
        let menu = UIMenu(children: [fetchAction])
        return UIBarButtonItem(image: UIImage(systemName: wiSecondaryActionSymbolName()), menu: menu)
    }

    private func canFetchBodies(for entry: NetworkEntry) -> Bool {
        if let requestBody = entry.requestBody, requestBody.canFetchBody {
            return true
        }
        if let responseBody = entry.responseBody, responseBody.canFetchBody {
            return true
        }
        return false
    }

    private func fetchBodies(force: Bool) {
        guard let entry else {
            return
        }
        let entryID = entry.id

        Task {
            if let requestBody = entry.requestBody {
                await inspector.fetchBodyIfNeeded(for: entry, body: requestBody, force: force)
            }
            if let responseBody = entry.responseBody {
                await inspector.fetchBodyIfNeeded(for: entry, body: responseBody, force: force)
            }
            guard self.inspector.selectedEntryID == entryID else {
                return
            }
            self.display(entry)
        }
    }

    private func configureListCell(_ cell: UICollectionViewListCell, item: ItemIdentifier) {
        guard item.stableID.cellKind == .list else {
            assertionFailure("List registration mismatch in NetworkDetailViewController")
            cell.contentConfiguration = nil
            return
        }
        guard let payload = payloadByStableID[item.stableID] else {
            cell.contentConfiguration = nil
            return
        }
        cell.accessories = []
        var content = UIListContentConfiguration.cell()

        switch payload {
        case let .summary(entryID):
            guard let entry, entry.id == entryID else {
                cell.contentConfiguration = nil
                return
            }
            content = makeOverviewSubtitleConfiguration(for: entry)
        case let .header(name, value):
            content = makeElementLikeSubtitleConfiguration(
                title: name,
                detail: value,
                titleColor: .secondaryLabel,
                detailColor: .label
            )
        case .emptyHeader:
            content = UIListContentConfiguration.cell()
            content.text = wiLocalized("network.headers.empty", default: "No headers")
            content.textProperties.color = .secondaryLabel
        case let .body(entryID, bodyKind):
            guard
                let entry,
                entry.id == entryID,
                let body = body(for: bodyKind, in: entry)
            else {
                cell.contentConfiguration = nil
                return
            }
            content = makeElementLikeSubtitleConfiguration(
                title: makeBodyPrimaryText(entry: entry, body: body),
                detail: makeBodySecondaryText(body),
                titleColor: .secondaryLabel,
                detailColor: .label,
                titleNumberOfLines: 1,
                detailNumberOfLines: 6
            )
            cell.accessories = [.disclosureIndicator()]
        case let .error(error):
            content = UIListContentConfiguration.cell()
            content.text = error
            content.textProperties.color = .systemOrange
            content.textProperties.numberOfLines = 0
        }
        cell.contentConfiguration = content
    }

    private func makeElementLikeSubtitleConfiguration(
        title: String,
        detail: String,
        titleColor: UIColor,
        detailColor: UIColor,
        titleNumberOfLines: Int = 1,
        detailNumberOfLines: Int = 0
    ) -> UIListContentConfiguration {
        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.text = title
        configuration.secondaryText = detail
        configuration.textProperties.numberOfLines = titleNumberOfLines
        configuration.secondaryTextProperties.numberOfLines = detailNumberOfLines
        configuration.textProperties.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                weight: .semibold
            )
        )
        configuration.textToSecondaryTextVerticalPadding = 8
        configuration.textProperties.color = titleColor
        configuration.secondaryTextProperties.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                weight: .regular
            )
        )
        configuration.secondaryTextProperties.color = detailColor
        return configuration
    }

    private func makeOverviewSubtitleConfiguration(for entry: NetworkEntry) -> UIListContentConfiguration {
        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.textProperties.numberOfLines = 1
        configuration.secondaryText = entry.url
        configuration.secondaryTextProperties.numberOfLines = 4
        configuration.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
        configuration.secondaryTextProperties.color = .label
        configuration.textToSecondaryTextVerticalPadding = 8

        let metricsFont = UIFont.preferredFont(forTextStyle: .footnote)
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(attachment: makeStatusBadgeAttachment(for: entry, baselineFont: metricsFont)))

        if let duration = entry.duration {
            appendOverviewMetric(
                symbolName: "clock",
                text: entry.durationText(for: duration),
                to: attributed,
                font: metricsFont,
                color: .secondaryLabel
            )
        }
        if let encodedBodyLength = entry.encodedBodyLength {
            appendOverviewMetric(
                symbolName: "arrow.down.to.line",
                text: entry.sizeText(for: encodedBodyLength),
                to: attributed,
                font: metricsFont,
                color: .secondaryLabel
            )
        }

        configuration.attributedText = attributed
        return configuration
    }

    private func makeStatusBadgeAttachment(for entry: NetworkEntry, baselineFont: UIFont) -> NSTextAttachment {
        let tint = networkStatusColor(for: entry.statusSeverity)
        let badgeFont = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
                weight: .semibold
            )
        )
        let badgeText = entry.statusLabel as NSString
        let textSize = badgeText.size(withAttributes: [.font: badgeFont])
        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = 4
        let badgeSize = CGSize(
            width: ceil(textSize.width + horizontalPadding * 2),
            height: ceil(textSize.height + verticalPadding * 2)
        )

        let badgeImage = UIGraphicsImageRenderer(size: badgeSize).image { _ in
            let rect = CGRect(origin: .zero, size: badgeSize)
            let cornerRadius = min(8, badgeSize.height / 2)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)
            tint.withAlphaComponent(0.14).setFill()
            path.fill()

            let textRect = CGRect(
                x: (badgeSize.width - textSize.width) / 2,
                y: (badgeSize.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            badgeText.draw(
                in: textRect,
                withAttributes: [
                    .font: badgeFont,
                    .foregroundColor: tint
                ]
            )
        }

        let attachment = NSTextAttachment()
        attachment.image = badgeImage
        let baselineOffset = (baselineFont.capHeight - badgeSize.height) / 2
        attachment.bounds = CGRect(x: 0, y: baselineOffset, width: badgeSize.width, height: badgeSize.height)
        return attachment
    }

    private func appendOverviewMetric(
        symbolName: String,
        text: String,
        to attributed: NSMutableAttributedString,
        font: UIFont,
        color: UIColor
    ) {
        attributed.append(NSAttributedString(string: "  "))
        if let symbol = makeSymbolAttachment(symbolName: symbolName, baselineFont: font, tintColor: color) {
            attributed.append(symbol)
            attributed.append(NSAttributedString(string: " "))
        }
        attributed.append(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: color
                ]
            )
        )
    }

    private func makeSymbolAttachment(
        symbolName: String,
        baselineFont: UIFont,
        tintColor: UIColor
    ) -> NSAttributedString? {
        let symbolConfiguration = UIImage.SymbolConfiguration(font: baselineFont)
        guard
            let symbolImage = UIImage(systemName: symbolName, withConfiguration: symbolConfiguration)?
                .withTintColor(tintColor, renderingMode: .alwaysOriginal)
        else {
            return nil
        }
        let attachment = NSTextAttachment()
        attachment.image = symbolImage
        let symbolSize = symbolImage.size
        let baselineOffset = (baselineFont.capHeight - symbolSize.height) / 2
        attachment.bounds = CGRect(x: 0, y: baselineOffset, width: symbolSize.width, height: symbolSize.height)
        return NSAttributedString(attachment: attachment)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard
            let item = dataSource.itemIdentifier(for: indexPath),
            let payload = payloadByStableID[item.stableID],
            case .body = payload
        else {
            return false
        }
        return true
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        defer {
            collectionView.deselectItem(at: indexPath, animated: true)
        }
        guard
            let item = dataSource.itemIdentifier(for: indexPath),
            let payload = payloadByStableID[item.stableID],
            case let .body(entryID, bodyKind) = payload,
            let entry,
            entry.id == entryID,
            let body = body(for: bodyKind, in: entry)
        else {
            return
        }

        let preview = NetworkBodyPreviewViewController(entry: entry, inspector: inspector, bodyState: body)
        navigationController?.pushViewController(preview, animated: true)
    }

    private func body(for bodyKind: BodyKind, in entry: NetworkEntry) -> NetworkBody? {
        switch bodyKind {
        case .request:
            return entry.requestBody
        case .response:
            return entry.responseBody
        }
    }

    private func summaryRenderHash(for entry: NetworkEntry) -> Int {
        var hasher = Hasher()
        hasher.combine(entry.url)
        hasher.combine(entry.method)
        hasher.combine(entry.statusLabel)
        hasher.combine(entry.statusSeverity)
        hasher.combine(entry.duration)
        hasher.combine(entry.encodedBodyLength)
        hasher.combine(entry.phase.rawValue)
        return hasher.finalize()
    }

    private func bodyRenderHash(entry: NetworkEntry, body: NetworkBody) -> Int {
        var hasher = Hasher()
        hasher.combine(entry.id)
        hasher.combine(body.role)
        hasher.combine(body.kind.rawValue)
        hasher.combine(body.size)
        hasher.combine(body.summary)
        hasher.combine(body.preview)
        hasher.combine(body.full)
        hasher.combine(body.reference)
        hasher.combine(bodyFetchStateKey(body.fetchState))
        return hasher.finalize()
    }

    private func bodyFetchStateKey(_ state: NetworkBody.FetchState) -> String {
        switch state {
        case .inline:
            return "inline"
        case .fetching:
            return "fetching"
        case .full:
            return "full"
        case let .failed(error):
            return "failed.\(String(describing: error))"
        }
    }

    private func makeBodyPrimaryText(entry: NetworkEntry, body: NetworkBody) -> String {
        var parts: [String] = []
        if let typeLabel = networkBodyTypeLabel(entry: entry, body: body) {
            parts.append(typeLabel)
        }
        if let size = networkBodySize(entry: entry, body: body) {
            parts.append(entry.sizeText(for: size))
        }
        if parts.isEmpty {
            return wiLocalized("network.body.unavailable", default: "Body unavailable")
        }
        return parts.joined(separator: "  ")
    }

    private func makeBodySecondaryText(_ body: NetworkBody) -> String {
        switch body.fetchState {
        case .fetching:
            return wiLocalized("network.body.fetching", default: "Fetching body...")
        case .failed(let error):
            return error.localizedDescriptionText
        default:
            if body.kind == .form, !body.formEntries.isEmpty {
                return body.formEntries.prefix(4).map {
                    let value: String
                    if $0.isFile, let fileName = $0.fileName, !fileName.isEmpty {
                        value = fileName
                    } else {
                        value = $0.value
                    }
                    return "\($0.name): \(value)"
                }.joined(separator: "\n")
            }
            return networkBodyPreviewText(body) ?? wiLocalized("network.body.unavailable", default: "Body unavailable")
        }
    }
}

private func networkStatusColor(for severity: NetworkStatusSeverity) -> UIColor {
    switch severity {
    case .success:
        return .systemGreen
    case .notice:
        return .systemYellow
    case .warning:
        return .systemOrange
    case .error:
        return .systemRed
    case .neutral:
        return .secondaryLabel
    }
}

private func networkBodyTypeLabel(entry: NetworkEntry, body: NetworkBody) -> String? {
    let headerValue: String?
    switch body.role {
    case .request:
        headerValue = entry.requestHeaders["content-type"]
    case .response:
        headerValue = entry.responseHeaders["content-type"] ?? entry.mimeType
    }
    if let headerValue, !headerValue.isEmpty {
        let trimmed = headerValue
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)
        return trimmed ?? headerValue
    }
    return body.kind.rawValue.uppercased()
}

private func networkBodySize(entry: NetworkEntry, body: NetworkBody) -> Int? {
    if let size = body.size {
        return size
    }
    switch body.role {
    case .request:
        return entry.requestBodyBytesSent
    case .response:
        return entry.decodedBodyLength ?? entry.encodedBodyLength
    }
}

private func networkBodyPreviewText(_ body: NetworkBody) -> String? {
    if body.kind == .binary {
        return body.displayText
    }
    return decodedBodyText(from: body) ?? body.displayText
}

private func decodedBodyText(from body: NetworkBody) -> String? {
    guard let rawText = body.full ?? body.preview, !rawText.isEmpty else {
        return nil
    }
    guard body.isBase64Encoded else {
        return rawText
    }
    guard let data = Data(base64Encoded: rawText) else {
        return rawText
    }
    return String(data: data, encoding: .utf8) ?? rawText
}

#elseif canImport(AppKit)
import AppKit
import SwiftUI

@MainActor
final class NetworkTabViewController: NSSplitViewController {
    private let inspector: WINetworkPaneViewModel
    private var observationTask: Task<Void, Never>?
    private var listHostingController: NSHostingController<NetworkMacListPane>?
    private var detailViewController: NetworkMacDetailViewController?

    init(inspector: WINetworkPaneViewModel) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        observationTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        inspector.selectedEntryID = nil

        let listHost = NSHostingController(rootView: NetworkMacListPane(inspector: inspector))
        let detailController = NetworkMacDetailViewController(inspector: inspector)
        listHostingController = listHost
        detailViewController = detailController

        let listItem = NSSplitViewItem(viewController: listHost)
        listItem.minimumThickness = 280
        listItem.preferredThicknessFraction = 0.42
        listItem.canCollapse = false

        let detailItem = NSSplitViewItem(viewController: detailController)
        detailItem.minimumThickness = 280

        splitViewItems = [listItem, detailItem]

        syncSelection()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        startObservingInspectorIfNeeded()
        syncSelection()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        stopObservingInspector()
    }

    private func syncSelection() {
        let resolvedSelection = NetworkListSelectionPolicy.resolvedSelection(
            current: inspector.selectedEntryID,
            entries: inspector.displayEntries
        )
        if inspector.selectedEntryID != resolvedSelection {
            inspector.selectedEntryID = resolvedSelection
        }
    }

    func canFetchSelectedBodies() -> Bool {
        detailViewController?.canFetchBodies ?? false
    }

    func fetchSelectedBodies(force: Bool) {
        detailViewController?.fetchBodies(force: force)
    }

    private func startObservingInspectorIfNeeded() {
        guard observationTask == nil else {
            return
        }
        observationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            for await _ in NetworkListEventStream.makeListStream(inspector: self.inspector) {
                guard !Task.isCancelled else {
                    break
                }
                self.syncSelection()
            }
        }
    }

    private func stopObservingInspector() {
        observationTask?.cancel()
        observationTask = nil
    }
}

@MainActor
private final class NetworkMacDetailViewController: NSViewController {
    private let inspector: WINetworkPaneViewModel
    private var hostingController: NSHostingController<NetworkMacDetailPane>?
    private var fetchTask: Task<Void, Never>?

    init(inspector: WINetworkPaneViewModel) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        fetchTask?.cancel()
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let hostingController = NSHostingController(rootView: NetworkMacDetailPane(inspector: inspector))
        self.hostingController = hostingController
        addChild(hostingController)
        let hostedView = hostingController.view
        hostedView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(hostedView)

        NSLayoutConstraint.activate([
            hostedView.topAnchor.constraint(equalTo: view.topAnchor),
            hostedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostedView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        fetchTask?.cancel()
        fetchTask = nil
    }

    private var selectedEntry: NetworkEntry? {
        inspector.store.entry(forEntryID: inspector.selectedEntryID)
    }

    var canFetchBodies: Bool {
        guard let entry = selectedEntry else {
            return false
        }
        if let requestBody = entry.requestBody, requestBody.canFetchBody {
            return true
        }
        if let responseBody = entry.responseBody, responseBody.canFetchBody {
            return true
        }
        return false
    }

    func fetchBodies(force: Bool) {
        guard let entry = selectedEntry else {
            return
        }
        let entryID = entry.id

        fetchTask?.cancel()
        fetchTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if let requestBody = entry.requestBody {
                await inspector.fetchBodyIfNeeded(for: entry, body: requestBody, force: force)
            }
            if let responseBody = entry.responseBody {
                await inspector.fetchBodyIfNeeded(for: entry, body: responseBody, force: force)
            }
            guard !Task.isCancelled else {
                return
            }
            guard inspector.selectedEntryID == entryID else {
                return
            }
            _ = inspector.store.entry(forEntryID: entryID)
        }
    }
}

@MainActor
private struct NetworkMacListPane: View {
    @Bindable var inspector: WINetworkPaneViewModel

    var body: some View {
        VStack(spacing: 8) {
            controls
            if inspector.displayEntries.isEmpty {
                emptyState
            } else {
                Table(inspector.displayEntries, selection: tableSelection) {
                    TableColumn(Text(LocalizedStringResource("network.table.column.request", bundle: .module))) { entry in
                        Text(entry.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.body.weight(.semibold))
                    }
                    .width(min: 220, ideal: 320)

                    TableColumn(Text(LocalizedStringResource("network.table.column.status", bundle: .module))) { entry in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(networkStatusColor(for: entry.statusSeverity))
                                .frame(width: 8, height: 8)
                            Text(entry.statusLabel)
                        }
                        .font(.footnote)
                        .foregroundStyle(networkStatusColor(for: entry.statusSeverity))
                    }
                    .width(min: 92, ideal: 120)

                    TableColumn(Text(LocalizedStringResource("network.table.column.method", bundle: .module))) { entry in
                        Text(entry.method)
                            .font(.footnote.monospaced())
                    }
                    .width(min: 80, ideal: 96)

                    TableColumn(Text(LocalizedStringResource("network.table.column.type", bundle: .module))) { entry in
                        Text(entry.fileTypeLabel)
                            .font(.footnote.monospaced())
                    }
                    .width(min: 88, ideal: 110)

                    TableColumn(Text(LocalizedStringResource("network.table.column.duration", bundle: .module))) { entry in
                        Text(entry.duration.map(entry.durationText(for:)) ?? "-")
                            .font(.footnote)
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn(Text(LocalizedStringResource("network.table.column.size", bundle: .module))) { entry in
                        Text(entry.encodedBodyLength.map(entry.sizeText(for:)) ?? "-")
                            .font(.footnote.monospaced())
                    }
                    .width(min: 90, ideal: 110)
                }
                .tableStyle(.inset)
            }
        }
        .padding(8)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Menu {
                Toggle(isOn: bindingForAllFilters()) {
                    Text(LocalizedStringResource("network.filter.all", bundle: .module))
                }
                Divider()
                ForEach(NetworkResourceFilter.pickerCases, id: \.self) { filter in
                    Toggle(isOn: bindingForResourceFilter(filter)) {
                        Text(localizedTitle(for: filter))
                    }
                }
            } label: {
                Label(LocalizedStringResource("network.controls.filter", bundle: .module), systemImage: "line.3.horizontal.decrease")
            }
            .menuStyle(.borderlessButton)

            Button(LocalizedStringResource("network.controls.clear", bundle: .module), role: .destructive) {
                inspector.clear()
            }
            .disabled(inspector.store.entries.isEmpty)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    "",
                    text: $inspector.searchText,
                    prompt: Text(LocalizedStringResource("network.search.placeholder", bundle: .module))
                )
                .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.secondary.opacity(0.2))
            )
            .frame(minWidth: 210, idealWidth: 260, maxWidth: 360)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Image(systemName: "waveform.path.ecg.rectangle")
                .foregroundStyle(.secondary)
        } description: {
            VStack(spacing: 4) {
                Text(LocalizedStringResource("network.empty.title", bundle: .module))
                Text(LocalizedStringResource("network.empty.description", bundle: .module))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tableSelection: Binding<Set<UUID>> {
        Binding(
            get: {
                guard let selected = inspector.selectedEntryID else {
                    return []
                }
                return [selected]
            },
            set: { newSelection in
                let nextSelected = newSelection.first
                let resolved = NetworkListSelectionPolicy.resolvedSelection(
                    current: nextSelected,
                    entries: inspector.displayEntries
                )
                inspector.selectedEntryID = resolved
            }
        )
    }

    private func bindingForAllFilters() -> Binding<Bool> {
        Binding(
            get: {
                inspector.effectiveResourceFilters.isEmpty
            },
            set: { isEnabled in
                if isEnabled {
                    inspector.setResourceFilter(.all, isEnabled: true)
                }
            }
        )
    }

    private func bindingForResourceFilter(_ filter: NetworkResourceFilter) -> Binding<Bool> {
        Binding(
            get: {
                inspector.activeResourceFilters.contains(filter)
            },
            set: { isEnabled in
                inspector.setResourceFilter(filter, isEnabled: isEnabled)
            }
        )
    }

    private func localizedTitle(for filter: NetworkResourceFilter) -> LocalizedStringResource {
        switch filter {
        case .all:
            return LocalizedStringResource("network.filter.all", bundle: .module)
        case .document:
            return LocalizedStringResource("network.filter.document", bundle: .module)
        case .stylesheet:
            return LocalizedStringResource("network.filter.stylesheet", bundle: .module)
        case .image:
            return LocalizedStringResource("network.filter.image", bundle: .module)
        case .font:
            return LocalizedStringResource("network.filter.font", bundle: .module)
        case .script:
            return LocalizedStringResource("network.filter.script", bundle: .module)
        case .xhrFetch:
            return LocalizedStringResource("network.filter.xhr_fetch", bundle: .module)
        case .other:
            return LocalizedStringResource("network.filter.other", bundle: .module)
        }
    }
}

@MainActor
private struct NetworkMacDetailPane: View {
    @Bindable var inspector: WINetworkPaneViewModel

    private var entry: NetworkEntry? {
        inspector.store.entry(forEntryID: inspector.selectedEntryID)
    }

    private var hasEntries: Bool {
        !inspector.store.entries.isEmpty
    }

    var body: some View {
        if let entry {
            List {
                Section(LocalizedStringResource("network.detail.section.overview", bundle: .module)) {
                    overviewRow(for: entry)
                }

                Section(LocalizedStringResource("network.section.request", bundle: .module)) {
                    headersRows(entry.requestHeaders)
                }

                if let requestBody = entry.requestBody {
                    Section(LocalizedStringResource("network.section.body.request", bundle: .module)) {
                        bodyRow(entry: entry, body: requestBody)
                    }
                }

                Section(LocalizedStringResource("network.section.response", bundle: .module)) {
                    headersRows(entry.responseHeaders)
                }

                if let responseBody = entry.responseBody {
                    Section(LocalizedStringResource("network.section.body.response", bundle: .module)) {
                        bodyRow(entry: entry, body: responseBody)
                    }
                }

                if let error = entry.errorDescription, !error.isEmpty {
                    Section(LocalizedStringResource("network.section.error", bundle: .module)) {
                        errorRow(error)
                    }
                }
            }
            .listStyle(.inset)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if hasEntries {
            ContentUnavailableView {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
            } description: {
                VStack(spacing: 4) {
                    Text(LocalizedStringResource("network.empty.selection.title", bundle: .module))
                    Text(LocalizedStringResource("network.empty.selection.description", bundle: .module))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .foregroundStyle(.secondary)
            } description: {
                VStack(spacing: 4) {
                    Text(LocalizedStringResource("network.empty.title", bundle: .module))
                    Text(LocalizedStringResource("network.empty.description", bundle: .module))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func overviewRow(for entry: NetworkEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(entry.statusLabel)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(networkStatusColor(for: entry.statusSeverity))
                if let duration = entry.duration {
                    Label(entry.durationText(for: duration), systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let encodedBodyLength = entry.encodedBodyLength {
                    Label(entry.sizeText(for: encodedBodyLength), systemImage: "arrow.down.to.line")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Text(entry.url)
                .font(.footnote.monospaced())
                .lineLimit(4)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }

    @ViewBuilder
    private func headersRows(_ headers: NetworkHeaders) -> some View {
        if headers.isEmpty {
            Text(LocalizedStringResource("network.headers.empty", bundle: .module))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(headers.fields.enumerated()), id: \.offset) { _, field in
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(field.value)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
        }
    }

    private func bodyRow(entry: NetworkEntry, body: NetworkBody) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let typeLabel = networkBodyTypeLabel(entry: entry, body: body) {
                    Label(typeLabel, systemImage: "doc.text")
                }
                if let size = networkBodySize(entry: entry, body: body) {
                    Label(entry.sizeText(for: size), systemImage: "ruler")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if let summary = body.summary, !summary.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider()

            Text(bodyPreviewText(for: body))
                .font(.caption.monospaced())
                .foregroundStyle(bodyPreviewColor(for: body))
                .lineLimit(10)
                .textSelection(.enabled)
        }
    }

    private func errorRow(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
    }

    private func bodyPreviewText(for body: NetworkBody) -> String {
        if body.kind == .form, !body.formEntries.isEmpty {
            return body.formEntries.prefix(4).map {
                let value: String
                if $0.isFile, let fileName = $0.fileName, !fileName.isEmpty {
                    value = fileName
                } else {
                    value = $0.value
                }
                return "\($0.name): \(value)"
            }.joined(separator: "\n")
        }

        switch body.fetchState {
        case .fetching:
            return wiLocalized("network.body.fetching", default: "Fetching body...")
        case .failed(let error):
            return error.localizedDescriptionText
        default:
            return networkBodyPreviewText(body) ?? wiLocalized("network.body.unavailable", default: "Body unavailable")
        }
    }

    private func bodyPreviewColor(for body: NetworkBody) -> Color {
        switch body.fetchState {
        case .fetching:
            return .secondary
        case .failed:
            return .red
        default:
            return .primary
        }
    }

}

private func networkStatusColor(for severity: NetworkStatusSeverity) -> Color {
    switch severity {
    case .success:
        return .green
    case .notice:
        return .yellow
    case .warning:
        return .orange
    case .error:
        return .red
    case .neutral:
        return .secondary
    }
}

private func networkBodyTypeLabel(entry: NetworkEntry, body: NetworkBody) -> String? {
    let headerValue: String?
    switch body.role {
    case .request:
        headerValue = entry.requestHeaders["content-type"]
    case .response:
        headerValue = entry.responseHeaders["content-type"] ?? entry.mimeType
    }
    if let headerValue, !headerValue.isEmpty {
        let trimmed = headerValue
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)
        return trimmed ?? headerValue
    }
    return body.kind.rawValue.uppercased()
}

private func networkBodySize(entry: NetworkEntry, body: NetworkBody) -> Int? {
    if let size = body.size {
        return size
    }
    switch body.role {
    case .request:
        return entry.requestBodyBytesSent
    case .response:
        return entry.decodedBodyLength ?? entry.encodedBodyLength
    }
}

private func networkBodyPreviewText(_ body: NetworkBody) -> String? {
    if body.kind == .binary {
        return body.displayText
    }
    return decodedBodyText(from: body) ?? body.displayText
}

private func decodedBodyText(from body: NetworkBody) -> String? {
    guard let rawText = body.full ?? body.preview, !rawText.isEmpty else {
        return nil
    }
    guard body.isBase64Encoded else {
        return rawText
    }
    guard let data = Data(base64Encoded: rawText) else {
        return rawText
    }
    return String(data: data, encoding: .utf8) ?? rawText
}

#endif
