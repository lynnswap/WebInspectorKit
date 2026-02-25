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
    private let inspector: WINetworkTabViewModel
    private var observationTask: Task<Void, Never>?

    private let listViewController: NetworkListViewController
    private let detailViewController: NetworkDetailViewController

    init(inspector: WINetworkTabViewModel) {
        self.inspector = inspector
        self.listViewController = NetworkListViewController(inspector: inspector)
        self.detailViewController = NetworkDetailViewController(inspector: inspector)
        super.init(style: .doubleColumn)
        delegate = self
        preferredDisplayMode = .oneBesideSecondary
        title = nil
        inspector.selectedEntry = nil

        listViewController.onSelectEntry = { [weak self] entry in
            guard let self else { return }
            self.inspector.selectedEntry = entry
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

    isolated deinit {
        observationTask?.cancel()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        syncSelectionBehaviorForLayout()
        startObservingInspectorIfNeeded()
        syncDetailSelection()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncSelectionBehaviorForLayout()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopObservingInspector()
    }

    private func syncDetailSelection() {
        let entry: NetworkEntry?
        if let selectedEntry = inspector.selectedEntry,
           inspector.displayEntries.contains(where: { $0.id == selectedEntry.id }) {
            entry = selectedEntry
        } else {
            inspector.selectedEntry = nil
            entry = nil
        }
        detailViewController.display(entry, hasEntries: !inspector.store.entries.isEmpty)
        listViewController.selectEntry(with: inspector.selectedEntry?.id)
        ensurePrimaryColumnIfNeeded()
    }

    private func syncSelectionBehaviorForLayout() {
        listViewController.setMissingSelectionBehavior(
            isCollapsed ? .none : .firstEntry
        )
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
        guard isCollapsed, inspector.selectedEntry == nil else {
            return
        }
        show(.primary)
    }

    func splitViewController(
        _ splitViewController: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        if inspector.selectedEntry == nil {
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

    private let inspector: WINetworkTabViewModel
    private var observationTask: Task<Void, Never>?

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

        navigationItem.rightBarButtonItems = [filterMenuController.item]
        syncFilterPresentation(notifyingVisibleMenu: false)

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

    func setMissingSelectionBehavior(_ behavior: NetworkListSelectionPolicy.MissingSelectionBehavior) {
        guard missingSelectionBehavior != behavior else {
            return
        }
        missingSelectionBehavior = behavior
        reconcileSelectionIfNeeded()
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
        reconcileSelectionIfNeeded()
        entryByID = Dictionary(uniqueKeysWithValues: displayedEntries.map { ($0.id, $0) })

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

    private func setResourceFilter(_ filter: NetworkResourceFilter, isEnabled: Bool) {
        let previousActiveFilters = inspector.activeResourceFilters
        let previousEffectiveFilters = inspector.effectiveResourceFilters
        inspector.setResourceFilter(filter, isEnabled: isEnabled)

        // Ignore no-op taps (e.g. tapping already-selected item in the same state).
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

func networkStatusColor(for severity: NetworkStatusSeverity) -> UIColor {
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

func networkBodyTypeLabel(entry: NetworkEntry, body: NetworkBody) -> String? {
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

func networkBodySize(entry: NetworkEntry, body: NetworkBody) -> Int? {
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

func networkBodyPreviewText(_ body: NetworkBody) -> String? {
    if body.kind == .binary {
        return body.displayText
    }
    return decodedBodyText(from: body) ?? body.displayText
}

func decodedBodyText(from body: NetworkBody) -> String? {
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
    private let inspector: WINetworkTabViewModel
    private var observationTask: Task<Void, Never>?
    private var listHostingController: NSHostingController<NetworkMacListTab>?
    private var detailViewController: NetworkMacDetailViewController?

    init(inspector: WINetworkTabViewModel) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        inspector.selectedEntry = nil

        let listHost = NSHostingController(rootView: NetworkMacListTab(inspector: inspector))
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
            current: inspector.selectedEntry,
            entries: inspector.displayEntries
        )
        if inspector.selectedEntry?.id != resolvedSelection?.id {
            inspector.selectedEntry = resolvedSelection
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
    private let inspector: WINetworkTabViewModel
    private var hostingController: NSHostingController<NetworkMacDetailTab>?
    private var fetchTask: Task<Void, Never>?

    init(inspector: WINetworkTabViewModel) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        fetchTask?.cancel()
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let hostingController = NSHostingController(rootView: NetworkMacDetailTab(inspector: inspector))
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
        inspector.selectedEntry
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
            guard inspector.selectedEntry?.id == entryID else {
                return
            }
            _ = inspector.selectedEntry
        }
    }
}

@MainActor
private struct NetworkMacListTab: View {
    @Bindable var inspector: WINetworkTabViewModel

    var body: some View {
        Group {
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
                guard let selected = inspector.selectedEntry?.id else {
                    return []
                }
                return [selected]
            },
            set: { newSelection in
                let nextSelectedEntry = newSelection.first.flatMap { nextSelectedID in
                    inspector.displayEntries.first(where: { $0.id == nextSelectedID })
                }
                let resolved = NetworkListSelectionPolicy.resolvedSelection(
                    current: nextSelectedEntry,
                    entries: inspector.displayEntries
                )
                inspector.selectedEntry = resolved
            }
        )
    }
}

@MainActor
private struct NetworkMacDetailTab: View {
    @Bindable var inspector: WINetworkTabViewModel

    private var entry: NetworkEntry? {
        inspector.selectedEntry
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
