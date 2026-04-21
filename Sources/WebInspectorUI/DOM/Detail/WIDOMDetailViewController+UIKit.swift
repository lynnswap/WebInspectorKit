import WebInspectorEngine
import WebInspectorRuntime
import ObservationBridge

#if canImport(UIKit)
import UIKit
import SwiftUI

private protocol DiffableStableID: Hashable, Sendable {}

private struct ElementAttributeEditingKey: Hashable, Sendable {
    let nodeID: DOMNodeModel.ID
    let name: String
}

@MainActor
private protocol ElementAttributeEditorCellDelegate: AnyObject {
    func elementAttributeEditorCellDidBeginEditing(
        _ cell: ElementAttributeEditorCell,
        key: ElementAttributeEditingKey,
        value: String
    )
    func elementAttributeEditorCellDidChangeDraft(
        _ cell: ElementAttributeEditorCell,
        key: ElementAttributeEditingKey,
        value: String
    )
    func elementAttributeEditorCellDidCommitValue(
        _ cell: ElementAttributeEditorCell,
        key: ElementAttributeEditingKey,
        value: String
    )
    func elementAttributeEditorCellDidEndEditing(
        _ cell: ElementAttributeEditorCell,
        key: ElementAttributeEditingKey,
        value: String
    )
    func elementAttributeEditorCellNeedsRelayout(_ cell: ElementAttributeEditorCell)
}

@MainActor
public final class WIDOMDetailViewController: UICollectionViewController {
    private struct PendingInlineCommitMarker: Equatable {
        let key: ElementAttributeEditingKey
        let generation: UInt64
    }

    @MainActor
    private final class InlineEditingEndWaiter {
        private var didFinish = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard didFinish == false else {
                return
            }

            await withCheckedContinuation { continuation in
                if didFinish {
                    continuation.resume()
                } else {
                    continuations.append(continuation)
                }
            }
        }

        func finish() {
            guard didFinish == false else {
                return
            }

            didFinish = true
            let continuations = self.continuations
            self.continuations.removeAll(keepingCapacity: false)
            continuations.forEach { $0.resume() }
        }
    }

    private struct SectionIdentifier: Hashable, Sendable {
        let index: Int
        let title: String
    }

    private enum SectionKey: String, Hashable, Sendable {
        case element
        case selector
        case attributes
    }

    fileprivate enum ItemCellKind: String, Hashable, Sendable {
        case list
        case attributeEditor
    }

    fileprivate enum ItemStableKey: DiffableStableID {
        case element
        case selector
        case attribute(nodeID: DOMNodeModel.ID, name: String)
        case emptyAttribute
    }

    fileprivate struct ItemStableID: DiffableStableID {
        let key: ItemStableKey
        let cellKind: ItemCellKind
    }

    private struct ItemIdentifier: Hashable, Sendable {
        let stableID: ItemStableID
        let selectionGeneration: UInt64
    }

    private struct DetailSection {
        let key: SectionKey
        let title: String
        let rows: [DetailRow]
    }

    private enum DetailRow {
        case element
        case selector
        case attribute(nodeID: DOMNodeModel.ID, name: String)
        case emptyAttribute
    }

    fileprivate enum ItemPayload {
        case element(preview: String)
        case selector(path: String)
        case attribute(nodeID: DOMNodeModel.ID, name: String, value: String)
        case emptyAttribute
    }

    private struct RenderSection {
        let sectionIdentifier: SectionIdentifier
        let stableIDs: [ItemStableID]
    }

    private let inspector: WIDOMInspector
    private let showsNavigationControls: Bool
    private var hasStartedObservingState = false
    private var stateObservationHandles: Set<ObservationHandle> = []
    private var documentStoreObservationHandles: Set<ObservationHandle> = []
    private var selectedEntryObservationHandles: Set<ObservationHandle> = []
    // Keep coalescing because navigation controls react to several independent state updates.
    private let navigationUpdateCoalescer = UIUpdateCoalescer()
    // Keep coalescing because structure snapshots can burst under DOM updates.
    private let structureUpdateCoalescer = UIUpdateCoalescer()
    private var sections: [DetailSection] = []
    private var attributeDraftSession: WIDOMAttributeDraftSession?
    private var editingAttributeKey: ElementAttributeEditingKey?
    private var suppressedInlineCommitKey: ElementAttributeEditingKey?
    private var pendingInlineCommitMarker: PendingInlineCommitMarker?
    private var nextInlineCommitGeneration: UInt64 = 0
    private var isInlineEditingActive = false
    private var pendingInlineSelectionClearTask: Task<Void, Never>?
    private var pendingInlineEditingRefreshTask: Task<Void, Never>?
    private var pendingInlineEditingEndWaiters: [ElementAttributeEditingKey: InlineEditingEndWaiter] = [:]
    private var pendingForcedProjectionRefresh = false
    private var pendingFocusRestoreKey: ElementAttributeEditingKey?
    private var pendingFocusRestoreGeneration: UInt64?
    private var pendingFocusRestoreFromModelUpdate = false
    private var attributeRelayoutCoordinator = AttributeEditorRelayoutCoordinator()
    private var needsSnapshotReloadOnNextAppearance = false
    private var pendingReloadDataTask: Task<Void, Never>?
    private var pendingForcedStructureRefresh = false
    private var selectedEntryRenderGeneration: UInt64 = 0

#if DEBUG
    private(set) var snapshotApplyCountForTesting = 0
#endif

    private lazy var dataSource = makeDataSource()

    private lazy var pickItem: UIBarButtonItem = {
        UIBarButtonItem(
            image: UIImage(systemName: pickSymbolName),
            style: .plain,
            target: self,
            action: #selector(toggleSelectionMode)
        )
    }()

    public init(inspector: WIDOMInspector, showsNavigationControls: Bool = true) {
        self.inspector = inspector
        self.showsNavigationControls = showsNavigationControls
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        pendingReloadDataTask?.cancel()
        pendingInlineEditingRefreshTask?.cancel()
        stateObservationHandles.removeAll()
        documentStoreObservationHandles.removeAll()
        selectedEntryObservationHandles.removeAll()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        collectionView.collectionViewLayout = makeLayout()
        setupNavigationItems()

        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.scheduleNavigationControlsUpdate()
            self.scheduleStructureUpdate(forceSnapshotUpdate: true)
        }

        startObservingStateIfNeeded()

        updateNavigationControls()
        handleSelectedNodeChange()
    }

    private var pickSymbolName: String {
        traitCollection.horizontalSizeClass == .compact ? "viewfinder.circle" : "scope"
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        flushPendingAttributeEditorRelayoutIfNeeded()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        flushPendingSnapshotUpdateIfNeeded()
    }

    private func setupNavigationItems() {
        guard showsNavigationControls else {
            navigationItem.rightBarButtonItems = nil
            return
        }
        navigationItem.rightBarButtonItems = [pickItem]
    }

    private func startObservingStateIfNeeded() {
        guard hasStartedObservingState == false else {
            return
        }
        hasStartedObservingState = true

        inspector.observe(
            \.hasPageWebView,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleNavigationControlsUpdate()
        }
        .store(in: &stateObservationHandles)
        inspector.observe(
            \.isSelectingElement,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleNavigationControlsUpdate()
        }
        .store(in: &stateObservationHandles)
        inspector.observe(
            \.document
        ) { [weak self] document in
            guard let self else {
                return
            }
            self.documentStoreObservationHandles.removeAll()
            document.observe(
                \.selectedNode,
                options: [.removeDuplicates]
            ) { [weak self] _ in
                self?.scheduleNavigationControlsUpdate()
                self?.handleSelectedNodeChange()
            }
            .store(in: &self.documentStoreObservationHandles)
            self.scheduleNavigationControlsUpdate()
            self.handleSelectedNodeChange()
        }
        .store(in: &stateObservationHandles)
    }

    private func makeSecondaryMenu() -> UIMenu {
        let hasSelection = inspector.document.selectedNode != nil
        let hasPageWebView = inspector.hasPageWebView

        return DOMSecondaryMenuBuilder.makeMenu(
            hasSelection: hasSelection,
            hasPageWebView: hasPageWebView,
            onCopyHTML: { [weak self] in
                self?.copySelectedHTML()
            },
            onCopySelectorPath: { [weak self] in
                self?.copySelectedSelectorPath()
            },
            onCopyXPath: { [weak self] in
                self?.copySelectedXPath()
            },
            onReloadInspector: { [weak self] in
                self?.reloadDocument()
            },
            onReloadPage: { [weak self] in
                guard let self else { return }
                Task {
                    do {
                        try await self.inspector.reloadPage()
                    } catch {
                    }
                }
            },
            onDeleteNode: { [weak self] in
                self?.deleteNode()
            }
        )
    }

    private func scheduleNavigationControlsUpdate() {
        navigationUpdateCoalescer.schedule { [weak self] in
            self?.updateNavigationControls()
        }
    }

    private func scheduleStructureUpdate(forceSnapshotUpdate: Bool = false) {
        pendingForcedStructureRefresh = pendingForcedStructureRefresh || forceSnapshotUpdate
        structureUpdateCoalescer.schedule { [weak self] in
            guard let self else {
                return
            }
            let shouldForceSnapshotUpdate = self.pendingForcedStructureRefresh
            self.pendingForcedStructureRefresh = false
            self.reconcileSectionStructure(forceSnapshotUpdate: shouldForceSnapshotUpdate)
        }
    }

    private func updateNavigationControls() {
        if showsNavigationControls {
            navigationItem.additionalOverflowItems = UIDeferredMenuElement.uncached { [weak self] completion in
                completion((self?.makeSecondaryMenu() ?? UIMenu()).children)
            }
            pickItem.isEnabled = inspector.hasPageWebView
            pickItem.image = UIImage(systemName: pickSymbolName)
            pickItem.tintColor = inspector.isSelectingElement ? .systemBlue : .label
        } else {
            navigationItem.additionalOverflowItems = nil
        }
    }

    private func handleSelectedNodeChange() {
        handleSelectedNodeChange(forceProjectionRefresh: false, allowTransientDeselection: true)
    }

    private func handleSelectedNodeChange(
        forceProjectionRefresh: Bool,
        allowTransientDeselection: Bool
    ) {
        pendingInlineSelectionClearTask?.cancel()
        pendingInlineSelectionClearTask = nil
        selectedEntryObservationHandles.removeAll()
        let currentSelectionIdentity = inspector.document.selectedNode?.id
        reconcileAttributeDraftSessionIfNeeded(allowTransientDeselection: allowTransientDeselection)
        if allowTransientDeselection,
           currentSelectionIdentity == nil,
           (editingAttributeKey != nil || !sections.isEmpty) {
            pendingInlineSelectionClearTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard
                    let self,
                    !Task.isCancelled
                else {
                    return
                }
                self.pendingInlineSelectionClearTask = nil
                self.handleSelectedNodeChange(
                    forceProjectionRefresh: false,
                    allowTransientDeselection: false
                )
            }
            return
        }
        selectedEntryRenderGeneration &+= 1
        if let editingAttributeKey,
           (
            editingAttributeKey.nodeID != currentSelectionIdentity
                || !isAttributeDraftDirty(for: editingAttributeKey)
           ) {
            discardInlineEditingState()
        }

        if currentSelectionIdentity == nil {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = wiLocalized("dom.element.select_prompt")
            configuration.secondaryText = wiLocalized("dom.element.hint")
            configuration.image = UIImage(systemName: "cursorarrow.rays")
            contentUnavailableConfiguration = configuration
            collectionView.isHidden = true
            discardInlineEditingState()
            sections = []
        } else {
            contentUnavailableConfiguration = nil
            collectionView.isHidden = false
            sections = makeSections()
            if let selectedEntry = inspector.document.selectedNode {
                startObservingSelectedEntry(selectedEntry)
            }
        }

        if isInlineEditingActive {
            if forceProjectionRefresh {
                let shouldCarryProjectionRefresh: Bool
                if let editingAttributeKey {
                    shouldCarryProjectionRefresh = editingAttributeKey.nodeID != currentSelectionIdentity
                        || !isAttributeDraftDirty(for: editingAttributeKey)
                } else {
                    shouldCarryProjectionRefresh = true
                }
                pendingForcedProjectionRefresh = pendingForcedProjectionRefresh || shouldCarryProjectionRefresh
            }
            return
        }
        let shouldForceProjectionRefresh = forceProjectionRefresh || pendingForcedProjectionRefresh
        pendingForcedProjectionRefresh = false
        requestSnapshotUpdate(animatingDifferences: true, force: shouldForceProjectionRefresh)
    }

    private func handleSelectedNodeProjectionEvent() {
        handleSelectedNodeChange(forceProjectionRefresh: true, allowTransientDeselection: true)
    }

    private func startObservingSelectedEntry(_ entry: DOMNodeModel) {
        // Element/selector rows observe preview-like payloads inside DOMObservingListCell.
        // This controller-level observer only tracks fields that can change section structure.
        entry.observe(
            [\.attributes],
            onChange: { [weak self, weak entry] in
                guard let self, let entry else {
                    return
                }
                guard self.inspector.document.selectedNode === entry else {
                    return
                }
                self.reconcileAttributeDraftSessionIfNeeded(allowTransientDeselection: false)
                self.refreshVisibleAttributeEditorsForSelectedNode()
                self.scheduleStructureUpdate()
            },
            isolation: MainActor.shared
        )
        .store(in: &selectedEntryObservationHandles)
    }

    private func reconcileSectionStructure(forceSnapshotUpdate: Bool = false) {
        guard inspector.document.selectedNode != nil else {
            handleSelectedNodeChange()
            return
        }

        let updatedSections = makeSections()
        let structureChanged = forceSnapshotUpdate || hasSectionStructureChanged(from: sections, to: updatedSections)
        sections = updatedSections

        guard structureChanged, !isInlineEditingActive else {
            return
        }
        requestSnapshotUpdate(animatingDifferences: true, force: forceSnapshotUpdate)
    }

    private func makeLayout() -> UICollectionViewLayout {
        var listConfiguration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        listConfiguration.showsSeparators = true
        listConfiguration.headerMode = .supplementary
        listConfiguration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.trailingSwipeActions(for: indexPath)
        }

        return UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(using: listConfiguration, layoutEnvironment: environment)
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

    private func makeSections() -> [DetailSection] {
        guard let selected = inspector.document.selectedNode else {
            return []
        }

        let elementSection = DetailSection(
            key: .element,
            title: wiLocalized("dom.element.section.element"),
            rows: [.element]
        )

        let selectorSection = DetailSection(
            key: .selector,
            title: wiLocalized("dom.element.section.selector"),
            rows: [.selector]
        )

        var attributeRows = selected.attributes.map { attribute in
            DetailRow.attribute(nodeID: selected.id, name: attribute.name)
        }
        if let draftSession = attributeDraftSession,
           draftSession.key.nodeID == selected.id,
           draftSession.isDirty,
           !selected.attributes.contains(where: { $0.name == draftSession.key.attributeName }) {
            attributeRows.append(.attribute(nodeID: selected.id, name: draftSession.key.attributeName))
        }
        if attributeRows.isEmpty {
            attributeRows = [.emptyAttribute]
        }

        let attributeSection = DetailSection(
            key: .attributes,
            title: wiLocalized("dom.element.section.attributes"),
            rows: attributeRows
        )

        return [elementSection, selectorSection, attributeSection]
    }

    private func defaultPreview(for entry: DOMNodeModel) -> String {
        switch entry.nodeType {
        case 3:
            return entry.nodeValue
        case 8:
            return "<!-- \(entry.nodeValue) -->"
        default:
            let name = entry.localName.isEmpty ? entry.nodeName : entry.localName
            let attributes = entry.attributes.map { attribute in
                "\(attribute.name)=\"\(attribute.value)\""
            }.joined(separator: " ")
            let suffix = attributes.isEmpty ? "" : " \(attributes)"
            return "<\(name)\(suffix)>"
        }
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<SectionIdentifier, ItemIdentifier> {
        let listCellRegistration = UICollectionView.CellRegistration<DOMObservingListCell, ItemIdentifier> { [weak self] cell, _, item in
            self?.configureListCell(cell, item: item)
        }
        let attributeCellRegistration = UICollectionView.CellRegistration<ElementAttributeEditorCell, ItemIdentifier> { [weak self] cell, _, item in
            self?.configureAttributeCell(cell, item: item)
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
                return UICollectionViewCell()
            }
            self.attributeRelayoutCoordinator.beginCellDequeue()
            defer {
                self.attributeRelayoutCoordinator.endCellDequeue()
            }
            switch item.stableID.cellKind {
            case .attributeEditor:
                return collectionView.dequeueConfiguredReusableCell(
                    using: attributeCellRegistration,
                    for: indexPath,
                    item: item
                )
            case .list:
                return collectionView.dequeueConfiguredReusableCell(
                    using: listCellRegistration,
                    for: indexPath,
                    item: item
                )
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration,
                for: indexPath
            )
        }
        return dataSource
    }

    private func requestAttributeEditorRelayout() {
        attributeRelayoutCoordinator.requestRelayout()
        flushPendingAttributeEditorRelayoutIfNeeded()
    }

    private func flushPendingAttributeEditorRelayoutIfNeeded() {
        guard attributeRelayoutCoordinator.beginRelayoutIfPossible(isViewVisible: collectionView.window != nil) else {
            return
        }

        collectionView.performBatchUpdates(nil) { [weak self] _ in
            guard let self else {
                return
            }
            self.attributeRelayoutCoordinator.finishRelayout()
            self.flushPendingAttributeEditorRelayoutIfNeeded()
        }
    }

    private func applySnapshot(
        _ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>,
        animatingDifferences: Bool
    ) {
        pendingReloadDataTask?.cancel()
#if DEBUG
        snapshotApplyCountForTesting += 1
#endif
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    private func applySnapshotUsingReloadData(
        _ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>
    ) {
        pendingReloadDataTask?.cancel()
        pendingReloadDataTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.pendingReloadDataTask = nil
            }
            guard !Task.isCancelled else {
                return
            }
#if DEBUG
            self.snapshotApplyCountForTesting += 1
#endif
            await self.dataSource.applySnapshotUsingReloadData(snapshot)
            guard !Task.isCancelled else {
                return
            }
        }
    }

    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier> {
        let renderSections = makeRenderSections(for: sections)
        let allStableIDs = renderSections.flatMap(\.stableIDs)
        precondition(
            allStableIDs.count == Set(allStableIDs).count,
            "Duplicate diffable IDs detected in WIDOMDetailViewController"
        )

        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>()
        for renderSection in renderSections {
            snapshot.appendSections([renderSection.sectionIdentifier])
            snapshot.appendItems(
                renderSection.stableIDs.map { stableID in
                    makeItemIdentifier(
                        stableID: stableID,
                        selectionGeneration: selectedEntryRenderGeneration
                    )
                },
                toSection: renderSection.sectionIdentifier
            )
        }
        return snapshot
    }

    private var isCollectionViewVisible: Bool {
        isViewLoaded && view.window != nil
    }

    private func requestSnapshotUpdate(animatingDifferences: Bool, force: Bool = false) {
        guard isCollectionViewVisible else {
            needsSnapshotReloadOnNextAppearance = true
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        let snapshot = makeSnapshot()
        guard force || snapshotStructureDiffers(from: dataSource.snapshot(), to: snapshot) else {
            return
        }
        if force {
            applySnapshotUsingReloadData(snapshot)
            return
        }
        applySnapshot(snapshot, animatingDifferences: animatingDifferences)
    }

    private func flushPendingSnapshotUpdateIfNeeded() {
        guard !isInlineEditingActive else {
            return
        }
        guard needsSnapshotReloadOnNextAppearance, isCollectionViewVisible else {
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        applySnapshotUsingReloadData(makeSnapshot())
    }

    private func makeRenderSections(for sections: [DetailSection]) -> [RenderSection] {
        return sections.enumerated().map { sectionIndex, section in
            let sectionIdentifier = SectionIdentifier(index: sectionIndex, title: section.title)
            let stableIDs = section.rows.map { row in itemStableID(for: row) }
            return RenderSection(sectionIdentifier: sectionIdentifier, stableIDs: stableIDs)
        }
    }

    private func hasSectionStructureChanged(from oldSections: [DetailSection], to newSections: [DetailSection]) -> Bool {
        let oldRenderSections = makeRenderSections(for: oldSections)
        let newRenderSections = makeRenderSections(for: newSections)
        guard oldRenderSections.count == newRenderSections.count else {
            return true
        }

        return zip(oldRenderSections, newRenderSections).contains { oldSection, newSection in
            oldSection.sectionIdentifier != newSection.sectionIdentifier || oldSection.stableIDs != newSection.stableIDs
        }
    }

    private func snapshotStructureDiffers(
        from current: NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>,
        to proposed: NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>
    ) -> Bool {
        current.sectionIdentifiers != proposed.sectionIdentifiers || current.itemIdentifiers != proposed.itemIdentifiers
    }

    private func makeItemIdentifier(
        stableID: ItemStableID,
        selectionGeneration: UInt64
    ) -> ItemIdentifier {
        ItemIdentifier(stableID: stableID, selectionGeneration: selectionGeneration)
    }

    private func itemStableID(for row: DetailRow) -> ItemStableID {
        switch row {
        case .element:
            return ItemStableID(key: .element, cellKind: .list)
        case .selector:
            return ItemStableID(key: .selector, cellKind: .list)
        case let .attribute(nodeID, name):
            return ItemStableID(key: .attribute(nodeID: nodeID, name: name), cellKind: .attributeEditor)
        case .emptyAttribute:
            return ItemStableID(key: .emptyAttribute, cellKind: .list)
        }
    }

    private func payload(for stableID: ItemStableID) -> ItemPayload? {
        guard let selectedEntry = inspector.document.selectedNode else {
            return nil
        }

        switch stableID.key {
        case .element:
            let previewText = selectedEntry.preview.isEmpty ? defaultPreview(for: selectedEntry) : selectedEntry.preview
            return .element(preview: previewText)
        case .selector:
            return .selector(path: selectedEntry.selectorPath)
        case let .attribute(nodeID, name):
            let key = ElementAttributeEditingKey(nodeID: nodeID, name: name)
            guard let value = attributeValue(for: key, in: selectedEntry) else {
                return nil
            }
            return .attribute(nodeID: nodeID, name: name, value: value)
        case .emptyAttribute:
            return .emptyAttribute
        }
    }

    private func configureListCell(_ cell: DOMObservingListCell, item: ItemIdentifier) {
        guard item.stableID.cellKind == .list else {
            assertionFailure("List cell registration received non-list item kind")
            cell.contentConfiguration = nil
            return
        }
        cell.configure(
            stableID: item.stableID,
            entry: inspector.document.selectedNode,
            payloadProvider: { [weak self] stableID in
                self?.payload(for: stableID)
            }
        )
    }

    private func configureAttributeCell(_ cell: ElementAttributeEditorCell, item: ItemIdentifier) {
        guard item.stableID.cellKind == .attributeEditor else {
            assertionFailure("Attribute editor registration received list item kind")
            return
        }
        guard
            case let .attribute(nodeID, name) = item.stableID.key
        else {
            return
        }
        let key = ElementAttributeEditingKey(nodeID: nodeID, name: name)
        cell.delegate = self
        cell.configure(
            key: key,
            name: name,
            value: attributeValue(for: key) ?? "",
            entry: inspector.document.selectedNode,
            activateEditor: shouldActivateEditor(for: key),
            preserveFocusedText: shouldPreserveFocusedText(for: key)
        )
    }

    public override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }

    public override func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        flushPendingAttributeEditorRelayoutIfNeeded()
    }

    private func trailingSwipeActions(for indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let attributeRow = attributeRow(at: indexPath) else {
            return nil
        }

        let action = UIContextualAction(style: .destructive, title: nil) { [weak self] _, _, completion in
            let key = ElementAttributeEditingKey(nodeID: attributeRow.nodeID, name: attributeRow.name)
            self?.deleteAttribute(for: key)
            completion(true)
        }
        action.image = UIImage(systemName: "trash")
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    public override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let attributeRow = attributeRow(at: indexPath) else {
            return nil
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let deleteAction = UIAction(
                title: wiLocalized("delete"),
                image: UIImage(systemName: "trash"),
                attributes: [.destructive]
            ) { _ in
                let key = ElementAttributeEditingKey(nodeID: attributeRow.nodeID, name: attributeRow.name)
                self?.deleteAttribute(for: key)
            }
            return UIMenu(children: [deleteAction])
        }
    }

    private func attributeRow(at indexPath: IndexPath) -> (nodeID: DOMNodeModel.ID, name: String, value: String)? {
        guard
            let item = dataSource.itemIdentifier(for: indexPath),
            case let .attribute(nodeID, name) = item.stableID.key
        else {
            return nil
        }

        let key = ElementAttributeEditingKey(nodeID: nodeID, name: name)
        guard let value = attributeValue(for: key) else {
            return nil
        }
        return (nodeID: nodeID, name: name, value: value)
    }

    private func deleteAttribute(for key: ElementAttributeEditingKey) {
        let draftKey = WIDOMAttributeDraftKey(nodeID: key.nodeID, attributeName: key.name)
        let preservedDraftSession = attributeDraftSession?.key == draftKey ? attributeDraftSession : nil
        let shouldRestoreInlineEditing = editingAttributeKey == key && isInlineEditingActive
        suppressInlineCommitAndEndEditing(for: key)
        if editingAttributeKey == key {
            clearInlineEditingState()
        }
        if preservedDraftSession != nil {
            attributeDraftSession = nil
        }
        let inspector = inspector
        Task { @MainActor [weak self] in
            let didFail: Bool
            do {
                try await inspector.removeAttribute(nodeID: key.nodeID, name: key.name)
                didFail = false
            } catch {
                didFail = true
            }
            guard let self, didFail, self.attributeValue(for: key) != nil else {
                return
            }
            if let preservedDraftSession {
                self.attributeDraftSession = preservedDraftSession
            }
            if shouldRestoreInlineEditing {
                self.editingAttributeKey = key
                self.isInlineEditingActive = true
            }
            self.reconcileSectionStructure(forceSnapshotUpdate: false)
        }
    }

    private func visibleAttributeEditorCell(for key: ElementAttributeEditingKey) -> ElementAttributeEditorCell? {
        for visibleCell in collectionView.visibleCells {
            guard let editorCell = visibleCell as? ElementAttributeEditorCell else {
                continue
            }
            if editorCell.currentEditingKey == key {
                return editorCell
            }
        }
        return nil
    }

    private func clearInlineEditingState() {
        let clearedKey = editingAttributeKey
        editingAttributeKey = nil
        if pendingFocusRestoreKey == clearedKey {
            pendingFocusRestoreKey = nil
            pendingFocusRestoreGeneration = nil
            pendingFocusRestoreFromModelUpdate = false
        }
        if pendingInlineCommitMarker?.key == clearedKey {
            pendingInlineCommitMarker = nil
        }
        if suppressedInlineCommitKey == clearedKey,
           let clearedKey,
           visibleAttributeEditorCell(for: clearedKey)?.isEditorFirstResponder == true {
            // Keep the suppression token armed until the editor's end-editing callbacks consume it.
        } else if suppressedInlineCommitKey == clearedKey {
            suppressedInlineCommitKey = nil
        }
        isInlineEditingActive = false
    }

    private func scheduleDeferredInlineEditingRefresh() {
        pendingInlineEditingRefreshTask?.cancel()
        pendingInlineEditingRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else {
                return
            }
            self.pendingInlineEditingRefreshTask = nil
            guard !self.isInlineEditingActive else {
                return
            }
            let forceProjectionRefresh = self.pendingForcedProjectionRefresh
            self.pendingForcedProjectionRefresh = false
            self.reconcileSectionStructure(forceSnapshotUpdate: forceProjectionRefresh)
        }
    }

    private func discardInlineEditingState() {
        guard let editingAttributeKey else {
            clearInlineEditingState()
            attributeDraftSession = nil
            return
        }
        pendingForcedProjectionRefresh = true
        let hasVisibleEditor = visibleAttributeEditorCell(for: editingAttributeKey) != nil
        let didDismissEditor = suppressInlineCommitAndEndEditing(for: editingAttributeKey)
        guard hasVisibleEditor, didDismissEditor else {
            clearInlineEditingState()
            attributeDraftSession = nil
            return
        }
        attributeDraftSession = nil
    }

    @discardableResult
    private func suppressInlineCommitAndEndEditing(
        for key: ElementAttributeEditingKey,
        forceViewFallback: Bool = false
    ) -> Bool {
        if !forceViewFallback,
           let editorCell = visibleAttributeEditorCell(for: key) {
            let didDismissEditor = editorCell.suppressNextCommitAndEndEditing()
            if didDismissEditor {
                suppressedInlineCommitKey = key
            } else if suppressedInlineCommitKey == key {
                suppressedInlineCommitKey = nil
            }
            return didDismissEditor
        }
        var didDismissEditor = view.endEditing(true)
        if !didDismissEditor {
            didDismissEditor = view.window?.endEditing(true) == true
        }
        if !didDismissEditor,
           let editorCell = visibleAttributeEditorCell(for: key) {
            didDismissEditor = editorCell.suppressNextCommitAndEndEditing()
        }
        if didDismissEditor {
            suppressedInlineCommitKey = key
        } else if suppressedInlineCommitKey == key {
            suppressedInlineCommitKey = nil
        }
        return didDismissEditor
    }

    @objc
    private func toggleSelectionMode() {
        inspector.requestSelectionModeToggle()
        updateNavigationControls()
    }

    @objc
    private func reloadDocument() {
        let inspector = inspector
        Task {
            try? await inspector.reloadDocument()
        }
    }

    @objc
    private func deleteNode() {
        let inspector = inspector
        let undoManager = undoManager
        Task {
            try? await inspector.deleteSelection(undoManager: undoManager)
        }
    }

    private func copySelectedHTML() {
        let inspector = inspector
        Task.immediateIfAvailable {
            do {
                let text = try await inspector.copySelectedHTML()
                guard !text.isEmpty else {
                    return
                }
                UIPasteboard.general.string = text
            } catch {
                return
            }
        }
    }

    private func copySelectedSelectorPath() {
        let inspector = inspector
        Task.immediateIfAvailable {
            do {
                let text = try await inspector.copySelectedSelectorPath()
                guard !text.isEmpty else {
                    return
                }
                UIPasteboard.general.string = text
            } catch {
                return
            }
        }
    }

    private func copySelectedXPath() {
        let inspector = inspector
        Task.immediateIfAvailable {
            do {
                let text = try await inspector.copySelectedXPath()
                guard !text.isEmpty else {
                    return
                }
                UIPasteboard.general.string = text
            } catch {
                return
            }
        }
    }
}

@MainActor
extension WIDOMDetailViewController: ElementAttributeEditorCellDelegate {
    fileprivate func elementAttributeEditorCellDidBeginEditing(
        _ cell: ElementAttributeEditorCell,
        key: ElementAttributeEditingKey,
        value: String
    ) {
        pendingInlineCommitMarker = nil
        pendingFocusRestoreKey = nil
        pendingFocusRestoreGeneration = nil
        pendingFocusRestoreFromModelUpdate = false
        if suppressedInlineCommitKey == key {
            suppressedInlineCommitKey = nil
        }
        editingAttributeKey = key
        beginAttributeDraftSessionIfNeeded(for: key, value: value)
        isInlineEditingActive = true
    }

    fileprivate func elementAttributeEditorCellDidChangeDraft(
        _ cell: ElementAttributeEditorCell,
        key: ElementAttributeEditingKey,
        value: String
    ) {
        editingAttributeKey = key
        updateAttributeDraftSession(for: key, value: value)
        refreshVisibleAttributeEditorsForSelectedNode()
    }

    fileprivate func elementAttributeEditorCellDidCommitValue(
        _ cell: ElementAttributeEditorCell,
        key: ElementAttributeEditingKey,
        value: String
    ) {
        if suppressedInlineCommitKey == key {
            suppressedInlineCommitKey = nil
            return
        }
        editingAttributeKey = key
        let previousValue = inspector.document.selectedNode?.attributes.first(where: { $0.name == key.name })?.value
        updateAttributeDraftSession(for: key, value: value)
        guard isAttributeDraftDirty(for: key) else {
            return
        }
        nextInlineCommitGeneration &+= 1
        let commitMarker = PendingInlineCommitMarker(
            key: key,
            generation: nextInlineCommitGeneration
        )
        pendingInlineCommitMarker = commitMarker
        let inspector = inspector
        let submittedValue = value
        Task {
            let didApply: Bool
            do {
                try await inspector.setAttribute(
                    nodeID: key.nodeID,
                    name: key.name,
                    value: submittedValue
                )
                didApply = true
            } catch {
                didApply = false
            }
            await MainActor.run {
                guard didApply else {
                    if self.pendingInlineCommitMarker == commitMarker {
                        self.pendingInlineCommitMarker = nil
                    }
                    let shouldRestoreDirtyDraft =
                        self.currentAttributeDraftSession(for: key)?.isDirty == true
                        && self.visibleAttributeEditorCell(for: key)?.isEditorFirstResponder != true
                    if shouldRestoreDirtyDraft {
                        self.pendingFocusRestoreKey = key
                        self.pendingFocusRestoreGeneration = commitMarker.generation
                        self.pendingFocusRestoreFromModelUpdate = true
                    } else if self.pendingFocusRestoreKey == key,
                              self.pendingFocusRestoreGeneration == commitMarker.generation {
                        self.pendingFocusRestoreKey = nil
                        self.pendingFocusRestoreGeneration = nil
                        self.pendingFocusRestoreFromModelUpdate = false
                    }
                    self.reconcileAttributeDraftSessionIfNeeded(allowTransientDeselection: false)
                    self.refreshVisibleAttributeEditorsForSelectedNode()
                    return
                }
                let resolvedSession = resolveInlineAttributeDraftSessionAfterSuccessfulSave(
                    currentSession: self.currentAttributeDraftSession(for: key),
                    key: .init(nodeID: key.nodeID, attributeName: key.name),
                    submittedValue: submittedValue,
                    previousValue: previousValue
                )
                self.attributeDraftSession = resolvedSession
                let shouldDeferFocusRestore =
                    (self.isInlineEditingActive && self.editingAttributeKey == key)
                    || self.visibleAttributeEditorCell(for: key)?.isEditorFirstResponder == true
                if resolvedSession?.isAwaitingModelEcho == true,
                   self.pendingInlineCommitMarker == commitMarker,
                   shouldDeferFocusRestore {
                    self.pendingFocusRestoreKey = key
                    self.pendingFocusRestoreGeneration = commitMarker.generation
                    self.pendingFocusRestoreFromModelUpdate = true
                } else if self.pendingFocusRestoreKey == key {
                    if self.pendingFocusRestoreGeneration == commitMarker.generation {
                        self.pendingFocusRestoreKey = nil
                        self.pendingFocusRestoreGeneration = nil
                        self.pendingFocusRestoreFromModelUpdate = false
                    }
                }
                if self.pendingInlineCommitMarker == commitMarker {
                    self.pendingInlineCommitMarker = nil
                }
                self.reconcileAttributeDraftSessionIfNeeded(allowTransientDeselection: false)
            }
        }
    }

    fileprivate func elementAttributeEditorCellDidEndEditing(
        _ cell: ElementAttributeEditorCell,
        key: ElementAttributeEditingKey,
        value: String
    ) {
        let suppressingInlineCommit = suppressedInlineCommitKey == key
        let currentDraftSession = currentAttributeDraftSession(for: key)
        let shouldKeepCleanSession = pendingFocusRestoreKey == key
        isInlineEditingActive = false
        if pendingFocusRestoreKey == key {
            if pendingFocusRestoreFromModelUpdate {
                pendingFocusRestoreFromModelUpdate = false
            } else {
                pendingFocusRestoreKey = nil
                pendingFocusRestoreGeneration = nil
            }
        }
        if suppressingInlineCommit {
            suppressedInlineCommitKey = nil
        }
        if editingAttributeKey == key {
            editingAttributeKey = nil
        }
        if let draftSession = currentDraftSession,
           !draftSession.isDirty,
           !shouldKeepCleanSession {
            attributeDraftSession = nil
        }
        finishInlineEditingEndWaiter(for: key)
        sections = makeSections()
        scheduleDeferredInlineEditingRefresh()
    }

    fileprivate func elementAttributeEditorCellNeedsRelayout(_ cell: ElementAttributeEditorCell) {
        requestAttributeEditorRelayout()
    }
}

private extension WIDOMDetailViewController {
    var currentSelectedNodeID: DOMNodeModel.ID? {
        inspector.document.selectedNode?.id
    }

    func currentAttributeDraftSession(
        for key: ElementAttributeEditingKey
    ) -> WIDOMAttributeDraftSession? {
        guard let attributeDraftSession,
              attributeDraftSession.key == .init(nodeID: key.nodeID, attributeName: key.name) else {
            return nil
        }
        return attributeDraftSession
    }

    func isAttributeDraftDirty(for key: ElementAttributeEditingKey) -> Bool {
        currentAttributeDraftSession(for: key)?.isDirty ?? false
    }

    func beginAttributeDraftSessionIfNeeded(for key: ElementAttributeEditingKey, value: String) {
        let sessionKey = WIDOMAttributeDraftKey(nodeID: key.nodeID, attributeName: key.name)
        if attributeDraftSession?.key == sessionKey {
            return
        }
        attributeDraftSession = .init(key: sessionKey, value: value)
    }

    func updateAttributeDraftSession(for key: ElementAttributeEditingKey, value: String) {
        let sessionKey = WIDOMAttributeDraftKey(nodeID: key.nodeID, attributeName: key.name)
        if attributeDraftSession?.key != sessionKey {
            attributeDraftSession = .init(key: sessionKey, value: value)
            return
        }
        guard var attributeDraftSession else {
            return
        }
        attributeDraftSession.userEditedDraft(value)
        self.attributeDraftSession = attributeDraftSession
    }

    func reconcileAttributeDraftSessionIfNeeded(allowTransientDeselection: Bool) {
        pendingInlineSelectionClearTask?.cancel()
        pendingInlineSelectionClearTask = nil

        guard var attributeDraftSession else {
            return
        }

        guard let selectedNode = inspector.document.selectedNode else {
            if allowTransientDeselection {
                pendingInlineSelectionClearTask = Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, !Task.isCancelled else {
                        return
                    }
                    self.pendingInlineSelectionClearTask = nil
                    self.reconcileAttributeDraftSessionIfNeeded(allowTransientDeselection: false)
                }
            } else {
                self.attributeDraftSession = nil
            }
            return
        }

        guard selectedNode.id == attributeDraftSession.key.nodeID else {
            pendingInlineCommitMarker = nil
            pendingFocusRestoreKey = nil
            pendingFocusRestoreGeneration = nil
            pendingFocusRestoreFromModelUpdate = false
            self.attributeDraftSession = nil
            return
        }

        let externalValue = selectedNode.attributes.first(where: { $0.name == attributeDraftSession.key.attributeName })?.value
        let reconcileResult = attributeDraftSession.applyObservedExternalValue(externalValue)
        switch reconcileResult {
        case .refreshClean:
            self.attributeDraftSession = attributeDraftSession
            pendingFocusRestoreKey = nil
            pendingFocusRestoreGeneration = nil
            pendingFocusRestoreFromModelUpdate = false
        case .preserveDirty:
            self.attributeDraftSession = attributeDraftSession
            let restoreKey = ElementAttributeEditingKey(
                nodeID: attributeDraftSession.key.nodeID,
                name: attributeDraftSession.key.attributeName
            )
            let existingRestoreKey = pendingFocusRestoreKey
            let existingRestoreGeneration = pendingFocusRestoreGeneration
            let wasRestoringFromModelUpdate = pendingFocusRestoreFromModelUpdate
            let editorCell = visibleAttributeEditorCell(for: restoreKey)
            let shouldRestoreFocus =
                (isInlineEditingActive && editingAttributeKey == restoreKey)
                || (pendingFocusRestoreKey == restoreKey && attributeDraftSession.isDirty)
            if let selectedEntry = inspector.document.selectedNode,
               let editorCell {
                editorCell.configure(
                    key: restoreKey,
                    name: restoreKey.name,
                    value: attributeDraftSession.draftValue,
                    entry: selectedEntry,
                    activateEditor: shouldRestoreFocus,
                    preserveFocusedText: shouldPreserveFocusedText(for: restoreKey)
                )
            }
            if shouldRestoreFocus {
                pendingFocusRestoreKey = restoreKey
                if let pendingInlineCommitMarker, pendingInlineCommitMarker.key == restoreKey {
                    pendingFocusRestoreGeneration = pendingInlineCommitMarker.generation
                } else if wasRestoringFromModelUpdate, existingRestoreKey == restoreKey {
                    pendingFocusRestoreGeneration = existingRestoreGeneration
                } else {
                    pendingFocusRestoreGeneration = nil
                }
                pendingFocusRestoreFromModelUpdate = true
            } else {
                pendingFocusRestoreKey = nil
                pendingFocusRestoreGeneration = nil
                pendingFocusRestoreFromModelUpdate = false
            }
        case .clear:
            pendingFocusRestoreKey = nil
            pendingFocusRestoreGeneration = nil
            pendingFocusRestoreFromModelUpdate = false
            self.attributeDraftSession = nil
        }
    }

    func attributeValue(for key: ElementAttributeEditingKey, in entry: DOMNodeModel? = nil) -> String? {
        let entry = entry ?? inspector.document.selectedNode
        guard let entry, entry.id == key.nodeID else {
            return nil
        }
        if let attributeDraftSession = currentAttributeDraftSession(for: key) {
            if let attribute = entry.attributes.first(where: { $0.name == key.name }) {
                _ = attribute
                return attributeDraftSession.draftValue
            }
            return attributeDraftSession.isDirty ? attributeDraftSession.draftValue : nil
        }
        return entry.attributes.first(where: { $0.name == key.name })?.value
    }

    func shouldActivateEditor(for key: ElementAttributeEditingKey) -> Bool {
        (isInlineEditingActive && editingAttributeKey == key) || pendingFocusRestoreKey == key
    }

    func shouldPreserveFocusedText(for key: ElementAttributeEditingKey) -> Bool {
        currentAttributeDraftSession(for: key)?.isDirty == true
    }

    func refreshVisibleAttributeEditorsForSelectedNode() {
        guard let selectedEntry = inspector.document.selectedNode else {
            return
        }

        for visibleCell in collectionView.visibleCells {
            guard let editorCell = visibleCell as? ElementAttributeEditorCell,
                  let key = editorCell.currentEditingKey,
                  key.nodeID == selectedEntry.id else {
                continue
            }
            editorCell.configure(
                key: key,
                name: key.name,
                value: attributeValue(for: key, in: selectedEntry) ?? "",
                entry: selectedEntry,
                activateEditor: shouldActivateEditor(for: key),
                preserveFocusedText: shouldPreserveFocusedText(for: key)
            )
        }
    }
}

private final class DOMObservingListCell: UICollectionViewListCell {
    private var observationHandles: Set<ObservationHandle> = []
    private var stableID: WIDOMDetailViewController.ItemStableID?
    private var payloadProvider: (@MainActor (WIDOMDetailViewController.ItemStableID) -> WIDOMDetailViewController.ItemPayload?)?

    override func prepareForReuse() {
        super.prepareForReuse()
        observationHandles.removeAll()
        stableID = nil
        payloadProvider = nil
    }

    func configure(
        stableID: WIDOMDetailViewController.ItemStableID,
        entry: DOMNodeModel?,
        payloadProvider: @escaping @MainActor (WIDOMDetailViewController.ItemStableID) -> WIDOMDetailViewController.ItemPayload?
    ) {
        observationHandles.removeAll()
        self.stableID = stableID
        self.payloadProvider = payloadProvider
        applyCurrentPayload()

        guard let entry else {
            return
        }
        startObserving(entry: entry, stableID: stableID)
    }

    private func startObserving(entry: DOMNodeModel, stableID: WIDOMDetailViewController.ItemStableID) {
        switch stableID.key {
        case .element:
            entry.observe(
                [\.preview, \.nodeType, \.nodeName, \.localName, \.nodeValue, \.attributes],
                onChange: { [weak self] in
                    self?.applyCurrentPayload()
                },
                isolation: MainActor.shared
            )
            .store(in: &observationHandles)
        case .selector:
            entry.observe(
                \.selectorPath,
                onChange: { [weak self] _ in
                    self?.applyCurrentPayload()
                },
                isolation: MainActor.shared
            )
            .store(in: &observationHandles)
        case .emptyAttribute:
            entry.observe(
                \.attributes,
                onChange: { [weak self] _ in
                    self?.applyCurrentPayload()
                },
                isolation: MainActor.shared
            )
            .store(in: &observationHandles)
        case .attribute:
            break
        }
    }

    private func applyCurrentPayload() {
        guard
            let stableID,
            let payload = payloadProvider?(stableID)
        else {
            contentConfiguration = nil
            accessories = []
            return
        }

        var configuration = UIListContentConfiguration.cell()
        accessories = []

        switch payload {
        case let .element(preview):
            configuration.text = preview
            configuration.textProperties.numberOfLines = 0
            configuration.textProperties.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
                for: .monospacedSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                    weight: .regular
                )
            )
            configuration.textProperties.color = .label
        case let .selector(path):
            configuration.text = path
            configuration.textProperties.numberOfLines = 0
            configuration.textProperties.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
                for: .monospacedSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                    weight: .regular
                )
            )
            configuration.textProperties.color = .label
        case .emptyAttribute:
            configuration.text = wiLocalized("dom.element.attributes.empty")
            configuration.textProperties.color = .secondaryLabel
        case .attribute:
            return
        }
        contentConfiguration = configuration
    }
}

#if DEBUG
extension WIDOMDetailViewController {
    func inlineDraftPhaseForTesting(
        nodeID: DOMNodeModel.ID,
        name: String
    ) -> WIDOMAttributeDraftPhase? {
        currentAttributeDraftSession(
            for: .init(nodeID: nodeID, name: name)
        )?.phase
    }

    func inlineDraftSessionForTesting(
        nodeID: DOMNodeModel.ID,
        name: String
    ) -> WIDOMAttributeDraftSession? {
        currentAttributeDraftSession(
            for: .init(nodeID: nodeID, name: name)
        )
    }

    func inlineDisplayedAttributeValueForTesting(
        nodeID: DOMNodeModel.ID,
        name: String
    ) -> String? {
        attributeValue(for: .init(nodeID: nodeID, name: name))
    }

    func hasPendingInlineCommitForTesting(
        nodeID: DOMNodeModel.ID,
        name: String
    ) -> Bool {
        pendingInlineCommitMarker?.key == .init(nodeID: nodeID, name: name)
    }

    func nextInlineCommitGenerationForTesting() -> UInt64 {
        nextInlineCommitGeneration
    }

    func applyInlineDraftForTesting(
        nodeID: DOMNodeModel.ID,
        name: String,
        value: String
    ) {
        let key = ElementAttributeEditingKey(nodeID: nodeID, name: name)
        editingAttributeKey = key
        updateAttributeDraftSession(for: key, value: value)
        refreshVisibleAttributeEditorsForSelectedNode()
    }

    func installInlineDraftSessionForTesting(
        nodeID: DOMNodeModel.ID,
        name: String,
        baselineValue: String,
        draftValue: String
    ) {
        let key = WIDOMAttributeDraftKey(nodeID: nodeID, attributeName: name)
        var session = WIDOMAttributeDraftSession(key: key, value: baselineValue)
        session.userEditedDraft(draftValue)
        attributeDraftSession = session
        refreshVisibleAttributeEditorsForSelectedNode()
    }

    func installStaleInlineEditingStateForTesting(nodeID: DOMNodeModel.ID, name: String) {
        editingAttributeKey = ElementAttributeEditingKey(nodeID: nodeID, name: name)
        isInlineEditingActive = true
    }

    func discardInlineEditingStateUsingViewFallbackForTesting() {
        guard let editingAttributeKey else {
            return
        }
        let cachedEditingKey = editingAttributeKey
        let endEditingWaiter = installInlineEditingEndWaiter(for: cachedEditingKey)
        pendingForcedProjectionRefresh = true
        var didRequestEndEditing = suppressInlineCommitAndEndEditing(
            for: cachedEditingKey,
            forceViewFallback: true
        )
        if let editorCell = visibleAttributeEditorCell(for: cachedEditingKey) {
            didRequestEndEditing = editorCell.suppressNextCommitAndEndEditing() || didRequestEndEditing
            if didRequestEndEditing {
                suppressedInlineCommitKey = cachedEditingKey
            }
        }
        attributeDraftSession = nil
        guard didRequestEndEditing else {
            pendingInlineEditingEndWaiters.removeValue(forKey: cachedEditingKey)
            endEditingWaiter.finish()
            finishDiscardInlineEditingStateUsingViewFallback(for: cachedEditingKey)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.waitForInlineEditingEnd(for: cachedEditingKey)
            self.finishDiscardInlineEditingStateUsingViewFallback(for: cachedEditingKey)
        }
    }

    private func installInlineEditingEndWaiter(
        for key: ElementAttributeEditingKey
    ) -> InlineEditingEndWaiter {
        if let existing = pendingInlineEditingEndWaiters[key] {
            return existing
        }

        let waiter = InlineEditingEndWaiter()
        pendingInlineEditingEndWaiters[key] = waiter
        return waiter
    }

    private func finishInlineEditingEndWaiter(for key: ElementAttributeEditingKey) {
        pendingInlineEditingEndWaiters.removeValue(forKey: key)?.finish()
    }

    private func waitForInlineEditingEnd(for key: ElementAttributeEditingKey) async {
        guard let waiter = pendingInlineEditingEndWaiters[key] else {
            return
        }
        await waiter.wait()
    }

    private func finishDiscardInlineEditingStateUsingViewFallback(
        for cachedEditingKey: ElementAttributeEditingKey
    ) {
        pendingInlineEditingRefreshTask?.cancel()
        pendingInlineEditingRefreshTask = nil
        clearInlineEditingState()
        suppressedInlineCommitKey = cachedEditingKey
        pendingFocusRestoreKey = nil
        pendingFocusRestoreFromModelUpdate = false
        if let liveValue = attributeValue(for: cachedEditingKey),
           let selectedEntry = inspector.document.selectedNode,
           let editorCell = visibleAttributeEditorCell(for: cachedEditingKey)
        {
            editorCell.configure(
                key: cachedEditingKey,
                name: cachedEditingKey.name,
                value: liveValue,
                entry: selectedEntry,
                activateEditor: false,
                preserveFocusedText: false
            )
            _ = editorCell.suppressNextCommitAndEndEditing()
        }
        pendingForcedProjectionRefresh = false
        collectionView?.layoutIfNeeded()
    }
}
#endif

private final class ElementAttributeEditorCell: UICollectionViewListCell, UITextViewDelegate {
    weak var delegate: ElementAttributeEditorCellDelegate?

    private let nameLabel = UILabel()
    private let valueTextView = UITextView()
    private let stackView = UIStackView()

    private var valueHeightConstraint: NSLayoutConstraint?
    private var editingKey: ElementAttributeEditingKey?
    private var debounceTask: Task<Void, Never>?
    private var isApplyingValue = false
    private var suppressNextCommit = false
    private lazy var keyboardAccessoryToolbar = ElementKeyboardAccessoryToolbar(onClose: { [weak self] in
        guard let self else {
            return
        }
        self.valueTextView.resignFirstResponder()
    })

    var currentEditingKey: ElementAttributeEditingKey? {
        editingKey
    }

    var isEditorFirstResponder: Bool {
        valueTextView.isFirstResponder
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        debounceTask?.cancel()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if valueTextView.isFirstResponder {
            valueTextView.resignFirstResponder()
        }
        suppressNextCommit = false
        debounceTask?.cancel()
        debounceTask = nil
        editingKey = nil
    }

    func configure(
        key: ElementAttributeEditingKey,
        name: String,
        value: String,
        entry: DOMNodeModel?,
        activateEditor: Bool,
        preserveFocusedText: Bool
    ) {
        editingKey = key
        nameLabel.text = name

        if !(valueTextView.isFirstResponder && preserveFocusedText), valueTextView.text != value {
            isApplyingValue = true
            valueTextView.text = value
            isApplyingValue = false
        }

        updateTextViewHeightIfNeeded()

        if activateEditor, !valueTextView.isFirstResponder {
            valueTextView.becomeFirstResponder()
        }
    }

    @discardableResult
    func suppressNextCommitAndEndEditing() -> Bool {
        guard valueTextView.isFirstResponder else {
            return false
        }
        suppressNextCommit = true
        debounceTask?.cancel()
        debounceTask = nil
        if valueTextView.isFirstResponder {
            _ = valueTextView.resignFirstResponder()
        }
        if valueTextView.isFirstResponder {
            _ = contentView.endEditing(true)
        }
        if valueTextView.isFirstResponder {
            _ = window?.endEditing(true)
        }
        return true
    }

    func activateEditorIfNeeded() {
        guard !valueTextView.isFirstResponder else {
            return
        }
        valueTextView.becomeFirstResponder()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateTextViewHeightIfNeeded()
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
        setNeedsLayout()
        layoutIfNeeded()
        let targetSize = CGSize(width: attributes.size.width, height: UIView.layoutFittingCompressedSize.height)
        let fittedSize = contentView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        attributes.size.height = ceil(fittedSize.height)
        return attributes
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        guard let editingKey else {
            return
        }
        delegate?.elementAttributeEditorCellDidBeginEditing(self, key: editingKey, value: textView.text ?? "")
    }

    func textViewDidChange(_ textView: UITextView) {
        guard
            !isApplyingValue,
            let editingKey
        else {
            return
        }

        let value = textView.text ?? ""
        updateTextViewHeightIfNeeded(notifyDelegate: true)
        delegate?.elementAttributeEditorCellDidChangeDraft(self, key: editingKey, value: value)

        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard
                let self,
                !Task.isCancelled,
                let currentKey = self.editingKey,
                currentKey == editingKey
            else {
                return
            }
            self.delegate?.elementAttributeEditorCellDidCommitValue(self, key: currentKey, value: self.valueTextView.text ?? "")
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        debounceTask?.cancel()
        guard let editingKey else {
            return
        }
        let value = textView.text ?? ""
        if suppressNextCommit {
            suppressNextCommit = false
            delegate?.elementAttributeEditorCellDidEndEditing(self, key: editingKey, value: value)
            return
        }
        delegate?.elementAttributeEditorCellDidCommitValue(self, key: editingKey, value: value)
        delegate?.elementAttributeEditorCellDidEndEditing(self, key: editingKey, value: value)
    }

    private func setupViews() {
        preservesSuperviewLayoutMargins = true
        contentView.preservesSuperviewLayoutMargins = true

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.numberOfLines = 1
        nameLabel.textColor = .secondaryLabel
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        nameLabel.setContentHuggingPriority(.required, for: .vertical)
        nameLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                weight: .semibold
            )
        )

        valueTextView.translatesAutoresizingMaskIntoConstraints = false
        valueTextView.delegate = self
        valueTextView.isEditable = true
        valueTextView.isSelectable = true
        valueTextView.isScrollEnabled = false
        valueTextView.backgroundColor = .clear
        valueTextView.textContainerInset = .zero
        valueTextView.textContainer.lineFragmentPadding = 0
        valueTextView.adjustsFontForContentSizeCategory = true
        valueTextView.textColor = .label
        valueTextView.autocapitalizationType = .none
        valueTextView.autocorrectionType = .no
        valueTextView.smartDashesType = .no
        valueTextView.smartQuotesType = .no
        valueTextView.spellCheckingType = .no
        valueTextView.inputAccessoryView = keyboardAccessoryToolbar
        valueTextView.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                weight: .regular
            )
        )
        valueTextView.setContentCompressionResistancePriority(.required, for: .vertical)
        valueTextView.setContentHuggingPriority(.required, for: .vertical)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 6
        stackView.addArrangedSubview(nameLabel)
        stackView.addArrangedSubview(valueTextView)
        contentView.addSubview(stackView)

        let valueHeightConstraint = valueTextView.heightAnchor.constraint(equalToConstant: ceil(UIFont.preferredFont(forTextStyle: .footnote).lineHeight))
        // The collection view may apply a transient encapsulated height during list updates.
        // Keep the editor height strong enough for self-sizing, but allow that transient pass.
        valueHeightConstraint.priority = UILayoutPriority(999)
        self.valueHeightConstraint = valueHeightConstraint

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            valueHeightConstraint
        ])
    }

    private func updateTextViewHeightIfNeeded(notifyDelegate: Bool = false) {
        guard let valueHeightConstraint else {
            return
        }
        let width = valueTextView.bounds.width
        guard width > 0 else {
            return
        }
        let fittingSize = valueTextView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        let minLineHeight = valueTextView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .footnote).lineHeight
        let targetHeight = max(ceil(minLineHeight), ceil(fittingSize.height))
        if abs(valueHeightConstraint.constant - targetHeight) < 0.5 {
            return
        }
        valueHeightConstraint.constant = targetHeight
        guard notifyDelegate else {
            return
        }
        delegate?.elementAttributeEditorCellNeedsRelayout(self)
    }
}

final class ElementKeyboardAccessoryToolbar: UIToolbar {
    private let onClose: () -> Void
    private var hostingVC: UIViewController?

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(frame: .zero)

        isTranslucent = true

        let swiftUIView = KeyboardToolbarView(onClose: { [weak self] in
            self?.onClose()
        })
        let hostingVC = UIHostingController(rootView: swiftUIView)
        hostingVC.view.backgroundColor = .clear

        self.hostingVC = hostingVC
        let customButton = UIBarButtonItem(customView: hostingVC.view)
        if #available(iOS 26.0, *) {
            customButton.hidesSharedBackground = false
            customButton.sharesBackground = true
        }
        setItems([customButton], animated: false)
        sizeToFit()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct KeyboardToolbarView: View {
    let onClose: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "chevron.down")
                    .frame(maxHeight: .infinity)
            }
            .foregroundStyle(.secondary)
            .containerShape(.capsule)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .background(.clear)
            .tint(.clear)
            .clipShape(.capsule)
        }
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("DOM Detail Empty (UIKit)") {
    WIUIKitPreviewContainer {
        UINavigationController(
            rootViewController: WIDOMDetailViewController(
                inspector: WIDOMPreviewFixtures.makeInspector(mode: .empty)
            )
        )
    }
}

#Preview("DOM Detail Selected (UIKit)") {
    WIUIKitPreviewContainer {
        UINavigationController(
            rootViewController: WIDOMDetailViewController(
                inspector: WIDOMPreviewFixtures.makeInspector(mode: .selected)
            )
        )
    }
}

#Preview("DOM Detail Editable Attributes (UIKit)") {
    WIUIKitPreviewContainer {
        UINavigationController(
            rootViewController: WIDOMDetailViewController(
                inspector: WIDOMPreviewFixtures.makeInspector(mode: .selectedEditableAttributes)
            )
        )
    }
}
#endif

#endif
