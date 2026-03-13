import Foundation
import ObservationBridge
import WebInspectorCore
import WebInspectorResources
import WebInspectorCore

#if canImport(UIKit)
import UIKit
import WebInspectorResources

@MainActor
public final class WINetworkListViewController: UICollectionViewController {
    private enum SectionIdentifier: Hashable {
        case main
    }

    private let store: WINetworkStore
    private let queryModel: WINetworkQueryState
    private var observationHandles: Set<ObservationHandle> = []

    private var needsSnapshotReloadOnNextAppearance = false
    package private(set) var snapshotApplyRevisionForTesting: UInt64 = 0
    package var onSnapshotAppliedForTesting: (@MainActor (UInt64) -> Void)?
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

    public init(store: WINetworkStore) {
        self.store = store
        self.queryModel = WINetworkQueryState(store: store)
        super.init(collectionViewLayout: Self.makeListLayout())
        startObservingQueryState()
    }

    init(store: WINetworkStore, queryModel: WINetworkQueryState) {
        self.store = store
        self.queryModel = queryModel
        super.init(collectionViewLayout: Self.makeListLayout())
        startObservingQueryState()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        view.accessibilityIdentifier = "WI.Network.ListPane"

        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "WI.Network.List"

        queryModel.syncSearchControllerText()
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

    private func startObservingQueryState() {
        queryModel.observe(\.displayEntries, options: WIObservationOptions.networkListSnapshot) { [weak self] displayEntries in
            self?.reloadDataFromInspector(displayEntries: displayEntries)
        }
        .store(in: &observationHandles)
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<SectionIdentifier, NetworkEntry> {
        let listCellRegistration = UICollectionView.CellRegistration<WINetworkObservingListCell, NetworkEntry> { [weak self] cell, _, item in
            self?.configureListCell(cell, item: item)
        }
        let dataSource = UICollectionViewDiffableDataSource<SectionIdentifier, NetworkEntry>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(
                using: listCellRegistration,
                for: indexPath,
                item: item
            )
        }
        return dataSource
    }
    private func makeSnapshot(
        displayEntries: [NetworkEntry]
    ) -> NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkEntry> {
        let identifiers = displayEntries
        precondition(
            identifiers.count == Set(identifiers.map(\.id)).count,
            "Duplicate row IDs detected in WINetworkListViewController"
        )

        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, NetworkEntry>()
        snapshot.appendSections([.main])
        snapshot.appendItems(identifiers, toSection: .main)
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
            self.recordSnapshotApplyForTesting()
        }
    }

    private func flushPendingSnapshotUpdateIfNeeded() {
        guard needsSnapshotReloadOnNextAppearance, isCollectionViewVisible else {
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        Task {
            let snapshot = self.makeSnapshot(displayEntries: self.queryModel.displayEntries)
            await self.dataSource.applySnapshotUsingReloadData(snapshot)
            self.recordSnapshotApplyForTesting()
        }
    }

    private func reloadDataFromInspector(displayEntries: [NetworkEntry]? = nil) {
        let resolvedDisplayEntries = displayEntries ?? queryModel.displayEntries
        queryModel.syncSearchControllerText()
        requestSnapshotUpdate(displayEntries: resolvedDisplayEntries)
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

    private func recordSnapshotApplyForTesting() {
        snapshotApplyRevisionForTesting &+= 1
        if snapshotApplyRevisionForTesting == 0 {
            snapshotApplyRevisionForTesting = 1
        }
        onSnapshotAppliedForTesting?(snapshotApplyRevisionForTesting)
    }

    private func configureListCell(_ cell: WINetworkObservingListCell, item: NetworkEntry) {
        cell.resetObservationHandles()

        var content = UIListContentConfiguration.cell()
        content.text = item.displayName
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
            .customView(configuration: statusIndicatorConfiguration(for: item)),
            .label(
                text: item.fileTypeLabel,
                options: .init(
                    reservedLayoutWidth: .actual,
                    tintColor: .secondaryLabel,
                    font: .preferredFont(forTextStyle: .footnote),
                    adjustsFontForContentSizeCategory: true
                )
            ),
            .disclosureIndicator()
        ]

        item.observe(\.displayName) { [weak cell] newValue in
            guard var content = cell?.contentConfiguration as? UIListContentConfiguration else { return }
            content.text = newValue
            cell?.contentConfiguration = content
        }
        .store(in: &cell.observationHandles)

        item.observe([\.fileTypeLabel, \.statusSeverity]) { [weak cell, weak item] in
            guard let cell, let item else { return }
            cell.accessories = [
                .customView(configuration: statusIndicatorConfiguration(for: item)),
                .label(
                    text: item.fileTypeLabel,
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
        .store(in: &cell.observationHandles)
    }

    private func makeSecondaryMenu() -> UIMenu {
        let hasEntries = !store.store.entries.isEmpty
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
        store.clear()
    }

    public override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let entry = dataSource.itemIdentifier(for: indexPath) else {
            store.selectEntry(nil)
            return
        }
        store.selectEntry(entry)
    }
}

@MainActor
private final class WINetworkObservingListCell: UICollectionViewListCell {
    fileprivate var observationHandles: Set<ObservationHandle> = []

    override func prepareForReuse() {
        super.prepareForReuse()
        observationHandles.removeAll()
    }

    func resetObservationHandles() {
        observationHandles.removeAll()
    }
}

@MainActor
private func statusIndicatorConfiguration(for item: NetworkEntry) -> UICellAccessory.CustomViewConfiguration {
    let dotView = UIView(frame: CGRect(origin: .zero, size: CGSize(width: 8, height: 8)))
    dotView.backgroundColor = networkStatusColor(for: item.statusSeverity)
    dotView.layer.cornerRadius = 4

    return .init(
        customView: dotView,
        placement: .leading(),
        reservedLayoutWidth: .custom(8),
        maintainsFixedSize: true
    )
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("Network List (UIKit)") {
    WIUIKitPreviewContainer {
        UINavigationController(
            rootViewController: WINetworkListViewController(
                store: WINetworkPreviewFixtures.makeStore(mode: .root)
            )
        )
    }
}
#endif
#endif
