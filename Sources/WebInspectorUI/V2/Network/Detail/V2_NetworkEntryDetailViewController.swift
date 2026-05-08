#if canImport(UIKit)
import ObservationBridge
import SyntaxEditorUI
import UIKit
import WebInspectorEngine
import WebInspectorRuntime

@MainActor
final class V2_NetworkEntryDetailViewController: UIViewController, UICollectionViewDelegate {
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
    private let observationScope = ObservationScope()
    private let selectedEntryObservationScope = ObservationScope()
    private let bodyViewController = V2_NetworkBodyViewController()
    private lazy var modeMenu = V2_NetworkEntryDetailModeMenu(
        detailViewController: self,
        inspector: inspector
    )
    private lazy var collectionView: UICollectionView = {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeListLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.accessibilityIdentifier = "V2.Network.Detail"
        collectionView.delegate = self
        collectionView.isHidden = true
        return collectionView
    }()
    private lazy var dataSource = makeDataSource()
    fileprivate var mode: V2_NetworkEntryDetailMode = .overview {
        didSet {
            guard mode != oldValue else {
                return
            }
            renderCurrentMode(reloadData: mode == .overview)
            modeMenu.render()
        }
    }

    private var selectedEntry: NetworkEntry? {
        inspector.selectedEntry
    }

    init(inspector: WINetworkModel) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)

        inspector.observe(\.selectedEntry) { [weak self] selectedEntry in
            self?.display(selectedEntry, reloadData: true)
        }
        .store(in: observationScope)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationScope.cancelAll()
        selectedEntryObservationScope.cancelAll()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureNavigationItem()
        installCollectionView()
        installBodyViewController()
        display(inspector.selectedEntry, reloadData: true)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }

    private func configureNavigationItem() {
        navigationItem.trailingItemGroups = [
            UIBarButtonItemGroup(
                barButtonItems: [modeMenu.makeCompactItem()],
                representativeItem: nil
            )
        ]
    }

    private func installCollectionView() {
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func installBodyViewController() {
        addChild(bodyViewController)
        bodyViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bodyViewController.view)
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            bodyViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            bodyViewController.view.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            bodyViewController.view.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            bodyViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        bodyViewController.didMove(toParent: self)
        bodyViewController.view.isHidden = true
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
        ) { [weak self] collectionView, indexPath, item in
            guard let self else {
                return nil
            }
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
        title = entry?.displayName

        guard isViewLoaded else {
            return
        }
        guard let entry else {
            selectedEntryObservationScope.update {}
            collectionView.isHidden = true
            bodyViewController.view.isHidden = true
            bodyViewController.display(body: nil)
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

        contentUnavailableConfiguration = nil
        startObserving(entry)
        renderCurrentMode(reloadData: reloadData)
    }

    private func startObserving(_ entry: NetworkEntry) {
        selectedEntryObservationScope.update {
            entry.observe([\.requestHeaders, \.responseHeaders, \.requestBody, \.responseBody]) { [weak self, weak entry] in
                guard let self, let entry, self.selectedEntry?.id == entry.id else {
                    return
                }
                self.renderCurrentMode(reloadData: false)
            }
            .store(in: selectedEntryObservationScope)

            entry.observe(\.url) { [weak self, weak entry] _ in
                guard let self, let entry, self.selectedEntry?.id == entry.id else {
                    return
                }
                self.title = entry.displayName
            }
            .store(in: selectedEntryObservationScope)
        }
    }

    private func renderCurrentMode(reloadData: Bool) {
        guard isViewLoaded else {
            return
        }
        guard let selectedEntry else {
            return
        }

        switch mode {
        case .overview:
            bodyViewController.display(body: nil)
            bodyViewController.view.isHidden = true
            collectionView.isHidden = false
            if reloadData {
                applySnapshotUsingReloadData()
            } else {
                applySnapshot()
            }
        case .requestBody, .responseBody:
            collectionView.isHidden = true
            bodyViewController.view.isHidden = false
            guard let role = mode.bodyRole else {
                return
            }
            bodyViewController.display(body: body(in: selectedEntry, for: role))
        }
    }

    func makeRegularModeItem() -> UIBarButtonItem {
        modeMenu.makeRegularItem()
    }

    private func body(in entry: NetworkEntry, for role: NetworkBody.Role) -> NetworkBody? {
        switch role {
        case .request:
            entry.requestBody
        case .response:
            entry.responseBody
        }
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

@MainActor
private final class V2_NetworkEntryDetailModeMenu {
    private weak var detailViewController: V2_NetworkEntryDetailViewController?
    private let inspector: WINetworkModel
    private let observationScope = ObservationScope()
    private let selectedEntryObservationScope = ObservationScope()
    private var compactItem: UIBarButtonItem?
    private var regularItem: UIBarButtonItem?

    init(detailViewController: V2_NetworkEntryDetailViewController, inspector: WINetworkModel) {
        self.detailViewController = detailViewController
        self.inspector = inspector

        inspector.observe(\.selectedEntry) { [weak self] entry in
            self?.observeBodyAvailability(in: entry)
            self?.render()
        }
        .store(in: observationScope)
    }

    isolated deinit {
        observationScope.cancelAll()
        selectedEntryObservationScope.cancelAll()
    }

    private func observeBodyAvailability(in entry: NetworkEntry?) {
        selectedEntryObservationScope.update {
            guard let entry else {
                return
            }
            entry.observe([\.requestBody, \.responseBody]) { [weak self, weak entry] in
                guard let self, let entry, self.inspector.selectedEntry?.id == entry.id else {
                    return
                }
                self.render()
            }
            .store(in: selectedEntryObservationScope)
        }
    }

    fileprivate func render() {
        let mode = detailViewController?.mode ?? .overview
        let selectedEntry = inspector.selectedEntry
        let isEnabled = selectedEntry != nil

        if let compactItem {
            compactItem.image = UIImage(systemName: mode.systemImageName)
            compactItem.title = nil
            compactItem.isEnabled = isEnabled
            compactItem.menu = makeMenu(includesImages: true)
            compactItem.accessibilityLabel = mode.title
            compactItem.preferredMenuElementOrder = .fixed
        }

        if let regularItem {
            regularItem.isEnabled = isEnabled
            regularItem.accessibilityLabel = mode.title
            regularItem.preferredMenuElementOrder = .fixed

            if let button = regularItem.customView as? UIButton {
                var configuration = button.configuration ?? .bordered()
                configuration.title = mode.title
                button.configuration = configuration
                button.menu = makeMenu(includesImages: false)
                button.isEnabled = isEnabled
                button.accessibilityLabel = mode.title
                button.preferredMenuElementOrder = .fixed
            }
        }
    }

    func makeCompactItem() -> UIBarButtonItem {
        if let compactItem {
            return compactItem
        }

        let compactItem = makeCompactBarButtonItem()
        self.compactItem = compactItem
        render()
        return compactItem
    }

    func makeRegularItem() -> UIBarButtonItem {
        if let regularItem {
            return regularItem
        }

        let regularItem = makeRegularBarButtonItem()
        self.regularItem = regularItem
        render()
        return regularItem
    }

    func makeMenuForTesting() -> UIMenu {
        makeMenu(includesImages: true)
    }

    private func makeCompactBarButtonItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: (detailViewController?.mode ?? .overview).systemImageName),
            menu: makeMenu(includesImages: true)
        )
        item.accessibilityIdentifier = "V2.Network.DetailModeButton"
        item.preferredMenuElementOrder = .fixed
        return item
    }

    private func makeRegularBarButtonItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(customView: makeRegularModeButton())
        item.accessibilityIdentifier = "V2.Network.DetailModeButton.Regular"
        item.preferredMenuElementOrder = .fixed
        return item
    }

    private func makeRegularModeButton() -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.bordered()
        configuration.title = (detailViewController?.mode ?? .overview).title
        button.configuration = configuration
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
        button.menu = makeMenu(includesImages: false)
        button.accessibilityIdentifier = "V2.Network.DetailModeButton.Regular.Button"
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    private func makeMenu(includesImages: Bool) -> UIMenu {
        UIMenu(
            title: "",
            options: .singleSelection,
            children: V2_NetworkEntryDetailMode.allCases.map { mode in
                UIAction(
                    title: mode.title,
                    image: includesImages ? UIImage(systemName: mode.systemImageName) : nil,
                    attributes: isModeEnabled(mode) ? [] : [.disabled],
                    state: detailViewController?.mode == mode ? .on : .off
                ) { [weak detailViewController] _ in
                    detailViewController?.mode = mode
                }
            }
        )
    }

    private func isModeEnabled(_ mode: V2_NetworkEntryDetailMode) -> Bool {
        guard let selectedEntry = inspector.selectedEntry else {
            return mode == .overview
        }
        switch mode {
        case .overview:
            return true
        case .requestBody:
            return selectedEntry.requestBody != nil
        case .responseBody:
            return selectedEntry.responseBody != nil
        }
    }
}

#if DEBUG
extension V2_NetworkEntryDetailViewController {
    var collectionViewForTesting: UICollectionView {
        collectionView
    }

    var currentModeForTesting: V2_NetworkEntryDetailMode {
        mode
    }

    var modeMenuForTesting: UIMenu {
        modeMenu.makeMenuForTesting()
    }

    var bodyTextViewForTesting: SyntaxEditorView {
        bodyViewController.syntaxViewForTesting
    }

    func setModeForTesting(_ mode: V2_NetworkEntryDetailMode) {
        self.mode = mode
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
