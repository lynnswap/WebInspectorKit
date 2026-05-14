#if canImport(UIKit)
import ObservationBridge
import SyntaxEditorUI
import UIKit
import V2_WebInspectorCore

@MainActor
package final class V2_NetworkDetailViewController: UIViewController, UICollectionViewDelegate {
    private struct HeaderField: Hashable {
        var name: String
        var value: String
    }

    private enum SectionIdentifier: Int, CaseIterable, Hashable {
        case overview
        case request
        case response

        var title: String {
            switch self {
            case .overview:
                v2WILocalized("network.detail.section.overview", default: "Overview")
            case .request:
                v2WILocalized("network.section.request", default: "Request")
            case .response:
                v2WILocalized("network.section.response", default: "Response")
            }
        }
    }

    private enum ItemIdentifier: Hashable {
        case overview
        case requestHeader(HeaderField)
        case requestHeadersEmpty
        case responseHeader(HeaderField)
        case responseHeadersEmpty
    }

    private let model: V2_NetworkPanelModel
    private let observationScope = ObservationScope()
    private let selectedRequestObservationScope = ObservationScope()
    private let bodyViewController = V2_NetworkBodyViewController()
    private lazy var modeMenu = V2_NetworkDetailModeMenu(
        detailViewController: self,
        model: model
    )
    private lazy var collectionView: UICollectionView = {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeListLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.accessibilityIdentifier = "WebInspector.Network.Detail"
        collectionView.delegate = self
        collectionView.isHidden = true
        return collectionView
    }()
    private lazy var dataSource = makeDataSource()
    fileprivate var mode: V2_NetworkDetailMode = .overview {
        didSet {
            guard mode != oldValue else {
                return
            }
            renderCurrentMode(reloadData: mode == .overview)
            modeMenu.render()
        }
    }

    private var selectedRequest: NetworkRequest? {
        model.selectedRequest
    }

    package init(model: V2_NetworkPanelModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)

        model.observe(\.selectedRequest) { [weak self] selectedRequest in
            self?.display(selectedRequest, reloadData: true)
        }
        .store(in: observationScope)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationScope.cancelAll()
        selectedRequestObservationScope.cancelAll()
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureNavigationItem()
        installCollectionView()
        installBodyViewController()
        display(model.selectedRequest, reloadData: true)
    }

    package func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }

    private func configureNavigationItem() {
        navigationItem.trailingItemGroups = [
            UIBarButtonItemGroup(
                barButtonItems: [modeMenu.makeCompactItem()],
                representativeItem: nil
            ),
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
        let overviewCellRegistration = UICollectionView.CellRegistration<V2_NetworkOverviewCell, NetworkRequest> {
            cell, _, request in
            cell.bind(request: request)
        }
        let fieldCellRegistration = UICollectionView.CellRegistration<V2_NetworkFieldCell, ItemIdentifier> {
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
            if case .overview = item, let selectedRequest = self.selectedRequest {
                return collectionView.dequeueConfiguredReusableCell(
                    using: overviewCellRegistration,
                    for: indexPath,
                    item: selectedRequest
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

    private func display(_ request: NetworkRequest?, reloadData: Bool) {
        title = request?.displayName

        guard isViewLoaded else {
            return
        }
        guard let request else {
            selectedRequestObservationScope.update {}
            collectionView.isHidden = true
            bodyViewController.view.isHidden = true
            bodyViewController.display(body: nil)
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = v2WILocalized("network.empty.selection.title", default: "No request selected")
            configuration.secondaryText = v2WILocalized(
                "network.empty.selection.description",
                default: "Select a request from the list to inspect details."
            )
            configuration.image = UIImage(systemName: "list.bullet.rectangle")
            contentUnavailableConfiguration = configuration
            applySnapshotUsingReloadData()
            return
        }

        contentUnavailableConfiguration = nil
        startObserving(request)
        renderCurrentMode(reloadData: reloadData)
    }

    private func startObserving(_ request: NetworkRequest) {
        selectedRequestObservationScope.update {
            request.observe([\.request, \.response, \.requestBody, \.responseBody]) { [weak self, weak request] in
                guard let self, let request, self.selectedRequest?.id == request.id else {
                    return
                }
                self.title = request.displayName
                self.renderCurrentMode(reloadData: false)
                self.modeMenu.render()
            }
            .store(in: selectedRequestObservationScope)
        }
    }

    private func renderCurrentMode(reloadData: Bool) {
        guard isViewLoaded else {
            return
        }
        guard let selectedRequest else {
            return
        }
        guard resetUnavailableModeIfNeeded(for: selectedRequest) == false else {
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
            if role == .response {
                model.fetchResponseBodyIfNeeded(for: selectedRequest)
            }
            bodyViewController.display(body: body(in: selectedRequest, for: role))
        }
    }

    private func resetUnavailableModeIfNeeded(for request: NetworkRequest) -> Bool {
        guard let role = mode.bodyRole else {
            return false
        }
        guard body(in: request, for: role) == nil else {
            return false
        }
        mode = .overview
        return true
    }

    package func makeRegularModeItem() -> UIBarButtonItem {
        modeMenu.makeRegularItem()
    }

    private func body(in request: NetworkRequest, for role: NetworkBodyRole) -> NetworkBody? {
        switch role {
        case .request:
            request.requestBody
        case .response:
            request.responseBody
        }
    }

    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier> {
        guard let selectedRequest else {
            return NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>()
        }

        let requestHeaders = headerFields(from: selectedRequest.request.headers)
        let responseHeaders = headerFields(from: selectedRequest.response?.headers ?? [:])
        let requestItems: [ItemIdentifier] = requestHeaders.isEmpty
            ? [.requestHeadersEmpty]
            : requestHeaders.map { .requestHeader($0) }
        let responseItems: [ItemIdentifier] = responseHeaders.isEmpty
            ? [.responseHeadersEmpty]
            : responseHeaders.map { .responseHeader($0) }

        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>()
        snapshot.appendSections(SectionIdentifier.allCases)
        snapshot.appendItems([.overview], toSection: .overview)
        snapshot.appendItems(requestItems, toSection: .request)
        snapshot.appendItems(responseItems, toSection: .response)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        return snapshot
    }

    private func headerFields(from headers: [String: String]) -> [HeaderField] {
        headers
            .map { HeaderField(name: $0.key, value: $0.value) }
            .sorted {
                let nameComparison = $0.name.localizedCaseInsensitiveCompare($1.name)
                if nameComparison == .orderedSame {
                    return $0.value < $1.value
                }
                return nameComparison == .orderedAscending
            }
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

    private func configure(_ cell: V2_NetworkFieldCell, item: ItemIdentifier) {
        switch item {
        case .overview:
            cell.clear()
        case .requestHeader(let field), .responseHeader(let field):
            cell.bindHeader(name: field.name, value: field.value)
        case .requestHeadersEmpty, .responseHeadersEmpty:
            cell.bindEmptyHeaders()
        }
    }
}

@MainActor
private final class V2_NetworkDetailModeMenu {
    private weak var detailViewController: V2_NetworkDetailViewController?
    private let model: V2_NetworkPanelModel
    private let observationScope = ObservationScope()
    private let selectedRequestObservationScope = ObservationScope()
    private var compactItem: UIBarButtonItem?
    private var regularItem: UIBarButtonItem?

    init(detailViewController: V2_NetworkDetailViewController, model: V2_NetworkPanelModel) {
        self.detailViewController = detailViewController
        self.model = model

        model.observe(\.selectedRequest) { [weak self] request in
            self?.observeBodyAvailability(in: request)
            self?.render()
        }
        .store(in: observationScope)
    }

    isolated deinit {
        observationScope.cancelAll()
        selectedRequestObservationScope.cancelAll()
    }

    private func observeBodyAvailability(in request: NetworkRequest?) {
        selectedRequestObservationScope.update {
            guard let request else {
                return
            }
            request.observe([\.requestBody, \.responseBody]) { [weak self, weak request] in
                guard let self, let request, self.model.selectedRequest?.id == request.id else {
                    return
                }
                self.render()
            }
            .store(in: selectedRequestObservationScope)
        }
    }

    fileprivate func render() {
        let mode = detailViewController?.mode ?? .overview
        let selectedRequest = model.selectedRequest
        let isEnabled = selectedRequest != nil

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
        item.accessibilityIdentifier = "WebInspector.Network.DetailModeButton"
        item.preferredMenuElementOrder = .fixed
        return item
    }

    private func makeRegularBarButtonItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(customView: makeRegularModeButton())
        item.accessibilityIdentifier = "WebInspector.Network.DetailModeButton.Regular"
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
        button.accessibilityIdentifier = "WebInspector.Network.DetailModeButton.Regular.Button"
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    private func makeMenu(includesImages: Bool) -> UIMenu {
        UIMenu(
            title: "",
            options: .singleSelection,
            children: V2_NetworkDetailMode.allCases.map { mode in
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

    private func isModeEnabled(_ mode: V2_NetworkDetailMode) -> Bool {
        guard let selectedRequest = model.selectedRequest else {
            return mode == .overview
        }
        switch mode {
        case .overview:
            return true
        case .requestBody:
            return selectedRequest.requestBody != nil
        case .responseBody:
            return selectedRequest.responseBody != nil
        }
    }
}

#if DEBUG
extension V2_NetworkDetailViewController {
    package var collectionViewForTesting: UICollectionView {
        collectionView
    }

    package var currentModeForTesting: V2_NetworkDetailMode {
        mode
    }

    package var modeMenuForTesting: UIMenu {
        modeMenu.makeMenuForTesting()
    }

    package var bodyTextViewForTesting: SyntaxEditorView {
        bodyViewController.syntaxViewForTesting
    }

    package func setModeForTesting(_ mode: V2_NetworkDetailMode) {
        self.mode = mode
    }
}
#endif

#if DEBUG && canImport(SwiftUI)
import SwiftUI

#Preview("V2 Network Detail") {
    UINavigationController(
        rootViewController: V2_NetworkDetailViewController(
            model: V2_NetworkPreviewFixtures.makePanelModel(mode: .detail)
        )
    )
}
#endif
#endif
