#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import ObservationBridge
import UIHostingMenu
import UIKit

@MainActor
package final class NetworkListViewController: UICollectionViewController, UISearchResultsUpdating {
    package typealias EntrySelectionAction = @MainActor (NetworkListEntry.ID?) -> Void

    private struct PendingListProjection {
        var latestRevision: UInt64

        mutating func merge(_ transaction: NetworkPanelListTransaction) {
            precondition(
                transaction.revision > latestRevision,
                "Network list transactions must be delivered in revision order."
            )
            latestRevision = transaction.revision
        }
    }

    @MainActor
    private final class ListSnapshotBuildCoordinator {
        typealias Request = NetworkListSnapshotBuildInput
        typealias Completion = @MainActor (NetworkListSnapshotArtifact) -> Void

        private struct Work {
            var request: Request
            var completion: Completion
        }

        private struct ActiveBuild {
            var generation: UInt64
            var task: Task<Void, Never>
            var work: Work
            var pendingWork: Work?
        }

        private enum State {
            case idle
            case building(ActiveBuild)
        }

        private let builderFactory: any NetworkListSnapshotBuilderMaking
        private var state = State.idle
        private var nextGeneration: UInt64 = 0
        private var idleWaiters: [CheckedContinuation<Void, Never>] = []

        init(builderFactory: any NetworkListSnapshotBuilderMaking) {
            self.builderFactory = builderFactory
        }

        var hasWorkInFlight: Bool {
            if case .building = state {
                return true
            }
            return false
        }

        func submit(
            _ request: Request,
            completion: @escaping Completion
        ) {
            let work = Work(request: request, completion: completion)
            switch state {
            case .idle:
                start(work)
            case .building(var activeBuild):
                if activeBuild.pendingWork == nil,
                   activeBuild.work.request == request {
                    return
                }
                if activeBuild.pendingWork?.request == request {
                    return
                }
                activeBuild.pendingWork = work
                state = .building(activeBuild)
            }
        }

        @discardableResult
        func cancel() -> Bool {
            guard case .building(let activeBuild) = state else {
                return false
            }
            state = .idle
            activeBuild.task.cancel()
            resumeIdleWaiters()
            return true
        }

        func waitUntilIdle() async {
            guard case .building = state else {
                return
            }
            await withCheckedContinuation { continuation in
                idleWaiters.append(continuation)
            }
        }

        private func start(_ work: Work) {
            guard case .idle = state else {
                preconditionFailure("A Network list snapshot build must be serialized.")
            }
            let generation = takeNextGeneration()
            let builder = builderFactory.makeBuilder()
            let request = work.request
            let task = Task(priority: .userInitiated) { @MainActor [weak self] in
                do {
                    let artifact = try await builder.build(request)
                    self?.buildDidFinish(
                        generation: generation,
                        artifact: artifact
                    )
                } catch {
                    self?.buildDidCancel(generation: generation)
                }
            }
            state = .building(
                ActiveBuild(
                    generation: generation,
                    task: task,
                    work: work,
                    pendingWork: nil
                )
            )
        }

        private func buildDidFinish(
            generation: UInt64,
            artifact: NetworkListSnapshotArtifact
        ) {
            guard case .building(let activeBuild) = state,
                  activeBuild.generation == generation else {
                return
            }
            precondition(
                artifact.input == activeBuild.work.request,
                "A Network list snapshot builder must return the requested input."
            )
            state = .idle
            if activeBuild.pendingWork == nil {
                activeBuild.work.completion(artifact)
            }
            if let pendingWork = activeBuild.pendingWork {
                start(pendingWork)
            } else {
                resumeIdleWaiters()
            }
        }

        private func buildDidCancel(generation: UInt64) {
            guard case .building(let activeBuild) = state,
                  activeBuild.generation == generation else {
                return
            }
            state = .idle
            if let pendingWork = activeBuild.pendingWork {
                start(pendingWork)
            } else {
                resumeIdleWaiters()
            }
        }

        private func takeNextGeneration() -> UInt64 {
            precondition(
                nextGeneration < UInt64.max,
                "Network list snapshot build generation overflowed."
            )
            nextGeneration += 1
            return nextGeneration
        }

        private func resumeIdleWaiters() {
            let waiters = idleWaiters
            idleWaiters.removeAll(keepingCapacity: true)
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private struct SnapshotCoordinator {
        var isRenderingActive = false
        var needsReloadOnNextAppearance = true
        var readyArtifact: NetworkListSnapshotArtifact?
        var state = NetworkListViewController.SnapshotState()

        mutating func resumeRendering() {
            isRenderingActive = true
        }

        mutating func suspendRendering() {
            isRenderingActive = false
            if readyArtifact != nil {
                needsReloadOnNextAppearance = true
            }
            readyArtifact = nil
        }

        mutating func markNeedsReloadOnNextAppearance() {
            needsReloadOnNextAppearance = true
        }

        var needsReloadForActiveRendering: Bool {
            isRenderingActive && needsReloadOnNextAppearance
        }
    }

    private let model: NetworkPanelModel
    private var entrySelectionAction: EntrySelectionAction
    private var listTransactionTask: Task<Void, Never>?
    private var searchTextObservation: PortableObservationTracking.Token?
    private var resourceFilterObservation: PortableObservationTracking.Token?
    private var selectedEntryObservation: PortableObservationTracking.Token?

    private var snapshotCoordinator = SnapshotCoordinator()
    private var pendingListProjection: PendingListProjection?
    private let listFrameScheduler: any NetworkListFrameScheduling
    private let listSnapshotBuildCoordinator: ListSnapshotBuildCoordinator
    private let snapshotApplyCompletionScheduler: any NetworkListSnapshotApplyCompletionScheduling
    private var latestListTransactionRevision: UInt64 = 0
    private var isApplyingSearchPresentation = false
    private var activeSearchController: UISearchController?
#if DEBUG
    private struct FetchedResultsTransactionDeliveryWaiter {
        var id: Int
        var targetCount: Int
        var continuation: CheckedContinuation<Bool, Never>
        var timeoutTask: Task<Void, Never>
    }

    private var deinitHandlerForTesting: (@MainActor () -> Void)?
    private var snapshotUpdateCompletionWaitersForTesting: [CheckedContinuation<Void, Never>] = []
    private var fetchedResultsTransactionDeliveryWaitersForTesting: [FetchedResultsTransactionDeliveryWaiter] = []
    private var fetchedResultsTransactionDeliveryWaiterIDStorageForTesting = 0
    private var fetchedResultsTransactionDeliveryCountStorageForTesting = 0
    private var displayRequestIDsEvaluationCountStorageForTesting = 0
    private var snapshotApplyCountStorageForTesting = 0
    private var listProjectionFlushCountStorageForTesting = 0
    private var filterMenuBuildCountStorageForTesting = 0
#endif
    private lazy var filterHostingMenu = UIHostingMenu(
        rootView: NetworkListFilterMenuView(model: model)
    )
    private lazy var overflowHostingMenu = UIHostingMenu(
        rootView: NetworkListOverflowMenuView(model: model)
    )
    private lazy var filterItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease"),
            menu: UIMenu(children: [makeFilterMenuElement()])
        )
        item.accessibilityIdentifier = "WebInspector.Network.FilterButton"
        item.isSelected = model.effectiveResourceFilters.isEmpty == false
        return item
    }()
    private lazy var dataSource = makeDataSource()

    package convenience init(model: NetworkPanelModel) {
        self.init(
            model: model,
            listFrameScheduler: NetworkListDisplayLinkFrameScheduler(),
            listSnapshotBuilderFactory: NetworkListSnapshotBuilderFactory(),
            snapshotApplyCompletionScheduler: NetworkListImmediateSnapshotApplyCompletionScheduler()
        )
    }

    package convenience init(
        model: NetworkPanelModel,
        listFrameScheduler: any NetworkListFrameScheduling,
        listSnapshotBuilderFactory: any NetworkListSnapshotBuilderMaking,
        snapshotApplyCompletionScheduler: any NetworkListSnapshotApplyCompletionScheduling =
            NetworkListImmediateSnapshotApplyCompletionScheduler()
    ) {
        self.init(
            model: model,
            frameScheduler: listFrameScheduler,
            snapshotBuilderFactory: listSnapshotBuilderFactory,
            snapshotApplyCompletionScheduler: snapshotApplyCompletionScheduler
        )
    }

    private init(
        model: NetworkPanelModel,
        frameScheduler: any NetworkListFrameScheduling,
        snapshotBuilderFactory: any NetworkListSnapshotBuilderMaking,
        snapshotApplyCompletionScheduler: any NetworkListSnapshotApplyCompletionScheduling
    ) {
        self.model = model
        listFrameScheduler = frameScheduler
        listSnapshotBuildCoordinator = ListSnapshotBuildCoordinator(
            builderFactory: snapshotBuilderFactory
        )
        self.snapshotApplyCompletionScheduler = snapshotApplyCompletionScheduler
        entrySelectionAction = { [model] entryID in
            model.selectEntry(entryID)
        }
        super.init(collectionViewLayout: Self.makeListLayout())
        startObservingModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        listFrameScheduler.invalidate()
        listSnapshotBuildCoordinator.cancel()
        listTransactionTask?.cancel()
        searchTextObservation?.cancel()
        resourceFilterObservation?.cancel()
        selectedEntryObservation?.cancel()
        detachSearchPresentation()
#if DEBUG
        resolveFetchedResultsTransactionDeliveryWaitersForTesting(result: false)
        deinitHandlerForTesting?()
#endif
    }

    package func setEntrySelectionAction(_ action: @escaping EntrySelectionAction) {
        entrySelectionAction = action
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        view.accessibilityIdentifier = "WebInspector.Network.ListPane"
        applyBackgroundFromTraits()
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { viewController in
                viewController.applyBackgroundFromTraits()
            }
        }

        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "WebInspector.Network.List"
        applyBackgroundFromTraits()

        configureNavigationItem()
    }

    override package func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureNavigationItem()
        navigationController?.setNavigationBarHidden(false, animated: animated)
        resumeRendering()
    }

    override package func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        suspendRendering()
    }

    override package func willMove(toParent parent: UIViewController?) {
        if parent == nil {
            detachSearchPresentation()
        }
        super.willMove(toParent: parent)
    }

    private static func makeListLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.showsSeparators = true

            let section = NSCollectionLayoutSection.list(
                using: configuration,
                layoutEnvironment: environment
            )
            var contentInsets = section.contentInsets
            contentInsets.top = 0
            section.contentInsets = contentInsets
            return section
        }
    }

    private func startObservingModel() {
        startObservingListTransactions()

        searchTextObservation?.cancel()
        searchTextObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }
            let searchText = model.searchText
            guard snapshotCoordinator.isRenderingActive else { return }
            renderSearchText(searchText)
        }

        resourceFilterObservation?.cancel()
        resourceFilterObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }
            let effectiveResourceFilters = model.effectiveResourceFilters
            guard snapshotCoordinator.isRenderingActive else { return }
            resourceFilterSelectionDidChange(effectiveResourceFilters: effectiveResourceFilters)
        }

        selectedEntryObservation?.cancel()
        selectedEntryObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }
            let selectedEntryID = model.selectedEntryID
            guard snapshotCoordinator.isRenderingActive else { return }
            renderSelectedEntryID(selectedEntryID)
        }
    }

    private func startObservingListTransactions() {
        listTransactionTask?.cancel()
        let transactions = model.listTransactions
        listTransactionTask = Task { @MainActor [weak self] in
            for await transaction in transactions {
                self?.listTransactionDidPublish(transaction)
            }
        }
    }

    private func resumeRendering() {
        snapshotCoordinator.resumeRendering()
        setVisibleCellRenderingActive(true)
        renderSearchText(model.searchText)
        resourceFilterSelectionDidChange(effectiveResourceFilters: model.effectiveResourceFilters)
        renderSelectedEntryID(model.selectedEntryID)
        renderInitialEmptyStateIfNeeded()
        if snapshotCoordinator.needsReloadForActiveRendering {
            reloadDataFromModel()
        }
    }

    private func suspendRendering() {
        guard snapshotCoordinator.isRenderingActive else {
            return
        }
        listFrameScheduler.cancel()
        let discardedSnapshotBuild = listSnapshotBuildCoordinator.cancel()
        if pendingListProjection != nil || discardedSnapshotBuild {
            snapshotCoordinator.markNeedsReloadOnNextAppearance()
            pendingListProjection = nil
        }
        snapshotCoordinator.suspendRendering()
        setVisibleCellRenderingActive(false)
    }

    private func configureNavigationItem() {
        navigationItem.style = .browser
        if activeSearchController == nil || navigationItem.searchController !== activeSearchController {
            attachSearchPresentation()
        }
        navigationItem.preferredSearchBarPlacement = .stacked
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.trailingItemGroups = [
            UIBarButtonItemGroup(
                barButtonItems: [filterItem],
                representativeItem: nil
            ),
        ]
        navigationItem.additionalOverflowItems = makeOverflowMenuElement()

        renderSearchText(model.searchText)
        resourceFilterSelectionDidChange(effectiveResourceFilters: model.effectiveResourceFilters)
    }

    private func applyBackgroundFromTraits() {
        webInspectorConfigureScrollEdgeObservedScrollView(
            collectionView,
            backgroundColor: webInspectorBackgroundPolicy.backgroundColor,
            traitCollection: traitCollection
        )
    }

    package func updateSearchResults(for searchController: UISearchController) {
        guard
            isApplyingSearchPresentation == false,
            searchController === activeSearchController
        else {
            return
        }
        let searchText = searchController.searchBar.text ?? ""
        guard searchText != model.searchText else {
            return
        }
        model.setSearchText(searchText)
    }

    private func attachSearchPresentation() {
        let searchController = makeSearchController()
        isApplyingSearchPresentation = true
        defer {
            isApplyingSearchPresentation = false
        }

        activeSearchController?.searchResultsUpdater = nil
        activeSearchController = searchController
        navigationItem.searchController = searchController
    }

    private func detachSearchPresentation() {
        guard activeSearchController != nil || navigationItem.searchController != nil else {
            return
        }

        isApplyingSearchPresentation = true
        defer {
            isApplyingSearchPresentation = false
        }

        activeSearchController?.searchResultsUpdater = nil
        activeSearchController = nil
        navigationItem.searchController = nil
    }

    private func makeSearchController() -> UISearchController {
        let searchController = UISearchController(searchResultsController: nil)
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = String(localized: "network.search.placeholder", bundle: WebInspectorUILocalization.bundle)
        searchController.searchBar.text = model.searchText
        searchController.searchResultsUpdater = self
        return searchController
    }

    private func renderSearchText(_ text: String) {
        guard
            isViewLoaded,
            let activeSearchController,
            activeSearchController.searchBar.text != text
        else {
            return
        }
        isApplyingSearchPresentation = true
        defer {
            isApplyingSearchPresentation = false
        }
        activeSearchController.searchBar.text = text
    }

    private func renderFilterItem(effectiveResourceFilters: Set<NetworkDisplay.ResourceFilter>) {
        guard isViewLoaded else {
            return
        }
        filterItem.isSelected = effectiveResourceFilters.isEmpty == false
    }

    private func resourceFilterSelectionDidChange(effectiveResourceFilters: Set<NetworkDisplay.ResourceFilter>) {
        renderFilterItem(effectiveResourceFilters: effectiveResourceFilters)
    }

    private func makeFilterMenuElement() -> UIDeferredMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            completion((self?.makeFilterMenu() ?? UIMenu()).children)
        }
    }

    private func makeFilterMenu() -> UIMenu {
#if DEBUG
        filterMenuBuildCountStorageForTesting += 1
#endif
        return (try? filterHostingMenu.menu()) ?? UIMenu()
    }

    private func makeOverflowMenuElement() -> UIDeferredMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            completion((self?.makeOverflowMenu() ?? UIMenu()).children)
        }
    }

    private func makeOverflowMenu() -> UIMenu {
        (try? overflowHostingMenu.menu()) ?? UIMenu()
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<NetworkListSnapshotSection, NetworkListEntry.ID> {
        let listCellRegistration = UICollectionView.CellRegistration<NetworkListCell, NetworkListEntry.ID> { [weak self] cell, _, id in
            guard let entry = self?.model.entry(for: id) else {
                cell.unbind()
                return
            }
            cell.bind(entry: entry, renderingActive: self?.snapshotCoordinator.isRenderingActive == true)
        }
        return UICollectionViewDiffableDataSource<NetworkListSnapshotSection, NetworkListEntry.ID>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(
                using: listCellRegistration,
                for: indexPath,
                item: item
            )
        }
    }

    private var isCollectionViewVisible: Bool {
        snapshotCoordinator.isRenderingActive && isViewLoaded
    }

    private func storeReadySnapshotArtifact(_ artifact: NetworkListSnapshotArtifact) {
        guard isCollectionViewVisible else {
            snapshotCoordinator.markNeedsReloadOnNextAppearance()
            return
        }
        snapshotCoordinator.needsReloadOnNextAppearance = false
        if let applyingRows = snapshotCoordinator.state.applyingRows {
            if applyingRows.entryIDs == artifact.input.entryIDs {
                snapshotCoordinator.readyArtifact = nil
                return
            }
        } else if snapshotCoordinator.state.appliedRows.entryIDs == artifact.input.entryIDs {
            snapshotCoordinator.readyArtifact = nil
            return
        }
        snapshotCoordinator.readyArtifact = artifact
        scheduleListRenderingFrameIfNeeded()
    }

    private func applyReadySnapshotArtifactOnDisplayFrameIfNeeded() {
        guard snapshotCoordinator.isRenderingActive else {
            if snapshotCoordinator.readyArtifact != nil {
                snapshotCoordinator.readyArtifact = nil
                snapshotCoordinator.markNeedsReloadOnNextAppearance()
            }
            return
        }
        guard !snapshotCoordinator.state.isApplying,
              let artifact = snapshotCoordinator.readyArtifact else {
            return
        }
        guard artifact.input.revision == latestListTransactionRevision else {
            snapshotCoordinator.readyArtifact = nil
            return
        }
        let rows = NetworkListViewController.SnapshotRows(entryIDs: artifact.input.entryIDs)
        guard rows != snapshotCoordinator.state.appliedRows else {
            snapshotCoordinator.readyArtifact = nil
            return
        }
        snapshotCoordinator.readyArtifact = nil
        snapshotCoordinator.state.beginApplying(rows)

        let completion: @MainActor @Sendable () -> Void = { [weak self] in
            self?.snapshotUpdateDidFinish(appliedRows: rows)
        }
#if DEBUG
        snapshotApplyCountStorageForTesting += 1
#endif
        let snapshotApplyCompletionScheduler = self.snapshotApplyCompletionScheduler
        dataSource.apply(artifact.snapshot, animatingDifferences: false) {
            snapshotApplyCompletionScheduler.schedule(completion)
        }
    }

    private func snapshotUpdateDidFinish(
        appliedRows: NetworkListViewController.SnapshotRows
    ) {
#if DEBUG
        defer {
            resumeSnapshotUpdateCompletionWaitersForTesting()
        }
#endif
        snapshotCoordinator.state.finishApplying(appliedRows)
        guard snapshotCoordinator.isRenderingActive else {
            if snapshotCoordinator.readyArtifact != nil {
                snapshotCoordinator.readyArtifact = nil
                snapshotCoordinator.markNeedsReloadOnNextAppearance()
            }
            return
        }
        renderSelectedEntryID(model.selectedEntryID)
        scheduleListRenderingFrameIfNeeded()
    }

    private func listTransactionDidPublish(_ transaction: NetworkPanelListTransaction) {
#if DEBUG
        recordFetchedResultsTransactionDeliveryForTesting()
#endif
        precondition(
            transaction.revision > latestListTransactionRevision,
            "Network list transactions must be delivered in revision order."
        )
        latestListTransactionRevision = transaction.revision
        guard snapshotCoordinator.isRenderingActive else {
            snapshotCoordinator.markNeedsReloadOnNextAppearance()
            return
        }
        if var pendingListProjection {
            pendingListProjection.merge(transaction)
            self.pendingListProjection = pendingListProjection
        } else {
            pendingListProjection = PendingListProjection(
                latestRevision: transaction.revision
            )
        }
        scheduleListRenderingFrameIfNeeded()
    }

    private func scheduleListRenderingFrameIfNeeded() {
        guard snapshotCoordinator.isRenderingActive,
              pendingListProjection != nil || snapshotCoordinator.readyArtifact != nil else {
            return
        }
        listFrameScheduler.schedule { [weak self] in
            self?.listRenderingDisplayFrameDidFire()
        }
    }

    private func listRenderingDisplayFrameDidFire() {
        guard snapshotCoordinator.isRenderingActive else {
            if pendingListProjection != nil || snapshotCoordinator.readyArtifact != nil {
                pendingListProjection = nil
                snapshotCoordinator.readyArtifact = nil
                snapshotCoordinator.markNeedsReloadOnNextAppearance()
            }
            return
        }
        capturePendingListProjectionIfNeeded()
        applyReadySnapshotArtifactOnDisplayFrameIfNeeded()
    }

    private func capturePendingListProjectionIfNeeded() {
        guard snapshotCoordinator.isRenderingActive else {
            if pendingListProjection != nil {
                pendingListProjection = nil
                snapshotCoordinator.markNeedsReloadOnNextAppearance()
            }
            return
        }
        guard let projection = pendingListProjection else {
            return
        }
        pendingListProjection = nil
#if DEBUG
        listProjectionFlushCountStorageForTesting += 1
#endif
        applyListProjection(projection, entryIDs: model.displayEntryIDs)
    }

    private func applyListProjection(
        _ projection: PendingListProjection,
        entryIDs: [NetworkListEntry.ID]
    ) {
        renderEmptyState(isEmpty: entryIDs.isEmpty)
        requestListSnapshotBuild(entryIDs: entryIDs, revision: projection.latestRevision)
    }

    private func requestListSnapshotBuild(
        entryIDs: [NetworkListEntry.ID],
        revision: UInt64
    ) {
        let request = ListSnapshotBuildCoordinator.Request(
            entryIDs: entryIDs,
            revision: revision
        )
        listSnapshotBuildCoordinator.submit(request) { [weak self] artifact in
            self?.listSnapshotDidBuild(artifact)
        }
    }

    private func listSnapshotDidBuild(_ artifact: NetworkListSnapshotArtifact) {
        guard snapshotCoordinator.isRenderingActive else {
            snapshotCoordinator.markNeedsReloadOnNextAppearance()
            return
        }
        storeReadySnapshotArtifact(artifact)
    }

    private func reloadDataFromModel() {
        guard snapshotCoordinator.isRenderingActive else {
            snapshotCoordinator.markNeedsReloadOnNextAppearance()
            return
        }
        let entryIDs = displayEntryIDsFromModel()
        renderEmptyState(isEmpty: entryIDs.isEmpty)
        requestListSnapshotBuild(
            entryIDs: entryIDs,
            revision: latestListTransactionRevision
        )
    }

    private func renderInitialEmptyStateIfNeeded() {
        guard dataSource.snapshot().itemIdentifiers.isEmpty,
              model.isEmpty else {
            return
        }
        renderEmptyState(isEmpty: true)
    }

    private func displayEntryIDsFromModel() -> [NetworkListEntry.ID] {
#if DEBUG
        displayRequestIDsEvaluationCountStorageForTesting += 1
#endif
        return model.displayEntryIDs
    }

    private func renderSelectedEntryID(_ selectedEntryID: NetworkListEntry.ID?) {
        guard isViewLoaded else {
            return
        }

        let selectedIndexPaths = collectionView.indexPathsForSelectedItems ?? []
        let targetIndexPath = selectedEntryID.flatMap { dataSource.indexPath(for: $0) }
        for indexPath in selectedIndexPaths where indexPath != targetIndexPath {
            collectionView.deselectItem(at: indexPath, animated: false)
        }
        guard let targetIndexPath, selectedIndexPaths.contains(targetIndexPath) == false else {
            return
        }
        collectionView.selectItem(at: targetIndexPath, animated: false, scrollPosition: [])
    }

    private func renderEmptyState(isEmpty: Bool) {
        if collectionView.isHidden != isEmpty {
            collectionView.isHidden = isEmpty
        }
        if isEmpty {
            let title = String(localized: "network.empty.title", bundle: WebInspectorUILocalization.bundle)
            if let configuration = contentUnavailableConfiguration as? UIContentUnavailableConfiguration,
               configuration.text == title,
               configuration.secondaryText == nil,
               configuration.image == nil,
               configuration.textProperties.color == .secondaryLabel {
                return
            }
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = title
            configuration.textProperties.color = .secondaryLabel
            contentUnavailableConfiguration = configuration
        } else if contentUnavailableConfiguration != nil {
            contentUnavailableConfiguration = nil
        }
    }

    private func setVisibleCellRenderingActive(_ isActive: Bool) {
        guard isViewLoaded else {
            return
        }
        for cell in collectionView.visibleCells {
            (cell as? NetworkListCell)?.setRenderingActive(isActive)
        }
    }

    override package func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        entrySelectionAction(dataSource.itemIdentifier(for: indexPath))
    }
}

#if DEBUG
extension NetworkListViewController {
    package var collectionViewForTesting: UICollectionView {
        collectionView
    }

    package var searchControllerForTesting: UISearchController {
        loadViewIfNeeded()
        configureNavigationItem()
        guard let activeSearchController else {
            fatalError("Expected NetworkListViewController to have an active search controller")
        }
        return activeSearchController
    }

    package var filterItemForTesting: UIBarButtonItem {
        filterItem
    }

    package var selectedRequestObservationDeliveryForTesting: PortableObservationTracking.Token? {
        selectedEntryObservation
    }

    package var displayRequestIDsEvaluationCountForTesting: Int {
        displayRequestIDsEvaluationCountStorageForTesting
    }

    package var snapshotApplyCountForTesting: Int {
        snapshotApplyCountStorageForTesting
    }

    package var listProjectionFlushCountForTesting: Int {
        listProjectionFlushCountStorageForTesting
    }

    package var fetchedResultsTransactionDeliveryCountForTesting: Int {
        fetchedResultsTransactionDeliveryCountStorageForTesting
    }

    package var filterMenuBuildCountForTesting: Int {
        filterMenuBuildCountStorageForTesting
    }

    package var displayedRequestIDsForTesting: [NetworkRequest.ID] {
        dataSource.snapshot().itemIdentifiers.compactMap {
            model.entry(for: $0)?.representativeRequest.id
        }
    }

    package var displayedEntryIDsForTesting: [NetworkListEntry.ID] {
        dataSource.snapshot().itemIdentifiers
    }

    package func networkListCellForTesting(at indexPath: IndexPath) -> NetworkListCell? {
        collectionView.cellForItem(at: indexPath) as? NetworkListCell
    }

    package var hasPendingSnapshotUpdateForTesting: Bool {
        snapshotCoordinator.readyArtifact != nil
    }

    package var hasActiveListSnapshotBuildForTesting: Bool {
        listSnapshotBuildCoordinator.hasWorkInFlight
    }

    package func suspendRenderingForTesting() {
        suspendRendering()
    }

    package func resumeRenderingForTesting() {
        resumeRendering()
    }

    package func flushPendingSnapshotUpdateForTesting() async {
        while true {
            await listSnapshotBuildCoordinator.waitUntilIdle()
            if snapshotCoordinator.isRenderingActive == false {
                await waitForSnapshotUpdateCompletionForTesting()
                return
            }
            if pendingListProjection != nil || snapshotCoordinator.readyArtifact != nil {
                listFrameScheduler.cancel()
                listRenderingDisplayFrameDidFire()
                continue
            }
            if snapshotCoordinator.state.isApplying {
                await waitForSnapshotUpdateCompletionForTesting()
                continue
            }
            if snapshotCoordinator.needsReloadForActiveRendering {
                reloadDataFromModel()
                continue
            }
            return
        }
    }

    package func waitForSnapshotPipelineQuiescenceForTesting() async {
        await flushPendingSnapshotUpdateForTesting()
    }

    package func waitForListSnapshotBuildIdleForTesting() async {
        await listSnapshotBuildCoordinator.waitUntilIdle()
    }

    package func flushPendingListProjectionForTesting() {
        listFrameScheduler.cancel()
        listRenderingDisplayFrameDidFire()
    }

    package func waitForFetchedResultsTransactionDeliveryForTesting(
        after baselineCount: Int,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        precondition(baselineCount < Int.max, "Network list transaction delivery count overflowed.")
        return await waitForFetchedResultsTransactionDeliveryCountForTesting(
            baselineCount + 1,
            timeout: timeout
        )
    }

    package func waitForFetchedResultsTransactionDeliveryCountForTesting(
        _ targetCount: Int,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        guard fetchedResultsTransactionDeliveryCountStorageForTesting < targetCount else {
            return true
        }
        return await withCheckedContinuation { continuation in
            let waiterID = fetchedResultsTransactionDeliveryWaiterIDStorageForTesting
            fetchedResultsTransactionDeliveryWaiterIDStorageForTesting &+= 1
            let timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolveFetchedResultsTransactionDeliveryWaiterForTesting(
                    id: waiterID,
                    result: false
                )
            }
            fetchedResultsTransactionDeliveryWaitersForTesting.append(
                FetchedResultsTransactionDeliveryWaiter(
                    id: waiterID,
                    targetCount: targetCount,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            )
        }
    }

    private func waitForSnapshotUpdateCompletionForTesting() async {
        guard snapshotCoordinator.state.isApplying else {
            return
        }
        await withCheckedContinuation { continuation in
            snapshotUpdateCompletionWaitersForTesting.append(continuation)
        }
    }

    private func resumeSnapshotUpdateCompletionWaitersForTesting() {
        guard snapshotCoordinator.state.isApplying == false else {
            return
        }
        let waiters = snapshotUpdateCompletionWaitersForTesting
        snapshotUpdateCompletionWaitersForTesting.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func recordFetchedResultsTransactionDeliveryForTesting() {
        fetchedResultsTransactionDeliveryCountStorageForTesting &+= 1
        resolveFetchedResultsTransactionDeliveryWaitersForTesting(result: true)
    }

    private func resolveFetchedResultsTransactionDeliveryWaitersForTesting(result: Bool) {
        let waiterIDs = fetchedResultsTransactionDeliveryWaitersForTesting.compactMap { waiter in
            if result == false || fetchedResultsTransactionDeliveryCountStorageForTesting >= waiter.targetCount {
                return waiter.id
            }
            return nil
        }
        for waiterID in waiterIDs {
            resolveFetchedResultsTransactionDeliveryWaiterForTesting(id: waiterID, result: result)
        }
    }

    private func resolveFetchedResultsTransactionDeliveryWaiterForTesting(id: Int, result: Bool) {
        guard let index = fetchedResultsTransactionDeliveryWaitersForTesting.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = fetchedResultsTransactionDeliveryWaitersForTesting.remove(at: index)
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: result)
    }

    package func setDeinitHandlerForTesting(_ handler: @escaping @MainActor () -> Void) {
        deinitHandlerForTesting = handler
    }
}
#endif

#Preview("Network List") {
    UINavigationController(
        rootViewController: NetworkListViewController(
            model: NetworkPreviewFixtures.makePanelModel(mode: .root)
        )
    )
}

#Preview("Network List Long Title") {
    UINavigationController(
        rootViewController: NetworkListViewController(
            model: NetworkPreviewFixtures.makePanelModel(mode: .rootLongTitle)
        )
    )
}
#endif
