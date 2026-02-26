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
final class NetworkListPaneViewController: UICollectionViewController, UISearchResultsUpdating {
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

    private let inspector: WINetworkTabViewModel
    private var hasStartedObservingInspector = false
    private var entryObservationHandlesByID: [UUID: [ObservationHandle]] = [:]
    private let listUpdateCoalescer = UIUpdateCoalescer()

    private var displayedEntries: [NetworkEntry] = []
    private var entryByID: [UUID: NetworkEntry] = [:]
    private var payloadByStableID: [ItemStableID: ItemPayload] = [:]
    private var revisionByStableID: [ItemStableID: Int] = [:]
    private var lastRenderSignature: Int?
    private var needsSnapshotReloadOnNextAppearance = false
    private var pendingReloadDataTask: Task<Void, Never>?
    private var snapshotTaskGeneration: UInt64 = 0
    private var missingSelectionBehavior: NetworkListSelectionPolicy.MissingSelectionBehavior = .firstEntry
    private lazy var filterMenuController = NetworkFilterMenuController(
        titleProvider: { [weak self] filter in
            self?.localizedTitle(for: filter) ?? filter.rawValue
        },
        toggleHandler: { [weak self] filter, isEnabled in
            self?.setResourceFilter(filter, isEnabled: isEnabled)
        }
    )
    private lazy var dataSource = makeDataSource()
    private lazy var closeInspectorItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            style: .plain,
            target: self,
            action: #selector(closeInspector)
        )
        return item
    }()

    var onSelectEntry: ((NetworkEntry?) -> Void)?

    init(inspector: WINetworkTabViewModel) {
        self.inspector = inspector
        super.init(collectionViewLayout: Self.makeListLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
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

    override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        navigationItem.title = ""
        view.accessibilityIdentifier = "WI.Network.ListPane"

        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "WI.Network.List"

        let searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = wiLocalized("network.search.placeholder")
        searchController.searchBar.text = inspector.searchText
        navigationItem.searchController = searchController

        navigationItem.rightBarButtonItems = [filterMenuController.item]
        navigationItem.leftBarButtonItem = closeInspectorItem
        syncFilterPresentation(notifyingVisibleMenu: false)
        navigationItem.additionalOverflowItems = UIDeferredMenuElement.uncached { [weak self] completion in
            completion((self?.makeSecondaryMenu() ?? UIMenu()).children)
        }
        updateCloseInspectorItemState()
        startObservingInspectorIfNeeded()
        reloadDataFromInspector()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        updateCloseInspectorItemState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        flushPendingSnapshotUpdateIfNeeded()
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

    func setMissingSelectionBehavior(_ behavior: NetworkListSelectionPolicy.MissingSelectionBehavior) {
        guard missingSelectionBehavior != behavior else {
            return
        }
        missingSelectionBehavior = behavior
        reconcileSelectionIfNeeded()
    }

    func applyNavigationItems(to navigationItem: UINavigationItem) {
        loadViewIfNeeded()
        updateCloseInspectorItemState()
        navigationItem.searchController = self.navigationItem.searchController
        navigationItem.setRightBarButtonItems(self.navigationItem.rightBarButtonItems, animated: false)
        navigationItem.setLeftBarButtonItems(self.navigationItem.leftBarButtonItems, animated: false)
        navigationItem.additionalOverflowItems = self.navigationItem.additionalOverflowItems
    }

    @objc
    private func closeInspector() {
        resolveInspectorDismissalController()?.dismiss(animated: true)
    }

    private func resolveInspectorDismissalController() -> UIViewController? {
        if let inspectorContainer = resolveInspectorContainer(),
           let dismissible = resolveDismissibleAncestor(startingAt: inspectorContainer) {
            return dismissible
        }
        return resolveDismissibleAncestor(startingAt: self)
    }

    private func resolveInspectorContainer() -> WIContainerViewController? {
        var cursor: UIViewController? = self
        while let current = cursor {
            if let container = current as? WIContainerViewController {
                return container
            }
            cursor = current.parent
        }
        return nil
    }

    private func resolveDismissibleAncestor(startingAt viewController: UIViewController) -> UIViewController? {
        var cursor: UIViewController? = viewController
        while let current = cursor {
            if let navigationController = current as? UINavigationController,
               navigationController.presentingViewController != nil {
                return navigationController
            }
            if current.presentingViewController != nil {
                return current
            }
            cursor = current.parent
        }
        return nil
    }

    private func updateCloseInspectorItemState() {
        closeInspectorItem.isEnabled = resolveInspectorDismissalController() != nil
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
            "Duplicate diffable IDs detected in NetworkListPaneViewController"
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
        reconcileSelectionIfNeeded()
        entryByID = Dictionary(uniqueKeysWithValues: displayedEntries.map { ($0.id, $0) })
        synchronizeEntryObservers()

        let renderSignature = snapshotRenderSignature(for: displayedEntries)
        if renderSignature != lastRenderSignature {
            lastRenderSignature = renderSignature
            requestSnapshotUpdate()
        } else if isCollectionViewVisible {
            selectEntry(with: inspector.selectedEntry?.id)
        }
        syncFilterPresentation(notifyingVisibleMenu: false)
        navigationItem.additionalOverflowItems = UIDeferredMenuElement.uncached { [weak self] completion in
            completion((self?.makeSecondaryMenu() ?? UIMenu()).children)
        }

        let shouldShowEmptyState = displayedEntries.isEmpty
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

    private func reconcileSelectionIfNeeded() {
        let resolvedSelection = NetworkListSelectionPolicy.resolvedSelection(
            current: inspector.selectedEntry,
            entries: displayedEntries,
            whenMissing: missingSelectionBehavior
        )
        if inspector.selectedEntry?.id != resolvedSelection?.id {
            inspector.selectedEntry = resolvedSelection
        }
    }

    private func startObservingInspectorIfNeeded() {
        guard hasStartedObservingInspector == false else {
            return
        }
        hasStartedObservingInspector = true

        inspector.observeTask(
            [
                \.selectedEntry,
                \.searchText,
                \.activeResourceFilters,
                \.effectiveResourceFilters,
                \.sortDescriptors
            ],
            retention: .automatic
        ) { [weak self] in
            self?.scheduleReloadDataFromInspector()
        }
        inspector.store.observeTask(
            [
                \.entries
            ],
            retention: .automatic
        ) { [weak self] in
            self?.scheduleReloadDataFromInspector()
        }
    }

    private func scheduleReloadDataFromInspector() {
        listUpdateCoalescer.schedule { [weak self] in
            self?.reloadDataFromInspector()
        }
    }

    private func synchronizeEntryObservers() {
        let currentIDs = Set(displayedEntries.map(\.id))
        let removedIDs = Set(entryObservationHandlesByID.keys).subtracting(currentIDs)
        for removedID in removedIDs {
            guard let handles = entryObservationHandlesByID.removeValue(forKey: removedID) else {
                continue
            }
            for handle in handles {
                handle.cancel()
            }
        }
        for entry in displayedEntries where entryObservationHandlesByID[entry.id] == nil {
            entryObservationHandlesByID[entry.id] = observeEntry(entry)
        }
    }

    private func observeEntry(_ entry: NetworkEntry) -> [ObservationHandle] {
        var handles: [ObservationHandle] = []
        handles.append(entry.observe(
            \.displayName,
            retention: .automatic,
            removeDuplicates: true
        ) { [weak self] _ in
            self?.scheduleReloadDataFromInspector()
        })
        handles.append(entry.observe(
            \.fileTypeLabel,
            retention: .automatic,
            removeDuplicates: true
        ) { [weak self] _ in
            self?.scheduleReloadDataFromInspector()
        })
        handles.append(entry.observe(
            \.statusLabel,
            retention: .automatic,
            removeDuplicates: true
        ) { [weak self] _ in
            self?.scheduleReloadDataFromInspector()
        })
        handles.append(entry.observe(
            \.statusSeverity,
            retention: .automatic,
            removeDuplicates: true
        ) { [weak self] _ in
            self?.scheduleReloadDataFromInspector()
        })
        handles.append(entry.observe(
            \.method,
            retention: .automatic,
            removeDuplicates: true
        ) { [weak self] _ in
            self?.scheduleReloadDataFromInspector()
        })
        handles.append(entry.observe(
            \.phase,
            retention: .automatic,
            removeDuplicates: true
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
            assertionFailure("List registration mismatch in NetworkListPaneViewController")
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

    private func setResourceFilter(_ filter: NetworkResourceFilter, isEnabled: Bool) {
        let previousActiveFilters = inspector.activeResourceFilters
        let previousEffectiveFilters = inspector.effectiveResourceFilters
        inspector.setResourceFilter(filter, isEnabled: isEnabled)

        guard
            previousActiveFilters != inspector.activeResourceFilters
                || previousEffectiveFilters != inspector.effectiveResourceFilters
        else {
            return
        }

        syncFilterPresentation(notifyingVisibleMenu: true)
    }

    private func syncFilterPresentation(notifyingVisibleMenu: Bool) {
        filterMenuController.sync(
            activeFilters: inspector.activeResourceFilters,
            effectiveFilters: inspector.effectiveResourceFilters,
            notifyingVisibleMenu: notifyingVisibleMenu
        )
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
#endif
