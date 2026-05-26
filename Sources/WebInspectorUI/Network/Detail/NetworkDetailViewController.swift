#if canImport(UIKit)
import ObservationBridge
import SyntaxEditorUI
import UIKit
import WebInspectorCore

@MainActor
package final class NetworkDetailViewController: UIViewController, UICollectionViewDelegate {
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
                webInspectorLocalized("network.detail.section.overview", default: "Overview")
            case .request:
                webInspectorLocalized("network.section.request", default: "Request")
            case .response:
                webInspectorLocalized("network.section.response", default: "Response")
            }
        }
    }

    private enum ItemIdentifier: Hashable {
        case overview(NetworkRequest.ID)
        case requestHeader(HeaderField)
        case requestHeadersEmpty
        case responseHeader(HeaderField)
        case responseHeadersEmpty
    }

    private let model: NetworkPanelModel
    private let observationScope = ObservationScope()
    private let bodyViewController = NetworkBodyViewController()
    private lazy var modeMenu = NetworkDetailModeMenu(
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
    fileprivate var mode: NetworkDetailMode = .overview {
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

    package init(model: NetworkPanelModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationScope.cancelAll()
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureNavigationItem()
        installCollectionView()
        installBodyViewController()
        startObservingModel()
    }

    package func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }

    private func startObservingModel() {
        observationScope.observe(model) { [weak self] event, model in
            self?.render(selectedRequest: model.selectedRequest, reloadData: event.kind == .initial)
        }
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
        let overviewCellRegistration = UICollectionView.CellRegistration<NetworkOverviewCell, NetworkRequest> {
            cell, _, request in
            cell.bind(request: request)
        }
        let fieldCellRegistration = UICollectionView.CellRegistration<NetworkFieldCell, ItemIdentifier> {
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

    private func render(selectedRequest request: NetworkRequest?, reloadData: Bool) {
        title = request?.displayName

        guard isViewLoaded else {
            return
        }
        guard let request else {
            showEmptySelection()
            return
        }

        if contentUnavailableConfiguration != nil {
            contentUnavailableConfiguration = nil
        }
        renderCurrentMode(reloadData: reloadData)
        modeMenu.render(selectedRequest: request)
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
            showOverview()
            if reloadData {
                applySnapshotUsingReloadData()
            } else {
                applySnapshot()
            }
        case .requestBody, .responseBody:
            guard let role = mode.bodyRole else {
                return
            }
            showBody()
            if role == .response {
                model.fetchResponseBodyIfNeeded(for: selectedRequest)
            }
            bodyViewController.display(body: body(in: selectedRequest, for: role))
        }
    }

    private func showEmptySelection() {
        if collectionView.isHidden == false {
            collectionView.isHidden = true
        }
        if bodyViewController.view.isHidden == false {
            bodyViewController.view.isHidden = true
        }
        bodyViewController.display(body: nil)
        if let configuration = contentUnavailableConfiguration as? UIContentUnavailableConfiguration,
           configuration.text == webInspectorLocalized("network.empty.selection.title", default: "No request selected") {
            applyEmptySnapshotUsingReloadData()
            return
        }
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.text = webInspectorLocalized("network.empty.selection.title", default: "No request selected")
        configuration.secondaryText = webInspectorLocalized(
            "network.empty.selection.description",
            default: "Select a request from the list to inspect details."
        )
        configuration.image = UIImage(systemName: "list.bullet.rectangle")
        contentUnavailableConfiguration = configuration
        applyEmptySnapshotUsingReloadData()
    }

    private func showOverview() {
        if bodyViewController.view.isHidden == false {
            bodyViewController.view.isHidden = true
        }
        if collectionView.isHidden {
            collectionView.isHidden = false
        }
        bodyViewController.display(body: nil)
    }

    private func showBody() {
        if collectionView.isHidden == false {
            collectionView.isHidden = true
        }
        if bodyViewController.view.isHidden {
            bodyViewController.view.isHidden = false
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
        snapshot.appendItems([.overview(selectedRequest.id)], toSection: .overview)
        snapshot.appendItems(requestItems, toSection: .request)
        snapshot.appendItems(responseItems, toSection: .response)
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
        let snapshot = makeSnapshot()
        let currentSnapshot = dataSource.snapshot()
        guard currentSnapshot.sectionIdentifiers != snapshot.sectionIdentifiers
            || currentSnapshot.itemIdentifiers != snapshot.itemIdentifiers else {
            return
        }
        Task {
            await self.dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    private func applySnapshotUsingReloadData() {
        guard isViewLoaded else {
            return
        }
        let snapshot = makeSnapshot()
        Task {
            await self.dataSource.applySnapshotUsingReloadData(snapshot)
        }
    }

    private func applyEmptySnapshotUsingReloadData() {
        guard isViewLoaded else {
            return
        }
        let snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>()
        let currentSnapshot = dataSource.snapshot()
        guard currentSnapshot.numberOfItems != 0 || currentSnapshot.numberOfSections != 0 else {
            return
        }
        Task {
            await self.dataSource.applySnapshotUsingReloadData(snapshot)
        }
    }

    private func configure(_ cell: NetworkFieldCell, item: ItemIdentifier) {
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
private final class NetworkDetailModeMenu {
    private struct ModeAvailability {
        var hasSelectedRequest: Bool
        var hasRequestBody: Bool
        var hasResponseBody: Bool
    }

    private weak var detailViewController: NetworkDetailViewController?
    private let model: NetworkPanelModel
    private var compactItem: UIBarButtonItem?
    private var regularItem: UIBarButtonItem?

    init(detailViewController: NetworkDetailViewController, model: NetworkPanelModel) {
        self.detailViewController = detailViewController
        self.model = model
    }

    fileprivate func render(selectedRequest: NetworkRequest? = nil) {
        let mode = detailViewController?.mode ?? .overview
        let availability = modeAvailability(for: selectedRequest ?? model.selectedRequest)
        let isEnabled = availability.hasSelectedRequest

        if let compactItem {
            compactItem.image = UIImage(systemName: mode.systemImageName)
            compactItem.title = nil
            compactItem.isEnabled = isEnabled
            compactItem.menu = makeMenu(includesImages: true, availability: availability)
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
                button.menu = makeMenu(includesImages: false, availability: availability)
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
        makeMenu(
            includesImages: true,
            availability: modeAvailability(for: model.selectedRequest)
        )
    }

    private func makeCompactBarButtonItem() -> UIBarButtonItem {
        let availability = modeAvailability(for: model.selectedRequest)
        let item = UIBarButtonItem(
            image: UIImage(systemName: (detailViewController?.mode ?? .overview).systemImageName),
            menu: makeMenu(includesImages: true, availability: availability)
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
        button.menu = makeMenu(
            includesImages: false,
            availability: modeAvailability(for: model.selectedRequest)
        )
        button.accessibilityIdentifier = "WebInspector.Network.DetailModeButton.Regular.Button"
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    private func makeMenu(
        includesImages: Bool,
        availability: ModeAvailability
    ) -> UIMenu {
        UIMenu(
            title: "",
            options: .singleSelection,
            children: NetworkDetailMode.allCases.map { mode in
                UIAction(
                    title: mode.title,
                    image: includesImages ? UIImage(systemName: mode.systemImageName) : nil,
                    attributes: isModeEnabled(mode, availability: availability) ? [] : [.disabled],
                    state: detailViewController?.mode == mode ? .on : .off
                ) { [weak detailViewController] _ in
                    detailViewController?.mode = mode
                }
            }
        )
    }

    private func modeAvailability(for selectedRequest: NetworkRequest?) -> ModeAvailability {
        ModeAvailability(
            hasSelectedRequest: selectedRequest != nil,
            hasRequestBody: selectedRequest?.requestBody != nil,
            hasResponseBody: selectedRequest?.responseBody != nil
        )
    }

    private func isModeEnabled(
        _ mode: NetworkDetailMode,
        availability: ModeAvailability
    ) -> Bool {
        guard availability.hasSelectedRequest else {
            return mode == .overview
        }
        switch mode {
        case .overview:
            return true
        case .requestBody:
            return availability.hasRequestBody
        case .responseBody:
            return availability.hasResponseBody
        }
    }
}

#if DEBUG
extension NetworkDetailViewController {
    package var collectionViewForTesting: UICollectionView {
        collectionView
    }

    package var currentModeForTesting: NetworkDetailMode {
        mode
    }

    package var modeMenuForTesting: UIMenu {
        modeMenu.makeMenuForTesting()
    }

    package var bodyTextViewForTesting: SyntaxEditorView {
        bodyViewController.syntaxViewForTesting
    }

    package func setModeForTesting(_ mode: NetworkDetailMode) {
        self.mode = mode
    }
}
#endif

#Preview("Network Detail") {
    UINavigationController(
        rootViewController: NetworkDetailViewController(
            model: NetworkPreviewFixtures.makePanelModel(mode: .detail)
        )
    )
}
#endif
