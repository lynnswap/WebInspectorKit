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
    private struct RenderedProjection {
        let subject: NetworkDetailSubject
        let visibleRequestsByID: [NetworkRequest.ID: NetworkRequest]
    }

    enum ItemID: Hashable {
        case entry(NetworkListEntry.ID)
        case request(NetworkRequest.ID)
    }

    private enum Section: Hashable {
        case requests
    }

    private let model: NetworkPanelModel
    private let boundEntryID: NetworkListEntry.ID
    private var renderedProjection: RenderedProjection?
    private var modelObservation: PortableObservationTracking.Token?
    private var isRenderingActive = false
    private var searchText = ""
    private lazy var dataSource = makeDataSource()

    init(model: NetworkPanelModel, subject: NetworkDetailSubject) {
        self.model = model
        boundEntryID = subject.entry.id
        renderedProjection = RenderedProjection(
            subject: subject,
            visibleRequestsByID: Dictionary(
                uniqueKeysWithValues: subject.entryRequests.map { ($0.id, $0) }
            )
        )

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
        setSearchText(nextSearchText)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        guard let itemID = dataSource.itemIdentifier(for: indexPath) else {
            return
        }
        guard let renderedProjection,
              model.detailSubject?.hasSameIdentity(as: renderedProjection.subject) == true else {
            renderCurrentEntry(animatingDifferences: false)
            return
        }
        let subject = renderedProjection.subject
        let resolvedSubject: NetworkDetailSubject?
        switch itemID {
        case .entry(let entryID):
            guard entryID == boundEntryID,
                  subject.entry.id == entryID else {
                renderCurrentEntry(animatingDifferences: false)
                return
            }
            resolvedSubject = model.selectEntry(
                subject.entry,
                ifSubjectUnchanged: subject
            )
        case .request(let requestID):
            guard let cell = collectionView.cellForItem(at: indexPath)
                    as? NetworkDetailRequestPickerCell,
                  let request = cell.boundRequest,
                  request.id == requestID else {
                renderCurrentEntry(animatingDifferences: false)
                return
            }
            resolvedSubject = model.selectRequest(
                request,
                ifSubjectUnchanged: subject
            )
        }
        guard resolvedSubject != nil else {
            renderCurrentEntry(animatingDifferences: false)
            return
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
        let token = withPortableContinuousObservation { [weak self] event in
            guard let self else {
                return
            }
            let subject = model.detailSubject
            _ = subject?.entryRequests
            render(
                subject: subject,
                animatingDifferences: event.kind != .initial
            )
        }
        guard isRenderingActive else {
            token.cancel()
            modelObservation = nil
            return
        }
        modelObservation = token
    }

    private func stopObservingSelection() {
        isRenderingActive = false
        setVisibleCellRenderingActive(false)
        modelObservation?.cancel()
        modelObservation = nil
    }

    private func setSearchText(_ text: String) {
        guard searchText != text else {
            return
        }
        searchText = text
        guard isRenderingActive else {
            return
        }
        startObservingSelection()
    }

    private func renderCurrentEntry(animatingDifferences: Bool) {
        render(
            subject: model.detailSubject,
            animatingDifferences: animatingDifferences
        )
    }

    private func render(
        subject: NetworkDetailSubject?,
        animatingDifferences: Bool
    ) {
        guard let subject,
              subject.entryRequests.count > 1 else {
            dismissPicker(animated: true)
            return
        }

        guard subject.entry.id == boundEntryID else {
            dismissPicker(animated: true)
            return
        }
        if let previousSubject = renderedProjection?.subject,
           previousSubject.entry !== subject.entry,
           previousSubject.intentID != subject.intentID {
            dismissPicker(animated: true)
            return
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleRequests = subject.entryRequests.filter { request in
            request.matchesDisplaySearchText(query)
        }
        renderedProjection = RenderedProjection(
            subject: subject,
            visibleRequestsByID: Dictionary(
                uniqueKeysWithValues: visibleRequests.map { ($0.id, $0) }
            )
        )

        var snapshot = NSDiffableDataSourceSnapshot<Section, ItemID>()
        snapshot.appendSections([.requests])
        snapshot.appendItems([.entry(boundEntryID)])
        snapshot.appendItems(visibleRequests.map { .request($0.id) })
        let preservesVisibleItemIdentity = dataSource.snapshot().itemIdentifiers
            == snapshot.itemIdentifiers
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences) { [weak self] in
            guard let self else {
                return
            }
            guard renderedProjection?.subject.hasSameIdentity(as: subject) == true else {
                return
            }
            rebindVisibleRequestCells()
            renderSelection(subject.selection)
        }
        if preservesVisibleItemIdentity {
            rebindVisibleRequestCells()
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
            bind(cell, to: itemID)
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

    private func rebindVisibleRequestCells() {
        for case let cell as NetworkDetailRequestPickerCell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell),
                  let itemID = dataSource.itemIdentifier(for: indexPath) else {
                cell.unbind()
                continue
            }
            bind(cell, to: itemID)
        }
    }

    private func bind(_ cell: NetworkDetailRequestPickerCell, to itemID: ItemID) {
        switch itemID {
        case .entry(let entryID):
            guard entryID == boundEntryID else {
                cell.unbind()
                return
            }
            cell.bindAllRequests(renderingActive: isRenderingActive)
        case .request(let requestID):
            guard let request = renderedProjection?.visibleRequestsByID[requestID] else {
                cell.unbind()
                return
            }
            cell.bind(request: request, renderingActive: isRenderingActive)
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

    var renderedEntryForTesting: NetworkListEntry? {
        renderedProjection?.subject.entry
    }

    var renderedIntentIDForTesting: NetworkPanelSelectionIntent.ID? {
        renderedProjection?.subject.intentID
    }

    func requestCellForTesting(
        requestID: NetworkRequest.ID
    ) -> NetworkDetailRequestPickerCell? {
        collectionView.layoutIfNeeded()
        guard let indexPath = dataSource.indexPath(for: .request(requestID)) else {
            return nil
        }
        return collectionView.cellForItem(at: indexPath) as? NetworkDetailRequestPickerCell
    }

    func resumeRenderingForTesting() {
        loadViewIfNeeded()
        startObservingSelection()
    }

    func suspendRenderingForTesting() {
        stopObservingSelection()
    }

    func setSearchTextForTesting(_ text: String) {
        setSearchText(text)
    }
}
#endif
#endif
