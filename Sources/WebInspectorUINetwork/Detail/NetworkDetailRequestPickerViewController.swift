#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorDataKit
import WebInspectorUIBase

@MainActor
final class NetworkDetailRequestPickerViewController: UICollectionViewController,
    UISearchResultsUpdating,
    UIPopoverPresentationControllerDelegate
{
    enum ItemID: Hashable {
        case entry(NetworkListEntry.ID)
        case request(NetworkRequest.ID)
    }

    private enum Section: Hashable {
        case requests
    }

    private let model: NetworkPanelModel
    private var boundEntryID: NetworkListEntry.ID
    private var modelObservation: PortableObservationTracking.Token?
    private var isRenderingActive = false
    private var searchText = ""
    private lazy var dataSource = makeDataSource()

    init(model: NetworkPanelModel, entryID: NetworkListEntry.ID) {
        self.model = model
        boundEntryID = entryID

        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.showsSeparators = true
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        preferredContentSize = CGSize(width: 440, height: 560)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        modelObservation?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        _ = dataSource
        title = String(
            localized: "network.section.request",
            bundle: WebInspectorUILocalization.bundle
        )
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "WebInspector.Network.DetailRequestPicker"
        collectionView.allowsMultipleSelection = false

        let searchController = UISearchController(searchResultsController: nil)
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = String(
            localized: "network.search.placeholder",
            bundle: WebInspectorUILocalization.bundle
        )
        searchController.searchResultsUpdater = self
        navigationItem.searchController = searchController
        navigationItem.preferredSearchBarPlacement = .stacked
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in
                self?.dismissPicker(animated: true)
            }
        )
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        startObservingSelection()
    }

    override func viewDidDisappear(_ animated: Bool) {
        stopObservingSelection()
        super.viewDidDisappear(animated)
    }

    func updateSearchResults(for searchController: UISearchController) {
        let nextSearchText = searchController.searchBar.text ?? ""
        guard searchText != nextSearchText else {
            return
        }
        searchText = nextSearchText
        renderCurrentEntry(animatingDifferences: true)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        guard let itemID = dataSource.itemIdentifier(for: indexPath) else {
            return
        }
        switch itemID {
        case .entry(let entryID):
            guard entryID == boundEntryID,
                  model.entry(for: entryID) != nil else {
                renderCurrentEntry(animatingDifferences: false)
                return
            }
            model.selectEntry(entryID)
        case .request(let requestID):
            guard model.entryID(containing: requestID) == boundEntryID else {
                renderCurrentEntry(animatingDifferences: false)
                return
            }
            model.selectRequest(id: requestID)
        }
        dismissPicker(animated: true)
    }

    func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle {
        traitCollection.horizontalSizeClass == .compact ? .pageSheet : .none
    }

    private func startObservingSelection() {
        isRenderingActive = true
        setVisibleCellRenderingActive(true)
        modelObservation?.cancel()
        modelObservation = withPortableContinuousObservation { [weak self] event in
            guard let self else {
                return
            }
            let selection = model.selection
            let entry = model.selectedEntry
            let requests = entry?.requests ?? []
            render(
                selection: selection,
                entry: entry,
                requests: requests,
                animatingDifferences: event.kind != .initial
            )
        }
    }

    private func stopObservingSelection() {
        isRenderingActive = false
        setVisibleCellRenderingActive(false)
        modelObservation?.cancel()
        modelObservation = nil
    }

    private func renderCurrentEntry(animatingDifferences: Bool) {
        let selection = model.selection
        let entry = model.selectedEntry
        render(
            selection: selection,
            entry: entry,
            requests: entry?.requests ?? [],
            animatingDifferences: animatingDifferences
        )
    }

    private func render(
        selection: NetworkPanelSelection?,
        entry: NetworkListEntry?,
        requests: [NetworkRequest],
        animatingDifferences: Bool
    ) {
        guard let selection,
              let entry,
              requests.count > 1 else {
            dismissPicker(animated: true)
            return
        }

        guard selection.entryID == entry.id else {
            preconditionFailure("The Network request picker must render the selected entry.")
        }

        boundEntryID = entry.id
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleRequests = requests.filter { request in
            request.matchesDisplaySearchText(query)
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, ItemID>()
        snapshot.appendSections([.requests])
        snapshot.appendItems([.entry(entry.id)])
        snapshot.appendItems(visibleRequests.map { .request($0.id) })
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences) { [weak self] in
            self?.renderSelection(selection)
        }
    }

    private func renderSelection(_ selection: NetworkPanelSelection) {
        let selectedItemID: ItemID
        switch selection {
        case .entry(let entryID):
            selectedItemID = .entry(entryID)
        case .request(_, let requestID):
            selectedItemID = .request(requestID)
        }

        for indexPath in collectionView.indexPathsForSelectedItems ?? [] {
            guard dataSource.itemIdentifier(for: indexPath) != selectedItemID else {
                continue
            }
            collectionView.deselectItem(at: indexPath, animated: false)
        }
        guard let indexPath = dataSource.indexPath(for: selectedItemID) else {
            return
        }
        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Section, ItemID> {
        let registration = UICollectionView.CellRegistration<NetworkDetailRequestPickerCell, ItemID> {
            [weak self] cell, _, itemID in
            guard let self else {
                cell.unbind()
                return
            }

            switch itemID {
            case .entry(let entryID):
                guard entryID == boundEntryID else {
                    preconditionFailure("The Network request picker received an entry from another binding.")
                }
                cell.bindAllRequests(renderingActive: isRenderingActive)
            case .request(let requestID):
                guard model.entryID(containing: requestID) == boundEntryID,
                      let request = model.request(for: requestID) else {
                    cell.unbind()
                    return
                }
                cell.bind(request: request, renderingActive: isRenderingActive)
            }
        }

        return UICollectionViewDiffableDataSource<Section, ItemID>(
            collectionView: collectionView
        ) { collectionView, indexPath, itemID in
            collectionView.dequeueConfiguredReusableCell(
                using: registration,
                for: indexPath,
                item: itemID
            )
        }
    }

    private func setVisibleCellRenderingActive(_ isActive: Bool) {
        for case let cell as NetworkDetailRequestPickerCell in collectionView.visibleCells {
            cell.setRenderingActive(isActive)
        }
    }

    private func dismissPicker(animated: Bool) {
        stopObservingSelection()
        navigationController?.dismiss(animated: animated)
    }
}

#if DEBUG
extension NetworkDetailRequestPickerViewController {
    var itemIDsForTesting: [ItemID] {
        dataSource.snapshot().itemIdentifiers
    }

    var selectedItemIDForTesting: ItemID? {
        guard let indexPath = collectionView.indexPathsForSelectedItems?.first else {
            return nil
        }
        return dataSource.itemIdentifier(for: indexPath)
    }

    var isObservingModelForTesting: Bool {
        modelObservation?.isActive == true
    }

    var modelObservationDeliveryForTesting: PortableObservationTracking.Token? {
        modelObservation
    }

    var boundEntryIDForTesting: NetworkListEntry.ID {
        boundEntryID
    }

    func resumeRenderingForTesting() {
        loadViewIfNeeded()
        startObservingSelection()
    }

    func suspendRenderingForTesting() {
        stopObservingSelection()
    }

    func setSearchTextForTesting(_ text: String) {
        searchText = text
        renderCurrentEntry(animatingDifferences: false)
    }
}
#endif
#endif
