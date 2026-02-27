import Foundation
import ObservationsCompat
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(UIKit)
import UIKit

private protocol DiffableStableID: Hashable, Sendable {}
private protocol DiffableCellKind: Hashable, Sendable {}

private struct DiffableRenderState<ID: DiffableStableID, Payload> {
    let payloadByID: [ID: Payload]
    let revisionByID: [ID: Int]
}

@MainActor
public final class WINetworkListViewController: UICollectionViewController {
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

    private struct ItemPayload {
        let entryID: UUID
        let displayName: String
        let fileTypeLabel: String
        let statusSeverity: NetworkStatusSeverity
    }

    private let inspector: WINetworkModel
    private let queryModel: WINetworkQueryModel
    private var hasStartedObservingInspector = false
    private var entryObservationHandlesByID: [UUID: [ObservationHandle]] = [:]
    private let listUpdateCoalescer = UIUpdateCoalescer()

    private var entryByID: [UUID: NetworkEntry] = [:]
    private var payloadByStableID: [ItemStableID: ItemPayload] = [:]
    private var revisionByStableID: [ItemStableID: Int] = [:]
    private var lastRenderSignature: Int?
    private var needsSnapshotReloadOnNextAppearance = false
    private var pendingReloadDataTask: Task<Void, Never>?
    private var snapshotTaskGeneration: UInt64 = 0
    private lazy var dataSource = makeDataSource()
    private var searchController: UISearchController {
        queryModel.searchController
    }

    var filterNavigationItem: UIBarButtonItem {
        queryModel.filterBarButtonItem
    }
    var hostOverflowItemsForRegularNavigation: UIDeferredMenuElement {
        makeOverflowMenuElement()
    }

    public init(inspector: WINetworkModel) {
        self.inspector = inspector
        self.queryModel = WINetworkQueryModel(inspector: inspector)
        super.init(collectionViewLayout: Self.makeListLayout())
    }

    init(inspector: WINetworkModel, queryModel: WINetworkQueryModel) {
        self.inspector = inspector
        self.queryModel = queryModel
        super.init(collectionViewLayout: Self.makeListLayout())
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        pendingReloadDataTask?.cancel()
        for handles in entryObservationHandlesByID.values {
            for handle in handles {
                handle.cancel()
            }
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        view.accessibilityIdentifier = "WI.Network.ListPane"

        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "WI.Network.List"

        queryModel.syncSearchControllerText()
        startObservingInspectorIfNeeded()
        reloadDataFromInspector()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        flushPendingSnapshotUpdateIfNeeded()
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

    func applyNavigationItems(to navigationItem: UINavigationItem) {
        applyCompactNavigationItems(to: navigationItem)
    }

    func applyCompactNavigationItems(to navigationItem: UINavigationItem) {
        loadViewIfNeeded()
        queryModel.syncSearchControllerText()
        if navigationItem.searchController !== searchController {
            navigationItem.searchController = searchController
        }
        navigationItem.preferredSearchBarPlacement = .stacked
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.setRightBarButtonItems([queryModel.filterBarButtonItem], animated: false)
        navigationItem.setLeftBarButtonItems(nil, animated: false)
        navigationItem.additionalOverflowItems = makeOverflowMenuElement()
    }

    func applyListColumnNavigationItemsForRegularLayout() {
        loadViewIfNeeded()
        queryModel.syncSearchControllerText()
        if navigationItem.searchController !== searchController {
            navigationItem.searchController = searchController
        }
        // iPad regular split list column should not show modal close/back affordance.
        navigationItem.hidesBackButton = true
        navigationItem.leftItemsSupplementBackButton = false
        if #available(iOS 26.0, *) {
            navigationItem.preferredSearchBarPlacement = .integratedCentered
        } else {
            navigationItem.preferredSearchBarPlacement = .stacked
        }
//        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.setRightBarButtonItems(nil, animated: false)
        navigationItem.setLeftBarButtonItems(nil, animated: false)
        navigationItem.additionalOverflowItems = nil
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
            self.selectEntry(with: self.inspector.selectedEntry?.id)
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
            self.selectEntry(with: self.inspector.selectedEntry?.id)
        }
    }

    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier> {
        let render = buildRenderState()
        let stableIDs = render.stableIDs
        precondition(
            stableIDs.count == Set(stableIDs).count,
            "Duplicate diffable IDs detected in WINetworkListViewController"
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
        queryModel.syncSearchControllerText()
        let visibleEntries = queryModel.displayEntries
        entryByID = Dictionary(uniqueKeysWithValues: visibleEntries.map { ($0.id, $0) })
        synchronizeEntryObservers(with: visibleEntries)

        let renderSignature = snapshotRenderSignature(for: visibleEntries)
        if renderSignature != lastRenderSignature {
            lastRenderSignature = renderSignature
            requestSnapshotUpdate()
        } else if isCollectionViewVisible {
            selectEntry(with: inspector.selectedEntry?.id)
        }
        let shouldShowEmptyState = visibleEntries.isEmpty
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
        guard hasStartedObservingInspector == false else {
            return
        }
        hasStartedObservingInspector = true

        inspector.observeTask(
            [
                \.selectedEntry
            ]
        ) { [weak self] in
            self?.scheduleReloadDataFromInspector()
        }
        inspector.observeTask(
            [
                \.sortDescriptors
            ],
            options: WIObservationOptions.debounced
        ) { [weak self] in
            self?.scheduleReloadDataFromInspector()
        }
        queryModel.observeTask(
            [
                \.searchText,
                \.activeFilters,
                \.effectiveFilters
            ],
            options: WIObservationOptions.debounced
        ) { [weak self] in
            self?.scheduleReloadDataFromInspector()
        }
        inspector.store.observeTask(
            [
                \.entries
            ],
            options: WIObservationOptions.debounced
        ) { [weak self] in
            self?.scheduleReloadDataFromInspector()
        }
    }

    private func scheduleReloadDataFromInspector() {
        listUpdateCoalescer.schedule { [weak self] in
            self?.reloadDataFromInspector()
        }
    }

    private func synchronizeEntryObservers(with visibleEntries: [NetworkEntry]) {
        let currentIDs = Set(visibleEntries.map(\.id))
        let removedIDs = Set(entryObservationHandlesByID.keys).subtracting(currentIDs)
        for removedID in removedIDs {
            guard let handles = entryObservationHandlesByID.removeValue(forKey: removedID) else {
                continue
            }
            for handle in handles {
                handle.cancel()
            }
        }
        for entry in visibleEntries where entryObservationHandlesByID[entry.id] == nil {
            entryObservationHandlesByID[entry.id] = observeEntry(entry)
        }
    }

    private func observeEntry(_ entry: NetworkEntry) -> [ObservationHandle] {
        var handles: [ObservationHandle] = []
        handles.append(entry.observe(
            \.displayName,
            options: WIObservationOptions.dedupeDebounced
        ) { [weak self] _ in
            self?.scheduleReloadDataFromInspector()
        })
        handles.append(entry.observe(
            \.fileTypeLabel,
            options: WIObservationOptions.dedupeDebounced
        ) { [weak self] _ in
            self?.scheduleReloadDataFromInspector()
        })
        handles.append(entry.observe(
            \.statusLabel,
            options: WIObservationOptions.dedupeDebounced
        ) { [weak self] _ in
            self?.scheduleReloadDataFromInspector()
        })
        handles.append(entry.observe(
            \.statusSeverity,
            options: WIObservationOptions.dedupeDebounced
        ) { [weak self] _ in
            self?.scheduleReloadDataFromInspector()
        })
        handles.append(entry.observe(
            \.method,
            options: WIObservationOptions.dedupeDebounced
        ) { [weak self] _ in
            self?.scheduleReloadDataFromInspector()
        })
        handles.append(entry.observe(
            \.phase,
            options: WIObservationOptions.dedupeDebounced
        ) { [weak self] _ in
            self?.scheduleReloadDataFromInspector()
        })
        return handles
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
            assertionFailure("List registration mismatch in WINetworkListViewController")
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

    private func makeOverflowMenuElement() -> UIDeferredMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            completion((self?.makeSecondaryMenu() ?? UIMenu()).children)
        }
    }

    private func clearEntries() {
        inspector.clear()
    }

    public override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard
            let item = dataSource.itemIdentifier(for: indexPath),
            let payload = payloadByStableID[item.stableID],
            let entry = entryByID[payload.entryID]
        else {
            inspector.selectEntry(id: nil)
            return
        }
        inspector.selectEntry(id: entry.id)
    }

    private func buildRenderState() -> (stableIDs: [ItemStableID], state: DiffableRenderState<ItemStableID, ItemPayload>) {
        var stableIDs: [ItemStableID] = []
        var payloadByID: [ItemStableID: ItemPayload] = [:]
        var revisionByID: [ItemStableID: Int] = [:]

        for entry in queryModel.displayEntries {
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

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("Network List (UIKit)") {
    WIUIKitPreviewContainer {
        UINavigationController(
            rootViewController: WINetworkListViewController(
                inspector: WINetworkPreviewFixtures.makeInspector(mode: .root)
            )
        )
    }
}
#endif
#endif
