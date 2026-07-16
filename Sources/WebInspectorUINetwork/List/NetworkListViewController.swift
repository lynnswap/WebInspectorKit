#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import ObservationBridge
import UIHostingMenu
import UIKit

@MainActor
package final class NetworkListViewController: UICollectionViewController, UISearchResultsUpdating {
    package typealias EntrySelectionAction = @MainActor (NetworkListEntry.ID?) -> Void
    package static let horizontalSectionInset: CGFloat = 20
    package static let bottomSectionInset: CGFloat = 20

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
            var isRetired: Bool
        }

        private enum BuildOutcome {
            case success(NetworkListSnapshotArtifact)
            case cancelled
        }

        private let builderFactory: any NetworkListSnapshotBuilderMaking
        private var activeBuild: ActiveBuild?
        private var nextGeneration: UInt64 = 0
        private var idleWaiters: [CheckedContinuation<Void, Never>] = []
        private var trackedTaskCompletionWaiters: [CheckedContinuation<Void, Never>] = []

        init(builderFactory: any NetworkListSnapshotBuilderMaking) {
            self.builderFactory = builderFactory
        }

        var hasWorkInFlight: Bool {
            guard let activeBuild else {
                return false
            }
            return activeBuild.isRetired == false || activeBuild.pendingWork != nil
        }

        var trackedBuildTaskCount: Int {
            activeBuild == nil ? 0 : 1
        }

        var hasDeferredWork: Bool {
            activeBuild?.pendingWork != nil
        }

        func submit(
            _ request: Request,
            completion: @escaping Completion
        ) {
            let work = Work(request: request, completion: completion)
            if var activeBuild {
                if activeBuild.isRetired == false,
                   activeBuild.pendingWork == nil,
                   activeBuild.work.request == request {
                    return
                }
                if activeBuild.pendingWork?.request == request {
                    return
                }
                activeBuild.pendingWork = work
                self.activeBuild = activeBuild
                return
            }
            start(work)
        }

        @discardableResult
        func cancel() -> Bool {
            guard var activeBuild else {
                return false
            }
            let discardedWork = activeBuild.isRetired == false || activeBuild.pendingWork != nil
            activeBuild.pendingWork = nil
            if activeBuild.isRetired == false {
                activeBuild.isRetired = true
                activeBuild.task.cancel()
            }
            self.activeBuild = activeBuild
            resumeIdleWaitersIfNeeded()
            return discardedWork
        }

        func waitUntilIdle() async {
            guard hasWorkInFlight else {
                return
            }
            await withCheckedContinuation { continuation in
                idleWaiters.append(continuation)
            }
        }

        func waitUntilTrackedTasksComplete() async {
            guard trackedBuildTaskCount > 0 else {
                return
            }
            await withCheckedContinuation { continuation in
                trackedTaskCompletionWaiters.append(continuation)
            }
        }

        private func start(_ work: Work) {
            precondition(
                activeBuild == nil,
                "Only one Network list snapshot build task may run at a time."
            )
            let generation = takeNextGeneration()
            let builder = builderFactory.makeBuilder()
            let request = work.request
            let task = Task(priority: .userInitiated) { @MainActor [weak self] in
                do {
                    let artifact = try await builder.build(request)
                    self?.buildDidComplete(
                        generation: generation,
                        outcome: .success(artifact)
                    )
                } catch {
                    self?.buildDidComplete(
                        generation: generation,
                        outcome: .cancelled
                    )
                }
            }
            activeBuild = ActiveBuild(
                generation: generation,
                task: task,
                work: work,
                pendingWork: nil,
                isRetired: false
            )
        }

        private func buildDidComplete(
            generation: UInt64,
            outcome: BuildOutcome
        ) {
            guard let completedBuild = activeBuild,
                  completedBuild.generation == generation else {
                preconditionFailure("A completed Network list snapshot build must be tracked.")
            }
            activeBuild = nil
            if completedBuild.isRetired == false,
               case .success(let artifact) = outcome {
                precondition(
                    artifact.input == completedBuild.work.request,
                    "A Network list snapshot builder must return the requested input."
                )
                if completedBuild.pendingWork == nil {
                    completedBuild.work.completion(artifact)
                }
            }
            if let pendingWork = completedBuild.pendingWork {
                start(pendingWork)
            }
            resumeIdleWaitersIfNeeded()
            resumeTrackedTaskCompletionWaitersIfNeeded()
        }

        private func takeNextGeneration() -> UInt64 {
            precondition(
                nextGeneration < UInt64.max,
                "Network list snapshot build generation overflowed."
            )
            nextGeneration += 1
            return nextGeneration
        }

        private func resumeIdleWaitersIfNeeded() {
            guard hasWorkInFlight == false else {
                return
            }
            let waiters = idleWaiters
            idleWaiters.removeAll(keepingCapacity: true)
            for waiter in waiters {
                waiter.resume()
            }
        }

        private func resumeTrackedTaskCompletionWaitersIfNeeded() {
            guard trackedBuildTaskCount == 0 else {
                return
            }
            let waiters = trackedTaskCompletionWaiters
            trackedTaskCompletionWaiters.removeAll(keepingCapacity: true)
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    @MainActor
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
    private let listInvalidationAccumulator: NetworkListInvalidationAccumulator
    private var listInvalidationInputTask: Task<Void, Never>?
    private var listFrameRequestTask: Task<Void, Never>?
    private var searchTextObservation: PortableObservationTracking.Token?
    private var resourceFilterObservation: PortableObservationTracking.Token?
    private var selectedEntryObservation: PortableObservationTracking.Token?

    private var snapshotCoordinator = SnapshotCoordinator()
    private var needsListProjectionCapture = false
    private let listFrameScheduler: any NetworkListFrameScheduling
    private let listSnapshotBuildCoordinator: ListSnapshotBuildCoordinator
    private let snapshotApplyCompletionScheduler: any NetworkListSnapshotApplyCompletionScheduling
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
        listInvalidationAccumulator = NetworkListInvalidationAccumulator()
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
        listInvalidationInputTask?.cancel()
        listFrameRequestTask?.cancel()
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
        updateListLayoutMetrics()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (viewController: NetworkListViewController, _) in
            viewController.updateListLayoutMetrics()
        }

        configureNavigationItem()
    }

    override package func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateListLayoutMetrics()
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
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.estimatedItemSize = .zero
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = UIEdgeInsets(
            top: 0,
            left: horizontalSectionInset,
            bottom: bottomSectionInset,
            right: horizontalSectionInset
        )
        layout.sectionInsetReference = .fromContentInset
        layout.itemSize = CGSize(
            width: 1,
            height: NetworkListCell.rowHeight(compatibleWith: UITraitCollection.current)
        )
        return layout
    }

    private func updateListLayoutMetrics() {
        guard isViewLoaded,
              let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else {
            return
        }
        let availableWidth = collectionView.bounds.width
            - collectionView.adjustedContentInset.left
            - collectionView.adjustedContentInset.right
            - layout.sectionInset.left
            - layout.sectionInset.right
        let nextItemSize = CGSize(
            width: max(1, availableWidth),
            height: NetworkListCell.rowHeight(compatibleWith: traitCollection)
        )
        guard layout.itemSize != nextItemSize else {
            return
        }
        layout.itemSize = nextItemSize
    }

    private func startObservingModel() {
        startObservingListInvalidations()

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

    private func startObservingListInvalidations() {
        listInvalidationInputTask?.cancel()
        listFrameRequestTask?.cancel()

        let invalidations = model.listInvalidations
        let accumulator = listInvalidationAccumulator
        listInvalidationInputTask = Task.detached {
            await accumulator.consume(invalidations)
        }

        let frameRequests = accumulator.frameRequests
        listFrameRequestTask = Task { @MainActor [weak self] in
            for await _ in frameRequests {
                self?.listFrameDidRequestProjectionCapture()
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
        if needsListProjectionCapture || discardedSnapshotBuild {
            snapshotCoordinator.markNeedsReloadOnNextAppearance()
            needsListProjectionCapture = false
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
        let listCellRegistration = UICollectionView.CellRegistration<NetworkListCell, NetworkListEntry.ID> { [weak self] cell, indexPath, id in
            self?.updateListPosition(of: cell, at: indexPath)
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
        guard artifact.input.target.version == model.listProjectionVersion,
              artifact.input.baseline.generation
                == snapshotCoordinator.state.submittedBaseline.generation else {
            requestListProjectionCapture()
            return
        }
        snapshotCoordinator.needsReloadOnNextAppearance = false
        guard artifact.changeCounts.requiresApply else {
            snapshotCoordinator.state.acknowledgeUnchanged(artifact)
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
        guard artifact.input.target.version == model.listProjectionVersion,
              artifact.input.baseline.generation
                == snapshotCoordinator.state.submittedBaseline.generation else {
            snapshotCoordinator.readyArtifact = nil
            requestListProjectionCapture()
            return
        }
        precondition(
            artifact.changeCounts.requiresApply,
            "A ready Network list snapshot artifact must change UIKit state."
        )
        snapshotCoordinator.readyArtifact = nil
        let rows = snapshotCoordinator.state.beginApplying(artifact)

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
        updateVisibleListCellPositions()
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

    private func listFrameDidRequestProjectionCapture() {
#if DEBUG
        recordFetchedResultsTransactionDeliveryForTesting()
#endif
        needsListProjectionCapture = true
        guard snapshotCoordinator.isRenderingActive else {
            snapshotCoordinator.markNeedsReloadOnNextAppearance()
            return
        }
        scheduleListRenderingFrameIfNeeded()
    }

    private func scheduleListRenderingFrameIfNeeded() {
        guard snapshotCoordinator.isRenderingActive,
              needsListProjectionCapture || snapshotCoordinator.readyArtifact != nil else {
            return
        }
        listFrameScheduler.schedule { [weak self] in
            self?.listRenderingDisplayFrameDidFire()
        }
    }

    private func listRenderingDisplayFrameDidFire() {
        guard snapshotCoordinator.isRenderingActive else {
            if needsListProjectionCapture || snapshotCoordinator.readyArtifact != nil {
                needsListProjectionCapture = false
                snapshotCoordinator.readyArtifact = nil
                snapshotCoordinator.markNeedsReloadOnNextAppearance()
            }
            return
        }
        applyReadySnapshotArtifactOnDisplayFrameIfNeeded()
        capturePendingListProjectionIfNeeded()
    }

    private func capturePendingListProjectionIfNeeded() {
        guard snapshotCoordinator.isRenderingActive else {
            if needsListProjectionCapture {
                needsListProjectionCapture = false
                snapshotCoordinator.markNeedsReloadOnNextAppearance()
            }
            return
        }
        guard needsListProjectionCapture else {
            return
        }
        needsListProjectionCapture = false
        let projection = model.captureListProjection()
#if DEBUG
        listProjectionFlushCountStorageForTesting += 1
        displayRequestIDsEvaluationCountStorageForTesting += 1
#endif
        let accumulator = listInvalidationAccumulator
        Task.detached {
            await accumulator.didCapture(projection.version)
        }
        renderEmptyState(isEmpty: projection.entryIDs.isEmpty)
        requestListSnapshotBuild(target: projection)
    }

    private func requestListSnapshotBuild(
        target: NetworkPanelListProjection
    ) {
        let request = ListSnapshotBuildCoordinator.Request(
            baseline: snapshotCoordinator.state.submittedBaseline,
            target: target
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
        snapshotCoordinator.needsReloadOnNextAppearance = false
        requestListProjectionCapture()
    }

    private func renderInitialEmptyStateIfNeeded() {
        guard dataSource.snapshot().itemIdentifiers.isEmpty,
              model.isEmpty else {
            return
        }
        renderEmptyState(isEmpty: true)
    }

    private func requestListProjectionCapture() {
        needsListProjectionCapture = true
        scheduleListRenderingFrameIfNeeded()
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

    private func updateVisibleListCellPositions() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let cell = collectionView.cellForItem(at: indexPath) as? NetworkListCell else {
                continue
            }
            updateListPosition(of: cell, at: indexPath)
        }
    }

    private func updateListPosition(of cell: NetworkListCell, at indexPath: IndexPath) {
        let count = collectionView.numberOfItems(inSection: indexPath.section)
        precondition(indexPath.item < count, "A visible Network list cell must belong to its section.")
        let position: NetworkListCell.ListPosition
        if count == 1 {
            position = .single
        } else if indexPath.item == 0 {
            position = .first
        } else if indexPath.item == count - 1 {
            position = .last
        } else {
            position = .middle
        }
        cell.setListPosition(position)
    }

    override package func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let cell = cell as? NetworkListCell else {
            return
        }
        updateListPosition(of: cell, at: indexPath)
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

    package var trackedListSnapshotBuildTaskCountForTesting: Int {
        listSnapshotBuildCoordinator.trackedBuildTaskCount
    }

    package var hasDeferredListSnapshotBuildForTesting: Bool {
        listSnapshotBuildCoordinator.hasDeferredWork
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
            if needsListProjectionCapture || snapshotCoordinator.readyArtifact != nil {
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

    package func waitForTrackedListSnapshotBuildTasksForTesting() async {
        await listSnapshotBuildCoordinator.waitUntilTrackedTasksComplete()
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
