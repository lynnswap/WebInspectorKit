#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorEngine
import WebInspectorRuntime

@MainActor
final class V2_NetworkEntryDetailViewController: UICollectionViewController {
    private enum SectionIdentifier: Int, CaseIterable, Hashable {
        case overview
        case request
        case response

        var title: String {
            switch self {
            case .overview:
                wiLocalized("network.detail.section.overview", default: "Overview")
            case .request:
                wiLocalized("network.section.request", default: "Request")
            case .response:
                wiLocalized("network.section.response", default: "Response")
            }
        }
    }

    private enum ItemIdentifier: Hashable {
        case overview
        case requestHeader(index: Int)
        case requestHeadersEmpty
        case responseHeader(index: Int)
        case responseHeadersEmpty
    }

    private let inspector: WINetworkModel
    private var observationHandles: Set<ObservationHandle> = []
    private var selectedEntryObservationHandles: Set<ObservationHandle> = []
    private lazy var dataSource = makeDataSource()

    private var selectedEntry: NetworkEntry? {
        inspector.selectedEntry
    }

    init(inspector: WINetworkModel) {
        self.inspector = inspector
        super.init(collectionViewLayout: Self.makeListLayout())

        inspector.observe(\.selectedEntry) { [weak self] selectedEntry in
            self?.display(selectedEntry, reloadData: true)
        }
        .store(in: &observationHandles)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationHandles.removeAll()
        selectedEntryObservationHandles.removeAll()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.accessibilityIdentifier = "V2.Network.Detail"
        display(inspector.selectedEntry, reloadData: true)
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }

    private static func makeListLayout() -> UICollectionViewLayout {
        var listConfiguration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        listConfiguration.showsSeparators = true
        listConfiguration.headerMode = .supplementary

        return UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(
                using: listConfiguration,
                layoutEnvironment: environment
            )
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
        let overviewCellRegistration = UICollectionView.CellRegistration<V2_NetworkEntryOverviewCell, NetworkEntry> {
            cell, _, entry in
            cell.bind(entry: entry)
        }
        let fieldCellRegistration = UICollectionView.CellRegistration<V2_NetworkEntryFieldCell, ItemIdentifier> {
            [weak self] cell, _, item in
            self?.configure(cell, item: item)
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
            if case .overview = item, let selectedEntry = self.selectedEntry {
                return collectionView.dequeueConfiguredReusableCell(
                    using: overviewCellRegistration,
                    for: indexPath,
                    item: selectedEntry
                )
            }
            return collectionView.dequeueConfiguredReusableCell(
                using: fieldCellRegistration,
                for: indexPath,
                item: item
            )
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration,
                for: indexPath
            )
        }
        return dataSource
    }

    private func display(_ entry: NetworkEntry?, reloadData: Bool) {
        selectedEntryObservationHandles.removeAll()
        title = entry?.displayName

        guard isViewLoaded else {
            return
        }

        guard let entry else {
            collectionView.isHidden = true
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = wiLocalized("network.empty.selection.title", default: "No request selected")
            configuration.secondaryText = wiLocalized(
                "network.empty.selection.description",
                default: "Select a request from the list to inspect details."
            )
            configuration.image = UIImage(systemName: "list.bullet.rectangle")
            contentUnavailableConfiguration = configuration
            applySnapshotUsingReloadData()
            return
        }

        collectionView.isHidden = false
        contentUnavailableConfiguration = nil
        if reloadData {
            applySnapshotUsingReloadData()
        } else {
            applySnapshot()
        }
        startObserving(entry)
    }

    private func startObserving(_ entry: NetworkEntry) {
        entry.observe([\.requestHeaders, \.responseHeaders]) { [weak self, weak entry] in
            guard let self, let entry, self.selectedEntry?.id == entry.id else {
                return
            }
            self.applySnapshot()
        }
        .store(in: &selectedEntryObservationHandles)

        entry.observe(\.url) { [weak self, weak entry] _ in
            guard let self, let entry, self.selectedEntry?.id == entry.id else {
                return
            }
            self.title = entry.displayName
        }
        .store(in: &selectedEntryObservationHandles)
    }

    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier> {
        guard let selectedEntry else {
            return NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>()
        }

        let requestItems: [ItemIdentifier] = selectedEntry.requestHeaders.fields.isEmpty
            ? [.requestHeadersEmpty]
            : selectedEntry.requestHeaders.fields.indices.map { .requestHeader(index: $0) }
        let responseItems: [ItemIdentifier] = selectedEntry.responseHeaders.fields.isEmpty
            ? [.responseHeadersEmpty]
            : selectedEntry.responseHeaders.fields.indices.map { .responseHeader(index: $0) }

        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>()
        snapshot.appendSections(SectionIdentifier.allCases)
        snapshot.appendItems([.overview], toSection: .overview)
        snapshot.appendItems(requestItems, toSection: .request)
        snapshot.appendItems(responseItems, toSection: .response)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        return snapshot
    }

    private func applySnapshot() {
        guard isViewLoaded else {
            return
        }
        Task {
            let snapshot = self.makeSnapshot()
            await self.dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    private func applySnapshotUsingReloadData() {
        guard isViewLoaded else {
            return
        }
        Task {
            let snapshot = self.makeSnapshot()
            await self.dataSource.applySnapshotUsingReloadData(snapshot)
        }
    }

    private func configure(_ cell: V2_NetworkEntryFieldCell, item: ItemIdentifier) {
        guard let selectedEntry else {
            cell.clear()
            return
        }

        switch item {
        case .overview:
            cell.clear()
        case let .requestHeader(index):
            guard selectedEntry.requestHeaders.fields.indices.contains(index) else {
                cell.clear()
                return
            }
            let field = selectedEntry.requestHeaders.fields[index]
            cell.bindHeader(name: field.name, value: field.value)
        case let .responseHeader(index):
            guard selectedEntry.responseHeaders.fields.indices.contains(index) else {
                cell.clear()
                return
            }
            let field = selectedEntry.responseHeaders.fields[index]
            cell.bindHeader(name: field.name, value: field.value)
        case .requestHeadersEmpty, .responseHeadersEmpty:
            cell.bindEmptyHeaders()
        }
    }
}

#if DEBUG
extension V2_NetworkEntryDetailViewController {
    var collectionViewForTesting: UICollectionView {
        collectionView
    }
}
#endif

#if DEBUG && canImport(SwiftUI)
import SwiftUI

#Preview("V2 Network Detail") {
    WIUIKitPreviewContainer {
        let inspector = WINetworkPreviewFixtures.makeInspector(mode: .detail)
        return UINavigationController(
            rootViewController: V2_NetworkEntryDetailViewController(inspector: inspector)
        )
    }
}
#endif
#endif
