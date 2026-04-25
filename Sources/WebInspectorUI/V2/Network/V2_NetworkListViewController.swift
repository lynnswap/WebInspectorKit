import Foundation
import ObservationBridge
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(UIKit)
import UIKit

@MainActor
class V2_NetworkListViewController: UICollectionViewController {
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
    private var observationHandles: Set<ObservationHandle> = []

    private var needsSnapshotReloadOnNextAppearance = false
    private lazy var dataSource = makeDataSource()

    init(inspector: WINetworkModel) {
        self.inspector = inspector
        super.init(collectionViewLayout: Self.makeListLayout())
        startObservingInspector()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        observationHandles.removeAll()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        view.accessibilityIdentifier = "V2.Network.ListPane"

        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "V2.Network.List"

        reloadDataFromInspector()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        flushPendingSnapshotUpdateIfNeeded()
    }

    private static func makeListLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.showsSeparators = true
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    private func startObservingInspector() {
        inspector.observe(\.displayEntries, options: Self.snapshotObservationOptions) { [weak self] displayEntries in
            self?.reloadDataFromInspector(displayEntries: displayEntries)
        }
        .store(in: &observationHandles)
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<SectionIdentifier, NetworkEntry> {
        let listCellRegistration = UICollectionView.CellRegistration<V2_NetworkObservingListCell, NetworkEntry> { cell, _, item in
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
            inspector.selectEntry(nil)
            return
        }
        inspector.selectEntry(entry)
    }
}

@MainActor
final class V2_NetworkObservingListCell: UICollectionViewListCell {
    private var observationHandles: Set<ObservationHandle> = []
#if DEBUG
    private(set) var fileTypeLabelTextForTesting: String?
    private(set) var statusIndicatorColorForTesting: UIColor?
#endif

    override func prepareForReuse() {
        super.prepareForReuse()
        resetObservationHandles()
        contentConfiguration = nil
        accessories = []
#if DEBUG
        fileTypeLabelTextForTesting = nil
        statusIndicatorColorForTesting = nil
#endif
    }

    func bind(item: NetworkEntry) {
        resetObservationHandles()

        store(
            item.observe(\.displayName) { [weak self] displayName in
                self?.render(displayName: displayName)
            }
        )
        store(
            item.observe([\.fileTypeLabel, \.statusSeverity]) { [weak self, weak item] in
                guard let item else {
                    return
                }
                self?.renderAccessories(item: item)
            }
        )
    }

    private func resetObservationHandles() {
        observationHandles.removeAll()
    }

    private func store(_ observationHandle: ObservationHandle) {
        observationHandle.store(in: &observationHandles)
    }

    private func render(displayName: String) {
        var content = (contentConfiguration as? UIListContentConfiguration) ?? Self.makeContentConfiguration()
        content.text = displayName
        contentConfiguration = content
    }

    private func renderAccessories(item: NetworkEntry) {
        let statusColor = networkStatusColor(for: item.statusSeverity)
        accessories = [
            .customView(configuration: Self.statusIndicatorConfiguration(color: statusColor)),
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
#if DEBUG
        fileTypeLabelTextForTesting = item.fileTypeLabel
        statusIndicatorColorForTesting = statusColor
#endif
    }

    private static func makeContentConfiguration() -> UIListContentConfiguration {
        var content = UIListContentConfiguration.cell()
        content.secondaryText = nil
        content.textProperties.numberOfLines = 2
        content.textProperties.lineBreakMode = .byTruncatingMiddle
        content.textProperties.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                weight: .semibold
            )
        )
        return content
    }

    private static func statusIndicatorConfiguration(color: UIColor) -> UICellAccessory.CustomViewConfiguration {
        let dotView = UIView(frame: CGRect(origin: .zero, size: CGSize(width: 8, height: 8)))
        dotView.backgroundColor = color
        dotView.layer.cornerRadius = 4

        return .init(
            customView: dotView,
            placement: .leading(),
            reservedLayoutWidth: .custom(8),
            maintainsFixedSize: true
        )
    }
}

#if DEBUG
extension V2_NetworkListViewController {
    var collectionViewForTesting: UICollectionView {
        collectionView
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
